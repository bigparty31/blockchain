import asyncio
from datetime import datetime, timezone
import logging
from typing import Callable, List, Optional, TypeVar

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import update
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from app.auth import User, require_roles
from app.chain import BudgetRevertReason, ChainClient, IncreaseRequest
from app.chain.models import check_tx_hash
from app.chain.provider import get_chain_client
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
from app.services.budget_relay import (
    MALFORMED_SIGNATURE,
    REASON_HASH_MISMATCH,
    BudgetRelayStatus,
    relay_increase,
)
from app.services.notifications import (
    NotificationKind,
    create_notification,
    resolve_notifications,
)
from app.utils.hashing import (
    canonical_text,
    text_hash,
    validate_multiline_text_for_hash,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/budget-revisions", tags=["BudgetRevisions"])

council_only = require_roles(Role.TREASURER, Role.PRESIDENT, Role.AUDITOR)

T = TypeVar("T")


class _RevisionConflictError(Exception):
    """동시 승인 요청 등으로 선점 또는 반영 조건이 맞지 않을 때 발생하는 409 예외"""


class _RevisionResignRequiredError(Exception):
    """승인 도중 SignatureExpired / VersionMismatch 로 PENDING 롤백된 경우 발생하는 400 예외"""


def _is_unpooled_memory_sqlite(bind) -> bool:
    url = bind.url
    return (
        url.get_backend_name() == "sqlite"
        and url.database in (None, "", ":memory:")
        and not isinstance(bind.pool, StaticPool)
    )


async def _run_short_db(db: Session, work: Callable[[Session], T]) -> T:
    """릴레이어 lock을 쥔 before_broadcast 및 결과 반영 시 짧은 스레드 세션을 사용한다."""
    bind = db.get_bind()
    if _is_unpooled_memory_sqlite(bind):
        try:
            val = work(db)
            db.commit()
            return val
        except BaseException:
            db.rollback()
            raise

    def _in_session() -> T:
        with Session(bind) as s:
            try:
                val = work(s)
                s.commit()
                return val
            except BaseException:
                s.rollback()
                raise

    return await asyncio.to_thread(_in_session)


def _ensure_budget_not_expired(target_budget: Budget) -> None:
    """마감일(expires_at)이 경과한 예산은 증액 요청·서명·승인을 모두 400으로 차단한다."""
    if target_budget.expires_at is None:
        return
    expires_at = target_budget.expires_at
    if expires_at.tzinfo is None:
        expires_at = expires_at.replace(tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    if int(expires_at.timestamp()) <= int(now.timestamp()):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"집행 마감일({target_budget.expires_at})이 경과한 예산은 증액할 수 없습니다.",
        )


def _get_latest_budget_version(budget_id: int, db: Session) -> Optional[BudgetVersion]:
    return (
        db.query(BudgetVersion)
        .filter(BudgetVersion.budget_id == budget_id)
        .order_by(BudgetVersion.version.desc())
        .first()
    )


def _ensure_budget_has_version(target_budget: Budget, db: Session) -> BudgetVersion:
    """버전(BudgetVersion)이 없는 초안 예산은 증액할 수 없다."""
    latest = _get_latest_budget_version(target_budget.id, db)
    if latest is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"예산 ID {target_budget.id}는 아직 온체인 발행이 완료되지 않은 초안 예산이므로 증액할 수 없습니다.",
        )
    return latest


def _get_target_budget(revision: BudgetRevisionRequest, db: Session) -> Budget:
    target_budget = None
    if revision.budget_id is not None:
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
    return target_budget


