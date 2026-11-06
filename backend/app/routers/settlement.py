"""결산 집계 (PRD §4.7, §7.4). 조회만 하고 DB 에 쓰지 않는다.

- 금액은 CONFIRMED 건만, 정정 포함으로 더한다 — GET /balance 와 같은 기준이다. 정정은 원본과 종류(kind)가 같고
  감액 정정은 음수라서, 그냥 더하면 최종값이 된다 (§4.4)
- 집행률의 잔량은 DB 의 확정 지출로 계산한다. 체인 remaining() 은 학생 화면(S6)의 실시간 값이고,
  결산은 학기 말 집계라 확정 기록끼리 맞추면 된다
- 감사일은 DB 에 없어 학기 종료일을 기본으로 쓰고 audit_at 으로 바꿀 수 있다
- 정정 시점은 등록일(created_at)이다. 확정 시각 컬럼이 없다. 「감사 직전에 정정을 올렸다」를 보는 지표라 의도와 맞는다
"""
import logging
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.auth import User, require_roles
from app.database import get_db
from app.models import (
    Budget as DBBudget,
    BudgetRevisionRequest as DBRevision,
    BudgetVersion as DBBudgetVersion,
    Entry as DBEntry,
    Snapshot as DBSnapshot,
    Term as DBTerm,
)
from app.routers.entries import WARNING_OCR_STATUSES
from app.schemas.auth import Role
from app.schemas.entry import CorrectionReason, EntryKind
from app.schemas.settlement import BudgetExecution, MetaMetrics, SettlementResponse

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/settlement", tags=["Settlement"])

# A11 은 학생회 화면 기능이다. 학생에게도 보여 주기로 하면 Role.STUDENT 만 더하면 된다
council_only = require_roles(Role.TREASURER, Role.AUDITOR, Role.PRESIDENT)

KST = timezone(timedelta(hours=9))
AUDIT_WINDOW = timedelta(days=30)


def _aware(dt: datetime) -> datetime:
    """SQLite 는 시간대를 떼고 돌려준다. 시간대 없는 값은 UTC 로 본다 (server_default=now() 가 UTC)."""
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _rate(part: int, whole: int) -> Optional[float]:
    return round(part / whole, 4) if whole else None


def _confirmed(term_id: int):
    return [DBEntry.term_id == term_id, DBEntry.status == "CONFIRMED"]


def _totals(db: Session, term_id: int) -> tuple[int, int]:
    rows = (
        db.query(DBEntry.kind, func.coalesce(func.sum(DBEntry.amount), 0))
        .filter(*_confirmed(term_id))
        .group_by(DBEntry.kind)
        .all()
    )
    sums = {kind: int(total) for kind, total in rows}
    return sums.get(EntryKind.INCOME.value, 0), sums.get(EntryKind.EXPENSE.value, 0)


def _budgets(db: Session, term_id: int) -> list[BudgetExecution]:
    spent = dict(
        db.query(DBEntry.budget_id, func.coalesce(func.sum(DBEntry.amount), 0))
        .filter(*_confirmed(term_id), DBEntry.kind == EntryKind.EXPENSE.value, DBEntry.budget_id.isnot(None))
        .group_by(DBEntry.budget_id)
        .all()
    )
    result = []
    for budget in db.query(DBBudget).filter(DBBudget.term_id == term_id).order_by(DBBudget.id).all():
        versions = (
            db.query(DBBudgetVersion)
            .filter(DBBudgetVersion.budget_id == budget.id)
            .order_by(DBBudgetVersion.version)
            .all()
        )
        if not versions:  # 편성액이 없는 예산 행은 집행률을 말할 수 없다 (시드·발행 도중 상태)
            continue
        planned = versions[-1].planned_amount
        used = int(spent.get(budget.id, 0))
        result.append(BudgetExecution(
            budget_id=budget.id,
            category=budget.category,
            initial_amount=versions[0].planned_amount,
            planned_amount=planned,
            version=versions[-1].version,
            spent=used,
            remaining=planned - used,
            execution_rate=_rate(used, planned),
        ))
    return result


def _metrics(db: Session, term: DBTerm, audit_at: datetime) -> MetaMetrics:
    confirmed = _confirmed(term.id)

    ocr_warning = db.query(func.count(DBEntry.id)).filter(*confirmed, DBEntry.ocr_status.in_(WARNING_OCR_STATUSES)).scalar()
    category_warning = db.query(func.count(DBEntry.id)).filter(*confirmed, DBEntry.category_warning.is_(True)).scalar()

    corrections = (
        db.query(DBEntry.correction_reason, DBEntry.created_at)
        .filter(*confirmed, DBEntry.corrects_entry_id.isnot(None))
        .all()
    )
    by_reason = {r.value: 0 for r in CorrectionReason}  # 0건 사유도 보여야 분포가 된다
    for reason, _ in corrections:
        if reason in by_reason:
            by_reason[reason] += 1
    # 시간대가 섞이지 않게 파이썬에서 비교한다. 정정은 학기에 수십 건이라 다 읽어도 된다
    window_start = audit_at - AUDIT_WINDOW
    before_audit = sum(1 for _, created in corrections if window_start <= _aware(created) <= audit_at)

    revisions = db.query(DBRevision.blocked_entry_id).filter(DBRevision.term_id == term.id, DBRevision.status == "APPROVED").all()
    after_block = sum(1 for (blocked,) in revisions if blocked is not None)

    return MetaMetrics(
        ocr_warning_approved=ocr_warning,
        category_warning_approved=category_warning,
        corrections=len(corrections),
        corrections_by_reason=by_reason,
        corrections_before_audit=before_audit,
        audit_at=audit_at,
        budget_revisions=len(revisions),
        budget_revisions_after_block=after_block,
        revision_after_block_rate=_rate(after_block, len(revisions)),
    )


@router.get("/{term_id}", response_model=SettlementResponse, summary="학기 결산 — 확정 합계·집행률·메타지표")
async def get_settlement(
    term_id: int,
    audit_at: Optional[datetime] = Query(None, description="감사일 (ISO 8601). 없으면 학기 종료일. 시간대가 없으면 KST"),
    user: User = Depends(council_only),
    db: Session = Depends(get_db),
):
    """결산 화면(A11)용. 학기 하나의 확정 수입·지출·장부잔액, 계좌 차액, 예산별 집행률, 메타지표를 한 번에 돌려준다."""
    try:
        term = db.query(DBTerm).filter(DBTerm.id == term_id).first()
        if term is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="학기를 찾을 수 없습니다.")

        if audit_at is None:
            audit_at = _aware(term.ended_at)
        elif audit_at.tzinfo is None:
            audit_at = audit_at.replace(tzinfo=KST)

        income, expense = _totals(db, term.id)
        ledger = income - expense
        snapshot = (
            db.query(DBSnapshot)
            .filter(DBSnapshot.term_id == term.id)
            .order_by(DBSnapshot.snapshot_at.desc(), DBSnapshot.id.desc())
            .first()
        )

        return SettlementResponse(
            term_id=term.id,
            term_code=term.term_code,
            term_name=term.name,
            income=income,
            expense=expense,
            ledger_balance=ledger,
            bank_balance=snapshot.bank_balance if snapshot else None,
            bank_snapshot_at=snapshot.snapshot_at if snapshot else None,
            balance_gap=ledger - snapshot.bank_balance if snapshot else None,
            budgets=_budgets(db, term.id),
            metrics=_metrics(db, term, audit_at),
        )
    except SQLAlchemyError as e:
        logger.exception("결산 집계 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )
