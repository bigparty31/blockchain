import time
from datetime import datetime, timezone
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.auth import users
from app.auth.security import create_access_token
from app.chain import FakeChainClient, fake_signature, get_chain_client, set_chain_client
from app.chain.models import BlockReason
from app.database import Base, get_db
from app.main import app
from app.models import (
    Budget as DBBudget,
    Entry as DBEntry,
    Term as DBTerm,
    User as DBUser,
)
from app.schemas.auth import Role

client = TestClient(app)

TREASURER_WALLET = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"  # 시드 총무 지갑
AUDITOR_WALLET = "0x90F79bf6EB2c4f870365E785982E1f101E93b906"    # 시드 감사 지갑
PRESIDENT_WALLET = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"  # 시드 회장 지갑

_test_session_factory = None


@pytest.fixture(autouse=True)
def setup_test_db(tmp_path):
    """각 테스트마다 독립된 임시 SQLite DB를 생성하고 기본 시드 데이터를 주입한다.
    실제 student_council.db를 건드리지 않으며, get_db를 override한다.
    """
    global _test_session_factory
    db_file = tmp_path / "test.db"
    engine = create_engine(
        f"sqlite:///{db_file}",
        connect_args={"check_same_thread": False},
    )
    Base.metadata.create_all(bind=engine)
    TestingSession = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    _test_session_factory = TestingSession

    # 기본 시드 데이터 삽입
    with TestingSession() as db:
        # 1. Users
        for u in users.SEED_USERS:
            db_u = DBUser(
                id=u.id,
                student_no=u.student_no,
                password_hash=u.password_hash,
                name=u.name,
                role=u.role.value if hasattr(u.role, "value") else u.role,
                wallet_index=u.wallet_index,
                wallet_address=u.wallet_address.lower() if u.wallet_address else None,
            )
            db.add(db_u)

        # 2. Term (term_code=20261)
        term = DBTerm(
            id=1,
            term_code=20261,
            name="2026-1학기",
            started_at=datetime.fromtimestamp(1772323200, tz=timezone.utc),
            ended_at=datetime.fromtimestamp(1788163200, tz=timezone.utc),
        )
        db.add(term)

        # 3. Budgets
        b1 = DBBudget(
            id=1,
            term_id=1,
            category="운영비",
            expires_at=datetime.fromtimestamp(1798704000, tz=timezone.utc),
        )
        b2 = DBBudget(
            id=2,
            term_id=1,
            category="행사비",
            expires_at=datetime.fromtimestamp(1798704000, tz=timezone.utc),
        )
        db.add(b1)
        db.add(b2)

        # 4. 초기 Entries 3건
        e1 = DBEntry(
            id=1,
            term_id=1,
            kind="EXPENSE",
            amount=35000,
            counterparty="한결문구",
            purpose="신입생 환영회 명찰 및 필기구 구매",
            budget_id=2,
            occurred_at=1788793200,
            receipt_path="/receipts/sample_01.jpg",
            receipt_hash="0xabc1234567890abcdef1234567890abcdef1234567890abcdef1234567890abc",
            meta_hash="0x24ae73988d927fb39f45eb6024e9ff8ffa19e8501603565bd82710ea8df4b937",
            hash_version=1,
            ocr_amount=35000,
            ocr_approval_no="12345678",
            ocr_paid_at=1788825820,
            ocr_status="MATCH",
            category_warning=False,
            warning_ack_reason=None,
            status="CONFIRMED",
            created_by=2,
            approved_by=3,
            rejected_by=None,
            reject_reason=None,
            tx_pending="0x1111111111111111111111111111111111111111111111111111111111111111",
            tx_confirm="0x2222222222222222222222222222222222222222222222222222222222222222",
            corrects_entry_id=None,
            correction_reason=None,
        )
        e2 = DBEntry(
            id=2,
            term_id=1,
            kind="EXPENSE",
            amount=120000,
            counterparty="청년피자",
            purpose="개강총회 다과 주문",
            budget_id=1,
            occurred_at=1788706800,
            receipt_path="/receipts/sample_02.jpg",
            receipt_hash="0xdef4567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
            meta_hash="0x622fc1b357c04032e65bc1855c73aaff6d519464d69bf22b10761f3b26a1b793",
            hash_version=1,
            ocr_amount=120000,
            ocr_approval_no="87654321",
            ocr_paid_at=1788775450,
            ocr_status="MATCH",
            category_warning=False,
            warning_ack_reason=None,
            status="PENDING",
            created_by=2,
            approved_by=None,
            rejected_by=None,
            reject_reason=None,
            tx_pending="0x3333333333333333333333333333333333333333333333333333333333333333",
            tx_confirm=None,
            corrects_entry_id=None,
            correction_reason=None,
        )
        e3 = DBEntry(
            id=3,
            term_id=1,
            kind="INCOME",
            amount=5000000,
            counterparty="컴퓨터공학과 학생회비 일괄 납부",
            purpose="2026-2학기 학과 학생회비 수납",
            budget_id=None,
            occurred_at=1788620400,
            receipt_path=None,
            receipt_hash=None,
            meta_hash="0x74c9740556d857575586251e71fa24091ffaece5c01c4f889d7c1224ce7af3a9",
            hash_version=1,
            ocr_amount=None,
            ocr_approval_no=None,
            ocr_paid_at=None,
            ocr_status=None,
            category_warning=False,
            warning_ack_reason=None,
            status="CONFIRMED",
            created_by=2,
            approved_by=3,
            rejected_by=None,
            reject_reason=None,
            tx_pending="0x4444444444444444444444444444444444444444444444444444444444444444",
            tx_confirm="0x5555555555555555555555555555555555555555555555555555555555555555",
            corrects_entry_id=None,
            correction_reason=None,
        )
        db.add(e1)
        db.add(e2)
        db.add(e3)
        db.commit()

    def override_get_db():
        session = TestingSession()
        try:
            yield session
        finally:
            session.close()

    app.dependency_overrides[get_db] = override_get_db
    set_chain_client(FakeChainClient())

    yield

    app.dependency_overrides.clear()
    set_chain_client(FakeChainClient())
    _test_session_factory = None


def test_get_entries():
    """초기 더미 데이터 3건(status가 존재하는 확정/대기 항목)만 조회되는지 검증"""
    response = client.get("/entries")
    assert response.status_code == 200
    data = response.json()
    assert len(data) >= 3
    # 모든 조회 결과는 status와 tx_pending이 존재해야 함 (초안 status IS NULL 제외 필터 검증)
    for entry in data:
        assert entry["status"] is not None
        assert entry["tx_pending"] is not None


def test_create_entry_draft_and_submit(auth_header):
    """1단계 초안 생성(id만 발급, 목록 미노출) 및 2단계 submit(signer_of 통과, PENDING 전환, 목록 노출) 검증"""
    now = int(time.time())

    # 1. 초안 등록 (1단계)
    req_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 45000,
        "counterparty": "알파문구",
        "purpose": "중간고사 간식 박스 테이프 구매",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": "0x11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff",
        "ocr_amount": 45000,
        "ocr_approval_no": "99887766",
        "ocr_paid_at": 1788829999,
        "ocr_status": "MATCH",
    }
    res_draft = client.post("/entries", json=req_body, headers=auth_header(Role.TREASURER))
    assert res_draft.status_code == 201
    draft_data = res_draft.json()

    draft_id = draft_data["id"]
    # 1단계 응답에는 status와 tx_pending이 없어야 함 (초안 status IS NULL)
    assert "status" not in draft_data or draft_data.get("status") is None
    assert "tx_pending" not in draft_data or draft_data.get("tx_pending") is None

    # submit 전에는 GET /entries 목록에 노출되지 않아야 함
    res_list_before = client.get("/entries")
    entries_before = res_list_before.json()
    assert not any(e["id"] == draft_id for e in entries_before)

    # 2. 기기 서명 제출 (2단계) - 등록 총무의 지갑으로 생성한 정상 서명
    submit_body = {
        "deadline": now + 600,
        "signature": fake_signature(TREASURER_WALLET),
    }
    res_submit = client.post(f"/entries/{draft_id}/submit", json=submit_body, headers=auth_header(Role.TREASURER))
    assert res_submit.status_code == 200
    submit_data = res_submit.json()

    assert submit_data["id"] == draft_id
    assert submit_data["status"] == "PENDING"
    assert submit_data["tx_pending"] is not None
    assert submit_data["tx_pending"].startswith("0x")

    # submit 후에는 GET /entries 목록에 정상 노출되어야 함
    res_list_after = client.get("/entries")
    entries_after = res_list_after.json()
    new_entry = next((e for e in entries_after if e["id"] == draft_id), None)
    assert new_entry is not None
    assert new_entry["counterparty"] == "알파문구"
    assert new_entry["status"] == "PENDING"
    assert new_entry["tx_pending"] == submit_data["tx_pending"]


