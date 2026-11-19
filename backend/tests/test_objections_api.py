from datetime import datetime, timezone
import time

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.auth import users
from app.auth.security import create_access_token
from app.chain import ChainUnavailable, FakeChainClient, fake_signature, get_chain_client
from app.database import Base, get_db
from app.main import app
from app.models import (
    Entry as DBEntry,
    Objection as DBObjection,
    Term as DBTerm,
    User as DBUser,
)
from app.schemas.auth import Role
from app.services.student_wallet import student_address
from app.utils.hashing import canonical_text, text_hash

client = TestClient(app)

AUDITOR_WALLET = "0x90F79bf6EB2c4f870365E785982E1f101E93b906"
PRESIDENT_WALLET = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

_test_session_factory = None
_test_chain: FakeChainClient = FakeChainClient()


@pytest.fixture(autouse=True)
def setup_objection_db(tmp_path, monkeypatch):
    global _test_session_factory, _test_chain
    monkeypatch.setenv(
        "STUDENT_WALLET_MNEMONIC",
        "test test test test test test test test test test test junk",
    )
    _test_chain = FakeChainClient()
    db_file = tmp_path / "objections_test.db"
    engine = create_engine(
        f"sqlite:///{db_file}",
        connect_args={"check_same_thread": False},
    )
    Base.metadata.create_all(bind=engine)
    TestingSession = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    _test_session_factory = TestingSession

    with TestingSession() as db:
        for u in users.SEED_USERS:
            db.add(
                DBUser(
                    id=u.id,
                    student_no=u.student_no,
                    password_hash=u.password_hash,
                    name=u.name,
                    role=u.role.value if hasattr(u.role, "value") else u.role,
                    wallet_index=u.wallet_index,
                    wallet_address=u.wallet_address.lower() if u.wallet_address else None,
                )
            )
        db.add(
            DBTerm(
                id=1,
                term_code=20262,
                name="2026-2학기",
                started_at=datetime.fromtimestamp(1788220800, tz=timezone.utc),
                ended_at=datetime.fromtimestamp(1803772800, tz=timezone.utc),
            )
        )
        db.add(
            DBEntry(
                id=1,
                term_id=1,
                kind="EXPENSE",
                amount=35000,
                counterparty="한결문구",
                purpose="명찰 구매",
                budget_id=None,
                occurred_at=1788793200,
                meta_hash="0x" + "11" * 32,
                hash_version=1,
                status="CONFIRMED",
                created_by=2,
                approved_by=3,
                tx_pending="0x" + "aa" * 32,
                tx_confirm="0x" + "bb" * 32,
            )
        )
        db.add(
            DBEntry(
                id=2,
                term_id=1,
                kind="EXPENSE",
                amount=12000,
                counterparty="카페",
                purpose="회의 다과",
                budget_id=None,
                occurred_at=1788793200,
                meta_hash="0x" + "22" * 32,
                hash_version=1,
                status="PENDING",
                created_by=2,
                tx_pending="0x" + "cc" * 32,
            )
        )
        db.add(
            DBEntry(
                id=3,
                term_id=1,
                kind="EXPENSE",
                amount=15000,
                counterparty="반려상점",
                purpose="반려 항목",
                budget_id=None,
                occurred_at=1788793200,
                meta_hash="0x" + "33" * 32,
                hash_version=1,
                status="REJECTED",
                created_by=2,
                rejected_by=3,
                reject_reason="영수증 누락",
                tx_pending="0x" + "dd" * 32,
                tx_confirm="0x" + "ee" * 32,
            )
        )
        db.commit()

    def override_get_db():
        s = TestingSession()
        try:
            yield s
        finally:
            s.close()

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_chain_client] = lambda: _test_chain
    yield
    app.dependency_overrides.clear()
    _test_session_factory = None


def _auth(role: Role) -> dict:
    u = next(item for item in users.SEED_USERS if item.role == role)
    token = create_access_token(u.id)
    return {"Authorization": f"Bearer {token}"}


def _grant_student_sbt(term_code: int = 20262):
    student = next(item for item in users.SEED_USERS if item.role == Role.STUDENT)
    _test_chain.grant_membership(student_address(student.wallet_index), term_code)


