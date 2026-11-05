import asyncio
import os
import time
from datetime import datetime, timezone
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

os.environ["CHAIN_FAKE"] = "1"
os.environ["JWT_DEV_SECRET"] = "1"

from app.auth import users
from app.auth.security import create_access_token
from app.chain import (
    BudgetRevertReason,
    ChainBudget,
    ChainSetupError,
    ChainUnavailable,
    FakeChainClient,
    fake_signature,
)
from app.chain.eip712 import category_hash
from app.chain.provider import get_chain_client
from app.database import Base, get_db
from app.main import app
from app.models import (
    Budget as DBBudget,
    BudgetRevisionRequest as DBBudgetRevisionRequest,
    BudgetVersion as DBBudgetVersion,
    Entry as DBEntry,
    Term as DBTerm,
    User as DBUser,
)
from app.routers import budget_revisions as budget_revisions_router
from app.schemas.auth import Role
from app.services.notifications import NotificationKind

client = TestClient(app)

_test_session_factory = None
_test_chain: FakeChainClient = None

TREASURER_WALLET = next(u.wallet_address for u in users.SEED_USERS if u.role == Role.TREASURER)
AUDITOR_WALLET = next(u.wallet_address for u in users.SEED_USERS if u.role == Role.AUDITOR)
PRESIDENT_WALLET = next(u.wallet_address for u in users.SEED_USERS if u.role == Role.PRESIDENT)


@pytest.fixture
def auth_header():
    def _make(role: Role) -> dict:
        matched = next(u for u in users.SEED_USERS if u.role == role)
        token = create_access_token(matched.id)
        return {"Authorization": f"Bearer {token}"}

    return _make


@pytest.fixture(autouse=True)
def setup_test_db(tmp_path):
    """각 테스트마다 격리된 임시 SQLite DB와 FakeChainClient를 생성하고 시드 데이터를 주입합니다."""
    global _test_session_factory, _test_chain
    db_file = tmp_path / "test_rev.db"
    engine = create_engine(
        f"sqlite:///{db_file}",
        connect_args={"check_same_thread": False},
    )
    Base.metadata.create_all(bind=engine)
    TestingSession = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    _test_session_factory = TestingSession

    _test_chain = FakeChainClient()
    _test_chain._budgets[1] = ChainBudget(
        id=1,
        term=20261,
        category=category_hash("운영비"),
        issued=1000000,
        spent=0,
        expires_at=1798704000,
        version=1,
        reclaim_count=0,
    )

    with TestingSession() as db:
        # 1. Users (1: 학생, 2: 총무, 3: 감사, 4: 회장 등)
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

        # 2. Term (id=1, term_code=20261)
        term = DBTerm(
            id=1,
            term_code=20261,
            name="2026-1학기",
            started_at=datetime.fromtimestamp(1772323200, tz=timezone.utc),
            ended_at=datetime.fromtimestamp(1788163200, tz=timezone.utc),
        )
        db.add(term)

        # 3. Budget (id=1, 운영비) & BudgetVersion v1 (100만원)
        budget = DBBudget(
            id=1,
            term_id=1,
            category="운영비",
            expires_at=datetime.fromtimestamp(1798704000, tz=timezone.utc),
            tx_issue="0x" + "11" * 32,
        )
        db.add(budget)
        db.flush()

        bv1 = DBBudgetVersion(
            budget_id=1,
            version=1,
            planned_amount=1000000,
            approved_by=4,
            tx_hash="0x" + "11" * 32,
        )
        db.add(bv1)

        # 4. Blocked Entry (id=10, 한도 초과 차단 지출)
        blocked_entry = DBEntry(
            id=10,
            term_id=1,
            kind="EXPENSE",
            amount=500000,
            counterparty="오피스문구",
            purpose="신학기 사무용품 대량 구매",
            budget_id=1,
            occurred_at=1788793200,
            status="BLOCKED",
            block_reason="BUDGET_EXCEEDED",
            created_by=2,
        )
        db.add(blocked_entry)

        # 5. Confirmed Entry (id=11, 이미 확정된 정상 지출)
        confirmed_entry = DBEntry(
            id=11,
            term_id=1,
            kind="EXPENSE",
            amount=30000,
            counterparty="복사실",
            purpose="회의자료 인쇄",
            budget_id=1,
            occurred_at=1788793200,
            status="CONFIRMED",
            created_by=2,
        )
        db.add(confirmed_entry)

        # 6. Budget 2 (id=2, 행사비 — BudgetVersion이 없는 초안 상태)
        budget2 = DBBudget(
            id=2,
            term_id=1,
            category="행사비",
            expires_at=datetime.fromtimestamp(1798704000, tz=timezone.utc),
        )
        db.add(budget2)

        # 7. Income Entry (id=12, PENDING 상태 수입)
        income_entry = DBEntry(
            id=12,
            term_id=1,
            kind="INCOME",
            amount=100000,
            counterparty="동문회",
            purpose="지원금",
            budget_id=None,
            occurred_at=1788793200,
            status="PENDING",
            created_by=2,
        )
        db.add(income_entry)

        # 8. 행사비 차단 지출 (id=13, BLOCKED 지출이지만 budget_id=2)
        diff_budget_entry = DBEntry(
            id=13,
            term_id=1,
            kind="EXPENSE",
            amount=700000,
            counterparty="공연기획사",
            purpose="축제 무대 음향",
            budget_id=2,
            occurred_at=1788793200,
            status="BLOCKED",
            block_reason="BUDGET_EXCEEDED",
            created_by=2,
        )
        db.add(diff_budget_entry)

        # 9. 만료된 예산 (id=3, category="사업비", 과거 시각)
        expired_budget = DBBudget(
            id=3,
            term_id=1,
            category="사업비",
            expires_at=datetime.fromtimestamp(1000000000, tz=timezone.utc),
        )
        db.add(expired_budget)
        db.flush()
        db.add(
            DBBudgetVersion(
                budget_id=3,
                version=1,
                planned_amount=500000,
                approved_by=4,
            )
        )

        db.commit()

    def override_get_db():
        db = _test_session_factory()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_chain_client] = lambda: _test_chain
    yield
    app.dependency_overrides.clear()


