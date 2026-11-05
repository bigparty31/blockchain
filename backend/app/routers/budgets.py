import asyncio
from datetime import datetime, timezone
import logging
from typing import Callable, List, Optional, TypeVar

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import or_, update
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.auth.deps import require_roles
from app.auth.users import User
from app.chain import (
    ChainClient,
    ChainError,
    ChainRevert,
    IssueRequest,
    get_chain_client,
)
from app.chain.eip712 import category_hash
from app.chain.models import check_tx_hash
from app.database import get_db
from app.models import (
    Budget as DBBudget,
    BudgetRevisionRequest as DBBudgetRevisionRequest,
    BudgetVersion as DBBudgetVersion,
    Term as DBTerm,
)
from app.schemas.auth import Role
from app.schemas.budget import (
    BudgetIssueCreate,
    BudgetIssueResponse,
    BudgetIssueSubmit,
    BudgetResponse,
)
from app.services.budget_relay import (
    MALFORMED_SIGNATURE,
    BudgetRelayOutcome,
    BudgetRelayStatus,
    relay_issue,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/budgets", tags=["Budgets"])

T = TypeVar("T")

# docs/CONTRACTS.md category 표 및 app/lib/core/budget_plan.dart(BudgetCategory)의 지출(EXPENSE) 8종.
# 학생회비·지원금·후원금·이자수입 등 수입(INCOME) 항목은 예산 발행 대상이 아니므로 거부한다.
EXPENSE_BUDGET_CATEGORIES = frozenset(
    {"행사비", "사업비", "운영비", "홍보비", "복지비", "회의비", "비품비", "예비비"}
)


def _validate_expense_category(category: str) -> str:
    """지출 예산 항목(EXPENSE 8종)인지 검증하고 keccak256 해시를 반환한다."""
    try:
        cat_hash = category_hash(category)
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(e),
        )
    if category not in EXPENSE_BUDGET_CATEGORIES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"예산 편성·발행은 지출(EXPENSE) 8종 항목만 허용됩니다 (입력값: '{category}').",
        )
    return cat_hash


def _to_unix_seconds(dt: datetime) -> int:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


def _from_unix_seconds(ts: int) -> datetime:
    try:
        return datetime.fromtimestamp(ts, tz=timezone.utc)
    except (OverflowError, OSError, ValueError):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="예산 만료 시각(expires_at)이 허용 범위를 벗어났습니다.",
        )


async def _run_short_db(db: Session, fn: Callable[[Session], T]) -> T:
    """릴레이어 락 점유 구간(before_broadcast)이나 온체인 대기 직후 DB 갱신을 별도 스레드·짧은 세션으로 실행한다."""
    bind = db.get_bind()

    def _work() -> T:
        with Session(bind=bind, expire_on_commit=False) as s:
            try:
                res = fn(s)
                s.commit()
                return res
            except Exception:
                s.rollback()
                raise

    return await asyncio.to_thread(_work)


class _BudgetIssueClaimConflictError(Exception):
    """다른 요청이 먼저 해당 예산의 tx_issue를 선점했거나 처리 완료한 경우"""


def _cleanup_unissued_seed_versions(s: Session, budget_id: int) -> None:
    """시드 스크립트 등이 미리 넣어 둔 미발행 더미 상위 버전(version > 1)과 고아 증액 요청을 정리한다.

    실제 체인에서 최초 발행(version=1)이 막 끝났을 때 시드 v2(2,500,000원 등)가 남아 있으면
    GET /budgets 에서 체인은 version 1인데 DB 시드 v2가 조회되어 편성액·집행률이 어긋나므로 제거한다.
    """
    stale_versions = (
        s.query(DBBudgetVersion)
        .filter(
            DBBudgetVersion.budget_id == budget_id,
            DBBudgetVersion.version > 1,
        )
        .all()
    )
    stale_rev_ids = [
        v.revision_request_id
        for v in stale_versions
        if v.revision_request_id is not None
    ]
    for v in stale_versions:
        s.delete(v)
    if stale_rev_ids:
        s.flush()
        for rev_id in stale_rev_ids:
            rev_row = (
                s.query(DBBudgetRevisionRequest)
                .filter(
                    DBBudgetRevisionRequest.id == rev_id,
                    DBBudgetRevisionRequest.budget_id == budget_id,
                )
                .first()
            )
            if rev_row is not None:
                s.delete(rev_row)