def test_raise_list_and_answer_objection_flow():
    """학생 이의 제기 -> 목록/미답변 조회 -> 임원 답변 준비 및 기기 서명 제출 전체 흐름."""
    _grant_student_sbt()

    # 1. 제기 전 미답변 건수 0
    assert client.get("/objections/open-count").json() == {"count": 0}

    # 2. 학생이 CRLF + 앞뒤 공백 포함 원문으로 이의 제기 -> 정본화 후 온체인 raise
    res_raise = client.post(
        "/objections",
        json={"entry_id": 1, "content": "  영수증 미첨부 사유가 궁금합니다\r\n감사합니다  "},
        headers=_auth(Role.STUDENT),
    )
    assert res_raise.status_code == 201
    created = res_raise.json()
    assert created["entry_id"] == 1
    assert created["status"] == "OPEN"
    assert created["content"] == "영수증 미첨부 사유가 궁금합니다\n감사합니다"
    assert isinstance(created["raised_at"], int) and created["raised_at"] > 0
    assert created["tx_raise"].startswith("0x")
    assert created["tx_answer"] is None

    # 3. 목록 조회 및 미답변 건수 확인
    assert client.get("/objections/open-count").json() == {"count": 1}
    listed = client.get("/objections?entry_id=1").json()
    assert len(listed) == 1
    assert listed[0]["id"] == created["id"]

    # 4. 임원 답변 준비(prepare-answer)
    answer_raw = "  행사 당일 간이 영수증 재발급 후 보완했습니다.\r\n확인 부탁드립니다.  "
    res_prep = client.post(
        f"/objections/{created['id']}/prepare-answer",
        json={"answer": answer_raw},
        headers=_auth(Role.AUDITOR),
    )
    assert res_prep.status_code == 200
    prep = res_prep.json()
    assert prep["objection_id"] == created["id"]
    assert prep["answer_hash"] == text_hash(canonical_text(answer_raw))

    # 5. 임원 답변 서명 제출(answer)
    res_ans = client.post(
        f"/objections/{created['id']}/answer",
        json={
            "answer": answer_raw,
            "answer_hash": prep["answer_hash"],
            "deadline": prep["deadline"],
            "signature": fake_signature(AUDITOR_WALLET),
        },
        headers=_auth(Role.AUDITOR),
    )
    assert res_ans.status_code == 200
    answered = res_ans.json()
    assert answered["status"] == "ANSWERED"
    assert answered["answer"] == canonical_text(answer_raw)
    assert answered["tx_answer"].startswith("0x")
    assert client.get("/objections/open-count").json() == {"count": 0}

    # 6. 중복 답변 시 409 Conflict
    res_dup = client.post(
        f"/objections/{created['id']}/answer",
        json={
            "answer": answer_raw,
            "answer_hash": prep["answer_hash"],
            "deadline": prep["deadline"],
            "signature": fake_signature(AUDITOR_WALLET),
        },
        headers=_auth(Role.PRESIDENT),
    )
    assert res_dup.status_code == 409


def test_raise_objection_requires_sbt_and_fails_closed(monkeypatch):
    """SBT 미보유 시 403, 체인 조회 불가 시 503(fail-closed)으로 차단된다."""
    # 1. SBT 미보유 -> 403
    res_no_sbt = client.post(
        "/objections",
        json={"entry_id": 1, "content": "SBT 없음 테스트"},
        headers=_auth(Role.STUDENT),
    )
    assert res_no_sbt.status_code == 403

    # 2. 체인 조회 불가 -> 503 fail-closed
    async def broken_membership(account: str, term: int):
        raise ChainUnavailable("노드 연결 실패")

    monkeypatch.setattr(_test_chain, "has_valid_membership", broken_membership)
    res_unavail = client.post(
        "/objections",
        json={"entry_id": 1, "content": "체인 불통 테스트"},
        headers=_auth(Role.STUDENT),
    )
    assert res_unavail.status_code == 503


def test_raise_and_answer_validation_and_role_guards():
    """PRD v0.17 §4.5: 확정(CONFIRMED)·대기 중(PENDING) 항목은 허용하고, 반려(REJECTED)·제어문자·빈 답변·잘못된 권한을 차단한다."""
    _grant_student_sbt()

    # 1. 대기 중(PENDING) 항목에 이의 제기 -> 201 허용, 반려(REJECTED) 항목 -> 400 차단
    res_pending = client.post(
        "/objections",
        json={"entry_id": 2, "content": "대기 항목 문의"},
        headers=_auth(Role.STUDENT),
    )
    assert res_pending.status_code == 201

    res_rejected = client.post(
        "/objections",
        json={"entry_id": 3, "content": "반려 항목 문의"},
        headers=_auth(Role.STUDENT),
    )
    assert res_rejected.status_code == 400

    # 2. 제어문자 포함 본문 -> 400
    res_ctrl = client.post(
        "/objections",
        json={"entry_id": 1, "content": "제어문자\u200b포함"},
        headers=_auth(Role.STUDENT),
    )
    assert res_ctrl.status_code == 400

    # 3. 총무(임원)는 이의 제기 불가 -> 403
    res_role = client.post(
        "/objections",
        json={"entry_id": 1, "content": "총무 호출"},
        headers=_auth(Role.TREASURER),
    )
    assert res_role.status_code == 403

    # 4. 정상 제기 후 빈/공백 답변 차단 및 총무 답변 차단
    created = client.post(
        "/objections",
        json={"entry_id": 1, "content": "정상 질문"},
        headers=_auth(Role.STUDENT),
    ).json()

    res_blank = client.post(
        f"/objections/{created['id']}/prepare-answer",
        json={"answer": "   \n\t  "},
        headers=_auth(Role.AUDITOR),
    )
    assert res_blank.status_code == 400

    res_treasurer_ans = client.post(
        f"/objections/{created['id']}/prepare-answer",
        json={"answer": "총무 답변 시도"},
        headers=_auth(Role.TREASURER),
    )
    assert res_treasurer_ans.status_code == 403


def test_raise_objection_recovers_after_chain_unavailable(monkeypatch):
    """전송 후 ChainUnavailable 발생 시(landed=True/False) 질문 본문과 ID를 보존하고 재요청 시 복구한다."""
    _grant_student_sbt()

    # 1. landed=True + 첫 get_objection 도 실패하여 503이 난 뒤 재시도 시 동일 ID/본문으로 복구
    _test_chain.unavailable_next("raise_objection", landed=True, sent=True)
    orig_get = _test_chain.get_objection
    calls = {"n": 0}

    async def flaky_get(oid: int):
        calls["n"] += 1
        if calls["n"] == 1:
            raise ChainUnavailable("조회 일시 실패")
        return await orig_get(oid)

    monkeypatch.setattr(_test_chain, "get_objection", flaky_get)

    res1 = client.post(
        "/objections",
        json={"entry_id": 1, "content": "응답 유실 복구 질문"},
        headers=_auth(Role.STUDENT),
    )
    assert res1.status_code == 503
    assert client.get("/objections").json() == []

    # 재요청 시 체인에 이미 들어간 기존 ID(1)를 복구하여 201 반환
    res2 = client.post(
        "/objections",
        json={"entry_id": 1, "content": "응답 유실 복구 질문"},
        headers=_auth(Role.STUDENT),
    )
    assert res2.status_code == 201
    data2 = res2.json()
    assert data2["id"] == 1
    assert data2["content"] == "응답 유실 복구 질문"
    assert data2["tx_raise"].startswith("0x")
    assert len(client.get("/objections").json()) == 1

    # 2. landed=False(채굴 대기 중) 시 503 반환 후 같은 질문 재요청은 중복 전송을 막기 위해 409 차단
    _test_chain.unavailable_next("raise_objection", landed=False, sent=True)
    res3 = client.post(
        "/objections",
        json={"entry_id": 1, "content": "미안착 재전송 질문"},
        headers=_auth(Role.STUDENT),
    )
    assert res3.status_code == 503
    assert len(client.get("/objections").json()) == 1

    res4 = client.post(
        "/objections",
        json={"entry_id": 1, "content": "미안착 재전송 질문"},
        headers=_auth(Role.STUDENT),
    )
    assert res4.status_code == 409
    assert len(client.get("/objections").json()) == 1