def expire_budget_revision_if_needed(revision: BudgetRevisionRequest, db: Session) -> bool:
    """PRD §4.1: 회장 서명 상태(PRESIDENT_SIGNED)에서 시한이 만료된 요청을 PENDING으로 되돌립니다.
    - 증액 트랜잭션 전송 중인 건(tx_increase 선점)은 되돌리지 않음.
    - 되돌릴 때 저장된 회장 서명값, 서명자, 시한, 버전 필드를 함께 초기화.
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
        resolve_notifications(db, budget_revision_request_id=revision.id)
        create_notification(db, NotificationKind.REVISION_REQUESTED, budget_revision_request_id=revision.id)
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
    """PRD §4.1: 총무가 예산 증액을 요청하는 1단계 API입니다.
    - 증액 요청액(requested_amount)은 증액분(> 0)이어야 합니다.
    - 사유는 제어문자 검사 후 canonical_text로 정규화되어 저장됩니다.
    - 등록 시 status는 'PENDING'으로 설정됩니다.
    """
    if payload.requested_amount <= 0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="증액 요청액은 0원보다 커야 합니다.",
        )

    try:
        validate_multiline_text_for_hash(payload.reason, "reason")
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(e),
        )
    clean_reason = canonical_text(payload.reason)
    if not clean_reason:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="증액 요청 사유는 필수입니다.",
        )

    # 1. 학기 존재 여부 검증
    term = db.query(Term).filter(Term.id == payload.term_id).first()
    if not term:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"학기 ID {payload.term_id}를 찾을 수 없습니다.",
        )

    # 2. 예산 매핑 검증 (PRD §4.1: 증액은 기존 예산에 대해서만 가능하므로 없으면 404)
    target_budget = None
    if payload.budget_id is not None:
        target_budget = db.query(Budget).filter(Budget.id == payload.budget_id).first()
        if not target_budget:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"예산 ID {payload.budget_id}를 찾을 수 없습니다.",
            )
        if target_budget.term_id != payload.term_id or target_budget.category != payload.category:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="지정된 예산의 학기 또는 카테고리가 일치하지 않습니다.",
            )
    else:
        target_budget = (
            db.query(Budget)
            .filter(Budget.term_id == payload.term_id, Budget.category == payload.category)
            .first()
        )
        if not target_budget:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"해당 학기({payload.term_id}) 및 카테고리('{payload.category}')에 해당하는 기존 예산이 존재하지 않습니다.",
            )

    # 3. 마감 경과 예산 및 미발행 초안 예산 차단
    _ensure_budget_not_expired(target_budget)
    _ensure_budget_has_version(target_budget, db)

    target_budget_id = target_budget.id

    # 4. 차단 지출(blocked_entry_id) 검증 (지정된 경우)
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
        if entry.kind != "EXPENSE":
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="차단 지출 연동은 지출(EXPENSE) 내역만 가능합니다.",
            )
        if entry.status not in ("BLOCKED", "PENDING"):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"지출 상태가 {entry.status}입니다. 차단 지출 연동은 BLOCKED 또는 PENDING 지출만 가능합니다.",
            )
        if entry.budget_id is not None and entry.budget_id != target_budget_id:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="차단 지출의 예산과 증액 요청 대상 예산이 일치하지 않습니다.",
            )

    # 5. 증액 요청 엔티티 생성 (PENDING, 사유 정규화)
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

    create_notification(db, NotificationKind.REVISION_REQUESTED, budget_revision_request_id=revision_req.id)

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
    chain: ChainClient = Depends(get_chain_client),
):
    """PRD §4.1: 회장이 총무의 증액 요청에 대해 EIP-712 IncreaseRequest 서명값을 제출합니다.
    - 대상 예산의 마감 경과 여부, 현재 버전 일치 여부, 서명자(signer_of) 지갑 주소를 검증합니다.
    - 검증 통과 시 서명 시한(signature_deadline), 당시 예산 버전(signed_version)을 저장하고 PRESIDENT_SIGNED 상태로 전이합니다.
    """
    revision = db.query(BudgetRevisionRequest).filter(BudgetRevisionRequest.id == id).first()
    if not revision:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"증액 요청 ID {id}를 찾을 수 없습니다.",
        )

    target_budget = _get_target_budget(revision, db)
    _ensure_budget_not_expired(target_budget)
    latest_version = _ensure_budget_has_version(target_budget, db)

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

    # 현재 최신 예산 버전 대조
    if payload.signed_version != latest_version.version:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"서명 당시 예산 버전({payload.signed_version})이 현재 예산 버전({latest_version.version})과 일치하지 않습니다.",
        )

    # IncreaseRequest 구조체 구성 및 EIP-712 서명자 검증
    try:
        inc_req = IncreaseRequest(
            budget_id=target_budget.id,
            amount=revision.requested_amount,
            reason_hash=text_hash(revision.reason),
            version=payload.signed_version,
            deadline=payload.signature_deadline,
        )
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"증액 서명 요청 파라미터가 유효하지 않습니다: {e}",
        )

    try:
        recovered = chain.signer_of(inc_req, payload.president_signature)
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"회장 서명 형식이 올바르지 않습니다: {e}",
        )

    if not current_user.wallet_address or recovered.lower() != current_user.wallet_address.lower():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="서명자가 회장 본인의 지갑 주소와 일치하지 않습니다.",
        )

    revision.president_signed_by = current_user.id
    revision.president_signature = payload.president_signature
    revision.president_signed_at = datetime.now(timezone.utc)
    revision.signature_deadline = payload.signature_deadline
    revision.signed_version = payload.signed_version
    revision.status = "PRESIDENT_SIGNED"

    resolve_notifications(db, budget_revision_request_id=revision.id)
    create_notification(db, NotificationKind.REVISION_PRESIDENT_SIGNED, budget_revision_request_id=revision.id)

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
    """PRD §4.1: 회장 또는 감사가 증액 요청을 반려합니다.
    - 반려 사유(reject_reason)는 제어문자 검사 및 정규화 후 비어 있으면 400으로 차단됩니다.
    - 요청 총무 본인은 반려 처리를 할 수 없습니다 (Maker-Checker).
    """
    try:
        validate_multiline_text_for_hash(payload.reject_reason, "reject_reason")
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(e),
        )
    clean_reject_reason = canonical_text(payload.reject_reason)
    if not clean_reject_reason:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="반려 사유는 필수입니다.",
        )

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

    revision.resolved_by = current_user.id
    revision.resolved_at = datetime.now(timezone.utc)
    revision.reject_reason = clean_reject_reason
    revision.status = "REJECTED"

    resolve_notifications(db, budget_revision_request_id=revision.id)
    create_notification(db, NotificationKind.REVISION_REJECTED, budget_revision_request_id=revision.id)

    db.commit()
    db.refresh(revision)

    return revision


@router.post(
    "/{id}/approve",
    response_model=BudgetRevisionResponse,
    summary="예산 증액 감사 최종 승인 및 릴레이 (감사 3단계)",
)
async def approve_budget_revision(
    id: int,
    payload: BudgetRevisionApproveRequest,
    current_user: User = Depends(require_roles(Role.AUDITOR)),
    db: Session = Depends(get_db),
    chain: ChainClient = Depends(get_chain_client),
):
    """PRD §4.1 & CHAIN_CLIENT.md §9: 감사가 증액 요청을 최종 승인하고 컨트랙트 increase를 릴레이합니다.
    - 저장된 signed_version, signature_deadline으로 IncreaseRequest를 재구성해 회장·감사 서명 모두 signer_of로 대조합니다.
    - relay_increase에 previous_tx_hash=revision.tx_increase를 전달하고 before_broadcast에서 조건부 선점합니다.
    - INCREASED 결과가 확인된 뒤에만 outcome.version으로 BudgetVersion을 생성하고 APPROVED로 확정합니다.
    """
    revision = db.query(BudgetRevisionRequest).filter(BudgetRevisionRequest.id == id).first()
    if not revision:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"증액 요청 ID {id}를 찾을 수 없습니다.",
        )

    # 대상 Budget 조회 및 마감 경과 / 초안 버전 유무 검사 (마감 경과 예산은 재서명으로 안내하지 않고 즉시 400 차단)
    target_budget = _get_target_budget(revision, db)
    _ensure_budget_not_expired(target_budget)
    latest_version_row = _ensure_budget_has_version(target_budget, db)

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

    if (
        not revision.president_signature
        or revision.signature_deadline is None
        or revision.signed_version is None
        or revision.president_signed_by is None
    ):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="회장 서명 정보가 누락되어 승인할 수 없습니다.",
        )

    # 선점된 앞선 트랜잭션이 없을 때 DB 버전이 이미 올라갔다면(다른 증액이 먼저 승인됨) VersionMismatch 로 PENDING 롤백
    if revision.tx_increase is None and revision.signed_version != latest_version_row.version:
        revision.status = "PENDING"
        revision.president_signed_by = None
        revision.president_signature = None
        revision.president_signed_at = None
        revision.signature_deadline = None
        revision.signed_version = None
        resolve_notifications(db, budget_revision_request_id=revision.id)
        create_notification(db, NotificationKind.REVISION_REQUESTED, budget_revision_request_id=revision.id)
        db.commit()
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                f"서명 당시 예산 버전({inc_version if (inc_version := latest_version_row.version) else ''})이 "
                "변경되어 PENDING 상태로 되돌아갔습니다. 회장의 재서명이 필요합니다. (VersionMismatch)"
            ),
        )

    # 저장된 signed_version, signature_deadline 으로 IncreaseRequest 재구성
    try:
        inc_req = IncreaseRequest(
            budget_id=target_budget.id,
            amount=revision.requested_amount,
            reason_hash=text_hash(revision.reason),
            version=revision.signed_version,
            deadline=revision.signature_deadline,
        )
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"증액 요청 구조체 재구성 실패: {e}",
        )

    # 회장 및 감사 서명자 대조 (signer_of)
    president_user = db.query(DBUser).filter(DBUser.id == revision.president_signed_by).first()
    if not president_user or not president_user.wallet_address:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="서명한 회장의 지갑 주소를 확인할 수 없습니다.",
        )

    try:
        recovered_president = chain.signer_of(inc_req, revision.president_signature)
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"회장 서명 형식이 올바르지 않습니다: {e}",
        )
    if recovered_president.lower() != president_user.wallet_address.lower():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="저장된 회장 서명자가 회장 지갑 주소와 일치하지 않습니다.",
        )

    try:
        recovered_auditor = chain.signer_of(inc_req, payload.auditor_signature)
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"감사 서명 형식이 올바르지 않습니다: {e}",
        )
    if not current_user.wallet_address or recovered_auditor.lower() != current_user.wallet_address.lower():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="감사 서명자가 로그인한 감사의 지갑 주소와 일치하지 않습니다.",
        )

    revision_id = revision.id
    target_budget_id = target_budget.id
    prev_tx_hash = revision.tx_increase
    req_reason = revision.reason
    requested_amount = revision.requested_amount
    pres_sig = revision.president_signature
    aud_sig = payload.auditor_signature

    # 체인 대기 중 라우터 세션의 트랜잭션을 열어 두지 않는다 (CHAIN_CLIENT §3)
    try:
        db.commit()
    except SQLAlchemyError as e:
        logger.exception("증액 릴레이 전 DB 커밋 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    async def _before_broadcast(tx_hash: str) -> None:
        checked_hash = check_tx_hash(tx_hash)

        def _claim(s: Session) -> None:
            tx_cond = (
                BudgetRevisionRequest.tx_increase.is_(None)
                if prev_tx_hash is None
                else BudgetRevisionRequest.tx_increase == prev_tx_hash
            )
            rows = s.execute(
                update(BudgetRevisionRequest)
                .where(
                    BudgetRevisionRequest.id == revision_id,
                    BudgetRevisionRequest.status == "PRESIDENT_SIGNED",
                    tx_cond,
                )
                .values(tx_increase=checked_hash)
                .execution_options(synchronize_session=False)
            ).rowcount
            if rows != 1:
                raise _RevisionConflictError("이미 다른 승인 요청이 처리 중이거나 완료되었습니다.")

        await _run_short_db(db, _claim)

    try:
        outcome = await relay_increase(
            chain,
            inc_req,
            req_reason,
            pres_sig,
            aud_sig,
            previous_tx_hash=prev_tx_hash,
            before_broadcast=_before_broadcast,
        )
    except _RevisionConflictError as e:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=str(e),
        )
    except SQLAlchemyError as e:
        logger.exception("증액 선점 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    # 선점 해제 규칙: failed_tx_hash 가 칸의 값과 같으면 비운다 (CHAIN_CLIENT.md §9)
    if outcome.failed_tx_hash is not None:
        failed_hash = outcome.failed_tx_hash

        def _release(s: Session) -> None:
            s.execute(
                update(BudgetRevisionRequest)
                .where(
                    BudgetRevisionRequest.id == revision_id,
                    BudgetRevisionRequest.tx_increase == failed_hash,
                )
                .values(tx_increase=None)
                .execution_options(synchronize_session=False)
            )

        try:
            await _run_short_db(db, _release)
        except SQLAlchemyError as e:
            logger.exception("증액 선점 해제 중 데이터베이스 오류: %s", e)
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="데이터베이스 처리 중 오류가 발생했습니다.",
            )

    if outcome.status == BudgetRelayStatus.INCREASED:
        if outcome.tx_hash is None or outcome.version is None:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="온체인 증액 결과 정보가 불완전합니다.",
            )
        landed_hash = outcome.tx_hash
        landed_version = outcome.version

        def _settle(s: Session) -> None:
            rev = s.get(BudgetRevisionRequest, revision_id)
            if rev is None:
                raise LookupError(f"증액 요청 ID {revision_id}를 찾을 수 없습니다.")
            if rev.status == "APPROVED":
                if rev.tx_increase == landed_hash:
                    return
                raise _RevisionConflictError("이미 다른 트랜잭션으로 승인 완료된 요청입니다.")

            rows = s.execute(
                update(BudgetRevisionRequest)
                .where(
                    BudgetRevisionRequest.id == revision_id,
                    BudgetRevisionRequest.status == "PRESIDENT_SIGNED",
                    BudgetRevisionRequest.tx_increase == landed_hash,
                )
                .values(
                    status="APPROVED",
                    tx_increase=landed_hash,
                    resolved_by=current_user.id,
                    resolved_at=datetime.now(timezone.utc),
                )
                .execution_options(synchronize_session=False)
            ).rowcount
            if rows != 1:
                raise _RevisionConflictError("이미 다른 승인 요청이 처리 중이거나 상태가 변경되었습니다.")

            latest_bv = (
                s.query(BudgetVersion)
                .filter(BudgetVersion.budget_id == target_budget_id)
                .order_by(BudgetVersion.version.desc())
                .first()
            )
            if latest_bv is None:
                raise ValueError("대상 예산의 기존 버전을 찾을 수 없습니다.")

            new_planned = latest_bv.planned_amount + requested_amount
            new_budget_version = BudgetVersion(
                budget_id=target_budget_id,
                version=landed_version,
                planned_amount=new_planned,
                revision_request_id=revision_id,
                revision_reason=req_reason,
                approved_by=current_user.id,
                tx_hash=landed_hash,
            )
            s.add(new_budget_version)
            try:
                s.flush()
            except IntegrityError as e:
                raise _RevisionConflictError(
                    f"예산 ID {target_budget_id}의 버전 {landed_version}이 이미 존재합니다."
                ) from e

            resolve_notifications(s, budget_revision_request_id=revision_id)
            create_notification(s, NotificationKind.REVISION_APPROVED, budget_revision_request_id=revision_id)

        try:
            await _run_short_db(db, _settle)
        except _RevisionConflictError as e:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(e))
        except LookupError as e:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))
        except ValueError as e:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))
        except SQLAlchemyError as e:
            logger.exception("증액 승인 확정 반영 중 데이터베이스 오류: %s", e)
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="데이터베이스 처리 중 오류가 발생했습니다. 다시 요청하면 결과를 확인합니다.",
            )

        db.expire_all()
        updated = db.query(BudgetRevisionRequest).filter(BudgetRevisionRequest.id == revision_id).first()
        return updated

    if outcome.status == BudgetRelayStatus.NO_RESPONSE:
        logger.warning("증액 릴레이 응답 미확인 (id=%s, tx=%s): %s", revision_id, outcome.tx_hash, outcome.detail)
        if prev_tx_hash is not None and "아직 블록에 없다" in outcome.detail:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="이미 진행 중인 증액 트랜잭션이 아직 블록에 반영되지 않았습니다.",
            )
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="블록체인 네트워크 응답을 확인하지 못했습니다. 잠시 후 다시 시도하면 이전 트랜잭션 결과를 확인합니다.",
        )

    if outcome.status == BudgetRelayStatus.NOT_SENT:
        logger.error("증액 릴레이 미전송 (id=%s): %s", revision_id, outcome.detail)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="블록체인 릴레이어를 사용할 수 없습니다. 설정을 확인한 뒤 다시 시도해 주세요.",
        )

    # REJECTED 처리
    reason = outcome.reason or "Unknown"
    logger.info("증액 릴레이 거부 (id=%s, reason=%s): %s", revision_id, reason, outcome.detail)

    if reason in (BudgetRevertReason.SIGNATURE_EXPIRED.value, BudgetRevertReason.VERSION_MISMATCH.value):
        def _rollback_for_resign(s: Session) -> None:
            rev = s.get(BudgetRevisionRequest, revision_id)
            if rev is None:
                raise LookupError(f"증액 요청 ID {revision_id}를 찾을 수 없습니다.")
            if rev.status == "APPROVED":
                raise _RevisionConflictError("이미 승인 완료된 증액 요청입니다.")
            if rev.status != "PRESIDENT_SIGNED" or rev.tx_increase is not None:
                raise _RevisionConflictError("다른 승인 요청이 처리 중이거나 상태가 변경되었습니다.")

            rev.status = "PENDING"
            rev.president_signed_by = None
            rev.president_signature = None
            rev.president_signed_at = None
            rev.signature_deadline = None
            rev.signed_version = None
            resolve_notifications(s, budget_revision_request_id=revision_id)
            create_notification(s, NotificationKind.REVISION_REQUESTED, budget_revision_request_id=revision_id)

        try:
            await _run_short_db(db, _rollback_for_resign)
        except _RevisionConflictError as e:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(e))
        except LookupError as e:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))
        except SQLAlchemyError as e:
            logger.exception("증액 재서명 롤백 중 데이터베이스 오류: %s", e)
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="데이터베이스 처리 중 오류가 발생했습니다.",
            )

        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"온체인 증액이 거부되어({reason}) PENDING 상태로 되돌아갔습니다. 회장의 재서명이 필요합니다.",
        )

    if reason == BudgetRevertReason.BUDGET_EXPIRED.value:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="집행 마감일이 경과한 예산은 증액할 수 없습니다. (BudgetExpired)",
        )

    if reason in (MALFORMED_SIGNATURE, REASON_HASH_MISMATCH):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"증액 서명 또는 사유 해시가 유효하지 않습니다 ({reason}).",
        )

    raise HTTPException(
        status_code=status.HTTP_400_BAD_REQUEST,
        detail=f"온체인 예산 증액이 거부되었습니다 ({reason}).",
    )


@router.get(
    "",
    response_model=List[BudgetRevisionResponse],
    summary="예산 증액 요청 목록 조회 (학생회 임원 전용)",
)
@router.get(
    "/",
    response_model=List[BudgetRevisionResponse],
    include_in_schema=False,
)
def list_budget_revisions(
    term_id: Optional[int] = None,
    status_filter: Optional[str] = None,
    current_user: User = Depends(council_only),
    db: Session = Depends(get_db),
):
    """예산 증액 요청 목록을 조회합니다 (학생회 임원 전용).
    - 상태 필터를 적용하기 전에 만료된 PRESIDENT_SIGNED 요청을 먼저 PENDING으로 롤백 반영합니다.
    """
    signed_query = db.query(BudgetRevisionRequest).filter(
        BudgetRevisionRequest.status == "PRESIDENT_SIGNED"
    )
    if term_id is not None:
        signed_query = signed_query.filter(BudgetRevisionRequest.term_id == term_id)
    for item in signed_query.all():
        expire_budget_revision_if_needed(item, db)

    query = db.query(BudgetRevisionRequest)
    if term_id is not None:
        query = query.filter(BudgetRevisionRequest.term_id == term_id)
    if status_filter is not None:
        query = query.filter(BudgetRevisionRequest.status == status_filter)

    return query.order_by(BudgetRevisionRequest.id.desc()).all()


@router.get(
    "/{id}",
    response_model=BudgetRevisionResponse,
    summary="예산 증액 요청 단건 상세 조회 (학생회 임원 전용)",
)
def get_budget_revision(
    id: int,
    current_user: User = Depends(council_only),
    db: Session = Depends(get_db),
):
    """예산 증액 요청의 상세 정보를 조회합니다 (학생회 임원 전용, 조회 시 만료된 건 자동 Lazy Update)."""
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
