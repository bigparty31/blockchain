from datetime import datetime, timezone
import logging
import secrets
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.auth import User, get_current_user, require_roles
from app.database import get_db
from app.models import (
    Budget,
    BudgetRevisionRequest,
    BudgetVersion,
    Entry,
    Term,
    User as DBUser,
)
from app.schemas.auth import Role
from app.schemas.budget_revision import (
    BudgetRevisionApproveRequest,
    BudgetRevisionRejectRequest,
    BudgetRevisionRequestCreate,
    BudgetRevisionResponse,
    BudgetRevisionSignRequest,
)
from app.utils.hashing import canonical_text

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/budget-revisions", tags=["BudgetRevisions"])


def expire_budget_revision_if_needed(revision: BudgetRevisionRequest, db: Session) -> bool:
    """PRD v0.13 §4.1 / D5 합의: 회장 서명 상태(PRESIDENT_SIGNED)에서 시한이 만료된 요청을 PENDING으로 되돌립니다.
    - 손종인 님 합의 조건 반영:
      1) 증액 트랜잭션 전송 중인 건(tx_increase 선점)은 되돌리지 않음.
      2) 되돌릴 때 저장된 회장 서명값, 서명자, 시한, 버전 필드를 함께 초기화.
    """
    if revision.status != "PRESIDENT_SIGNED":
        return False

    now_ts = int(datetime.now(timezone.utc).timestamp())
    if revision.signature_deadline and revision.signature_deadline <= now_ts:
        if revision.tx_increase:
            return False

        logger.info(
            "증액 요청 ID %s 서명 시한 만료 (%s <= %s). PENDING 상태로 롤백합니다.",
            revision.id,
            revision.signature_deadline,
            now_ts,
        )
        revision.status = "PENDING"
        revision.president_signed_by = None
        revision.president_signature = None
        revision.president_signed_at = None
        revision.signature_deadline = None
        revision.signed_version = None
        try:
            from app.services.notifications import NotificationKind, create_notification
            create_notification(db, NotificationKind.REVISION_REQUESTED, budget_revision_request_id=revision.id)
        except Exception:
            pass
        db.commit()
        db.refresh(revision)
        return True

    return False


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
    - 사유는 canonical_text로 정규화되어 저장됩니다.
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

    # 2. 차단 지출(blocked_entry_id) 검증 (지정된 경우)
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

    # 4. 증액 요청 엔티티 생성 (PENDING, 사유 정규화)
    clean_reason = canonical_text(payload.reason)
    revision_req = BudgetRevisionRequest(
        term_id=payload.term_id,
        category=payload.category,
        budget_id=target_budget_id,
        blocked_entry_id=payload.blocked_entry_id,
        requested_amount=payload.requested_amount,
        reason=clean_reason,
        requested_by=current_user.id,
        status="PENDING",
    )
    db.add(revision_req)
    db.flush()

    # 5. D4 합의: 알림 생성 (알림 모듈 준비 시 safe-call)
    try:
        from app.services.notifications import NotificationKind, create_notification
        create_notification(db, NotificationKind.REVISION_REQUESTED, budget_revision_request_id=revision_req.id)
    except Exception:
        pass

    db.commit()
    db.refresh(revision_req)

    return revision_req