# =========================================================================
# A2: 1단계 증액 요청 (총무) 테스트
# =========================================================================


def test_create_budget_revision_success(auth_header):
    """총무가 예산 증액을 정상적으로 요청하면 201 Created와 PENDING 상태 응답을 받는다."""
    body = {
        "term_id": 1,
        "category": "운영비",
        "requested_amount": 500000,
        "reason": "신학기 비품 구매로 인한 운영비 부족",
    }
    response = client.post(
        "/budget-revisions",
        json=body,
        headers=auth_header(Role.TREASURER),
    )
    assert response.status_code == 201
    data = response.json()
    assert data["id"] > 0
    assert data["term_id"] == 1
    assert data["category"] == "운영비"
    assert data["budget_id"] == 1
    assert data["requested_amount"] == 500000
    assert data["reason"] == "신학기 비품 구매로 인한 운영비 부족"
    assert data["status"] == "PENDING"
    assert data["blocked_entry_id"] is None
    assert data["president_signed_by"] is None


def test_create_budget_revision_with_blocked_entry(auth_header):
    """차단 지출(BLOCKED) 연계 증액 요청 시 blocked_entry_id가 정상적으로 저장된다."""
    body = {
        "term_id": 1,
        "category": "운영비",
        "requested_amount": 500000,
        "reason": "한도 초과 차단 지출 건 구제 요청",
        "blocked_entry_id": 10,
    }
    response = client.post(
        "/budget-revisions",
        json=body,
        headers=auth_header(Role.TREASURER),
    )
    assert response.status_code == 201
    data = response.json()
    assert data["blocked_entry_id"] == 10
    assert data["status"] == "PENDING"


@pytest.mark.parametrize("role", [Role.STUDENT, Role.AUDITOR, Role.PRESIDENT])
def test_create_budget_revision_forbidden_for_non_treasurer(auth_header, role):
    """총무(TREASURER) 이외의 사용자는 증액 요청을 할 수 없다 (403 Forbidden)."""
    body = {
        "term_id": 1,
        "category": "운영비",
        "requested_amount": 100000,
        "reason": "권한 없는 요청",
    }
    response = client.post(
        "/budget-revisions",
        json=body,
        headers=auth_header(role),
    )
    assert response.status_code == 403


def test_create_budget_revision_invalid_amount(auth_header):
    """증액 요청액이 0원 이하인 경우 거부된다 (400 또는 422)."""
    body = {
        "term_id": 1,
        "category": "운영비",
        "requested_amount": 0,
        "reason": "0원 증액 요청",
    }
    response = client.post(
        "/budget-revisions",
        json=body,
        headers=auth_header(Role.TREASURER),
    )
    assert response.status_code in (400, 422)


@pytest.mark.parametrize("bad_reason", ["   \t\n  ", "사유\x00널문자", "사유\u200b제로폭", "사유\u00a0NBSP"])
def test_create_budget_revision_invalid_reason_rejected(auth_header, bad_reason):
    """공백만 있거나 금지 제어문자/공백류가 포함된 사유는 400으로 차단된다."""
    response = client.post(
        "/budget-revisions",
        json={
            "term_id": 1,
            "category": "운영비",
            "requested_amount": 100000,
            "reason": bad_reason,
        },
        headers=auth_header(Role.TREASURER),
    )
    assert response.status_code == 400


def test_create_budget_revision_term_not_found(auth_header):
    """존재하지 않는 학기로 요청 시 404 Not Found를 반환한다."""
    body = {
        "term_id": 99999,
        "category": "운영비",
        "requested_amount": 100000,
        "reason": "학기 없음",
    }
    response = client.post(
        "/budget-revisions",
        json=body,
        headers=auth_header(Role.TREASURER),
    )
    assert response.status_code == 404


