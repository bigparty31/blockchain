import time
from datetime import datetime, timezone
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import sessionmaker

from app.auth import users
from app.auth.security import create_access_token
from app.chain import ChainUnavailable, FakeChainClient, fake_signature, get_chain_client
from app.chain.models import BlockReason, RevertReason
from app.database import Base, get_db
from app.main import app
from app.routers import entries as entries_router
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

TEST_RECEIPT_HASH = "0x" + "a" * 64
TEST_RECEIPT_PATH = "/receipts/sample_01.jpg"

_test_session_factory = None
_test_chain = FakeChainClient()


@pytest.fixture(autouse=True)
def setup_test_db(tmp_path):
    """각 테스트마다 독립된 임시 SQLite DB를 생성하고 기본 시드 데이터를 주입한다.
    실제 student_council.db를 건드리지 않으며, get_db를 override한다.
    """
    global _test_session_factory, _test_chain
    _test_chain = FakeChainClient()
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
    app.dependency_overrides[get_chain_client] = lambda: _test_chain

    yield

    app.dependency_overrides.clear()
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
        "receipt_path": TEST_RECEIPT_PATH,
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
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
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
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
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
    chain: FakeChainClient = _test_chain
    chain.block_next(BlockReason.BUDGET_EXCEEDED)

    req_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 15000000,
        "counterparty": "대형장비업체",
        "purpose": "축제 음향 장비 렌탈",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
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


def test_ocr_duplication_warning_returns_201_duplicate(auth_header):
    """동일한 승인번호/결제일시/금액 중복 등록 시 409 차단 대신 201 Created 및 ocr_status=DUPLICATE 경고 전환 검증 (PRD v0.15 §6, §8, B4)"""
    dup_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 35000,
        "counterparty": "다른문구점",
        "purpose": "명찰 중복 구매 시도",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": "0x" + "bb" * 32,
        "receipt_path": TEST_RECEIPT_PATH,
        "ocr_amount": 35000,
        "ocr_approval_no": "12345678",
        "ocr_paid_at": 1788825820,
        "ocr_status": "MATCH",
    }
    res = client.post("/entries", json=dup_body, headers=auth_header(Role.TREASURER))
    assert res.status_code == 201
    saved = res.json()
    assert saved["id"] is not None

    with _test_session_factory() as db:
        row = db.query(DBEntry).filter(DBEntry.id == saved["id"]).first()
        assert row is not None
        assert row.ocr_status == "DUPLICATE"


def test_create_income_with_budget_returns_400(auth_header):
    """수입(INCOME) 내역에는 예산을 연결할 수 없으며 400 Bad Request가 반환되어야 함 (ck_entries_income_no_budget)"""
    income_with_budget = {
        "term_id": 1,
        "kind": "INCOME",
        "amount": 50000,
        "counterparty": "학생회비납부자",
        "purpose": "학생회비 납부",
        "budget_id": 1,
        "occurred_at": 1788793200,
    }
    res = client.post("/entries", json=income_with_budget, headers=auth_header(Role.TREASURER))
    assert res.status_code == 400
    assert "수입 내역에는 예산을 연결할 수 없습니다" in res.json()["detail"]


def test_create_income_without_budget_succeeds(auth_header):
    """수입(INCOME) 내역에 예산이 없으면 정상적으로 201 Created 초안 등록 성공해야 함"""
    income_without_budget = {
        "term_id": 1,
        "kind": "INCOME",
        "amount": 50000,
        "counterparty": "학생회비납부자",
        "purpose": "학생회비 납부",
        "budget_id": None,
        "occurred_at": 1788793200,
    }
    res = client.post("/entries", json=income_without_budget, headers=auth_header(Role.TREASURER))
    assert res.status_code == 201
    assert "id" in res.json()


# ---------------------------------------------------------------- 역할 권한 검사

DRAFT_BODY = {
    "term_id": 1,
    "kind": "EXPENSE",
    "amount": 12000,
    "counterparty": "권한테스트문구",
    "purpose": "권한 검사용 초안",
    "budget_id": 2,
    "occurred_at": 1788793200,
    "receipt_hash": TEST_RECEIPT_HASH,
    "receipt_path": TEST_RECEIPT_PATH,
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
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
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
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
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
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
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
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
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

    with _test_session_factory() as db:
        row = db.query(DBEntry).filter(DBEntry.id == entry_id).first()
        assert row.status == "REJECTED"
        assert row.tx_confirm is not None
        assert row.rejected_by == 3
        assert row.reject_reason == "영수증 식별 불가로 인한 반려"


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
        "receipt_path": TEST_RECEIPT_PATH,
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
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
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
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
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


def test_submit_entry_retry_recovers_state_2(auth_header, monkeypatch):
    """상태 ②(전송 후 응답 유실 + 노드 일시 불능)에서 재제출 시 200 PENDING으로 정상 복구 검증"""
    global _test_chain
    now = int(time.time())
    draft_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 40000,
        "counterparty": "상태2복구문구",
        "purpose": "상태 2 재시도 복구 검증",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
    }
    res_draft = client.post("/entries", json=draft_body, headers=auth_header(Role.TREASURER))
    assert res_draft.status_code == 201
    entry_id = res_draft.json()["id"]

    submit_body = {
        "deadline": now + 600,
        "signature": fake_signature(TREASURER_WALLET),
    }

    # 1. 전송 후 응답 유실 + 결과 확인 시 노드 일시 불능 (상태 ② 유도)
    _test_chain.unavailable_next("record_pending", landed=True)
    orig_tx_result = _test_chain.tx_result
    failed_once = False

    async def fail_once_tx_result(tx_hash, eid):
        nonlocal failed_once
        if not failed_once:
            failed_once = True
            raise ChainUnavailable("결과 확인 시 노드 일시 불능")
        return await orig_tx_result(tx_hash, eid)

    monkeypatch.setattr(_test_chain, "tx_result", fail_once_tx_result)

    res_fail = client.post(
        f"/entries/{entry_id}/submit",
        json=submit_body,
        headers=auth_header(Role.TREASURER),
    )
    assert res_fail.status_code == 503
    assert res_fail.json()["detail"] == "블록체인 네트워크와 통신할 수 없습니다."

    # DB 상태 확인: 상태 ② (status는 None, tx_pending은 채워짐)
    with _test_session_factory() as db:
        row = db.query(DBEntry).filter(DBEntry.id == entry_id).first()
        assert row.status is None
        assert row.tx_pending is not None
        saved_tx = row.tx_pending

    # 2. 노드 복구 후 재제출 -> 200 OK 및 PENDING 상태로 복구 확인
    res_retry = client.post(
        f"/entries/{entry_id}/submit",
        json=submit_body,
        headers=auth_header(Role.TREASURER),
    )
    assert res_retry.status_code == 200
    retry_data = res_retry.json()
    assert retry_data["status"] == "PENDING"
    assert retry_data["tx_pending"] == saved_tx

    # DB 확인: status가 PENDING으로 정상 갱신됨
    with _test_session_factory() as db:
        row = db.query(DBEntry).filter(DBEntry.id == entry_id).first()
        assert row.status == "PENDING"
        assert row.tx_pending == saved_tx


def test_reject_blocked_when_confirm_in_flight(auth_header):
    """확정 처리가 상태 ②로 선점된 도중 반려 시 409 Conflict 차단 검증"""
    now = int(time.time())
    draft_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 25000,
        "counterparty": "확정선점문구",
        "purpose": "확정 선점 중 반려 차단 검증",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
    }
    res_draft = client.post("/entries", json=draft_body, headers=auth_header(Role.TREASURER))
    entry_id = res_draft.json()["id"]

    res_submit = client.post(
        f"/entries/{entry_id}/submit",
        json={"deadline": now + 600, "signature": fake_signature(TREASURER_WALLET)},
        headers=auth_header(Role.TREASURER),
    )
    assert res_submit.status_code == 200

    # 확정이 진행 중(상태 ② 선점)인 상태를 DB에 모사
    with _test_session_factory() as db:
        row = db.query(DBEntry).filter(DBEntry.id == entry_id).first()
        row.tx_confirm = "0x" + "7" * 64
        row.approved_by = 3
        db.commit()

    # 회장이 반려를 시도할 경우 409로 차단
    reject_body = {
        "deadline": now + 600,
        "signature": fake_signature(PRESIDENT_WALLET),
        "reject_reason": "확정 선점 중 반려 시도",
    }
    res_reject = client.post(
        f"/entries/{entry_id}/reject",
        json=reject_body,
        headers=auth_header(Role.PRESIDENT),
    )
    assert res_reject.status_code == 409
    assert "확정 처리 중인 내역은 반려할 수 없습니다." in res_reject.json()["detail"]

    # DB 상태가 REJECTED로 오염되지 않고 유지되었는지 확인
    with _test_session_factory() as db:
        row = db.query(DBEntry).filter(DBEntry.id == entry_id).first()
        assert row.status == "PENDING"
        assert row.rejected_by is None


def _pending_entry(auth_header) -> int:
    now = int(time.time())
    draft_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 25000,
        "counterparty": "반려선점문구",
        "purpose": "반려 선점 검증",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
    }
    entry_id = client.post("/entries", json=draft_body, headers=auth_header(Role.TREASURER)).json()["id"]
    res = client.post(
        f"/entries/{entry_id}/submit",
        json={"deadline": now + 600, "signature": fake_signature(TREASURER_WALLET)},
        headers=auth_header(Role.TREASURER),
    )
    assert res.status_code == 200
    return entry_id


def _reject_request(entry_id: int, auth_header):
    body = {
        "deadline": int(time.time()) + 600,
        "signature": fake_signature(AUDITOR_WALLET),
        "reject_reason": "영수증 식별 불가로 인한 반려",
    }
    return client.post(f"/entries/{entry_id}/reject", json=body, headers=auth_header(Role.AUDITOR))


def test_reject_reason_is_not_exposed_until_the_rejection_lands(auth_header):
    """반려 선점 때 적은 사유·반려자는 체인에서 끝나기 전에는 응답에 없다 (실패하면 비워지는 값이다)"""
    entry_id = _pending_entry(auth_header)
    with _test_session_factory() as db:
        row = db.query(DBEntry).filter(DBEntry.id == entry_id).first()
        row.tx_confirm = "0x" + "7" * 64
        row.rejected_by = 3
        row.reject_reason = "아직 체인에 없는 사유"
        db.commit()

    listed = next(e for e in client.get("/entries").json() if e["id"] == entry_id)
    assert listed["status"] == "PENDING"
    assert listed["reject_reason"] is None and listed["rejected_by"] is None


def test_rejected_entry_shows_its_reason(auth_header):
    entry_id = _pending_entry(auth_header)
    assert _reject_request(entry_id, auth_header).status_code == 200
    listed = next(e for e in client.get("/entries").json() if e["id"] == entry_id)
    assert listed["status"] == "REJECTED"
    assert (listed["rejected_by"], listed["reject_reason"]) == (3, "영수증 식별 불가로 인한 반려")


def test_approver_is_not_exposed_until_the_confirmation_lands(auth_header):
    """확정 선점 때 적은 승인자·경고 사유는 체인에서 끝나기 전에는 응답에 없다. 앱 단건 검증이 승인자 불일치로 판정한다"""
    entry_id = _pending_entry(auth_header)
    with _test_session_factory() as db:
        row = db.query(DBEntry).filter(DBEntry.id == entry_id).first()
        row.tx_confirm = "0x" + "7" * 64
        row.approved_by = 3
        row.warning_ack_reason = "아직 체인에 없는 사유"
        db.commit()

    listed = next(e for e in client.get("/entries").json() if e["id"] == entry_id)
    assert listed["status"] == "PENDING"
    assert listed["approved_by"] is None and listed["warning_ack_reason"] is None
    assert listed["tx_confirm"] == "0x" + "7" * 64