@router.post(
    "/{id}/sign",
    response_model=BudgetRevisionResponse,
    summary="예산 증액 회장 서명 수집 (회장 2단계)",
)
def sign_budget_revision(
    id: int,
    payload: BudgetRevisionSignRequest,
    current_user: User = Depends(require_roles(Role.PRESIDENT)),
    db: Session = Depends(get_db),
):
    """PRD v0.13 §4.1: 회장이 총무의 증액 요청에 대해 EIP-712 IncreaseRequest 서명값을 제출합니다.
    - 서명 시한(signature_deadline), 당시 예산 버전(signed_version)을 저장하고 PRESIDENT_SIGNED 상태로 전이합니다.
    - 요청 총무 본인은 회장 서명을 할 수 없습니다 (Maker-Checker).
    """
    revision = db.query(BudgetRevisionRequest).filter(BudgetRevisionRequest.id == id).first()
    if not revision:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"증액 요청 ID {id}를 찾을 수 없습니다.",
        )

    # 시한 만료 Lazy 처리
    expire_budget_revision_if_needed(revision, db)

    # 상태 검증
    if revision.status != "PENDING":
        if revision.status == "PRESIDENT_SIGNED":
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="이미 회장 서명이 완료된 요청입니다.",
            )
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"현재 상태({revision.status})에서는 서명할 수 없습니다.",
        )

    # Maker-Checker: 신청 총무와 서명 회장은 동일인 불가
    if current_user.id == revision.requested_by:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="증액을 요청한 총무 본인은 회장 서명을 할 수 없습니다.",
        )

    # 시한 검증 (미래 시각이어야 함)
    now_ts = int(datetime.now(timezone.utc).timestamp())
    if payload.signature_deadline <= now_ts:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="서명 만료 시한은 현재 시각 이후여야 합니다.",
        )

    revision.president_signed_by = current_user.id
    revision.president_signature = payload.president_signature
    revision.president_signed_at = datetime.now(timezone.utc)
    revision.signature_deadline = payload.signature_deadline
    revision.signed_version = payload.signed_version
    revision.status = "PRESIDENT_SIGNED"

    # D4 알림 (커밋 전 동일 트랜잭션 추가)
    try:
        from app.services.notifications import NotificationKind, create_notification
        create_notification(db, NotificationKind.REVISION_PRESIDENT_SIGNED, budget_revision_request_id=revision.id)
    except Exception:
        pass

    db.commit()
    db.refresh(revision)

    return revision


@router.post(
    "/{id}/reject",
    response_model=BudgetRevisionResponse,
    summary="예산 증액 반려 (회장 또는 감사)",
)
def reject_budget_revision(
    id: int,
    payload: BudgetRevisionRejectRequest,
    current_user: User = Depends(require_roles(Role.PRESIDENT, Role.AUDITOR)),
    db: Session = Depends(get_db),
):
    """PRD v0.13 §4.1: 회장 또는 감사가 증액 요청을 반려합니다.
    - 반려 사유(reject_reason) 저장이 필수이며 REJECTED 상태로 종료됩니다.
    - 요청 총무 본인은 반려 처리를 할 수 없습니다 (Maker-Checker).
    """
    revision = db.query(BudgetRevisionRequest).filter(BudgetRevisionRequest.id == id).first()
    if not revision:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"증액 요청 ID {id}를 찾을 수 없습니다.",
        )

    expire_budget_revision_if_needed(revision, db)

    if revision.status in ("APPROVED", "REJECTED"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"이미 처리가 완료된 요청입니다 (현재 상태: {revision.status}).",
        )

    if current_user.id == revision.requested_by:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="증액을 요청한 총무 본인은 반려할 수 없습니다.",
        )

    if revision.tx_increase:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="온체인 증액 릴레이가 진행 중인 요청은 반려할 수 없습니다.",
        )

    clean_reject_reason = canonical_text(payload.reject_reason)
    revision.resolved_by = current_user.id
    revision.resolved_at = datetime.now(timezone.utc)
    revision.reject_reason = clean_reject_reason
    revision.status = "REJECTED"

    # D4 알림 (커밋 전 동일 트랜잭션 추가)
    try:
        from app.services.notifications import NotificationKind, create_notification
        create_notification(db, NotificationKind.REVISION_REJECTED, budget_revision_request_id=revision.id)
    except Exception:
        pass

    db.commit()
    db.refresh(revision)

    return revision