async def _execute_budget_issue(
    *,
    db: Session,
    chain: ChainClient,
    user: User,
    budget_id: int,
    term_id: int,
    term_code: int,
    category: str,
    cat_hash: str,
    planned_amount: int,
    expires_at: int,
    deadline: int,
    signature: str,
    prev_tx_issue: Optional[str],
) -> BudgetIssueResponse:
    """서명자 대조 후 relay_issue를 호출하고 결과를 DB(Budget.tx_issue·BudgetVersion)에 반영한다."""
    expires_dt = _from_unix_seconds(expires_at)

    issue_req = IssueRequest(
        budget_id=budget_id,
        term=term_code,
        category=cat_hash,
        amount=planned_amount,
        expires_at=expires_at,
        deadline=deadline,
    )

    try:
        recovered_signer = chain.signer_of(issue_req, signature)
    except ValueError as e:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"유효하지 않은 서명 형식입니다: {e}",
        )

    if not user.wallet_address or recovered_signer.lower() != user.wallet_address.lower():
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="서명자가 요청한 회장의 지갑 주소와 일치하지 않습니다.",
        )

    # 릴레이 호출 전 열린 트랜잭션을 닫아 둔다 (CHAIN_CLIENT §3)
    try:
        db.commit()
    except SQLAlchemyError as e:
        db.rollback()
        logger.exception("예산 발행 전 DB 커밋 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    # 앞서 보낸 tx_issue가 이미 있으면 새로 브로드캐스트하기 전에 그 결과부터 확인한다
    failed_previous: Optional[str] = None
    outcome: Optional[BudgetRelayOutcome] = None
    claimed_tx_hash: Optional[str] = prev_tx_issue

    if prev_tx_issue is not None:
        try:
            landed = await chain.budget_tx_result(prev_tx_issue, budget_id)
        except ChainRevert:
            failed_previous = prev_tx_issue
        except ChainError as e:
            logger.warning("앞선 예산 발행 트랜잭션 확인 실패 (budget_id=%s, tx=%s): %s", budget_id, prev_tx_issue, e)
            outcome = BudgetRelayOutcome(
                BudgetRelayStatus.NO_RESPONSE,
                tx_hash=prev_tx_issue,
                detail=f"앞선 트랜잭션을 확인하지 못했다: {e}",
            )
        else:
            if landed is None:
                # 앞선 트랜잭션이 아직 멤풀/블록 대기 중일 수 있으므로 중복 전송하지 않는다
                outcome = BudgetRelayOutcome(
                    BudgetRelayStatus.NO_RESPONSE,
                    tx_hash=prev_tx_issue,
                    detail="앞선 트랜잭션이 아직 블록에 없다",
                )
            else:
                try:
                    existing_on_chain = await chain.get_budget(budget_id)
                except ChainError as e:
                    logger.warning("발행 완료된 예산 온체인 조회 실패 (budget_id=%s): %s", budget_id, e)
                    outcome = BudgetRelayOutcome(
                        BudgetRelayStatus.NO_RESPONSE,
                        tx_hash=prev_tx_issue,
                        detail=f"체인의 예산을 확인하지 못했다: {e}",
                    )
                else:
                    outcome = BudgetRelayOutcome(
                        BudgetRelayStatus.ALREADY_ISSUED,
                        tx_hash=landed.tx_hash,
                        version=landed.version,
                        existing=existing_on_chain,
                    )

    async def _before_broadcast(tx_hash: str) -> None:
        nonlocal claimed_tx_hash
        normalized_tx = check_tx_hash(tx_hash)

        def _claim(s: Session) -> None:
            if prev_tx_issue is None:
                claim_cond = DBBudget.tx_issue.is_(None)
            else:
                claim_cond = or_(
                    DBBudget.tx_issue.is_(None),
                    DBBudget.tx_issue == prev_tx_issue,
                )
            stmt = (
                update(DBBudget)
                .where(
                    DBBudget.id == budget_id,
                    claim_cond,
                )
                .values(tx_issue=normalized_tx)
            )
            res = s.execute(stmt)
            if res.rowcount != 1:
                raise _BudgetIssueClaimConflictError()

        await _run_short_db(db, _claim)
        claimed_tx_hash = normalized_tx

    if outcome is None:
        try:
            outcome = await relay_issue(
                chain,
                issue_req,
                signature,
                before_broadcast=_before_broadcast,
            )
            if outcome.failed_tx_hash is None and failed_previous is not None and outcome.tx_hash is None:
                outcome = BudgetRelayOutcome(
                    outcome.status,
                    tx_hash=outcome.tx_hash,
                    failed_tx_hash=failed_previous,
                    version=outcome.version,
                    reason=outcome.reason,
                    detail=outcome.detail,
                    existing=outcome.existing,
                )
        except _BudgetIssueClaimConflictError:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="다른 예산 발행 요청이 이미 처리 중이거나 완료되었습니다.",
            )
        except SQLAlchemyError as e:
            logger.exception("예산 발행 선점 중 데이터베이스 오류: %s", e)
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="데이터베이스 처리 중 오류가 발생했습니다.",
            )

    def _release_claim_if_matches(s: Session, row: DBBudget, failed_hash: Optional[str]) -> None:
        target_hashes = {h for h in (failed_hash, claimed_tx_hash, failed_previous) if h is not None}
        if row.tx_issue is not None and row.tx_issue in target_hashes:
            row.tx_issue = None

    try:
        if outcome.status == BudgetRelayStatus.ISSUED:
            ver_no = outcome.version or 1

            def _apply_issued(s: Session) -> int:
                row = s.query(DBBudget).filter(DBBudget.id == budget_id).first()
                if row is None:
                    raise LookupError(f"ID {budget_id}에 해당하는 예산을 찾을 수 없습니다.")
                if row.tx_issue is not None and row.tx_issue not in {
                    prev_tx_issue,
                    claimed_tx_hash,
                    outcome.tx_hash,
                }:
                    raise _BudgetIssueClaimConflictError()

                row.tx_issue = outcome.tx_hash
                row.expires_at = expires_dt
                if ver_no == 1:
                    _cleanup_unissued_seed_versions(s, row.id)

                v1 = (
                    s.query(DBBudgetVersion)
                    .filter(DBBudgetVersion.budget_id == row.id, DBBudgetVersion.version == 1)
                    .first()
                )
                if v1 is None:
                    v1 = DBBudgetVersion(
                        budget_id=row.id,
                        version=1,
                        planned_amount=planned_amount,
                        revision_reason=None,
                        approved_by=user.id,
                        revision_request_id=None,
                        tx_hash=outcome.tx_hash,
                    )
                    s.add(v1)
                else:
                    v1.planned_amount = planned_amount
                    v1.approved_by = user.id
                    v1.tx_hash = outcome.tx_hash
                return int(row.id)

            saved_id = await _run_short_db(db, _apply_issued)
            return BudgetIssueResponse(
                id=saved_id,
                term_id=term_id,
                term_code=term_code,
                category=category,
                category_hash=cat_hash,
                planned_amount=planned_amount,
                expires_at=expires_at,
                version=ver_no,
                status="ISSUED",
                issue_status="issued",
                tx_hash=outcome.tx_hash,
                reason=None,
                existing_id=None,
                message="예산 토큰이 온체인에 발행되었습니다.",
            )

        if outcome.status == BudgetRelayStatus.ALREADY_ISSUED:
            existing = outcome.existing
            if existing is not None and existing.id != budget_id:
                def _release_on_id_mismatch(s: Session) -> None:
                    row = s.query(DBBudget).filter(DBBudget.id == budget_id).first()
                    if row is not None and outcome.failed_tx_hash and row.tx_issue == outcome.failed_tx_hash:
                        row.tx_issue = prev_tx_issue if prev_tx_issue != outcome.failed_tx_hash else None

                await _run_short_db(db, _release_on_id_mismatch)
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=(
                        f"온체인에 동일 학기·항목 예산이 다른 ID(온체인 ID={existing.id}, DB ID={budget_id})로 "
                        "이미 발행되어 있습니다."
                    ),
                )

            actual_amount = int(existing.issued) if existing is not None else planned_amount
            actual_expires = int(existing.expires_at) if existing is not None else expires_at
            actual_version = int(existing.version) if existing is not None else 1
            actual_expires_dt = _from_unix_seconds(actual_expires)

            def _apply_already_issued(s: Session) -> tuple[int, Optional[str]]:
                row = s.query(DBBudget).filter(DBBudget.id == budget_id).first()
                if row is None:
                    raise LookupError(f"ID {budget_id}에 해당하는 예산을 찾을 수 없습니다.")
                if outcome.failed_tx_hash and row.tx_issue == outcome.failed_tx_hash:
                    row.tx_issue = prev_tx_issue if prev_tx_issue != outcome.failed_tx_hash else None

                row.expires_at = actual_expires_dt
                if actual_version == 1:
                    _cleanup_unissued_seed_versions(s, row.id)

                v1 = (
                    s.query(DBBudgetVersion)
                    .filter(DBBudgetVersion.budget_id == row.id, DBBudgetVersion.version == 1)
                    .first()
                )
                if v1 is None:
                    v1 = DBBudgetVersion(
                        budget_id=row.id,
                        version=1,
                        planned_amount=actual_amount,
                        revision_reason=None,
                        approved_by=user.id,
                        revision_request_id=None,
                        tx_hash=row.tx_issue,
                    )
                    s.add(v1)
                else:
                    if actual_version == 1:
                        v1.planned_amount = actual_amount
                    if v1.tx_hash is None and row.tx_issue is not None:
                        v1.tx_hash = row.tx_issue
                return int(row.id), row.tx_issue

            saved_id, saved_tx = await _run_short_db(db, _apply_already_issued)
            return BudgetIssueResponse(
                id=saved_id,
                term_id=term_id,
                term_code=term_code,
                category=category,
                category_hash=cat_hash,
                planned_amount=actual_amount,
                expires_at=actual_expires,
                version=actual_version,
                status="ALREADY_ISSUED",
                issue_status="alreadyIssued",
                tx_hash=saved_tx,
                reason=outcome.reason,
                existing_id=saved_id,
                message="이미 온체인에 발행된 예산 항목입니다.",
            )

        if outcome.status == BudgetRelayStatus.NO_RESPONSE:
            logger.warning("예산 발행 체인 응답 미확인 (budget_id=%s): %s", budget_id, outcome.detail)

            def _apply_no_response(s: Session) -> tuple[int, Optional[str]]:
                row = s.query(DBBudget).filter(DBBudget.id == budget_id).first()
                if row is None:
                    raise LookupError(f"ID {budget_id}에 해당하는 예산을 찾을 수 없습니다.")
                if outcome.tx_hash is not None:
                    if row.tx_issue in {None, prev_tx_issue, claimed_tx_hash, outcome.tx_hash}:
                        row.tx_issue = outcome.tx_hash
                elif outcome.failed_tx_hash and row.tx_issue == outcome.failed_tx_hash:
                    row.tx_issue = prev_tx_issue if prev_tx_issue != outcome.failed_tx_hash else None
                return int(row.id), row.tx_issue

            saved_id, saved_tx = await _run_short_db(db, _apply_no_response)
            return BudgetIssueResponse(
                id=saved_id,
                term_id=term_id,
                term_code=term_code,
                category=category,
                category_hash=cat_hash,
                planned_amount=planned_amount,
                expires_at=expires_at,
                version=1,
                status="NO_RESPONSE",
                issue_status="noResponse",
                tx_hash=saved_tx,
                reason=outcome.reason,
                existing_id=None,
                message="체인 응답을 확인하지 못했습니다. 수정하지 말고 같은 값으로 다시 요청해 결과를 확인하세요.",
            )

        if outcome.status == BudgetRelayStatus.NOT_SENT:
            logger.error("예산 발행 릴레이어 전송 불가 (budget_id=%s): %s", budget_id, outcome.detail)

            def _release_not_sent(s: Session) -> None:
                row = s.query(DBBudget).filter(DBBudget.id == budget_id).first()
                if row is not None and outcome.failed_tx_hash:
                    _release_claim_if_matches(s, row, outcome.failed_tx_hash)

            await _run_short_db(db, _release_not_sent)
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="블록체인 릴레이어가 트랜잭션을 전송할 수 없는 상태입니다.",
            )

        # BudgetRelayStatus.REJECTED
        logger.warning("예산 발행 체인 거부 (budget_id=%s, reason=%s): %s", budget_id, outcome.reason, outcome.detail)

        def _release_rejected(s: Session) -> int:
            row = s.query(DBBudget).filter(DBBudget.id == budget_id).first()
            if row is None:
                raise LookupError(f"ID {budget_id}에 해당하는 예산을 찾을 수 없습니다.")
            if outcome.failed_tx_hash:
                _release_claim_if_matches(s, row, outcome.failed_tx_hash)
            return int(row.id)

        saved_id = await _run_short_db(db, _release_rejected)

        if outcome.reason == MALFORMED_SIGNATURE:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="유효하지 않은 서명 형식입니다.",
            )

        return BudgetIssueResponse(
            id=saved_id,
            term_id=term_id,
            term_code=term_code,
            category=category,
            category_hash=cat_hash,
            planned_amount=planned_amount,
            expires_at=expires_at,
            version=1,
            status="REJECTED",
            issue_status="rejected",
            tx_hash=None,
            reason=outcome.reason,
            existing_id=None,
            message=f"체인에서 예산 발행이 거부되었습니다 ({outcome.reason}).",
        )
    except LookupError as e:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=str(e),
        )
    except _BudgetIssueClaimConflictError:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="다른 예산 발행 요청이 이미 처리 중이거나 완료되었습니다.",
        )
    except HTTPException:
        raise
    except SQLAlchemyError as e:
        logger.exception("예산 발행 결과 저장 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )


@router.get("", response_model=List[BudgetResponse], summary="항목별 예산 편성액 및 잔량 조회")
@router.get("/", response_model=List[BudgetResponse], include_in_schema=False)
async def get_budgets(
    term_id: Optional[int] = Query(None, ge=1, description="조회할 학기 ID (미지정 시 전체 학기)"),
    db: Session = Depends(get_db),
    chain: ChainClient = Depends(get_chain_client),
):
    """모바일 앱 '예산 현황' 및 집행률 그래프 화면에서 호출하는 카테고리별 예산 현황 API입니다.
    스마트 컨트랙트 BudgetToken에 발행 완료된 예산의 온체인 한도(issued)·실시간 잔량(remaining)과
    DB의 해당 버전 개정 사유(revision_reason)를 결합해 반환합니다.
    """
    try:
        query = db.query(DBBudget)
        if term_id is not None:
            query = query.filter(DBBudget.term_id == term_id)
        db_budgets = query.order_by(DBBudget.id.asc()).all()
    except SQLAlchemyError as e:
        logger.exception("예산 목록 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    result: List[BudgetResponse] = []

    for b in db_budgets:
        try:
            chain_budget = await chain.get_budget(b.id)
        except ChainError as e:
            logger.error("체인 예산(id=%s) 조회 실패: %s", b.id, e)
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="블록체인 네트워크와 통신할 수 없습니다.",
            )

        # 온체인에 발행되지 않은 행(초안, 시드 전용 더미, NO_RESPONSE 대기 건)은 목록에서 제외
        if chain_budget is None:
            continue

        planned_amount = int(chain_budget.issued)
        remaining_amount = max(0, int(chain_budget.remaining))
        version = int(chain_budget.version)

        matched_ver = next((v for v in b.versions if v.version == version), None)
        if matched_ver is None and b.versions:
            valid_versions = [v for v in b.versions if v.version <= version]
            if valid_versions:
                matched_ver = max(valid_versions, key=lambda v: v.version)
        revision_reason = matched_ver.revision_reason if matched_ver is not None else None

        spent_amount = max(0, planned_amount - remaining_amount)
        execution_rate = round(spent_amount / planned_amount, 4) if planned_amount > 0 else 0.0
        expires_at = (
            int(chain_budget.expires_at)
            if chain_budget.expires_at
            else _to_unix_seconds(b.expires_at)
        )

        result.append(
            BudgetResponse(
                id=b.id,
                term_id=b.term_id,
                category=b.category,
                planned_amount=planned_amount,
                remaining_amount=remaining_amount,
                execution_rate=execution_rate,
                version=version,
                expires_at=expires_at,
                revision_reason=revision_reason,
            )
        )

    return result


@router.post(
    "",
    response_model=BudgetIssueResponse,
    status_code=status.HTTP_201_CREATED,
    summary="예산 최초 편성 1단계 초안 ID 발급 (회장 전용)",
)
@router.post(
    "/",
    response_model=BudgetIssueResponse,
    status_code=status.HTTP_201_CREATED,
    include_in_schema=False,
)
async def create_budget_draft(
    req: BudgetIssueCreate,
    db: Session = Depends(get_db),
    chain: ChainClient = Depends(get_chain_client),
    user: User = Depends(require_roles(Role.PRESIDENT)),
):
    """학기 초 회장이 항목별 예산을 편성할 때 EIP-712 `IssueRequest` 서명에 필요한 `budget_id`를 발급(1단계)합니다.

    - 이어서 `POST /budgets/{id}/submit`으로 회장 기기 서명을 제출하면 온체인 `BudgetToken.issue`가 실행됩니다.
    - 이미 온체인에 발행된 학기·항목이면 `status='ALREADY_ISSUED'`로 기존 예산 정보를 안내합니다.
    """
    cat_hash = _validate_expense_category(req.category)
    expires_dt = _from_unix_seconds(req.expires_at)

    try:
        term = db.query(DBTerm).filter(DBTerm.id == req.term_id).first()
        if term is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"ID {req.term_id}에 해당하는 학기를 찾을 수 없습니다.",
            )

        budget = (
            db.query(DBBudget)
            .filter(DBBudget.term_id == req.term_id, DBBudget.category == req.category)
            .first()
        )
        if budget is not None:
            chain_budget = None
            try:
                chain_budget = await chain.get_budget(budget.id)
            except ChainError:
                chain_budget = None

            if chain_budget is not None:
                return BudgetIssueResponse(
                    id=budget.id,
                    term_id=budget.term_id,
                    term_code=term.term_code,
                    category=budget.category,
                    category_hash=cat_hash,
                    planned_amount=int(chain_budget.issued),
                    expires_at=int(chain_budget.expires_at),
                    version=int(chain_budget.version),
                    status="ALREADY_ISSUED",
                    issue_status="alreadyIssued",
                    tx_hash=budget.tx_issue,
                    reason=None,
                    existing_id=budget.id,
                    message="이미 온체인에 발행된 예산 항목입니다.",
                )

            if budget.tx_issue is None:
                budget.expires_at = expires_dt
                db.commit()
        else:
            budget = DBBudget(
                term_id=req.term_id,
                category=req.category,
                expires_at=expires_dt,
                tx_issue=None,
            )
            db.add(budget)
            db.commit()
            db.refresh(budget)

        return BudgetIssueResponse(
            id=budget.id,
            term_id=budget.term_id,
            term_code=term.term_code,
            category=budget.category,
            category_hash=cat_hash,
            planned_amount=req.planned_amount,
            expires_at=_to_unix_seconds(budget.expires_at) if budget.expires_at is not None else req.expires_at,
            version=1,
            status="DRAFT",
            issue_status=None,
            tx_hash=budget.tx_issue,
            reason=None,
            existing_id=None,
            message="예산 초안 ID가 준비되었습니다. 회장 기기 서명을 제출해 주세요.",
        )
    except HTTPException:
        raise
    except SQLAlchemyError as e:
        db.rollback()
        logger.exception("예산 초안 준비 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )


@router.post(
    "/{id}/submit",
    response_model=BudgetIssueResponse,
    status_code=status.HTTP_200_OK,
    summary="채번된 예산 초안에 대한 회장 기기 서명 제출 (회장 전용)",
)
async def submit_budget_issue(
    id: int,
    req: BudgetIssueSubmit,
    db: Session = Depends(get_db),
    chain: ChainClient = Depends(get_chain_client),
    user: User = Depends(require_roles(Role.PRESIDENT)),
):
    """1단계(`POST /budgets`)로 발급받은 예산 `id`에 대해 회장 기기 서명(`IssueRequest`)을 제출하여 온체인에 발행합니다."""
    try:
        budget = db.query(DBBudget).filter(DBBudget.id == id).first()
        if budget is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"ID {id}에 해당하는 예산을 찾을 수 없습니다.",
            )
        term = db.query(DBTerm).filter(DBTerm.id == budget.term_id).first()
        if term is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"ID {budget.term_id}에 해당하는 학기를 찾을 수 없습니다.",
            )

        cat_hash = _validate_expense_category(budget.category)

        prev_tx_issue = budget.tx_issue
        expires_at = req.expires_at if req.expires_at is not None else _to_unix_seconds(budget.expires_at)
        expires_dt = _from_unix_seconds(expires_at)
        if budget.tx_issue is None and req.expires_at is not None:
            budget.expires_at = expires_dt
            db.flush()

        budget_id = int(budget.id)
        term_id = int(budget.term_id)
        term_code = int(term.term_code)
        category = str(budget.category)
    except HTTPException:
        raise
    except SQLAlchemyError as e:
        db.rollback()
        logger.exception("예산 서명 제출 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    return await _execute_budget_issue(
        db=db,
        chain=chain,
        user=user,
        budget_id=budget_id,
        term_id=term_id,
        term_code=term_code,
        category=category,
        cat_hash=cat_hash,
        planned_amount=req.planned_amount,
        expires_at=expires_at,
        deadline=req.deadline,
        signature=req.signature,
        prev_tx_issue=prev_tx_issue,
    )