def test_confirmed_entry_shows_its_approver(auth_header):
    entry_id = _pending_entry(auth_header)
    body = {"deadline": int(time.time()) + 600, "signature": fake_signature(AUDITOR_WALLET), "warning_reason": None}
    assert client.post(f"/entries/{entry_id}/confirm", json=body, headers=auth_header(Role.AUDITOR)).status_code == 200
    listed = next(e for e in client.get("/entries").json() if e["id"] == entry_id)
    assert (listed["status"], listed["approved_by"]) == ("CONFIRMED", 3)


def test_confirm_is_refused_before_reading_the_chain_while_a_rejection_is_in_flight(auth_header, monkeypatch):
    """반려가 처리 중이고 노드가 죽어 있어도 503 이 아니라 409 다"""
    entry_id = _pending_entry(auth_header)
    with _test_session_factory() as db:
        row = db.query(DBEntry).filter(DBEntry.id == entry_id).first()
        row.tx_confirm = "0x" + "7" * 64
        row.rejected_by = 3
        row.reject_reason = "처리 중인 반려"
        db.commit()

    async def chain_is_down(*_):
        raise AssertionError("체인을 읽으면 안 된다")

    monkeypatch.setattr(entries_router, "_get_chain_registrant", chain_is_down)
    body = {"deadline": int(time.time()) + 600, "signature": fake_signature(AUDITOR_WALLET), "warning_reason": None}
    res = client.post(f"/entries/{entry_id}/confirm", json=body, headers=auth_header(Role.AUDITOR))
    assert res.status_code == 409
    assert "반려 처리 중인 내역은 확정할 수 없습니다." in res.json()["detail"]


def test_reject_retry_of_its_own_claim_reaches_the_relay_with_no_open_transaction(auth_header, monkeypatch):
    """내 반려의 ② 는 라우터가 막지 않는다. 릴레이를 부를 때 라우터 세션에 열린 트랜잭션이 없다 (CHAIN_CLIENT §3)"""
    entry_id = _pending_entry(auth_header)
    with _test_session_factory() as db:
        row = db.query(DBEntry).filter(DBEntry.id == entry_id).first()
        row.tx_confirm = "0x" + "7" * 64
        row.rejected_by = 3
        row.reject_reason = "영수증 식별 불가로 인한 반려"
        db.commit()
    seen = []

    async def relay(db, **_):
        seen.append(db.in_transaction())

    monkeypatch.setattr(entries_router, "relay_reject", relay)
    assert _reject_request(entry_id, auth_header).status_code == 200
    assert seen == [False]


@pytest.mark.parametrize(
    "path, relay_name, signer, role",
    [
        ("reject", "relay_reject", AUDITOR_WALLET, Role.AUDITOR),
        ("confirm", "relay_confirm", AUDITOR_WALLET, Role.AUDITOR),
    ],
)
def test_database_failure_during_the_relay_is_503(auth_header, monkeypatch, path, relay_name, signer, role):
    """다시 요청하면 복구되는 상황이다. 일반 서버 오류(500)로 내보내지 않는다"""
    entry_id = _pending_entry(auth_header)

    async def relay(*args, **kwargs):
        raise OperationalError("UPDATE entries", {}, Exception("연결 끊김 (흉내)"))

    monkeypatch.setattr(entries_router, relay_name, relay)
    body = {"deadline": int(time.time()) + 600, "signature": fake_signature(signer), "reject_reason": "사유", "warning_reason": None}
    if path == "confirm":
        body.pop("reject_reason")
    res = client.post(f"/entries/{entry_id}/{path}", json=body, headers=auth_header(role))
    assert res.status_code == 503


def test_confirm_or_reject_when_chain_entry_missing_returns_404(auth_header):
    """DB에는 PENDING이나 체인에 미등록된 항목에 대해 확정/반려 시 404 차단 검증"""
    now = int(time.time())
    # entry 2는 시드 DB에 PENDING이지만 _test_chain._entries에는 없음
    confirm_body = {
        "deadline": now + 600,
        "signature": fake_signature(AUDITOR_WALLET),
        "warning_reason": None,
    }
    res_confirm = client.post("/entries/2/confirm", json=confirm_body, headers=auth_header(Role.AUDITOR))
    assert res_confirm.status_code == 404
    assert "체인에서 항목" in res_confirm.json()["detail"]

    reject_body = {
        "deadline": now + 600,
        "signature": fake_signature(AUDITOR_WALLET),
        "reject_reason": "체인 미등록 건 반려 시도",
    }
    res_reject = client.post("/entries/2/reject", json=reject_body, headers=auth_header(Role.AUDITOR))
    assert res_reject.status_code == 404
    assert "체인에서 항목" in res_reject.json()["detail"]


def test_confirm_when_chain_unavailable_on_get_entry_returns_503(auth_header, monkeypatch):
    """체인 항목 등록자 조회 중 ChainUnavailable 발생 시 503 에스컬레이션 검증"""
    now = int(time.time())
    draft_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 15000,
        "counterparty": "장애테스트점",
        "purpose": "노드 장애 에스컬레이션 검증",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
    }
    res_draft = client.post("/entries", json=draft_body, headers=auth_header(Role.TREASURER))
    entry_id = res_draft.json()["id"]

    res_submit = client.post(
        f"/entries/{entry_id}/submit",
        json={"deadline": now + 600, "signature": fake_signature(TREASURER_WALLET)},
        headers=auth_header(Role.TREASURER),
    )
    assert res_submit.status_code == 200

    async def mock_get_entry(entry_id):
        raise ChainUnavailable("체인 RPC 노드 연결 단절")

    monkeypatch.setattr(_test_chain, "get_entry", mock_get_entry)

    confirm_body = {
        "deadline": now + 600,
        "signature": fake_signature(AUDITOR_WALLET),
        "warning_reason": None,
    }
    res = client.post(f"/entries/{entry_id}/confirm", json=confirm_body, headers=auth_header(Role.AUDITOR))
    assert res.status_code == 503
    assert "블록체인 네트워크와 통신할 수 없습니다." in res.json()["detail"]

