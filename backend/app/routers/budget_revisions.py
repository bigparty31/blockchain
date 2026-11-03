import logging
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.auth import User, get_current_user, require_roles
from app.database import get_db
from app.models import Budget, BudgetRevisionRequest, Entry, Term, User as DBUser
from app.schemas.auth import Role
from app.schemas.budget_revision import (
    BudgetRevisionRequestCreate,
    BudgetRevisionResponse,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/budget-revisions", tags=["BudgetRevisions"])


@router.post(
    "",
    response_model=BudgetRevisionResponse,
    status_code=status.HTTP_201_CREATED,
    summary="예산 증액 요청 등록 (총무 1단계)",
)
@router.post(
    "/",
    response_model=BudgetRevisionResponse,
    status_code=status.HTTP_201_CREATED,
    include_in_schema=False,
)
def create_budget_revision(
    payload: BudgetRevisionRequestCreate,
    current_user: User = Depends(require_roles(Role.TREASURER)),
    db: Session = Depends(get_db),
):
    """PRD v0.13 §4.1: 총무가 예산 증액을 요청하는 1단계 API입니다.
    - 증액 요청액(requested_amount)은 증액분(> 0)이어야 합니다.
    - 한도 초과/기간 만료로 차단(BLOCKED)된 지출이 있는 경우 blocked_entry_id를 연계합니다.
    - 등록 시 status는 'PENDING'으로 설정됩니다.
    """
    if payload.requested_amount <= 0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="증액 요청액은 0원보다 커야 합니다.",
        )

    # 1. 학기 존재 여부 검증
    term = db.query(Term).filter(Term.id == payload.term_id).first()
    if not term:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"학기 ID {payload.term_id}를 찾을 수 없습니다.",
        )

    # 2. 차단 지출(blocked_entry_id) 연동 시 유효성 검증
    if payload.blocked_entry_id is not None:
        entry = db.query(Entry).filter(Entry.id == payload.blocked_entry_id).first()
        if not entry:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"차단 지출 ID {payload.blocked_entry_id}를 찾을 수 없습니다.",
            )
        if entry.term_id != payload.term_id:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="차단 지출의 학기와 증액 요청 학기가 일치하지 않습니다.",
            )
        if entry.status not in ("BLOCKED", "PENDING"):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"지출 상태가 {entry.status}입니다. 차단 지출 연동은 BLOCKED 또는 PENDING 지출만 가능합니다.",
            )

    # 3. 예산 매핑 검증
    target_budget_id = payload.budget_id
    if target_budget_id is not None:
        budget = db.query(Budget).filter(Budget.id == target_budget_id).first()
        if not budget:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"예산 ID {target_budget_id}를 찾을 수 없습니다.",
            )
        if budget.term_id != payload.term_id or budget.category != payload.category:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="지정된 예산의 학기 또는 카테고리가 일치하지 않습니다.",
            )
    else:
        # term_id와 category로 기존 예산 매핑 시도
        budget = (
            db.query(Budget)
            .filter(Budget.term_id == payload.term_id, Budget.category == payload.category)
            .first()
        )
        if budget:
            target_budget_id = budget.id

    # 4. 증액 요청 엔티티 생성 (PENDING)
    revision_req = BudgetRevisionRequest(
        term_id=payload.term_id,
        category=payload.category,
        budget_id=target_budget_id,
        blocked_entry_id=payload.blocked_entry_id,
        requested_amount=payload.requested_amount,
        reason=payload.reason,
        requested_by=current_user.id,
        status="PENDING",
    )
    db.add(revision_req)
    db.commit()
    db.refresh(revision_req)

    # 5. D4 합의: 알림 생성 (알림 모듈 준비 시 safe-call)
    try:
        from app.services.notifications import create_notification  # type: ignore
        create_notification("BUDGET_REVISION_REQUESTED", revision_id=revision_req.id)
    except Exception:
        pass

    return revision_req


@router.get(
    "",
    response_model=List[BudgetRevisionResponse],
    summary="예산 증액 요청 목록 조회",
)
@router.get(
    "/",
    response_model=List[BudgetRevisionResponse],
    include_in_schema=False,
)
def list_budget_revisions(
    term_id: Optional[int] = None,
    status_filter: Optional[str] = None,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """예산 증액 요청 목록을 조회합니다."""
    query = db.query(BudgetRevisionRequest)
    if term_id is not None:
        query = query.filter(BudgetRevisionRequest.term_id == term_id)
    if status_filter is not None:
        query = query.filter(BudgetRevisionRequest.status == status_filter)

    return query.order_by(BudgetRevisionRequest.id.desc()).all()


@router.get(
    "/{id}",
    response_model=BudgetRevisionResponse,
    summary="예산 증액 요청 단건 상세 조회",
)
def get_budget_revision(
    id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """예산 증액 요청의 상세 정보를 조회합니다."""
    revision_req = (
        db.query(BudgetRevisionRequest)
        .filter(BudgetRevisionRequest.id == id)
        .first()
    )
    if not revision_req:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"증액 요청 ID {id}를 찾을 수 없습니다.",
        )
    return revision_req