def test_create_budget_revision_expired_budget_rejected(auth_header):
    """집행 마감일(expires_at)이 경과한 예산은 증액 요청 시 400 Bad Request로 차단된다."""
    response = client.post(
        "/budget-revisions",
        json={
            "term_id": 1,
            "category": "사업비",
            "requested_amount": 100000,
            "reason": "마감 지난 예산 증액 시도",
        },
        headers=auth_header(Role.TREASURER),
    )
    assert response.status_code == 400
    assert "마감일" in response.json()["detail"] and "경과" in response.json()["detail"]


def test_create_budget_revision_draft_budget_without_version_rejected(auth_header):
    """버전(BudgetVersion)이 없는 초안 예산에 대한 증액 요청은 400 Bad Request로 차단된다."""
    response = client.post(
        "/budget-revisions",
        json={
            "term_id": 1,
            "category": "행사비",
            "requested_amount": 100000,
            "reason": "초안 예산 증액 시도",
        },
        headers=auth_header(Role.TREASURER),
    )
    assert response.status_code == 400
    assert "초안 예산" in response.json()["detail"]


def test_create_budget_revision_target_budget_not_found(auth_header):
    """기존 예산이 없는 항목으로 증액 요청 시 404 Not Found를 반환한다 (PRD §4.1)."""
    res1 = client.post(
        "/budget-revisions",
        json={
            "term_id": 1,
            "category": "존재하지않는예산",
            "requested_amount": 100000,
            "reason": "없는 예산 증액 시도",
        },
        headers=auth_header(Role.TREASURER),
    )
    assert res1.status_code == 404
    assert "기존 예산이 존재하지 않습니다" in res1.json()["detail"]

    res2 = client.post(
        "/budget-revisions",
        json={
            "term_id": 1,
            "category": "운영비",
            "budget_id": 99999,
            "requested_amount": 100000,
            "reason": "없는 budget_id 지정",
        },
        headers=auth_header(Role.TREASURER),
    )
    assert res2.status_code == 404


def test_create_budget_revision_blocked_entry_validation(auth_header):
    """존재하지 않거나, 지출(EXPENSE)이 아니거나, 차단 상태가 아니거나, 예산이 불일치하는 연동은 거부된다."""
    res1 = client.post(
        "/budget-revisions",
        json={
            "term_id": 1,
            "category": "운영비",
            "requested_amount": 100000,
            "reason": "없는 지출 연동",
            "blocked_entry_id": 99999,
        },
        headers=auth_header(Role.TREASURER),
    )
    assert res1.status_code == 404

    res2 = client.post(
        "/budget-revisions",
        json={
            "term_id": 1,
            "category": "운영비",
            "requested_amount": 100000,
            "reason": "확정 지출 연동",
            "blocked_entry_id": 11,
        },
        headers=auth_header(Role.TREASURER),
    )
    assert res2.status_code == 400

    res3 = client.post(
        "/budget-revisions",
        json={
            "term_id": 1,
            "category": "운영비",
            "requested_amount": 100000,
            "reason": "수입 내역 연동 시도",
            "blocked_entry_id": 12,
        },
        headers=auth_header(Role.TREASURER),
    )
    assert res3.status_code == 400
    assert "지출(EXPENSE)" in res3.json()["detail"]

    res4 = client.post(
        "/budget-revisions",
        json={
            "term_id": 1,
            "category": "운영비",
            "requested_amount": 100000,
            "reason": "다른 예산 차단 지출 연동 시도",
            "blocked_entry_id": 13,
        },
        headers=auth_header(Role.TREASURER),
    )
    assert res4.status_code == 400
    assert "예산과 증액 요청 대상 예산이 일치하지 않습니다" in res4.json()["detail"]


def test_list_and_get_budget_revisions_restricted_to_council(auth_header):
    """증액 요청 목록 및 단건 조회는 학생회 임원만 가능하며 학생 토큰은 403으로 차단된다."""
    create_res = client.post(
        "/budget-revisions",
        json={
            "term_id": 1,
            "category": "운영비",
            "requested_amount": 300000,
            "reason": "목록 조회 테스트",
        },
        headers=auth_header(Role.TREASURER),
    )
    assert create_res.status_code == 201
    rev_id = create_res.json()["id"]

    # 학생은 목록 및 단건 조회 모두 403
    assert client.get("/budget-revisions", headers=auth_header(Role.STUDENT)).status_code == 403
    assert client.get(f"/budget-revisions/{rev_id}", headers=auth_header(Role.STUDENT)).status_code == 403

    # 임원(총무·감사·회장)은 정상 조회
    list_res = client.get("/budget-revisions", headers=auth_header(Role.TREASURER))
    assert list_res.status_code == 200
    items = list_res.json()
    assert len(items) >= 1
    assert any(item["id"] == rev_id for item in items)

    get_res = client.get(f"/budget-revisions/{rev_id}", headers=auth_header(Role.AUDITOR))
    assert get_res.status_code == 200
    assert get_res.json()["id"] == rev_id
    assert get_res.json()["requested_amount"] == 300000

    not_found_res = client.get("/budget-revisions/99999", headers=auth_header(Role.AUDITOR))
    assert not_found_res.status_code == 404


# =========================================================================
# A3: 2단계 회장 서명 / 반려 & 서명 시한 만료 처리 테스트
# =========================================================================


