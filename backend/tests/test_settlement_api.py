"""GET /settlement/{term_id} 테스트 (PRD §4.7, §7.4).

학기 1 데이터와 기대값 (손으로 계산할 수 있게 적어 둔다)
- 수입: e1 5,000,000 (확정)
- 지출 확정: e2 300,000(행사비) + e3 120,000(비품비, OCR MISMATCH) + e6 −20,000(e3 환불 정정)
            + e7 10,000(e2 입력오류 정정) + e10 30,000(비품비, 용도 경고) = 440,000
- 집계 제외: e4 대기, e5 차단, e8 반려, e9 초안
- 장부잔액 4,560,000 / 최근 스냅샷 4,500,000 → 차액 60,000
- 행사비: v1 2,000,000 → v2 2,500,000, 지출 310,000 → 집행률 0.124
- 비품비: v1 500,000, 지출 130,000 → 집행률 0.26
- 식비: 버전 없음 → 결산에서 빠짐
- 증액 승인 2건(그중 차단 근거 1건) → 비율 0.5. 대기 1건은 세지 않음
"""
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.auth import users
from app.database import Base, get_db
from app.main import app
from app.models import (
    Budget as DBBudget,
    BudgetRevisionRequest as DBRevision,
    BudgetVersion as DBBudgetVersion,
    Entry as DBEntry,
    Snapshot as DBSnapshot,
    Term as DBTerm,
    User as DBUser,
)
from app.schemas.auth import Role

client = TestClient(app)

TREASURER, AUDITOR, PRESIDENT = 2, 3, 4  # app/auth/users.py 시드 id
UTC = timezone.utc
_session = None


def _entry(id, kind, amount, status, budget_id=None, **kw):
    return DBEntry(
        id=id, term_id=kw.pop("term_id", 1), kind=kind, amount=amount, counterparty="거래처", purpose="목적",
        budget_id=budget_id, occurred_at=1789657200, status=status, created_by=TREASURER,
        approved_by=AUDITOR if status == "CONFIRMED" else None, **kw,
    )


@pytest.fixture(autouse=True)
def setup(tmp_path):
    global _session
    engine = create_engine(f"sqlite:///{tmp_path / 'test.db'}", connect_args={"check_same_thread": False})
    Base.metadata.create_all(bind=engine)
    _session = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    with _session() as db:
        for u in users.SEED_USERS:
            db.add(DBUser(id=u.id, student_no=u.student_no, password_hash=u.password_hash, name=u.name,
                          role=u.role.value, wallet_index=u.wallet_index,
                          wallet_address=u.wallet_address.lower() if u.wallet_address else None))
        db.add_all([
            DBTerm(id=1, term_code=20262, name="2026-2학기",
                   started_at=datetime(2026, 9, 1, tzinfo=UTC), ended_at=datetime(2026, 12, 20, tzinfo=UTC)),
            DBTerm(id=2, term_code=20271, name="2027-1학기",
                   started_at=datetime(2027, 3, 1, tzinfo=UTC), ended_at=datetime(2027, 6, 20, tzinfo=UTC)),
        ])
        db.add_all([
            DBBudget(id=1, term_id=1, category="행사비", expires_at=datetime(2026, 12, 31, tzinfo=UTC)),
            DBBudget(id=2, term_id=1, category="비품비", expires_at=datetime(2026, 12, 31, tzinfo=UTC)),
            DBBudget(id=3, term_id=1, category="식비", expires_at=datetime(2026, 12, 31, tzinfo=UTC)),
        ])
        approved = dict(status="APPROVED", requested_by=TREASURER, resolved_by=AUDITOR,
                        resolved_at=datetime(2026, 10, 2, tzinfo=UTC), tx_increase="0x" + "a" * 64)
        db.add_all([
            DBRevision(id=1, term_id=1, category="행사비", budget_id=1, blocked_entry_id=5, requested_amount=500000,
                       reason="참가 인원 증가", **approved),
            DBRevision(id=2, term_id=1, category="비품비", budget_id=2, requested_amount=100000, reason="신규 사업", **approved),
            DBRevision(id=3, term_id=1, category="비품비", budget_id=2, requested_amount=50000, reason="검토 중",
                       requested_by=TREASURER),
        ])
        db.add_all([
            DBBudgetVersion(budget_id=1, version=1, planned_amount=2000000),
            DBBudgetVersion(budget_id=1, version=2, planned_amount=2500000, revision_reason="참가 인원 증가", revision_request_id=1),
            DBBudgetVersion(budget_id=2, version=1, planned_amount=500000),
        ])
        db.add_all([
            _entry(1, "INCOME", 5000000, "CONFIRMED"),
            _entry(2, "EXPENSE", 300000, "CONFIRMED", 1, ocr_status="MATCH"),
            _entry(3, "EXPENSE", 120000, "CONFIRMED", 2, ocr_status="MISMATCH", warning_ack_reason="영수증 금액 오기"),
            _entry(4, "EXPENSE", 50000, "PENDING", 1, ocr_status="DUPLICATE"),
            _entry(5, "EXPENSE", 2300000, "BLOCKED", 1, block_reason="BUDGET_EXCEEDED"),
            _entry(6, "EXPENSE", -20000, "CONFIRMED", 2, corrects_entry_id=3, correction_reason="REFUND",
                   created_at=datetime(2026, 12, 10, tzinfo=UTC)),
            _entry(7, "EXPENSE", 10000, "CONFIRMED", 1, corrects_entry_id=2, correction_reason="INPUT_ERROR",
                   created_at=datetime(2026, 10, 1, tzinfo=UTC)),
            _entry(8, "EXPENSE", 40000, "REJECTED", 2, reject_reason="영수증 불일치", rejected_by=AUDITOR),
            _entry(9, "EXPENSE", 999, None, 2),
            _entry(10, "EXPENSE", 30000, "CONFIRMED", 2, category_warning=True, warning_ack_reason="비품으로 판단"),
            _entry(11, "INCOME", 777, "CONFIRMED", term_id=2),  # 다른 학기 — 섞이면 안 된다
        ])
        db.add_all([
            DBSnapshot(id=1, term_id=1, bank_balance=4400000, snapshot_at=datetime(2026, 11, 1, tzinfo=UTC)),
            DBSnapshot(id=2, term_id=1, bank_balance=4500000, snapshot_at=datetime(2026, 12, 1, tzinfo=UTC)),
        ])
        db.commit()

    def override_db():
        with _session() as db:
            yield db

    app.dependency_overrides[get_db] = override_db
    yield
    app.dependency_overrides.clear()