def test_get_entry_by_id_success(auth_header):
    """GET /entries/{id} 단건 상세 조회 및 term_code 반환 검증"""
    # id=1 (시드 확정 항목)
    res = client.get("/entries/1")
    assert res.status_code == 200
    data = res.json()
    assert data["id"] == 1
    assert data["term_id"] == 1
    assert data["term_code"] == 20261
    assert data["counterparty"] == "한결문구"
    assert data["amount"] == 35000
    assert data["status"] == "CONFIRMED"


def test_get_entry_by_id_not_found():
    """존재하지 않는 ID 단건 조회 시 404 Not Found 검증"""
    res = client.get("/entries/99999")
    assert res.status_code == 404
    assert "찾을 수 없습니다" in res.json()["detail"]


def test_get_entry_by_id_draft_returns_404(auth_header):
    """POST /entries로 생성된 미제출 초안(status=None)을 단건 조회할 때 404 Not Found 반환 검증 (PRD §4.3)"""
    draft_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 15000,
        "counterparty": "비공개초안문구",
        "purpose": "초안 단건 조회 차단 검증",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
    }
    res_draft = client.post("/entries", json=draft_body, headers=auth_header(Role.TREASURER))
    assert res_draft.status_code == 201
    draft_id = res_draft.json()["id"]

    res_get = client.get(f"/entries/{draft_id}")
    assert res_get.status_code == 404
    assert "찾을 수 없습니다" in res_get.json()["detail"]

# ---------------------------------------------------------------- 문자열 길이 제한 (DB VARCHAR 정합성)


def test_create_entry_counterparty_max_length(auth_header):
    """counterparty(DB VARCHAR(100)) 길이 검증 — NFC·앞뒤 공백 제거 기준 100자 이하 허용, 101자 이상 422 차단"""
    import unicodedata

    base_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 10000,
        "purpose": "상호명 길이 검증",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
    }

    # 1. 정확히 100자 -> 201 통과
    res_100 = client.post(
        "/entries",
        json={**base_body, "counterparty": "가" * 100},
        headers=auth_header(Role.TREASURER),
    )
    assert res_100.status_code == 201

    # 2. 앞뒤 공백 포함 104자이나 정본화 후 100자 -> 201 통과
    res_padded = client.post(
        "/entries",
        json={**base_body, "counterparty": "  " + ("나" * 100) + "  "},
        headers=auth_header(Role.TREASURER),
    )
    assert res_padded.status_code == 201

    # 3. NFD 조합형 한글 100음절(코드포인트 300개)이나 NFC 정본화 후 100자 -> 201 통과
    nfd_100 = unicodedata.normalize("NFD", "한" * 100)
    assert len(nfd_100) > 100
    res_nfd = client.post(
        "/entries",
        json={**base_body, "counterparty": nfd_100},
        headers=auth_header(Role.TREASURER),
    )
    assert res_nfd.status_code == 201

    # 4. 101자 -> 422 차단 (Postgres DataError -> 503 방지)
    res_101 = client.post(
        "/entries",
        json={**base_body, "counterparty": "가" * 101},
        headers=auth_header(Role.TREASURER),
    )
    assert res_101.status_code == 422


@pytest.mark.parametrize(
    "field, value",
    [
        ("receipt_path", "/" + "a" * 255),
        ("receipt_hash", "0x" + "a" * 65),
        ("ocr_approval_no", "1" * 51),
    ],
)
def test_create_entry_optional_string_max_lengths(auth_header, field, value):
    """기타 DB VARCHAR 컬럼(receipt_path 255, receipt_hash 66, ocr_approval_no 50) 초과 시 422 차단"""
    body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 10000,
        "counterparty": "길이검증점",
        "purpose": "부가 문자열 길이 검증",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
        field: value,
    }
    res = client.post("/entries", json=body, headers=auth_header(Role.TREASURER))
    assert res.status_code == 422


# ---------------------------------------------------------------- registrant, onchain endpoint & fail_reason


def test_entry_response_registrant(auth_header):
    """GET /entries 및 GET /entries/{id}에서 온체인 registrant 필드 반환 검증 (체인 미기록 건은 None)"""
    now = int(time.time())
    body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 15000,
        "counterparty": "등록자조회상점",
        "purpose": "온체인 등록자 반환 테스트",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
    }
    res_create = client.post("/entries", json=body, headers=auth_header(Role.TREASURER))
    entry_id = res_create.json()["id"]
    res_sub = client.post(
        f"/entries/{entry_id}/submit",
        json={"deadline": now + 600, "signature": fake_signature(TREASURER_WALLET)},
        headers=auth_header(Role.TREASURER),
    )
    assert res_sub.status_code == 200

    # 1. 온체인 등록된 건 단건 상세 조회 -> registrant 채워짐
    res = client.get(f"/entries/{entry_id}")
    assert res.status_code == 200
    data = res.json()
    assert data["registrant"] is not None
    assert data["registrant"].lower() == TREASURER_WALLET.lower()

    # 2. 목록 조회 -> 온체인 등록된 건은 registrant 채워지고, 체인에 없는 시드 건(id=1)은 None
    res_list = client.get("/entries")
    assert res_list.status_code == 200
    entries = {e["id"]: e for e in res_list.json()}
    assert entries[entry_id]["registrant"].lower() == TREASURER_WALLET.lower()
    assert entries[1]["registrant"] is None