def test_answer_objection_recovers_after_chain_unavailable(monkeypatch):
    """답변 전송 후 ChainUnavailable 발생 시(landed=True/False) 미확정 전송 덮어쓰기를 차단하고 채굴 시 복구한다."""
    _grant_student_sbt()
    created1 = client.post(
        "/objections",
        json={"entry_id": 1, "content": "답변 미채굴 테스트 질문"},
        headers=_auth(Role.STUDENT),
    ).json()
    oid1 = created1["id"]

    prep1 = client.post(
        f"/objections/{oid1}/prepare-answer",
        json={"answer": "첫 번째 답변"},
        headers=_auth(Role.AUDITOR),
    ).json()

    # 1. landed=False(채굴 대기 중) -> 503 후 미확정 답변이 덮어씌워지지 않도록 409 차단
    _test_chain.unavailable_next("answer_objection", landed=False, sent=True)
    res_unlanded = client.post(
        f"/objections/{oid1}/answer",
        json={
            "answer": "첫 번째 답변",
            "answer_hash": prep1["answer_hash"],
            "deadline": prep1["deadline"],
            "signature": fake_signature(AUDITOR_WALLET),
        },
        headers=_auth(Role.AUDITOR),
    )
    assert res_unlanded.status_code == 503

    assert (
        client.post(
            f"/objections/{oid1}/prepare-answer",
            json={"answer": "다른 답변 시도"},
            headers=_auth(Role.AUDITOR),
        ).status_code
        == 409
    )

    # 2. 별도 이의(oid2)에서 landed=True + 첫 get_objection 도 실패 -> 503 후 재요청 시 본문·답변자·tx_answer 복구
    created2 = client.post(
        "/objections",
        json={"entry_id": 1, "content": "답변 복구 테스트 질문"},
        headers=_auth(Role.STUDENT),
    ).json()
    oid = created2["id"]
    prep2 = client.post(
        f"/objections/{oid}/prepare-answer",
        json={"answer": "최종 복구 답변"},
        headers=_auth(Role.AUDITOR),
    ).json()

    _test_chain.unavailable_next("answer_objection", landed=True, sent=True)
    orig_get = _test_chain.get_objection
    calls = {"n": 0}

    async def flaky_get(target_id: int):
        calls["n"] += 1
        if calls["n"] == 1:
            raise ChainUnavailable("조회 일시 실패")
        return await orig_get(target_id)

    monkeypatch.setattr(_test_chain, "get_objection", flaky_get)

    res_landed_503 = client.post(
        f"/objections/{oid}/answer",
        json={
            "answer": "최종 복구 답변",
            "answer_hash": prep2["answer_hash"],
            "deadline": prep2["deadline"],
            "signature": fake_signature(AUDITOR_WALLET),
        },
        headers=_auth(Role.AUDITOR),
    )
    assert res_landed_503.status_code == 503

    res_recovered = client.post(
        f"/objections/{oid}/answer",
        json={
            "answer": "최종 복구 답변",
            "answer_hash": prep2["answer_hash"],
            "deadline": prep2["deadline"],
            "signature": fake_signature(AUDITOR_WALLET),
        },
        headers=_auth(Role.AUDITOR),
    )
    assert res_recovered.status_code == 200
    body = res_recovered.json()
    assert body["status"] == "ANSWERED"
    assert body["answer"] == "최종 복구 답변"
    assert body["answered_by"] is not None
    assert body["tx_answer"].startswith("0x")


def test_get_objection_by_id_and_student_jwt_secret_split(monkeypatch):
    """GET /objections/{id} 단건 조회 및 STUDENT_JWT_SECRET 분리 시 POST /objections 전용 학생 토큰 검증(PRD v0.17 §9.1)."""
    import jwt as pyjwt
    from datetime import timedelta

    _grant_student_sbt()
    monkeypatch.setenv("STUDENT_JWT_SECRET", "student-only-separate-secret-key")

    student = next(u for u in users.SEED_USERS if u.role == Role.STUDENT)
    auditor = next(u for u in users.SEED_USERS if u.role == Role.AUDITOR)
    now = datetime.now(timezone.utc)

    student_token = pyjwt.encode(
        {"sub": str(student.id), "iat": now, "exp": now + timedelta(hours=1)},
        "student-only-separate-secret-key",
        algorithm="HS256",
    )
    auditor_forged_with_student_key = pyjwt.encode(
        {"sub": str(auditor.id), "iat": now, "exp": now + timedelta(hours=1)},
        "student-only-separate-secret-key",
        algorithm="HS256",
    )

    # 1. STUDENT_JWT_SECRET 로 서명된 학생 토큰은 POST /objections 통과 -> 201
    res_raise = client.post(
        "/objections",
        json={"entry_id": 1, "content": "분리 키 이의 제기"},
        headers={"Authorization": f"Bearer {student_token}"},
    )
    assert res_raise.status_code == 201
    oid = res_raise.json()["id"]

    # 2. 단건 상세 조회 GET /objections/{id} -> 200, 미존재 -> 404
    res_detail = client.get(f"/objections/{oid}")
    assert res_detail.status_code == 200
    assert res_detail.json()["content"] == "분리 키 이의 제기"
    assert client.get("/objections/99999").status_code == 404

    # 3. STUDENT_JWT_SECRET 로 임원 ID를 서명해도 POST /objections 는 403 거부
    res_officer_student_key = client.post(
        "/objections",
        json={"entry_id": 1, "content": "임원 위장 시도"},
        headers={"Authorization": f"Bearer {auditor_forged_with_student_key}"},
    )
    assert res_officer_student_key.status_code == 403

    # 4. STUDENT_JWT_SECRET 로 서명된 토큰은 다른 경로(GET /auth/me, prepare-answer)에서 401 거부
    assert client.get("/auth/me", headers={"Authorization": f"Bearer {student_token}"}).status_code == 401
    assert (
        client.post(
            f"/objections/{oid}/prepare-answer",
            json={"answer": "권한 우회 시도"},
            headers={"Authorization": f"Bearer {auditor_forged_with_student_key}"},
        ).status_code
        == 401
    )