def _get(auth_header, term_id=1, role=Role.AUDITOR, **params):
    return client.get(f"/settlement/{term_id}", params=params, headers=auth_header(role))


# --- 금액 -----------------------------------------------------------------------


def test_totals_count_confirmed_only_with_corrections(auth_header):
    data = _get(auth_header).json()
    assert (data["income"], data["expense"], data["ledger_balance"]) == (5000000, 440000, 4560000)
    assert (data["term_code"], data["term_name"]) == (20262, "2026-2학기")


def test_balance_gap_uses_latest_snapshot(auth_header):
    data = _get(auth_header).json()
    assert data["bank_balance"] == 4500000
    assert data["balance_gap"] == 60000  # 장부잔액 − 통장 잔액 (PRD §7.4)


def test_budget_execution(auth_header):
    budgets = {b["category"]: b for b in _get(auth_header).json()["budgets"]}
    assert set(budgets) == {"행사비", "비품비"}  # 버전 없는 식비는 빠진다
    assert budgets["행사비"] == {
        "budget_id": 1, "category": "행사비", "initial_amount": 2000000, "planned_amount": 2500000, "version": 2,
        "spent": 310000, "remaining": 2190000, "execution_rate": 0.124,
    }
    assert (budgets["비품비"]["spent"], budgets["비품비"]["execution_rate"]) == (130000, 0.26)


# --- 메타지표 --------------------------------------------------------------------


def test_meta_metrics(auth_header):
    m = _get(auth_header).json()["metrics"]
    assert m["ocr_warning_approved"] == 1  # e3 MISMATCH 확정. 대기 중인 e4 DUPLICATE 는 세지 않는다
    assert m["category_warning_approved"] == 1
    assert m["corrections"] == 2
    assert m["corrections_by_reason"] == {"INPUT_ERROR": 1, "RECEIPT_RECHECK": 0, "REFUND": 1, "RECLASSIFY": 0, "OTHER": 0}
    assert (m["budget_revisions"], m["budget_revisions_after_block"], m["revision_after_block_rate"]) == (2, 1, 0.5)
    assert "objections" not in m  # v0.13 범위 밖


def test_corrections_before_audit_defaults_to_term_end(auth_header):
    m = _get(auth_header).json()["metrics"]
    assert m["audit_at"].startswith("2026-12-20")
    assert m["corrections_before_audit"] == 1  # 12/10 환불 정정만. 10/1 입력오류는 30일 밖


@pytest.mark.parametrize("audit_at, expected", [
    ("2026-10-05T00:00:00", 1),   # 9/5~10/5 → 10/1 정정
    ("2026-11-15T00:00:00", 0),   # 10/16~11/15 → 없음
    ("2026-12-10T09:00:00", 1),   # 시간대 없으면 KST — 12/10 09:00 KST = 12/10 00:00 UTC 경계 포함
])
def test_corrections_before_audit_with_audit_at(auth_header, audit_at, expected):
    assert _get(auth_header, audit_at=audit_at).json()["metrics"]["corrections_before_audit"] == expected


def test_empty_term(auth_header):
    data = _get(auth_header, term_id=2).json()
    assert (data["income"], data["expense"], data["ledger_balance"]) == (777, 0, 777)
    assert data["bank_balance"] is None and data["balance_gap"] is None
    assert data["budgets"] == []
    assert data["metrics"]["revision_after_block_rate"] is None


# --- 권한·오류 ------------------------------------------------------------------


@pytest.mark.parametrize("role", [Role.TREASURER, Role.AUDITOR, Role.PRESIDENT])
def test_council_roles_can_read(auth_header, role):
    assert _get(auth_header, role=role).status_code == 200


def test_student_is_403(auth_header):
    assert _get(auth_header, role=Role.STUDENT).status_code == 403


def test_without_token_is_401():
    assert client.get("/settlement/1").status_code == 401


def test_unknown_term_is_404(auth_header):
    assert _get(auth_header, term_id=99).status_code == 404