def test_submit_signature_mismatch_fails(auth_header):
    """서명자가 등록자와 다르면(체인 가스 낭비 방지) 400 Bad Request 반환 검증 (CHAIN_CLIENT.md §4)"""
    now = int(time.time())
    req_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 25000,
        "counterparty": "베타문구",
        "purpose": "서명 불일치 검증용",
        "budget_id": 2,
        "occurred_at": 1788793200,
    }
    res_draft = client.post("/entries", json=req_body, headers=auth_header(Role.TREASURER))
    assert res_draft.status_code == 201
    draft_id = res_draft.json()["id"]

    # 다른 사람(예: 0x9999...)의 지갑 주소로 서명한 경우
    submit_body = {
        "deadline": now + 600,
        "signature": fake_signature("0x9999999999999999999999999999999999999999"),
    }
    res_submit = client.post(f"/entries/{draft_id}/submit", json=submit_body, headers=auth_header(Role.TREASURER))
    assert res_submit.status_code == 400
    assert "서명자가 등록자와 일치하지 않습니다" in res_submit.json()["detail"]


def test_submit_invalid_signature_format_fails(auth_header):
    """서명 형식이 0x + 130자 hex가 아니면 ValueError -> 400 Bad Request 반환 검증"""
    now = int(time.time())
    req_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 25000,
        "counterparty": "감마문구",
        "purpose": "서명 형식 오류 검증용",
        "budget_id": 2,
        "occurred_at": 1788793200,
    }
    res_draft = client.post("/entries", json=req_body, headers=auth_header(Role.TREASURER))
    draft_id = res_draft.json()["id"]

    submit_body = {
        "deadline": now + 600,
        "signature": "0xinvalid_signature_length",
    }
    res_submit = client.post(f"/entries/{draft_id}/submit", json=submit_body, headers=auth_header(Role.TREASURER))
    assert res_submit.status_code == 400
    assert "유효하지 않은 서명 형식입니다" in res_submit.json()["detail"]


def test_submit_blocked_budget_exceeded(auth_header):
    """예산 초과 시 2단계 submit에서 BLOCKED 상태, block_reason 및 체인 tx_pending 반환 검증"""
    chain: FakeChainClient = get_chain_client()
    chain.block_next(BlockReason.BUDGET_EXCEEDED)

    req_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 15000000,
        "counterparty": "대형장비업체",
        "purpose": "축제 음향 장비 렌탈",
        "budget_id": 2,
        "occurred_at": 1788793200,
    }
    res_draft = client.post("/entries", json=req_body, headers=auth_header(Role.TREASURER))
    assert res_draft.status_code == 201
    draft_id = res_draft.json()["id"]

    submit_body = {
        "deadline": int(time.time()) + 600,
        "signature": fake_signature(TREASURER_WALLET),
    }
    res_submit = client.post(f"/entries/{draft_id}/submit", json=submit_body, headers=auth_header(Role.TREASURER))
    if res_submit.status_code != 200:
        print("BLOCKED ERROR:", res_submit.json())
    assert res_submit.status_code == 200
    submit_data = res_submit.json()

    assert submit_data["id"] == draft_id
    assert submit_data["status"] == "BLOCKED"
    assert submit_data["block_reason"] == "BUDGET_EXCEEDED"
    assert submit_data["tx_pending"] is not None
    assert submit_data["tx_pending"].startswith("0x")

    # PRD §8 "BLOCKED 기록은 남겨 개정 요청 근거로 사용" - 목록 조회 시 포함되어야 함
    res_list = client.get("/entries")
    entries = res_list.json()
    blocked_entry = next((e for e in entries if e["id"] == draft_id), None)
    assert blocked_entry is not None
    assert blocked_entry["status"] == "BLOCKED"
    assert blocked_entry["tx_pending"] == submit_data["tx_pending"]


