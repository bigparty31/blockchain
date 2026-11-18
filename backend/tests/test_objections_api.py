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
    """미확정 항목·제어문자·빈 답변·잘못된 권한을 차단한다."""
    _grant_student_sbt()

    # 1. 미확정(PENDING) 항목에 이의 제기 -> 400
    res_pending = client.post(
        "/objections",
        json={"entry_id": 2, "content": "대기 항목 문의"},
        headers=_auth(Role.STUDENT),
    )
    assert res_pending.status_code == 400

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

    # 2. landed=False 시 503 반환 후 재시도하면 같은 행을 재전송하여 성공
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
    assert res4.status_code == 201
    assert res4.json()["id"] == 2
    assert len(client.get("/objections").json()) == 2


def test_answer_objection_recovers_after_chain_unavailable(monkeypatch):
    """답변 전송 후 ChainUnavailable 발생 시(landed=True/False) 본문·답변자를 보존하고 재요청 시 복구한다."""
    _grant_student_sbt()
    created = client.post(
        "/objections",
        json={"entry_id": 1, "content": "답변 복구 테스트 질문"},
        headers=_auth(Role.STUDENT),
    ).json()
    oid = created["id"]

    prep = client.post(
        f"/objections/{oid}/prepare-answer",
        json={"answer": "첫 번째 답변"},
        headers=_auth(Role.AUDITOR),
    ).json()

    # 1. landed=False -> 503 후 prepare-answer 와 answer 재요청이 409로 막히지 않고 통과해야 함
    _test_chain.unavailable_next("answer_objection", landed=False, sent=True)
    res_unlanded = client.post(
        f"/objections/{oid}/answer",
        json={
            "answer": "첫 번째 답변",
            "answer_hash": prep["answer_hash"],
            "deadline": prep["deadline"],
            "signature": fake_signature(AUDITOR_WALLET),
        },
        headers=_auth(Role.AUDITOR),
    )
    assert res_unlanded.status_code == 503

    prep_retry = client.post(
        f"/objections/{oid}/prepare-answer",
        json={"answer": "최종 복구 답변"},
        headers=_auth(Role.AUDITOR),
    )
    assert prep_retry.status_code == 200
    prep2 = prep_retry.json()

    # 2. landed=True + 첫 get_objection 도 실패 -> 503 후 재요청 시 본문·답변자·tx_answer 복구
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