def _create_pending_revision(auth_header, amount=500000):
    res = client.post(
        "/budget-revisions",
        json={
            "term_id": 1,
            "category": "운영비",
            "requested_amount": amount,
            "reason": "운영비 증액 신청",
        },
        headers=auth_header(Role.TREASURER),
    )
    assert res.status_code == 201
    return res.json()["id"]


def test_president_sign_success(auth_header):
    """회장이 유효한 EIP-712 서명으로 서명하면 200 OK와 PRESIDENT_SIGNED 상태 응답을 받는다."""
    rev_id = _create_pending_revision(auth_header)
    future_deadline = int(time.time()) + 86400
    pres_sig = fake_signature(PRESIDENT_WALLET)

    sign_body = {
        "president_signature": pres_sig,
        "signature_deadline": future_deadline,
        "signed_version": 1,
    }
    response = client.post(
        f"/budget-revisions/{rev_id}/sign",
        json=sign_body,
        headers=auth_header(Role.PRESIDENT),
    )
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "PRESIDENT_SIGNED"
    assert data["president_signed_by"] == 4
    assert data["president_signature"] == pres_sig
    assert data["signature_deadline"] == future_deadline
    assert data["signed_version"] == 1


def test_president_sign_invalid_or_mismatched_signature_rejected(auth_header):
    """형식이 잘못된 서명이나 다른 지갑의 서명은 400 Bad Request로 거부된다."""
    rev_id = _create_pending_revision(auth_header)
    future_deadline = int(time.time()) + 86400

    # 1. 잘못된 형식("not-a-signature")
    res_malformed = client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": "not-a-signature",
            "signature_deadline": future_deadline,
            "signed_version": 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert res_malformed.status_code == 400
    assert "서명 형식" in res_malformed.json()["detail"]

    # 2. 다른 지갑(총무 지갑)으로 서명
    res_wrong_signer = client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": fake_signature(TREASURER_WALLET),
            "signature_deadline": future_deadline,
            "signed_version": 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert res_wrong_signer.status_code == 400
    assert "일치하지 않습니다" in res_wrong_signer.json()["detail"]

    # 3. 잘못된 signed_version (현재 v1인데 v2로 서명)
    res_wrong_ver = client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": fake_signature(PRESIDENT_WALLET),
            "signature_deadline": future_deadline,
            "signed_version": 2,
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert res_wrong_ver.status_code == 400
    assert "버전" in res_wrong_ver.json()["detail"]


def test_president_sign_expired_budget_rejected(auth_header):
    """요청 생성 후 예산 마감일(expires_at)이 지난 경우 회장 서명 단계에서 400으로 차단된다."""
    rev_id = _create_pending_revision(auth_header)
    with _test_session_factory() as db:
        b = db.query(DBBudget).filter_by(id=1).first()
        b.expires_at = datetime.fromtimestamp(int(time.time()) - 10, tz=timezone.utc)
        db.commit()

    res = client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": fake_signature(PRESIDENT_WALLET),
            "signature_deadline": int(time.time()) + 86400,
            "signed_version": 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert res.status_code == 400
    assert "마감일" in res.json()["detail"]


@pytest.mark.parametrize("role", [Role.STUDENT, Role.TREASURER, Role.AUDITOR])
def test_president_sign_forbidden_for_non_president(auth_header, role):
    """회장 이외의 사용자는 회장 서명을 수행할 수 없다 (403 Forbidden)."""
    rev_id = _create_pending_revision(auth_header)
    response = client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": fake_signature(PRESIDENT_WALLET),
            "signature_deadline": int(time.time()) + 86400,
            "signed_version": 1,
        },
        headers=auth_header(role),
    )
    assert response.status_code == 403


def test_president_sign_expired_deadline_rejected(auth_header):
    """서명 만료 시한이 과거 시각인 경우 400 Bad Request로 거부된다."""
    rev_id = _create_pending_revision(auth_header)
    past_deadline = int(time.time()) - 100

    response = client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": fake_signature(PRESIDENT_WALLET),
            "signature_deadline": past_deadline,
            "signed_version": 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert response.status_code == 400
    assert "현재 시각 이후" in response.json()["detail"]


def test_president_sign_invalid_state_rejected(auth_header):
    """이미 회장 서명이 완료되었거나 처리 완료된 요청에 다시 서명 시도하면 400 Bad Request."""
    rev_id = _create_pending_revision(auth_header)
    future_deadline = int(time.time()) + 86400
    body = {
        "president_signature": fake_signature(PRESIDENT_WALLET),
        "signature_deadline": future_deadline,
        "signed_version": 1,
    }
    res1 = client.post(f"/budget-revisions/{rev_id}/sign", json=body, headers=auth_header(Role.PRESIDENT))
    assert res1.status_code == 200

    res2 = client.post(f"/budget-revisions/{rev_id}/sign", json=body, headers=auth_header(Role.PRESIDENT))
    assert res2.status_code == 400
    assert "이미 회장 서명이 완료" in res2.json()["detail"]


def test_reject_budget_revision_by_president(auth_header):
    """회장이 요청 검토 후 반려(reject)하면 사유가 저장되고 REJECTED 상태로 변경된다."""
    rev_id = _create_pending_revision(auth_header)
    response = client.post(
        f"/budget-revisions/{rev_id}/reject",
        json={"reject_reason": "행사 규모 축소로 인한 증액 불필요"},
        headers=auth_header(Role.PRESIDENT),
    )
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "REJECTED"
    assert data["reject_reason"] == "행사 규모 축소로 인한 증액 불필요"
    assert data["resolved_by"] is not None


@pytest.mark.parametrize("bad_reason", ["   \t\n ", "\u0000", "사유\u0000", "사유\u200b", "사유\u00a0", "사유\ufeff"])
def test_reject_budget_revision_invalid_reason_rejected(auth_header, bad_reason):
    """반려 사유가 공백뿐이거나 제어문자(U+0000, U+200B 등)를 포함하면 400으로 거부된다."""
    rev_id = _create_pending_revision(auth_header)
    response = client.post(
        f"/budget-revisions/{rev_id}/reject",
        json={"reject_reason": bad_reason},
        headers=auth_header(Role.PRESIDENT),
    )
    assert response.status_code == 400


def test_reject_budget_revision_by_auditor(auth_header):
    """감사가 PRESIDENT_SIGNED 상태의 요청을 반려(reject)할 수 있다."""
    rev_id = _create_pending_revision(auth_header)
    client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": fake_signature(PRESIDENT_WALLET),
            "signature_deadline": int(time.time()) + 86400,
            "signed_version": 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )

    response = client.post(
        f"/budget-revisions/{rev_id}/reject",
        json={"reject_reason": "증빙 서류 미비로 감사 반려"},
        headers=auth_header(Role.AUDITOR),
    )
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "REJECTED"
    assert data["reject_reason"] == "증빙 서류 미비로 감사 반려"


def test_lazy_expiration_rolls_back_to_pending_and_filters_correctly(auth_header):
    """회장 서명 시한 만료 후 목록 필터(PENDING / PRESIDENT_SIGNED) 조회 시 만료가 먼저 반영되어 필터링된다."""
    rev_id = _create_pending_revision(auth_header)

    client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": fake_signature(PRESIDENT_WALLET),
            "signature_deadline": int(time.time()) + 86400,
            "signed_version": 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )

    with _test_session_factory() as db:
        rev = db.query(DBBudgetRevisionRequest).filter_by(id=rev_id).first()
        rev.signature_deadline = int(time.time()) - 100
        db.commit()

    # 1. PRESIDENT_SIGNED 필터 조회 시 만료 처리가 먼저 돌아 결과에서 빠진다
    signed_res = client.get(
        "/budget-revisions?status_filter=PRESIDENT_SIGNED",
        headers=auth_header(Role.AUDITOR),
    )
    assert signed_res.status_code == 200
    assert all(item["id"] != rev_id for item in signed_res.json())

    # 2. PENDING 필터 조회 시 만료 롤백된 건이 정상 포함된다
    pending_res = client.get(
        "/budget-revisions?status_filter=PENDING",
        headers=auth_header(Role.AUDITOR),
    )
    assert pending_res.status_code == 200
    matched = next(item for item in pending_res.json() if item["id"] == rev_id)
    assert matched["status"] == "PENDING"
    assert matched["president_signed_by"] is None
    assert matched["president_signature"] is None
    assert matched["signature_deadline"] is None


# =========================================================================
# A4: 3단계 감사 최종 승인 & 온체인 릴레이 & BudgetVersion 발행 테스트
# =========================================================================


def test_auditor_approve_success_and_creates_budget_version_v2(auth_header, monkeypatch):
    """감사가 유효한 서명으로 최종 승인하면 relay_increase를 통해 APPROVED 및 BudgetVersion(outcome.version=2)이 생성된다."""
    calls = []
    orig_resolve = budget_revisions_router.resolve_notifications
    orig_create = budget_revisions_router.create_notification

    def track_resolve(db, **kw):
        calls.append(("resolve", kw.get("budget_revision_request_id")))
        return orig_resolve(db, **kw)

    def track_create(db, kind, **kw):
        calls.append(("create", kind, kw.get("budget_revision_request_id")))
        return orig_create(db, kind, **kw)

    monkeypatch.setattr(budget_revisions_router, "resolve_notifications", track_resolve)
    monkeypatch.setattr(budget_revisions_router, "create_notification", track_create)

    rev_id = _create_pending_revision(auth_header, amount=500000)

    # 1. 회장 서명 (1단계 -> 2단계)
    sign_res = client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": fake_signature(PRESIDENT_WALLET),
            "signature_deadline": int(time.time()) + 86400,
            "signed_version": 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert sign_res.status_code == 200

    # 2. 감사 최종 승인 (2단계 -> 3단계)
    approve_res = client.post(
        f"/budget-revisions/{rev_id}/approve",
        json={"auditor_signature": fake_signature(AUDITOR_WALLET)},
        headers=auth_header(Role.AUDITOR),
    )
    assert approve_res.status_code == 200
    data = approve_res.json()
    assert data["status"] == "APPROVED"
    assert data["tx_increase"] is not None
    assert data["tx_increase"].startswith("0x")
    assert data["resolved_by"] == 3

    # 3. 체인 한도 및 BudgetVersion v2 생성 확인
    assert _test_chain._budgets[1].issued == 1500000
    assert _test_chain._budgets[1].version == 2

    with _test_session_factory() as db:
        versions = (
            db.query(DBBudgetVersion)
            .filter_by(budget_id=1)
            .order_by(DBBudgetVersion.version.asc())
            .all()
        )
        assert len(versions) == 2
        v1, v2 = versions[0], versions[1]
        assert v1.version == 1
        assert v1.planned_amount == 1000000
        assert v2.version == 2
        assert v2.planned_amount == 1500000
        assert v2.revision_request_id == rev_id
        assert v2.tx_hash == data["tx_increase"]

    # 4. 알림 호출 순서 확인 (resolve_notifications가 create_notification보다 먼저 호출됨)
    assert calls == [
        ("create", NotificationKind.REVISION_REQUESTED, rev_id),
        ("resolve", rev_id),
        ("create", NotificationKind.REVISION_PRESIDENT_SIGNED, rev_id),
        ("resolve", rev_id),
        ("create", NotificationKind.REVISION_APPROVED, rev_id),
    ]