def test_unmined_then_retry_then_late_mined_preserves_question_and_answer():
    """Codex 2차 회귀: 미확정(채굴 대기) 상태에서 다른 요청/재요청이 들어온 뒤 원래 전송이 뒤늦게 채굴되어도 질문·답변 본문이 보존된다."""
    from app.chain.models import OnChainObjection, ZERO_ADDRESS, ZERO_BYTES32

    _grant_student_sbt()
    student = next(u for u in users.SEED_USERS if u.role == Role.STUDENT)
    raiser_addr = student_address(student.wallet_index)

    # 1) 질문 A 전송 중 타임아웃(채굴 대기: landed=False) -> id=1 채번 및 '?...' 보존
    _test_chain.unavailable_next("raise_objection", landed=False, sent=True)
    res_q1 = client.post(
        "/objections",
        json={"entry_id": 1, "content": "원래 채굴 대기 질문 A"},
        headers=_auth(Role.STUDENT),
    )
    assert res_q1.status_code == 503

    # 2) 아직 질문 A가 미채굴인 상태에서 질문 B를 새로 요청 -> id=1을 덮어쓰지 않고 id=2로 등록
    res_q2 = client.post(
        "/objections",
        json={"entry_id": 1, "content": "다른 새 질문 B"},
        headers=_auth(Role.STUDENT),
    )
    assert res_q2.status_code == 201
    assert res_q2.json()["id"] == 2
    assert res_q2.json()["content"] == "다른 새 질문 B"

    # 3) 뒤늦게 원래 질문 A(id=1)가 체인에서 채굴됨 -> 재요청/조회 시 질문 A 본문과 해시가 일치하며 복구됨
    _test_chain._objections[1] = OnChainObjection(
        entry_id=1,
        content_hash=text_hash("원래 채굴 대기 질문 A"),
        answer_hash=ZERO_BYTES32,
        status="OPEN",
        raiser=raiser_addr,
        responder=ZERO_ADDRESS,
    )
    res_q1_recover = client.post(
        "/objections",
        json={"entry_id": 1, "content": "원래 채굴 대기 질문 A"},
        headers=_auth(Role.STUDENT),
    )
    assert res_q1_recover.status_code == 201
    assert res_q1_recover.json()["id"] == 1
    assert res_q1_recover.json()["content"] == "원래 채굴 대기 질문 A"

    # 4) 답변 A 전송 중 타임아웃(채굴 대기: landed=False) -> prepare-answer 재요청이 와도 보존된 답변 A가 삭제되지 않음
    prep_a = client.post(
        "/objections/1/prepare-answer",
        json={"answer": "원래 채굴 대기 답변 A"},
        headers=_auth(Role.AUDITOR),
    ).json()
    _test_chain.unavailable_next("answer_objection", landed=False, sent=True)
    assert (
        client.post(
            "/objections/1/answer",
            json={
                "answer": "원래 채굴 대기 답변 A",
                "answer_hash": prep_a["answer_hash"],
                "deadline": prep_a["deadline"],
                "signature": fake_signature(AUDITOR_WALLET),
            },
            headers=_auth(Role.AUDITOR),
        ).status_code
        == 503
    )

    # 아직 미채굴인 동안 다른 답변 B로 prepare-answer/answer를 호출하면 덮어쓰지 않고 409로 차단하며 답변 A 보존
    prep_b = client.post(
        "/objections/1/prepare-answer",
        json={"answer": "새 답변 B"},
        headers=_auth(Role.AUDITOR),
    )
    assert prep_b.status_code == 409

    # 5) 뒤늦게 원래 답변 A가 체인에서 채굴됨 -> 이후 답변 A(또는 B) 제출 시 보존된 답변 A로 복구됨
    _test_chain._objections[1] = OnChainObjection(
        entry_id=1,
        content_hash=text_hash("원래 채굴 대기 질문 A"),
        answer_hash=text_hash("원래 채굴 대기 답변 A"),
        status="ANSWERED",
        raiser=raiser_addr,
        responder=AUDITOR_WALLET,
    )
    res_ans_recover = client.post(
        "/objections/1/answer",
        json={
            "answer": "원래 채굴 대기 답변 A",
            "answer_hash": prep_a["answer_hash"],
            "deadline": prep_a["deadline"],
            "signature": fake_signature(AUDITOR_WALLET),
        },
        headers=_auth(Role.AUDITOR),
    )
    assert res_ans_recover.status_code == 200
    assert res_ans_recover.json()["status"] == "ANSWERED"
    assert res_ans_recover.json()["answer"] == "원래 채굴 대기 답변 A"