def test_ocr_duplication_conflict(auth_header):
    """동일한 승인번호/결제일시/금액 중복 등록 시 409 Conflict 발생 검증"""
    dup_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 35000,
        "counterparty": "다른문구점",
        "purpose": "명찰 중복 구매 시도",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "ocr_amount": 35000,
        "ocr_approval_no": "12345678",
        "ocr_paid_at": 1788825820,
        "ocr_status": "MATCH",
    }
    res = client.post("/entries", json=dup_body, headers=auth_header(Role.TREASURER))
    assert res.status_code == 409
    assert "이미 등록된 영수증입니다" in res.json()["detail"]


# ---------------------------------------------------------------- 역할 권한 검사

DRAFT_BODY = {
    "term_id": 1,
    "kind": "EXPENSE",
    "amount": 12000,
    "counterparty": "권한테스트문구",
    "purpose": "권한 검사용 초안",
    "budget_id": 2,
    "occurred_at": 1788793200,
}
SUBMIT_BODY = {"deadline": 9999999999, "signature": fake_signature(TREASURER_WALLET)}


@pytest.fixture
def draft_id(auth_header):
    """시드 총무가 만든 초안 id"""
    res = client.post("/entries", json=DRAFT_BODY, headers=auth_header(Role.TREASURER))
    assert res.status_code == 201
    return res.json()["id"]


@pytest.fixture
def second_treasurer(monkeypatch):
    """시드 총무 말고 총무를 하나 더 둔다. 테스트가 끝나면 monkeypatch 가 되돌린다."""
    new_id = max(u.id for u in users.SEED_USERS) + 1
    second_wallet = "0x2222222222222222222222222222222222222222"
    user = users.User(
        id=new_id,
        student_no=f"2099{new_id:04d}",
        name="최총무",
        role=Role.TREASURER,
        password_hash="unused",
        wallet_address=second_wallet,
    )
    monkeypatch.setattr(users, "SEED_USERS", [*users.SEED_USERS, user])

    if _test_session_factory:
        with _test_session_factory() as db:
            db.add(
                DBUser(
                    id=user.id,
                    student_no=user.student_no,
                    password_hash="unused",
                    name=user.name,
                    role="TREASURER",
                    wallet_address=second_wallet.lower(),
                )
            )
            db.commit()

    return SimpleNamespace(
        id=user.id,
        wallet_address=second_wallet,
        headers={"Authorization": f"Bearer {create_access_token(user.id)}"},
    )


def get_draft(entry_id):
    with _test_session_factory() as db:
        return db.query(DBEntry).filter(DBEntry.id == entry_id).first()


@pytest.mark.parametrize("role", [Role.STUDENT, Role.AUDITOR, Role.PRESIDENT])
def test_only_treasurer_can_create_entry(role, auth_header):
    with _test_session_factory() as db:
        count_before = db.query(DBEntry).count()
    res = client.post("/entries", json=DRAFT_BODY, headers=auth_header(role))
    assert res.status_code == 403
    with _test_session_factory() as db:
        assert db.query(DBEntry).count() == count_before