def test_get_entries_and_detail_return_200_when_chain_setup_fails(auth_header):
    """체인 클라이언트 초기화 실패(ChainSetupError 등) 시 GET /entries 및 GET /entries/{id}는 200으로 동작하되 registrant는 null(None)로 두어 앱이 확인 불가 상태를 감지하게 한다 (#66 리뷰 3)."""
    from app.chain import ChainSetupError

    def broken_chain_client():
        raise ChainSetupError("체인 노드 미기동 또는 연결 실패")

    app.dependency_overrides[get_chain_client] = broken_chain_client

    # 1. 목록 조회: 200 OK 및 registrant=None
    res_list = client.get("/entries")
    assert res_list.status_code == 200
    entries = res_list.json()
    assert len(entries) > 0
    assert entries[0]["registrant"] is None
    assert entries[0]["block_number"] is None

    # 2. 단건 상세 조회: 200 OK 및 registrant=None
    res_detail = client.get("/entries/1")
    assert res_detail.status_code == 200
    detail = res_detail.json()
    assert detail["registrant"] is None
    assert detail["block_number"] is None


def test_get_entries_slow_node_returns_200_within_timeout(auth_header, monkeypatch):
    """체인 클라이언트 획득(get_chain_client) 또는 RPC 응답(get_entry)이 지연되어도 GET /entries·GET /entries/{id}가 타임아웃 내에 200 OK와 registrant=None으로 반환된다."""
    import asyncio

    async def slow_chain_client():
        await asyncio.sleep(5.0)
        return _test_chain

    app.dependency_overrides[get_chain_client] = slow_chain_client

    start_t = time.time()
    res_list = client.get("/entries")
    elapsed = time.time() - start_t

    assert res_list.status_code == 200
    assert elapsed < 2.5  # 1.5초 wait_for에 의해 획득 지연까지 포함해 3초 앱 타임아웃 이전에 안전하게 반환
    entries = res_list.json()
    assert len(entries) > 0
    assert entries[0]["registrant"] is None

    start_detail = time.time()
    res_detail = client.get("/entries/1")
    elapsed_detail = time.time() - start_detail
    assert res_detail.status_code == 200
    assert elapsed_detail < 2.8  # 2.0초 wait_for에 의해 획득 지연까지 포함해 안전하게 반환
    assert res_detail.json()["registrant"] is None


def test_get_onchain_entry_endpoint(auth_header):
    """GET /entries/{id}/onchain 엔드포인트 동작 검증"""
    now = int(time.time())
    # 신규 항목 생성 및 submit
    body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 25000,
        "counterparty": "체인조회테스트",
        "purpose": "온체인조회 검증",
        "budget_id": 1,
        "occurred_at": 1788793200,
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
    }
    res_create = client.post("/entries", json=body, headers=auth_header(Role.TREASURER))
    entry_id = res_create.json()["id"]

    res_submit = client.post(
        f"/entries/{entry_id}/submit",
        json={"deadline": now + 600, "signature": fake_signature(TREASURER_WALLET)},
        headers=auth_header(Role.TREASURER),
    )
    assert res_submit.status_code == 200

    # GET /entries/{entry_id}/onchain 호출
    res_onchain = client.get(f"/entries/{entry_id}/onchain")
    assert res_onchain.status_code == 200
    data = res_onchain.json()
    assert data["id"] == entry_id
    assert data["amount"] == 25000
    assert data["kind"] == "EXPENSE"
    assert data["status"] == "PENDING"
    assert data["registrant"].lower() == TREASURER_WALLET.lower()
    assert data["block_number"] is not None

    # 존재하지 않는 체인 항목은 404
    res_not_found = client.get("/entries/99999/onchain")
    assert res_not_found.status_code == 404


def test_confirm_entry_fail_reason_on_chain_revert(auth_header):
    """POST /entries/{id}/confirm 실패(ChainRevert) 시 400과 fail_reason 코드 반환 검증"""
    now = int(time.time())
    body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 30000,
        "counterparty": "예산초과상점",
        "purpose": "확정 실패 사유코드 검증",
        "budget_id": 1,
        "occurred_at": 1788793200,
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
    }
    res_create = client.post("/entries", json=body, headers=auth_header(Role.TREASURER))
    entry_id = res_create.json()["id"]

    client.post(
        f"/entries/{entry_id}/submit",
        json={"deadline": now + 600, "signature": fake_signature(TREASURER_WALLET)},
        headers=auth_header(Role.TREASURER),
    )

    # FakeChainClient에 InsufficientBudget 강제 주입
    _test_chain.fail_next("confirm_entry", RevertReason.INSUFFICIENT_BUDGET)

    confirm_body = {
        "deadline": now + 600,
        "signature": fake_signature(AUDITOR_WALLET),
        "warning_reason": None,
    }
    res_confirm = client.post(
        f"/entries/{entry_id}/confirm",
        json=confirm_body,
        headers=auth_header(Role.AUDITOR),
    )
    assert res_confirm.status_code == 400
    res_json = res_confirm.json()
    assert res_json["fail_reason"] == "InsufficientBudget"
    assert "온체인 승인이 거부되었습니다 (InsufficientBudget)." in res_json["detail"]


def test_reject_entry_fail_reason_on_chain_revert(auth_header):
    """POST /entries/{id}/reject 실패(ChainRevert) 시 400과 fail_reason 코드 반환 검증"""
    now = int(time.time())
    body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 12000,
        "counterparty": "반려테스트점",
        "purpose": "반려 실패 사유코드 검증",
        "budget_id": 1,
        "occurred_at": 1788793200,
        "receipt_hash": TEST_RECEIPT_HASH,
        "receipt_path": TEST_RECEIPT_PATH,
    }
    res_create = client.post("/entries", json=body, headers=auth_header(Role.TREASURER))
    entry_id = res_create.json()["id"]

    client.post(
        f"/entries/{entry_id}/submit",
        json={"deadline": now + 600, "signature": fake_signature(TREASURER_WALLET)},
        headers=auth_header(Role.TREASURER),
    )

    # FakeChainClient에 InvalidStatus 강제 주입
    _test_chain.fail_next("reject_entry", RevertReason.INVALID_STATUS)

    reject_body = {
        "deadline": now + 600,
        "signature": fake_signature(AUDITOR_WALLET),
        "reject_reason": "증빙 불충분으로 반려합니다.",
    }
    res_reject = client.post(
        f"/entries/{entry_id}/reject",
        json=reject_body,
        headers=auth_header(Role.AUDITOR),
    )
    assert res_reject.status_code == 400
    res_json = res_reject.json()
    assert res_json["fail_reason"] == "InvalidStatus"
    assert "온체인 반려가 거부되었습니다 (InvalidStatus)." in res_json["detail"]


