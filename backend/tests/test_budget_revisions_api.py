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
from app.schemas.auth import Role

client = TestClient(app)

_test_session_factory = None


@pytest.fixture(autouse=True)
def setup_test_db(tmp_path):
    """각 테스트마다 격리된 임시 SQLite DB를 생성하고 시드 데이터를 주입합니다."""
    global _test_session_factory
    db_file = tmp_path / "test_rev.db"
    engine = create_engine(
        f"sqlite:///{db_file}",
        connect_args={"check_same_thread": False},
    )
    Base.metadata.create_all(bind=engine)
    TestingSession = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    _test_session_factory = TestingSession

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
        )
        db.add(budget)
        db.flush()

        bv1 = DBBudgetVersion(
            budget_id=1,
            version=1,
            planned_amount=1000000,
            approved_by=1,
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
            created_by=2,  # 총무 ID
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
            created_by=2,  # 총무 ID
        )
        db.add(confirmed_entry)

        db.commit()

    def override_get_db():
        db = _test_session_factory()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
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


def test_create_budget_revision_blocked_entry_validation(auth_header):
    """존재하지 않거나 차단 상태가 아닌 지출을 blocked_entry_id로 지정하면 거부된다."""
    # 1. 존재하지 않는 entry_id
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

    # 2. 이미 CONFIRMED된 entry_id 연동 시도
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


def test_list_and_get_budget_revisions(auth_header):
    """증액 요청 목록 및 단건 조회가 정상 동작한다."""
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

    list_res = client.get("/budget-revisions", headers=auth_header(Role.STUDENT))
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
    """회장이 정상적으로 서명하면 200 OK와 PRESIDENT_SIGNED 상태 응답을 받는다."""
    rev_id = _create_pending_revision(auth_header)
    future_deadline = int(time.time()) + 86400

    sign_body = {
        "president_signature": "0x" + "aa" * 65,
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
    assert data["president_signed_by"] is not None
    assert data["president_signature"] == sign_body["president_signature"]
    assert data["signature_deadline"] == future_deadline
    assert data["signed_version"] == 1


@pytest.mark.parametrize("role", [Role.STUDENT, Role.TREASURER, Role.AUDITOR])
def test_president_sign_forbidden_for_non_president(auth_header, role):
    """회장 이외의 사용자는 회장 서명을 수행할 수 없다 (403 Forbidden)."""
    rev_id = _create_pending_revision(auth_header)
    response = client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": "0x" + "aa" * 65,
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
            "president_signature": "0x" + "aa" * 65,
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
        "president_signature": "0x" + "aa" * 65,
        "signature_deadline": future_deadline,
        "signed_version": 1,
    }
    res1 = client.post(f"/budget-revisions/{rev_id}/sign", json=body, headers=auth_header(Role.PRESIDENT))
    assert res1.status_code == 200

    # 다시 서명 시도
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


def test_reject_budget_revision_by_auditor(auth_header):
    """감사가 PRESIDENT_SIGNED 상태의 요청을 반려(reject)할 수 있다."""
    rev_id = _create_pending_revision(auth_header)
    client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": "0x" + "aa" * 65,
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


def test_lazy_expiration_rolls_back_to_pending(auth_header):
    """D5 합의: 회장 서명 시한이 만료된 후 조회나 승인 시점에 PENDING 상태로 Lazy 롤백된다."""
    rev_id = _create_pending_revision(auth_header)

    # 1. 회장 서명 완료
    client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": "0x" + "aa" * 65,
            "signature_deadline": int(time.time()) + 86400,
            "signed_version": 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )

    # 2. DB의 signature_deadline을 과거 시각으로 강제 조작
    with _test_session_factory() as db:
        rev = db.query(DBBudgetRevisionRequest).filter_by(id=rev_id).first()
        rev.signature_deadline = int(time.time()) - 100
        db.commit()

    # 3. 단건 조회 API 호출 시 Lazy Update 트리거 확인
    get_res = client.get(f"/budget-revisions/{rev_id}", headers=auth_header(Role.STUDENT))
    assert get_res.status_code == 200
    data = get_res.json()
    assert data["status"] == "PENDING"
    assert data["president_signed_by"] is None
    assert data["president_signature"] is None
    assert data["signature_deadline"] is None


# =========================================================================
# A4: 3단계 감사 최종 승인 & 온체인 릴레이 & BudgetVersion 발행 테스트
# =========================================================================

def test_auditor_approve_success_and_creates_budget_version_v2(auth_header):
    """감사가 최종 승인하면 APPROVED 상태가 되고, 온체인 해시 및 BudgetVersion v2(150만원)가 생성된다."""
    rev_id = _create_pending_revision(auth_header, amount=500000)

    # 1. 회장 서명 (1단계 -> 2단계)
    client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": "0x" + "aa" * 65,
            "signature_deadline": int(time.time()) + 86400,
            "signed_version": 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )

    # 2. 감사 최종 승인 (2단계 -> 3단계)
    approve_res = client.post(
        f"/budget-revisions/{rev_id}/approve",
        headers=auth_header(Role.AUDITOR),
    )
    assert approve_res.status_code == 200
    data = approve_res.json()
    assert data["status"] == "APPROVED"
    assert data["tx_increase"] is not None
    assert data["tx_increase"].startswith("0x")
    assert data["resolved_by"] is not None

    # 3. BudgetVersion v2 생성 확인
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
        assert v2.planned_amount == 1500000  # 100만 + 50만
        assert v2.revision_request_id == rev_id
        assert v2.tx_hash == data["tx_increase"]


def test_auditor_approve_fails_if_expired(auth_header):
    """서명 시한이 만료된 요청에 감사가 승인을 시도하면 거부되고 PENDING으로 롤백된다."""
    rev_id = _create_pending_revision(auth_header)
    client.post(
        f"/budget-revisions/{rev_id}/sign",
        json={
            "president_signature": "0x" + "aa" * 65,
            "signature_deadline": int(time.time()) + 86400,
            "signed_version": 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )

    # 시한 만료 조작
    with _test_session_factory() as db:
        rev = db.query(DBBudgetRevisionRequest).filter_by(id=rev_id).first()
        rev.signature_deadline = int(time.time()) - 100
        db.commit()

    # 감사 승인 시도
    response = client.post(
        f"/budget-revisions/{rev_id}/approve",
        headers=auth_header(Role.AUDITOR),
    )
    assert response.status_code == 400
    assert "만료" in response.json()["detail"]

    # 요청 상태 확인
    get_res = client.get(f"/budget-revisions/{rev_id}", headers=auth_header(Role.STUDENT))
    assert get_res.json()["status"] == "PENDING"


def test_auditor_approve_fails_on_pending(auth_header):
    """회장 서명이 없는 PENDING 상태에서는 감사 승인이 불가능하다."""
    rev_id = _create_pending_revision(auth_header)

    response = client.post(
        f"/budget-revisions/{rev_id}/approve",
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
        headers=auth_header(role),
    )
    assert response.status_code == 403