def test_auditor_approve_requires_valid_auditor_signature(auth_header):
    """감사 승인 시 auditor_signature 누락(422), 잘못된 형식(400), 서명자 불일치(400) 모두 거부된다."""
    rev_id = _create_pending_revision(auth_header)
    client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": fake_signature(PRESIDENT_WALLET),
            "signature_deadline": int(time.time()) + 86400,
            "signed_version": 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )

    # 1. 본문 없이 호출 -> 422
    res_empty = client.post(
        f"/budget-revisions/{rev_id}/approve",
        headers=auth_header(Role.AUDITOR),
    )
    assert res_empty.status_code == 422

    # 2. 잘못된 서명 형식 -> 400
    res_bad = client.post(
        f"/budget-revisions/{rev_id}/approve",
        json={"auditor_signature": "not-a-signature"},
        headers=auth_header(Role.AUDITOR),
    )
    assert res_bad.status_code == 400
    assert "감사 서명 형식" in res_bad.json()["detail"]

    # 3. 다른 지갑(총무 지갑) 서명 -> 400
    res_mismatch = client.post(
        f"/budget-revisions/{rev_id}/approve",
        json={"auditor_signature": fake_signature(TREASURER_WALLET)},
        headers=auth_header(Role.AUDITOR),
    )
    assert res_mismatch.status_code == 400
    assert "일치하지 않습니다" in res_mismatch.json()["detail"]


def test_auditor_approve_fails_if_expired(auth_header):
    """서명 시한이 만료된 요청에 감사가 승인을 시도하면 거부되고 PENDING으로 롤백된다."""
    rev_id = _create_pending_revision(auth_header)
    client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": fake_signature(PRESIDENT_WALLET),
            "signature_deadline": int(time.time()) + 86400,
            "signed_version": 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )

    with _test_session_factory() as db:
        rev = db.query(DBBudgetRevisionRequest).filter_by(id=rev_id).first()
        rev.signature_deadline = int(time.time()) - 100
        db.commit()

    response = client.post(
        f"/budget-revisions/{rev_id}/approve",
        json={"auditor_signature": fake_signature(AUDITOR_WALLET)},
        headers=auth_header(Role.AUDITOR),
    )
    assert response.status_code == 400
    assert "만료" in response.json()["detail"]

    get_res = client.get(f"/budget-revisions/{rev_id}", headers=auth_header(Role.AUDITOR))
    assert get_res.json()["status"] == "PENDING"


def test_auditor_approve_expired_budget_rejected_without_resign_prompt(auth_header):
    """회장 서명 후 예산 마감일(expires_at)이 지난 경우 감사 승인 시 재서명 안내 없이 400으로 차단된다."""
    rev_id = _create_pending_revision(auth_header)
    client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": fake_signature(PRESIDENT_WALLET),
            "signature_deadline": int(time.time()) + 86400,
            "signed_version": 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )

    with _test_session_factory() as db:
        b = db.query(DBBudget).filter_by(id=1).first()
        b.expires_at = datetime.fromtimestamp(int(time.time()) - 10, tz=timezone.utc)
        db.commit()

    res = client.post(
        f"/budget-revisions/{rev_id}/approve",
        json={"auditor_signature": fake_signature(AUDITOR_WALLET)},
        headers=auth_header(Role.AUDITOR),
    )
    assert res.status_code == 400
    assert "마감일" in res.json()["detail"]
    assert "재서명" not in res.json()["detail"]