def test_objection_eip712_vectors():
    """PR #129 objectionVectors(감사·회장 AnswerRequest 서명 벡터 2건)와 백엔드 EIP-712 인코딩·복구가 일치하는지 검증."""
    from app.chain.deployment import Eip712Domain
    from app.chain.eip712 import digest, recover_signer, typed_data_for
    from app.chain.models import AnswerRequest

    domain = Eip712Domain(
        name="ObjectionRegistry",
        version="1",
        chain_id=31337,
        verifying_contract="0x5FC8d32690cc91D4c39d9d3abcBD16989F875707",
        domain_separator="0x416805697be1ff041a4ce947f9cbc23108bba4e7fde1ccf4ab4145ae330f9dfc",
    )
    vectors = [
        (
            AnswerRequest(
                objection_id=1,
                answer_hash="0x441076584b2fc8da010f82ea6727c17b7a05df0aef7087bbf1ccc072a865efde",
                deadline=1790700000,
            ),
            "0x9dd2e581a12e0fdf2696b0b32f36bd1c30d972be8539d36392a041359d8307aa",
            "0x4d13b117b5ae8b3df899901e3b8d583ca503d9b04456bfed7b7b414f759efb651ad453a8eca0f666161bd7a3ca86f04ad20d85dbe11bff0134f1553bd600bfb31b",
            "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
        ),
        (
            AnswerRequest(
                objection_id=2,
                answer_hash="0x441076584b2fc8da010f82ea6727c17b7a05df0aef7087bbf1ccc072a865efde",
                deadline=1790700000,
            ),
            "0x4e48f1c4c6d0d68e7bcce39b011b7ab3d804e9af77ed3818357a45361822728b",
            "0x824448c59930316a32410761b725b011e11c8dafe01220fa99f8168a4c3b5b583f98cdba7286c4a9e3e61009478d104076cde3d68c8427928271d472a74442cf1c",
            "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
        ),
    ]
    for req, expected_digest, sig, expected_signer in vectors:
        td = typed_data_for(req, domain)
        assert digest(td) == expected_digest
        assert recover_signer(td, sig) == expected_signer


def test_raise_timeout_then_reverted_receipt_allows_retry():
    """등록 타임아웃 후 최종 revert 된 receipt 가 확정되면 '?...' 선점을 해제하고 재제출이 성공해야 한다."""
    _grant_student_sbt()
    _test_chain.unavailable_next("raise_objection", sent=True, landed=False)
    res1 = client.post(
        "/objections",
        json={"entry_id": 1, "content": "지연 실패 테스트 질문"},
        headers=_auth(Role.STUDENT),
    )
    assert res1.status_code == 503

    with _test_session_factory() as db:
        row = db.query(DBObjection).filter(DBObjection.id == 1).first()
        assert row is not None
        assert row.tx_raise is not None and row.tx_raise.startswith("?")
        timed_out_hash = "0x" + row.tx_raise[1:]

    # 아직 블록에 없으면 동일 질문 재시도는 409로 대기 안내
    res_pending = client.post(
        "/objections",
        json={"entry_id": 1, "content": "지연 실패 테스트 질문"},
        headers=_auth(Role.STUDENT),
    )
    assert res_pending.status_code == 409

    # 이후 해당 트랜잭션이 블록에서 실패(status=0)로 확정됨
    _test_chain.mark_reverted(timed_out_hash)

    # 동일 질문 재시도 시 선점이 해제되고 같은 행을 재사용해 정상 등록
    res_retry = client.post(
        "/objections",
        json={"entry_id": 1, "content": "지연 실패 테스트 질문"},
        headers=_auth(Role.STUDENT),
    )
    assert res_retry.status_code == 201
    body = res_retry.json()
    assert body["id"] == 1
    assert body["tx_raise"].startswith("0x")
    assert body["tx_raise"] != timed_out_hash