@pytest.mark.parametrize("role", [Role.STUDENT, Role.AUDITOR, Role.PRESIDENT])
def test_only_treasurer_can_submit_entry(role, auth_header, draft_id):
    res = client.post(f"/entries/{draft_id}/submit", json=SUBMIT_BODY, headers=auth_header(role))
    assert res.status_code == 403
    assert get_draft(draft_id).status is None
    assert get_draft(draft_id).tx_pending is None


def test_write_apis_without_token_are_401(draft_id):
    assert client.post("/entries", json=DRAFT_BODY).status_code == 401
    assert client.post(f"/entries/{draft_id}/submit", json=SUBMIT_BODY).status_code == 401


def test_created_by_is_logged_in_treasurer(second_treasurer):
    res = client.post("/entries", json=DRAFT_BODY, headers=second_treasurer.headers)
    assert res.status_code == 201
    assert get_draft(res.json()["id"]).created_by == second_treasurer.id


def test_other_treasurer_cannot_submit_someone_elses_draft(second_treasurer, draft_id):
    # 다른 총무가 서명하면 체인 등록자와 DB created_by 가 달라진다
    submit_req = {
        "deadline": 9999999999,
        "signature": fake_signature(second_treasurer.wallet_address),
    }
    res = client.post(f"/entries/{draft_id}/submit", json=submit_req, headers=second_treasurer.headers)
    assert res.status_code == 403
    assert res.json() == {"detail": "본인이 등록한 초안만 제출할 수 있습니다."}
    assert get_draft(draft_id).status is None
    assert get_draft(draft_id).tx_pending is None


# ---------------------------------------------------------------- 승인(Confirm) 및 반려(Reject) 테스트


def test_confirm_entry_success(auth_header):
    """감사가 PENDING 항목을 정상 승인(CONFIRMED)하는 흐름 검증"""
    now = int(time.time())
    # 1. 초안 생성 및 온체인 PENDING 등록
    draft_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 50000,
        "counterparty": "승인테스트문구",
        "purpose": "승인 테스트용 구매",
        "budget_id": 2,
        "occurred_at": 1788793200,
    }
    res_draft = client.post("/entries", json=draft_body, headers=auth_header(Role.TREASURER))
    entry_id = res_draft.json()["id"]

    submit_body = {
        "deadline": now + 600,
        "signature": fake_signature(TREASURER_WALLET),
    }
    res_submit = client.post(f"/entries/{entry_id}/submit", json=submit_body, headers=auth_header(Role.TREASURER))
    assert res_submit.status_code == 200

    # 2. 감사 승인 제출
    confirm_body = {
        "deadline": now + 600,
        "signature": fake_signature(AUDITOR_WALLET),
        "warning_reason": None,
    }
    res = client.post(f"/entries/{entry_id}/confirm", json=confirm_body, headers=auth_header(Role.AUDITOR))
    assert res.status_code == 200
    data = res.json()
    assert data["id"] == entry_id
    assert data["status"] == "CONFIRMED"
    assert data["tx_confirm"] is not None


def test_confirm_self_approval_is_blocked(auth_header):
    """총무(등록자 본인)가 승인 권한이 있는 경우에도 자기 승인은 403 차단 검증"""
    now = int(time.time())
    # 초안 생성 및 PENDING 등록 (등록자: 시드 총무 id=2)
    draft_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 30000,
        "counterparty": "자기승인방지문구",
        "purpose": "자기 승인 차단 검증",
        "budget_id": 2,
        "occurred_at": 1788793200,
    }
    res_draft = client.post("/entries", json=draft_body, headers=auth_header(Role.TREASURER))
    entry_id = res_draft.json()["id"]

    submit_body = {
        "deadline": now + 600,
        "signature": fake_signature(TREASURER_WALLET),
    }
    res_submit = client.post(f"/entries/{entry_id}/submit", json=submit_body, headers=auth_header(Role.TREASURER))
    assert res_submit.status_code == 200

    # 등록자(id=2)가 회장 권한으로 승인을 시도하는 경우 시뮬레이션
    token = create_access_token(2)
    headers = {"Authorization": f"Bearer {token}"}
    orig_role = users.SEED_USERS[1].role
    users.SEED_USERS[1].role = Role.PRESIDENT
    try:
        confirm_body = {
            "deadline": now + 600,
            "signature": fake_signature(TREASURER_WALLET),
        }
        res = client.post(f"/entries/{entry_id}/confirm", json=confirm_body, headers=headers)
        assert res.status_code == 403
        assert "본인이 등록한 항목은 승인·반려할 수 없습니다" in res.json()["detail"]
    finally:
        users.SEED_USERS[1].role = orig_role