def test_auditor_approve_chain_budget_expired_revert_does_not_rollback_to_pending(auth_header):
    """체인 릴레이에서 BudgetExpired로 거부된 경우 재서명(PENDING)으로 롤백하거나 안내하지 않는다."""
    rev_id = _create_pending_revision(auth_header)
    client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": fake_signature(PRESIDENT_WALLET),
            "signature_deadline": int(time.time()) + 86400,
            "signed_version": 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )

    _test_chain.fail_next("increase_budget", BudgetRevertReason.BUDGET_EXPIRED)
    res = client.post(
        f"/budget-revisions/{rev_id}/approve",
        json={"auditor_signature": fake_signature(AUDITOR_WALLET)},
        headers=auth_header(Role.AUDITOR),
    )
    assert res.status_code == 400
    assert "BudgetExpired" in res.json()["detail"]
    assert "재서명" not in res.json()["detail"]

    get_res = client.get(f"/budget-revisions/{rev_id}", headers=auth_header(Role.AUDITOR))
    assert get_res.json()["status"] == "PRESIDENT_SIGNED"
    assert get_res.json()["tx_increase"] is None


def test_auditor_approve_version_mismatch_rolls_back_to_pending(auth_header):
    """같은 버전(v1)에 서명한 두 요청 중 첫 번째가 승인되면 두 번째는 VersionMismatch로 PENDING 롤백된다."""
    rev1 = _create_pending_revision(auth_header, amount=200000)
    rev2 = _create_pending_revision(auth_header, amount=300000)
    deadline = int(time.time()) + 86400

    for rid in (rev1, rev2):
        res_sign = client.post(
            f"/budget-revisions/{rid}/sign",
            json={
                "president_signature": fake_signature(PRESIDENT_WALLET),
                "signature_deadline": deadline,
                "signed_version": 1,
            },
            headers=auth_header(Role.PRESIDENT),
        )
        assert res_sign.status_code == 200

    # 첫 번째 요청 승인 -> v2 발행 성공
    res_app1 = client.post(
        f"/budget-revisions/{rev1}/approve",
        json={"auditor_signature": fake_signature(AUDITOR_WALLET)},
        headers=auth_header(Role.AUDITOR),
    )
    assert res_app1.status_code == 200
    assert res_app1.json()["status"] == "APPROVED"

    # 두 번째 요청 승인 시도 -> signed_version(1) != 현재 버전(2) 대조로 400 및 PENDING 롤백
    res_app2 = client.post(
        f"/budget-revisions/{rev2}/approve",
        json={"auditor_signature": fake_signature(AUDITOR_WALLET)},
        headers=auth_header(Role.AUDITOR),
    )
    assert res_app2.status_code == 400
    assert "VersionMismatch" in res_app2.json()["detail"]
    assert "재서명" in res_app2.json()["detail"]

    rev2_state = client.get(f"/budget-revisions/{rev2}", headers=auth_header(Role.AUDITOR)).json()
    assert rev2_state["status"] == "PENDING"
    assert rev2_state["president_signature"] is None
    assert rev2_state["signed_version"] is None


def test_auditor_approve_no_response_keeps_tx_increase_and_retry_recovers(auth_header, monkeypatch):
    """NO_RESPONSE 시 APPROVED로 바꾸지 않고 tx_increase를 유지하며(503), 재시도 시 previous_tx_hash로 복구한다."""
    rev_id = _create_pending_revision(auth_header, amount=400000)
    client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": fake_signature(PRESIDENT_WALLET),
            "signature_deadline": int(time.time()) + 86400,
            "signed_version": 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )

    # 전송 후 응답 유실 + 첫 번째 budget_tx_result 확인도 실패 -> NO_RESPONSE 유도
    _test_chain.unavailable_next("increase_budget", landed=True, sent=True)
    orig_budget_tx_result = _test_chain.budget_tx_result
    failed_once = False

    async def fail_once(tx_hash: str, budget_id: int):
        nonlocal failed_once
        if not failed_once:
            failed_once = True
            raise ChainUnavailable("일시적 조회 실패")
        return await orig_budget_tx_result(tx_hash, budget_id)

    monkeypatch.setattr(_test_chain, "budget_tx_result", fail_once)

    res1 = client.post(
        f"/budget-revisions/{rev_id}/approve",
        json={"auditor_signature": fake_signature(AUDITOR_WALLET)},
        headers=auth_header(Role.AUDITOR),
    )
    assert res1.status_code == 503

    # DB 확인: status는 PRESIDENT_SIGNED 유지, tx_increase는 선점 해시 유지
    with _test_session_factory() as db:
        rev = db.query(DBBudgetRevisionRequest).filter_by(id=rev_id).first()
        assert rev.status == "PRESIDENT_SIGNED"
        assert rev.tx_increase is not None
        saved_tx = rev.tx_increase

    # 재시도 -> previous_tx_hash로 앞선 트랜잭션 성공 결과를 확인하여 이중 증액 없이 APPROVED 확정
    res2 = client.post(
        f"/budget-revisions/{rev_id}/approve",
        json={"auditor_signature": fake_signature(AUDITOR_WALLET)},
        headers=auth_header(Role.AUDITOR),
    )
    assert res2.status_code == 200
    data = res2.json()
    assert data["status"] == "APPROVED"
    assert data["tx_increase"] == saved_tx
    assert _test_chain._budgets[1].issued == 1400000
    assert _test_chain._budgets[1].version == 2