# ---------------------------------------------------------------- B2, B3, B4 영수증 필수화·해시검증·중복경고 신규 회귀 테스트


def test_expense_requires_receipt_hash_returns_400(auth_header):
    """B2: 지출(EXPENSE) 등록 시 영수증(receipt_hash)이 없으면 400 Bad Request 반환"""
    body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 10000,
        "counterparty": "해시누락점",
        "purpose": "영수증 없는 지출 차단",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": None,
    }
    res = client.post("/entries", json=body, headers=auth_header(Role.TREASURER))
    assert res.status_code == 400
    assert "영수증(receipt_hash)은 필수입니다" in res.json()["detail"]


def test_income_optional_receipt_hash_returns_201(auth_header):
    """B2: 수입(INCOME) 등록 시 영수증(receipt_hash)이 없어도 201 Created 정상 성공"""
    body = {
        "term_id": 1,
        "kind": "INCOME",
        "amount": 100000,
        "counterparty": "영수증없는수입원",
        "purpose": "학생회비 납부",
        "budget_id": None,
        "occurred_at": 1788793200,
        "receipt_hash": None,
    }
    res = client.post("/entries", json=body, headers=auth_header(Role.TREASURER))
    assert res.status_code == 201
    assert "id" in res.json()


def test_receipt_hash_format_validation(auth_header):
    """B3: 영수증 해시는 0x로 시작하는 64자리 소문자 hex여야 하며, 대문자/길이오류/접두사 누락 시 400 차단"""
    base_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 10000,
        "counterparty": "해시형식검증점",
        "purpose": "해시 형식 검증",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_path": TEST_RECEIPT_PATH,
    }

    # 1. 대문자 포함 시 400
    res_upper = client.post(
        "/entries",
        json={**base_body, "receipt_hash": "0x" + "A" * 64},
        headers=auth_header(Role.TREASURER),
    )
    assert res_upper.status_code == 400
    assert "소문자 16진수" in res_upper.json()["detail"]

    # 2. 0x 접두사 누락 시 400
    res_no_prefix = client.post(
        "/entries",
        json={**base_body, "receipt_hash": "a" * 64},
        headers=auth_header(Role.TREASURER),
    )
    assert res_no_prefix.status_code == 400
    assert "소문자 16진수" in res_no_prefix.json()["detail"]

    # 3. 길이 부족(63자) 시 400
    res_short = client.post(
        "/entries",
        json={**base_body, "receipt_hash": "0x" + "a" * 63},
        headers=auth_header(Role.TREASURER),
    )
    assert res_short.status_code == 400
    assert "소문자 16진수" in res_short.json()["detail"]


def test_receipt_file_not_found_returns_400(auth_header):
    """B2: 서버 저장소에 존재하지 않는 파일/미업로드 해시는 400 Bad Request 차단"""
    body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 10000,
        "counterparty": "유령파일상점",
        "purpose": "존재하지 않는 영수증 등록 차단",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": "0x" + "f" * 64,
        "receipt_path": "/receipts/non_existent_file_12345.jpg",
    }
    res = client.post("/entries", json=body, headers=auth_header(Role.TREASURER))
    assert res.status_code == 400
    assert "서버에 존재하지 않는 영수증입니다" in res.json()["detail"]


def test_duplicate_receipt_hash_sets_ocr_status_duplicate(auth_header):
    """B4: 동일한 receipt_hash 중복 등록 시 409 대신 201 Created 및 ocr_status=DUPLICATE 경고 전환 검증"""
    body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 20000,
        "counterparty": "해시중복상점",
        "purpose": "중복 영수증 해시 등록",
        "budget_id": 2,
        "occurred_at": 1788793200,
        # 시드 e1의 receipt_hash 중복 사용
        "receipt_hash": "0xabc1234567890abcdef1234567890abcdef1234567890abcdef1234567890abc",
        "receipt_path": TEST_RECEIPT_PATH,
        "ocr_amount": 20000,
        "ocr_approval_no": "99998888",
        "ocr_paid_at": 1788825820,
        "ocr_status": "MATCH",
    }
    res = client.post("/entries", json=body, headers=auth_header(Role.TREASURER))
    assert res.status_code == 201
    data = res.json()
    assert data["id"] is not None

    with _test_session_factory() as db:
        row = db.query(DBEntry).filter(DBEntry.id == data["id"]).first()
        assert row is not None
        assert row.ocr_status == "DUPLICATE"


def test_duplicate_receipt_ignores_rejected_and_blocked(auth_header):
    """반려(REJECTED)되거나 예산초과 차단(BLOCKED)된 항목의 영수증으로 재등록 시 DUPLICATE 경고가 붙지 않음"""
    # 1. 시드 DB의 e1을 REJECTED 상태로 변경
    with _test_session_factory() as db:
        e1 = db.query(DBEntry).filter(DBEntry.id == 1).first()
        e1.status = "REJECTED"
        e1.reject_reason = "영수증 식별 불가"
        e1.rejected_by = 3
        db.commit()

    # e1과 동일한 영수증 해시로 재등록 시도
    body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 20000,
        "counterparty": "재등록상점",
        "purpose": "반려 후 재등록",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": "0xabc1234567890abcdef1234567890abcdef1234567890abcdef1234567890abc",
        "receipt_path": TEST_RECEIPT_PATH,
        "ocr_amount": 20000,
        "ocr_approval_no": "99998888",
        "ocr_paid_at": 1788825820,
        "ocr_status": "MATCH",
    }
    res = client.post("/entries", json=body, headers=auth_header(Role.TREASURER))
    assert res.status_code == 201
    data = res.json()

    with _test_session_factory() as db:
        row = db.query(DBEntry).filter(DBEntry.id == data["id"]).first()
        assert row is not None
        # REJECTED 항목은 제외되었으므로 MATCH 상태 유지 (DUPLICATE 아님)
        assert row.ocr_status == "MATCH"