def test_confirm_signer_mismatch_fails(auth_header):
    """승인 시 서명자가 요청자와 다르면 400 Bad Request 반환 검증"""
    now = int(time.time())
    draft_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 20000,
        "counterparty": "서명불일치문구",
        "purpose": "승인 서명 불일치 검증",
        "budget_id": 2,
        "occurred_at": 1788793200,
    }
    res_draft = client.post("/entries", json=draft_body, headers=auth_header(Role.TREASURER))
    entry_id = res_draft.json()["id"]

    submit_body = {
        "deadline": now + 600,
        "signature": fake_signature(TREASURER_WALLET),
    }
    res_submit = client.post(f"/entries/{entry_id}/submit", json=submit_body, headers=auth_header(Role.TREASURER))
    assert res_submit.status_code == 200

    confirm_body = {
        "deadline": now + 600,
        "signature": fake_signature("0x8888888888888888888888888888888888888888"),
    }
    res = client.post(f"/entries/{entry_id}/confirm", json=confirm_body, headers=auth_header(Role.AUDITOR))
    assert res.status_code == 400
    assert "서명자가 승인권자와 일치하지 않습니다" in res.json()["detail"]


def test_reject_entry_success(auth_header):
    """감사가 PENDING 항목을 사유와 함께 정상 반려(REJECTED)하는 흐름 검증"""
    now = int(time.time())
    draft_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 60000,
        "counterparty": "반려테스트문구",
        "purpose": "반려 테스트용 구매",
        "budget_id": 2,
        "occurred_at": 1788793200,
    }
    res_draft = client.post("/entries", json=draft_body, headers=auth_header(Role.TREASURER))
    entry_id = res_draft.json()["id"]

    submit_body = {
        "deadline": now + 600,
        "signature": fake_signature(TREASURER_WALLET),
    }
    res_submit = client.post(f"/entries/{entry_id}/submit", json=submit_body, headers=auth_header(Role.TREASURER))
    assert res_submit.status_code == 200

    reject_body = {
        "deadline": now + 600,
        "signature": fake_signature(AUDITOR_WALLET),
        "reject_reason": "영수증 식별 불가로 인한 반려",
    }
    res = client.post(f"/entries/{entry_id}/reject", json=reject_body, headers=auth_header(Role.AUDITOR))
    assert res.status_code == 200
    data = res.json()
    assert data["id"] == entry_id
    assert data["status"] == "REJECTED"


def test_confirm_ocr_mismatch_requires_warning_reason(auth_header):
    """OCR 불일치(AMOUNT_MISMATCH) 항목 승인 시 warning_reason 누락 시 400 Bad Request 차단 검증"""
    now = int(time.time())
    draft_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 50000,
        "counterparty": "OCR경고테스트점",
        "purpose": "OCR 금액 불일치 항목",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
        "ocr_amount": 48000,
        "ocr_approval_no": "11223344",
        "ocr_paid_at": 1788829999,
        "ocr_status": "MISMATCH",
    }
    res_draft = client.post("/entries", json=draft_body, headers=auth_header(Role.TREASURER))
    assert res_draft.status_code == 201
    entry_id = res_draft.json()["id"]

    submit_body = {
        "deadline": now + 600,
        "signature": fake_signature(TREASURER_WALLET),
    }
    res_submit = client.post(f"/entries/{entry_id}/submit", json=submit_body, headers=auth_header(Role.TREASURER))
    assert res_submit.status_code == 200

    # 사유 없이 승인 시도 -> 400 차단 검증
    confirm_body_no_reason = {
        "deadline": now + 600,
        "signature": fake_signature(AUDITOR_WALLET),
        "warning_reason": None,
    }
    res_fail = client.post(f"/entries/{entry_id}/confirm", json=confirm_body_no_reason, headers=auth_header(Role.AUDITOR))
    assert res_fail.status_code == 400
    assert "경고 무시 사유(warning_reason)가 필수입니다" in res_fail.json()["detail"]

    # 사유 포함 승인 시도 -> 200 성공 검증
    confirm_body_with_reason = {
        "deadline": now + 600,
        "signature": fake_signature(AUDITOR_WALLET),
        "warning_reason": "봉투값 2000원 수기 합산 확인 완료",
    }
    res_ok = client.post(f"/entries/{entry_id}/confirm", json=confirm_body_with_reason, headers=auth_header(Role.AUDITOR))
    assert res_ok.status_code == 200
    assert res_ok.json()["status"] == "CONFIRMED"


def test_confirm_without_warning_rejects_warning_reason(auth_header):
    """경고가 없는 정상 항목에 warning_reason 제출 시 400 Bad Request 차단 검증"""
    now = int(time.time())
    draft_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 20000,
        "counterparty": "정상거래점",
        "purpose": "정상 거래 승인",
        "budget_id": 2,
        "occurred_at": 1788793200,
    }
    res_draft = client.post("/entries", json=draft_body, headers=auth_header(Role.TREASURER))
    entry_id = res_draft.json()["id"]

    client.post(
        f"/entries/{entry_id}/submit",
        json={"deadline": now + 600, "signature": fake_signature(TREASURER_WALLET)},
        headers=auth_header(Role.TREASURER),
    )

    confirm_body = {
        "deadline": now + 600,
        "signature": fake_signature(AUDITOR_WALLET),
        "warning_reason": "경고 없는 건에 불필요한 사유 제출",
    }
    res = client.post(f"/entries/{entry_id}/confirm", json=confirm_body, headers=auth_header(Role.AUDITOR))
    assert res.status_code == 400
    assert "경고 항목이 아닌 경우" in res.json()["detail"]


def test_confirm_ocr_no_number_is_normal(auth_header):
    """PRD 기준 OCRStatus NO_NUMBER(계좌이체 등)는 정상 항목이므로 warning_reason 없이 승인 가능하고 사유 제출 시 400 차단 검증"""
    now = int(time.time())
    draft_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 30000,
        "counterparty": "계좌이체거래처",
        "purpose": "승인번호 없는 계좌이체 영수증",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "ocr_status": "NO_NUMBER",
    }
    res_draft = client.post("/entries", json=draft_body, headers=auth_header(Role.TREASURER))
    assert res_draft.status_code == 201
    entry_id = res_draft.json()["id"]

    res_submit = client.post(
        f"/entries/{entry_id}/submit",
        json={"deadline": now + 600, "signature": fake_signature(TREASURER_WALLET)},
        headers=auth_header(Role.TREASURER),
    )
    assert res_submit.status_code == 200

    # 1. NO_NUMBER 항목에 불필요한 사유 제출 시 -> 400 차단 검증
    confirm_fail = client.post(
        f"/entries/{entry_id}/confirm",
        json={
            "deadline": now + 600,
            "signature": fake_signature(AUDITOR_WALLET),
            "warning_reason": "정상 건에 사유 제출",
        },
        headers=auth_header(Role.AUDITOR),
    )
    assert confirm_fail.status_code == 400
    assert "경고 항목이 아닌 경우" in confirm_fail.json()["detail"]

    # 2. 사유 없이 승인 시 -> 200 정상 승인 검증
    confirm_ok = client.post(
        f"/entries/{entry_id}/confirm",
        json={
            "deadline": now + 600,
            "signature": fake_signature(AUDITOR_WALLET),
            "warning_reason": None,
        },
        headers=auth_header(Role.AUDITOR),
    )
    assert confirm_ok.status_code == 200
    assert confirm_ok.json()["status"] == "CONFIRMED"