def test_auditor_approve_not_sent_returns_503_and_releases_claim(auth_header, monkeypatch):
    """NOT_SENT(ChainSetupError) 발생 시 503을 반환하고 선점된 해시가 있으면 비운다."""
    rev_id = _create_pending_revision(auth_header)
    client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": fake_signature(PRESIDENT_WALLET),
            "signature_deadline": int(time.time()) + 86400,
            "signed_version": 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )

    async def broken_increase(*args, **kwargs):
        raise ChainSetupError("릴레이어 설정 오류")

    monkeypatch.setattr(_test_chain, "increase_budget", broken_increase)

    res = client.post(
        f"/budget-revisions/{rev_id}/approve",
        json={"auditor_signature": fake_signature(AUDITOR_WALLET)},
        headers=auth_header(Role.AUDITOR),
    )
    assert res.status_code == 503
    with _test_session_factory() as db:
        rev = db.query(DBBudgetRevisionRequest).filter_by(id=rev_id).first()
        assert rev.status == "PRESIDENT_SIGNED"
        assert rev.tx_increase is None


def test_concurrent_approve_does_not_double_increase(auth_header):
    """동시 승인 요청 시 조건부 선점 및 상태 검사로 한 번만 증액(v2)되고 두 번째는 409로 차단된다."""
    rev_id = _create_pending_revision(auth_header, amount=500000)
    client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": fake_signature(PRESIDENT_WALLET),
            "signature_deadline": int(time.time()) + 86400,
            "signed_version": 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )

    auditor_user = next(u for u in users.SEED_USERS if u.role == Role.AUDITOR)
    payload = budget_revisions_router.BudgetRevisionApproveRequest(
        auditor_signature=fake_signature(AUDITOR_WALLET)
    )

    async def _run_concurrent():
        db1 = _test_session_factory()
        db2 = _test_session_factory()
        try:
            results = await asyncio.gather(
                budget_revisions_router.approve_budget_revision(
                    id=rev_id,
                    payload=payload,
                    current_user=auditor_user,
                    db=db1,
                    chain=_test_chain,
                ),
                budget_revisions_router.approve_budget_revision(
                    id=rev_id,
                    payload=payload,
                    current_user=auditor_user,
                    db=db2,
                    chain=_test_chain,
                ),
                return_exceptions=True,
            )
            return results
        finally:
            db1.close()
            db2.close()

    res_a, res_b = asyncio.run(_run_concurrent())
    successes = [r for r in (res_a, res_b) if not isinstance(r, Exception)]
    errors = [r for r in (res_a, res_b) if isinstance(r, Exception)]

    assert len(successes) == 1
    assert len(errors) == 1
    assert errors[0].status_code == 409

    # 체인과 DB 모두 정확히 v2(150만원) 1건만 존재해야 함
    assert _test_chain._budgets[1].version == 2
    assert _test_chain._budgets[1].issued == 1500000
    with _test_session_factory() as db:
        versions = db.query(DBBudgetVersion).filter_by(budget_id=1).all()
        assert len(versions) == 2


def test_auditor_approve_fails_on_pending(auth_header):
    """회장 서명이 없는 PENDING 상태에서는 감사 승인이 불가능하다."""
    rev_id = _create_pending_revision(auth_header)

    response = client.post(
        f"/budget-revisions/{rev_id}/approve",
        json={"auditor_signature": fake_signature(AUDITOR_WALLET)},
        headers=auth_header(Role.AUDITOR),
    )
    assert response.status_code == 400
    assert "회장 서명이 완료되지 않은" in response.json()["detail"]


@pytest.mark.parametrize("role", [Role.STUDENT, Role.TREASURER, Role.PRESIDENT])
def test_auditor_approve_forbidden_for_non_auditor(auth_header, role):
    """감사 이외의 사용자는 감사 최종 승인을 수행할 수 없다 (403 Forbidden)."""
    rev_id = _create_pending_revision(auth_header)
    response = client.post(
        f"/budget-revisions/{rev_id}/approve",
        json={"auditor_signature": fake_signature(AUDITOR_WALLET)},
        headers=auth_header(role),
    )
    assert response.status_code == 403


def test_reject_budget_revision_fails_when_tx_increase_in_flight(auth_header):
    """온체인 증액 릴레이 진행 중(tx_increase 존재)인 요청은 반려할 수 없다 (409 Conflict)."""
    rev_id = _create_pending_revision(auth_header)
    future_deadline = int(time.time()) + 86400
    client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": fake_signature(PRESIDENT_WALLET),
            "signature_deadline": future_deadline,
            "signed_version": 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )

    with _test_session_factory() as db:
        rev = db.query(DBBudgetRevisionRequest).filter_by(id=rev_id).first()
        rev.tx_increase = "0x" + "99" * 32
        db.commit()

    response = client.post(
        f"/budget-revisions/{rev_id}/reject",
        json={"reject_reason": "지금 반려 시도"},
        headers=auth_header(Role.AUDITOR),
    )
    assert response.status_code == 409
    assert "온체인 증액 릴레이가 진행 중인" in response.json()["detail"]