def test_answer_timeout_then_reverted_receipt_allows_prepare_and_retry():
    """답변 타임아웃 후 최종 revert 된 receipt 가 확정되면 선점을 해제하고 prepare·제출이 성공해야 한다."""
    _grant_student_sbt()
    res_raise = client.post(
        "/objections",
        json={"entry_id": 1, "content": "답변 지연 실패 테스트"},
        headers=_auth(Role.STUDENT),
    )
    assert res_raise.status_code == 201

    prep1 = client.post(
        "/objections/1/prepare-answer",
        json={"answer": "첫 번째 답변"},
        headers=_auth(Role.AUDITOR),
    ).json()

    # 답변 전송 후 receipt 대기 타임아웃 (landed=False)
    _test_chain.unavailable_next("answer_objection", sent=True, landed=False)
    res_fail = client.post(
        "/objections/1/answer",
        json={
            "answer": "첫 번째 답변",
            "answer_hash": prep1["answer_hash"],
            "deadline": prep1["deadline"],
            "signature": fake_signature(AUDITOR_WALLET),
        },
        headers=_auth(Role.AUDITOR),
    )
    assert res_fail.status_code == 503

    with _test_session_factory() as db:
        row = db.query(DBObjection).filter(DBObjection.id == 1).first()
        assert row is not None
        assert row.status == "OPEN"
        assert row.tx_answer is not None
        timed_out_hash = row.tx_answer

    # 아직 블록에 없으면 prepare/answer 모두 409
    assert (
        client.post(
            "/objections/1/prepare-answer",
            json={"answer": "새 답변"},
            headers=_auth(Role.AUDITOR),
        ).status_code
        == 409
    )

    # 이후 해당 트랜잭션이 블록에서 실패(status=0)로 확정됨
    _test_chain.mark_reverted(timed_out_hash)

    # prepare 및 재제출 모두 정상 성공
    prep2 = client.post(
        "/objections/1/prepare-answer",
        json={"answer": "재시도 답변"},
        headers=_auth(Role.AUDITOR),
    )
    assert prep2.status_code == 200
    p2 = prep2.json()

    res_retry = client.post(
        "/objections/1/answer",
        json={
            "answer": "재시도 답변",
            "answer_hash": p2["answer_hash"],
            "deadline": p2["deadline"],
            "signature": fake_signature(AUDITOR_WALLET),
        },
        headers=_auth(Role.AUDITOR),
    )
    assert res_retry.status_code == 200
    ans_body = res_retry.json()
    assert ans_body["status"] == "ANSWERED"
    assert ans_body["answer"] == "재시도 답변"
    assert ans_body["tx_answer"] != timed_out_hash


def test_concurrent_reconcile_does_not_clear_newly_claimed_raise_or_answer():
    """Codex 5차 회귀: 이전 실패 receipt 확인 중 다른 요청이 새 전송을 선점하면 늦은 복구가 새 선점을 지우지 않아야 한다."""
    import asyncio
    from datetime import datetime, timezone
    from app.chain.models import ChainRevert, ObjectionRevertReason
    from app.routers.objections import _reconcile_pending_answer, _reconcile_pending_raise

    _grant_student_sbt()
    _test_chain.unavailable_next("raise_objection", sent=True, landed=False)
    assert (
        client.post(
            "/objections",
            json={"entry_id": 1, "content": "동시 복구 경쟁 테스트"},
            headers=_auth(Role.STUDENT),
        ).status_code
        == 503
    )

    new_raise_hash = "?" + "a" * 64
    new_answer_hash = "0x" + "b" * 64

    class RacingChain:
        async def get_objection(self, objection_id: int):
            return None

        async def objection_tx_result(self, tx_hash: str):
            # receipt 확인 도중 다른 요청이 이미 이전 선점을 해제하고 새 전송을 선점한 상황 재현
            with _test_session_factory() as other_db:
                row = other_db.query(DBObjection).filter(DBObjection.id == 1).first()
                if row.tx_raise and row.tx_raise.startswith("?"):
                    row.tx_raise = new_raise_hash
                else:
                    row.tx_answer = new_answer_hash
                    row.answer = "새로 선점된 답변"
                    row.answered_by = 3
                    row.answered_at = datetime.now(timezone.utc)
                other_db.commit()
            raise ChainRevert(ObjectionRevertReason.UNKNOWN, "old tx reverted")

    with _test_session_factory() as db:
        obj = db.query(DBObjection).filter(DBObjection.id == 1).first()
        landed = asyncio.run(_reconcile_pending_raise(db, RacingChain(), obj))
        assert landed is False
        assert obj.tx_raise == new_raise_hash

        # 답변 선점 경쟁 케이스도 동일하게 검증
        obj.tx_raise = "0x" + "1" * 64
        obj.tx_answer = "0x" + "2" * 64
        obj.answer = "이전 실패 답변"
        obj.answered_by = 3
        obj.answered_at = datetime.now(timezone.utc)
        db.commit()

        updated_obj, recovered = asyncio.run(_reconcile_pending_answer(db, RacingChain(), obj))
        assert recovered is False
        assert updated_obj.tx_answer == new_answer_hash
        assert updated_obj.answer == "새로 선점된 답변"
        assert updated_obj.answered_by == 3
        assert updated_obj.answered_at is not None