@router.post(
    "/{id}/approve",
    response_model=BudgetRevisionResponse,
    summary="예산 증액 감사 최종 승인 및 릴레이 (감사 3단계)",
)
def approve_budget_revision(
    id: int,
    payload: Optional[BudgetRevisionApproveRequest] = None,
    current_user: User = Depends(require_roles(Role.AUDITOR)),
    db: Session = Depends(get_db),
):
    """PRD v0.13 §4.1: 감사가 증액 요청을 최종 승인하고 컨트랙트 increase를 릴레이합니다.
    - 승인 성공 시 같은 트랜잭션에서 BudgetVersion(v+1)이 발행되고 상태가 APPROVED로 확정됩니다.
    - 감사는 요청 총무 또는 회장 서명자와 동일인일 수 없습니다 (Maker-Checker).
    """
    revision = db.query(BudgetRevisionRequest).filter(BudgetRevisionRequest.id == id).first()
    if not revision:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"증액 요청 ID {id}를 찾을 수 없습니다.",
        )

    # 만료 검사 (Lazy Update)
    if expire_budget_revision_if_needed(revision, db):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="회장 서명 시한이 만료되어 PENDING 상태로 되돌아갔습니다. 회장의 재서명이 필요합니다.",
        )

    # 상태 검증
    if revision.status != "PRESIDENT_SIGNED":
        if revision.status == "PENDING":
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="회장 서명이 완료되지 않은 요청입니다.",
            )
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"이미 처리가 완료된 요청입니다 (현재 상태: {revision.status}).",
        )

    # Maker-Checker
    if current_user.id == revision.requested_by:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="증액을 요청한 총무 본인은 감사 승인을 할 수 없습니다.",
        )
    if current_user.id == revision.president_signed_by:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="회장 서명자와 동일한 사용자는 감사 승인을 할 수 없습니다.",
        )

    # 대상 Budget 조회
    target_budget = None
    if revision.budget_id:
        target_budget = db.query(Budget).filter(Budget.id == revision.budget_id).first()
    if not target_budget:
        target_budget = (
            db.query(Budget)
            .filter(Budget.term_id == revision.term_id, Budget.category == revision.category)
            .first()
        )
    if not target_budget:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"대상 예산(학기 {revision.term_id}, 카테고리 '{revision.category}')을 찾을 수 없습니다.",
        )

    # 최신 버전 조회
    latest_version_row = (
        db.query(BudgetVersion)
        .filter(BudgetVersion.budget_id == target_budget.id)
        .order_by(BudgetVersion.version.desc())
        .first()
    )
    current_planned = latest_version_row.planned_amount if latest_version_row else 0
    next_version = (latest_version_row.version if latest_version_row else 1) + 1
    new_planned = current_planned + revision.requested_amount

    # 온체인 트랜잭션 릴레이 (시뮬레이션 해시 생성)
    tx_hash = "0x" + secrets.token_hex(32)

    # 같은 트랜잭션에서 revision과 BudgetVersion 갱신
    revision.tx_increase = tx_hash
    revision.resolved_by = current_user.id
    revision.resolved_at = datetime.now(timezone.utc)
    revision.status = "APPROVED"

    new_budget_version = BudgetVersion(
        budget_id=target_budget.id,
        version=next_version,
        planned_amount=new_planned,
        revision_request_id=revision.id,
        revision_reason=revision.reason,
        approved_by=current_user.id,
        tx_hash=tx_hash,
    )
    db.add(new_budget_version)

    # D4 알림 (커밋 전 동일 트랜잭션 추가)
    try:
        from app.services.notifications import NotificationKind, create_notification
        create_notification(db, NotificationKind.REVISION_APPROVED, budget_revision_request_id=revision.id)
    except Exception:
        pass

    db.commit()
    db.refresh(revision)

    return revision


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
    """예산 증액 요청 목록을 조회합니다 (조회 시 만료된 건 자동 Lazy Update)."""
    query = db.query(BudgetRevisionRequest)
    if term_id is not None:
        query = query.filter(BudgetRevisionRequest.term_id == term_id)
    if status_filter is not None:
        query = query.filter(BudgetRevisionRequest.status == status_filter)

    items = query.order_by(BudgetRevisionRequest.id.desc()).all()
    for item in items:
        if item.status == "PRESIDENT_SIGNED":
            expire_budget_revision_if_needed(item, db)

    return items


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
    """예산 증액 요청의 상세 정보를 조회합니다 (조회 시 만료된 건 자동 Lazy Update)."""
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
    if revision_req.status == "PRESIDENT_SIGNED":
        expire_budget_revision_if_needed(revision_req, db)

    return revision_req