def test_correction_expense_optional_receipt_hash(auth_header):
    """음수 감액 정정 지출(corrects_entry_id 있음, amount < 0)은 영수증(receipt_hash) 없이 201 성공하되,
    양수 증액·재분류 정정 지출(amount > 0)은 영수증이 없으면 400 Bad Request로 차단 (docs/HASHING.md 샘플 3, PRD §13)"""
    body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": -10000,
        "counterparty": "환불문구점",
        "purpose": "물품 반품 환불 정정",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "corrects_entry_id": 1,
        "correction_reason": "REFUND",
        "receipt_hash": None,
        "receipt_path": None,
    }
    res = client.post("/entries", json=body, headers=auth_header(Role.TREASURER))
    assert res.status_code == 201
    assert "id" in res.json()

    # 양수 정정 지출에 영수증 누락 시 400 차단
    pos_body = {
        **body,
        "amount": 10000,
        "purpose": "양수 정정 영수증 누락",
        "correction_reason": "RECLASSIFY",
        "budget_id": 1,
    }
    res_pos = client.post("/entries", json=pos_body, headers=auth_header(Role.TREASURER))
    assert res_pos.status_code == 400
    assert "영수증(receipt_hash)은 필수" in res_pos.json()["detail"]


def test_arbitrary_server_file_path_without_uploaded_hash_returns_400(auth_header):
    """서버의 아무 파일(app/main.py 등) 경로를 지정해도 미업로드 해시이면 400 Bad Request 차단 (리뷰어 피드백 1)"""
    body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 15000,
        "counterparty": "임의경로상점",
        "purpose": "서버 내부 파일 도용 시도",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": "0x" + "1" * 64,  # 저장소에 없는 해시
        "receipt_path": "backend/app/main.py",  # 실제 존재하는 서버 파일
    }
    res = client.post("/entries", json=body, headers=auth_header(Role.TREASURER))
    assert res.status_code == 400
    assert "서버에 존재하지 않는 영수증" in res.json()["detail"]


def test_server_resolves_and_overwrites_receipt_path(auth_header):
    """클라이언트가 receipt_path에 엉뚱한 경로를 보내도, 서버가 해시로 찾은 실제 파일 경로(/receipts/{hash}.*)로 덮어씌움 (리뷰어 피드백 1)"""
    body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 15000,
        "counterparty": "경로보정상점",
        "purpose": "서버 경로 보정 확인",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": TEST_RECEIPT_HASH,  # conftest에서 준비한 'a'*64.jpg
        "receipt_path": "/fake/wrong/path.jpg",
    }
    res = client.post("/entries", json=body, headers=auth_header(Role.TREASURER))
    assert res.status_code == 201
    entry_id = res.json()["id"]

    with _test_session_factory() as db:
        row = db.query(DBEntry).filter(DBEntry.id == entry_id).first()
        assert row is not None
        # 클라이언트의 /fake/wrong/path.jpg 가 아니라 실제 저장소 파일명으로 채워짐
        assert row.receipt_path == f"/receipts/{'a' * 64}.jpg"


def test_duplicate_check_ignores_draft_entries(auth_header):
    """제출되지 않은 미제출 초안(status NULL)끼리는 영수증이 같아도 DUPLICATE가 되지 않음 (리뷰어 피드백 2)"""
    # 1. 초안 1 생성 (status NULL)
    body1 = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 25000,
        "counterparty": "초안상점1",
        "purpose": "미제출 초안 1",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": TEST_RECEIPT_HASH,
        "ocr_status": "MATCH",
    }
    res1 = client.post("/entries", json=body1, headers=auth_header(Role.TREASURER))
    assert res1.status_code == 201
    id1 = res1.json()["id"]

    # 2. 동일한 영수증 해시로 초안 2 생성 -> 초안 1은 PENDING/CONFIRMED가 아니므로 중복 걸리지 않음
    body2 = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 25000,
        "counterparty": "초안상점2",
        "purpose": "미제출 초안 2",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": TEST_RECEIPT_HASH,
        "ocr_status": "MATCH",
    }
    res2 = client.post("/entries", json=body2, headers=auth_header(Role.TREASURER))
    assert res2.status_code == 201
    id2 = res2.json()["id"]

    with _test_session_factory() as db:
        row2 = db.query(DBEntry).filter(DBEntry.id == id2).first()
        assert row2.ocr_status == "MATCH"  # 아직 둘 다 초안이므로 DUPLICATE 아님!

    # 3. 초안 1 제출(PENDING) 후 초안 2 제출(submit) 시 -> submit 단계 재검사에서 DUPLICATE로 전환됨 (#66 리뷰 2)
    now = int(time.time())
    sub1 = client.post(
        f"/entries/{id1}/submit",
        json={"deadline": now + 600, "signature": fake_signature(TREASURER_WALLET)},
        headers=auth_header(Role.TREASURER),
    )
    assert sub1.status_code == 200

    sub2 = client.post(
        f"/entries/{id2}/submit",
        json={"deadline": now + 600, "signature": fake_signature(TREASURER_WALLET)},
        headers=auth_header(Role.TREASURER),
    )
    assert sub2.status_code == 200

    detail2 = client.get(f"/entries/{id2}").json()
    assert detail2["ocr_status"] == "DUPLICATE"
    assert detail2["duplicate_of"] == id1