def test_late_revert_cleanup_does_not_clear_replaced_raise_or_answer_claim(monkeypatch):
    """Codex 6차 회귀: 요청 A 가 revert 사유 조회 중 다른 요청이 선점 B 로 교체하면 A 의 오류 정리가 B 를 지우지 않아야 한다."""
    from datetime import datetime, timezone
    from app.chain.models import ChainRevert, ObjectionRevertReason

    _grant_student_sbt()

    replaced_raise_marker = "?" + "c" * 64
    replaced_answer_hash = "0x" + "d" * 64
    orig_raise = _test_chain.raise_objection
    orig_answer = _test_chain.answer_objection

    # 1) raise_objection: A 가 before_broadcast 선점 후 revert 되기 전에 B 가 선점을 교체
    async def racing_raise(objection_id, entry_id, content_hash, raiser, before_broadcast=None):
        assert before_broadcast is not None
        await before_broadcast("0x" + "1" * 64)
        with _test_session_factory() as other_db:
            row = other_db.query(DBObjection).filter(DBObjection.id == objection_id).first()
            row.tx_raise = replaced_raise_marker
            other_db.commit()
        raise ChainRevert(ObjectionRevertReason.UNKNOWN, "delayed revert on A")

    monkeypatch.setattr(_test_chain, "raise_objection", racing_raise)
    res_raise_fail = client.post(
        "/objections",
        json={"entry_id": 1, "content": "지연 revert 경쟁 테스트"},
        headers=_auth(Role.STUDENT),
    )
    assert res_raise_fail.status_code == 400
    with _test_session_factory() as db:
        row = db.query(DBObjection).filter(DBObjection.id == 1).first()
        assert row is not None
        assert row.tx_raise == replaced_raise_marker

    # 정상 등록으로 원복 후 답변 경쟁 테스트
    monkeypatch.setattr(_test_chain, "raise_objection", orig_raise)
    with _test_session_factory() as db:
        row = db.query(DBObjection).filter(DBObjection.id == 1).first()
        row.tx_raise = None
        db.commit()
    assert (
        client.post(
            "/objections",
            json={"entry_id": 1, "content": "지연 revert 경쟁 테스트"},
            headers=_auth(Role.STUDENT),
        ).status_code
        == 201
    )

    prep = client.post(
        "/objections/1/prepare-answer",
        json={"answer": "요청 A 답변"},
        headers=_auth(Role.AUDITOR),
    ).json()

    # 2) answer_objection: A 가 before_broadcast 선점 후 revert 되기 전에 B 가 선점을 교체
    async def racing_answer(request, signature, before_broadcast=None):
        assert before_broadcast is not None
        await before_broadcast("0x" + "2" * 64)
        with _test_session_factory() as other_db:
            row = other_db.query(DBObjection).filter(DBObjection.id == request.objection_id).first()
            row.tx_answer = replaced_answer_hash
            row.answer = "요청 B 새 답변"
            row.answered_by = 3
            row.answered_at = datetime.now(timezone.utc)
            other_db.commit()
        raise ChainRevert(ObjectionRevertReason.UNKNOWN, "delayed answer revert on A")

    monkeypatch.setattr(_test_chain, "answer_objection", racing_answer)
    res_ans_fail = client.post(
        "/objections/1/answer",
        json={
            "answer": "요청 A 답변",
            "answer_hash": prep["answer_hash"],
            "deadline": prep["deadline"],
            "signature": fake_signature(AUDITOR_WALLET),
        },
        headers=_auth(Role.AUDITOR),
    )
    assert res_ans_fail.status_code == 400
    monkeypatch.setattr(_test_chain, "answer_objection", orig_answer)

    with _test_session_factory() as db:
        row = db.query(DBObjection).filter(DBObjection.id == 1).first()
        assert row is not None
        assert row.tx_answer == replaced_answer_hash
        assert row.answer == "요청 B 새 답변"
        assert row.answered_by == 3
        assert row.answered_at is not None
