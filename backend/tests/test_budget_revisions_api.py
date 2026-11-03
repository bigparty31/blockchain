import os
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

        # 2. Term (id=1, term_code=20261)
        term = DBTerm(
            id=1,
            term_code=20261,
            name="2026-1학기",
            started_at=datetime.fromtimestamp(1772323200, tz=timezone.utc),
            ended_at=datetime.fromtimestamp(1788163200, tz=timezone.utc),
        )
        db.add(term)

        # 3. Budget (id=1, 운영비)
        budget = DBBudget(
            id=1,
            term_id=1,
            category="운영비",
            expires_at=datetime.fromtimestamp(1798704000, tz=timezone.utc),
        )
        db.add(budget)

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
    assert data["budget_id"] == 1  # 자동 매핑
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
    """총무(TREASURER) 이외의 사용자(학생, 감사, 회장)는 증액 요청을 할 수 없다 (403 Forbidden)."""
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

    # 2. 이미 CONFIRMED된 entry_id 연동 시도 (차단 건 아님)
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
    # 1. 증액 요청 1건 생성
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

    # 2. 목록 조회 (회원 누구나 조회 가능)
    list_res = client.get("/budget-revisions", headers=auth_header(Role.STUDENT))
    assert list_res.status_code == 200
    items = list_res.json()
    assert len(items) >= 1
    assert any(item["id"] == rev_id for item in items)

    # 3. 단건 상세 조회
    get_res = client.get(f"/budget-revisions/{rev_id}", headers=auth_header(Role.AUDITOR))
    assert get_res.status_code == 200
    assert get_res.json()["id"] == rev_id
    assert get_res.json()["requested_amount"] == 300000

    # 4. 존재하지 않는 ID 단건 조회 (404)
    not_found_res = client.get("/budget-revisions/99999", headers=auth_header(Role.AUDITOR))
    assert not_found_res.status_code == 404