def test_duplicate_check_concurrent_submit(auth_header):
    """같은 영수증의 초안 A·B를 동시에 제출(asyncio.gather)해도 나중 건이 DUPLICATE로 갱신되어 두 건 모두 MATCH로 남지 않음 검증 (#66 Codex 2차)"""
    import asyncio
    from app.schemas.entry import EntrySubmitRequest

    now = int(time.time())
    draft_ids = []
    for idx in (1, 2):
        res = client.post(
            "/entries",
            json={
                "term_id": 1,
                "kind": "EXPENSE",
                "amount": 27000,
                "counterparty": f"동시제출상점{idx}",
                "purpose": f"동시 제출 초안 {idx}",
                "budget_id": 2,
                "occurred_at": 1788793200,
                "receipt_hash": TEST_RECEIPT_HASH,
                "ocr_status": "MATCH",
            },
            headers=auth_header(Role.TREASURER),
        )
        assert res.status_code == 201
        draft_ids.append(res.json()["id"])

    id_a, id_b = draft_ids
    treasurer = next(u for u in users.SEED_USERS if u.role == Role.TREASURER)
    submit_req = EntrySubmitRequest(deadline=now + 600, signature=fake_signature(TREASURER_WALLET))

    async def _run_concurrent_submits():
        with _test_session_factory() as db1, _test_session_factory() as db2:
            return await asyncio.gather(
                entries_router.submit_entry(id=id_a, req=submit_req, user=treasurer, db=db1, chain=_test_chain),
                entries_router.submit_entry(id=id_b, req=submit_req, user=treasurer, db=db2, chain=_test_chain),
            )

    res_a, res_b = asyncio.run(_run_concurrent_submits())
    assert res_a.status == "PENDING"
    assert res_b.status == "PENDING"

    detail_a = client.get(f"/entries/{id_a}").json()
    detail_b = client.get(f"/entries/{id_b}").json()
    statuses = {detail_a["ocr_status"], detail_b["ocr_status"]}
    assert statuses == {"MATCH", "DUPLICATE"}


def test_duplicate_check_ignores_correction_original_entry(auth_header):
    """정정 건이 원본 영수증을 그대로 다시 붙여도 원본 건(corrects_entry_id) 및 같은 원본을 고치는 다른 정정 건은 중복 대조에서 제외됨 (리뷰어 피드백)"""
    # e1은 시드 DB에서 CONFIRMED 상태인 확정 건
    with _test_session_factory() as db:
        e1 = db.query(DBEntry).filter(DBEntry.id == 1).first()
        e1_hash = e1.receipt_hash

    # 1. 원본 #1에 재분류 양수 정정(+5000, 원본 영수증)을 등록하고 PENDING으로 전환
    pos_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 5000,
        "counterparty": "한결문구",
        "purpose": "재분류 양수 정정 (+)",
        "budget_id": 1,
        "occurred_at": 1788793200,
        "corrects_entry_id": 1,
        "correction_reason": "RECLASSIFY",
        "receipt_hash": e1_hash,
        "ocr_status": "MATCH",
    }
    res_pos = client.post("/entries", json=pos_body, headers=auth_header(Role.TREASURER))
    assert res_pos.status_code == 201
    assert res_pos.json()["duplicate_of"] is None
    pos_id = res_pos.json()["id"]

    with _test_session_factory() as db:
        pos_row = db.query(DBEntry).filter(DBEntry.id == pos_id).first()
        assert pos_row.ocr_status == "MATCH"
        pos_row.status = "PENDING"
        db.commit()

    # 2. 같은 원본 #1에 재분류 음수 정정(-5000, 같은 원본 영수증) 등록 -> 양수 정정(pos_id)이 PENDING이어도 같은 원본 정정이므로 중복 아님!
    neg_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": -5000,
        "counterparty": "한결문구",
        "purpose": "재분류 음수 정정 (-)",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "corrects_entry_id": 1,
        "correction_reason": "RECLASSIFY",
        "receipt_hash": e1_hash,
        "ocr_status": "MATCH",
    }
    res_neg = client.post("/entries", json=neg_body, headers=auth_header(Role.TREASURER))
    assert res_neg.status_code == 201
    assert res_neg.json()["duplicate_of"] is None
    neg_id = res_neg.json()["id"]

    with _test_session_factory() as db:
        neg_row = db.query(DBEntry).filter(DBEntry.id == neg_id).first()
        # 원본 건(e1)과 같은 원본의 정정 건(pos_id) 모두 제외되었으므로 DUPLICATE가 되지 않고 MATCH 유지
        assert neg_row.ocr_status == "MATCH"


def test_duplicate_sets_duplicate_of_in_response_and_query(auth_header):
    """확정 건과 중복 시 duplicate_of에 기존 건 ID가 반환되고 상세 조회에서도 확인됨 (리뷰어 피드백 4)"""
    # e1은 시드 DB에서 CONFIRMED 상태인 ID=1 항목
    body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 35000,
        "counterparty": "중복발생상점",
        "purpose": "중복 건 duplicate_of 테스트",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": "0xabc1234567890abcdef1234567890abcdef1234567890abcdef1234567890abc",
        "ocr_status": "MATCH",
    }
    res = client.post("/entries", json=body, headers=auth_header(Role.TREASURER))
    assert res.status_code == 201
    data = res.json()
    assert data["duplicate_of"] == 1  # e1의 id=1을 지목!

    # GET /entries/{id} 상세 조회에서도 duplicate_of 가 내려오는지 확인
    # (단, 상세 조회를 위해 임시로 status='PENDING' 부여)
    with _test_session_factory() as db:
        e = db.query(DBEntry).filter(DBEntry.id == data["id"]).first()
        e.status = "PENDING"
        db.commit()

    res_detail = client.get(f"/entries/{data['id']}")
    assert res_detail.status_code == 200
    assert res_detail.json()["duplicate_of"] == 1
    assert res_detail.json()["ocr_status"] == "DUPLICATE"


