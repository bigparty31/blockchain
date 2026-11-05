from datetime import datetime, timezone
import logging
from typing import Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.auth.deps import require_roles
from app.auth.users import User
from app.chain import (
    ChainClient,
    ChainError,
    FakeChainClient,
    IssueRequest,
    get_chain_client,
)
from app.chain.eip712 import category_hash
from app.database import get_db
from app.models import (
    Budget as DBBudget,
    BudgetVersion as DBBudgetVersion,
    Entry as DBEntry,
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
    BudgetRelayStatus,
    relay_issue,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/budgets", tags=["Budgets"])


def _to_unix_seconds(dt: datetime) -> int:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


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

    async def _before_broadcast(tx_hash: str) -> None:
        row = db.query(DBBudget).filter(DBBudget.id == budget_id).first()
        if row is not None:
            row.tx_issue = tx_hash
            db.commit()

    try:
        outcome = await relay_issue(
            chain,
            issue_req,
            signature,
            before_broadcast=_before_broadcast,
        )
    except SQLAlchemyError as e:
        db.rollback()
        logger.exception("예산 발행 선점 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    try:
        row = db.query(DBBudget).filter(DBBudget.id == budget_id).first()
        if row is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"ID {budget_id}에 해당하는 예산을 찾을 수 없습니다.",
            )

        if outcome.status == BudgetRelayStatus.ISSUED:
            row.tx_issue = outcome.tx_hash
            row.expires_at = datetime.fromtimestamp(expires_at, tz=timezone.utc)
            ver_no = outcome.version or 1
            v1 = (
                db.query(DBBudgetVersion)
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
                db.add(v1)
            else:
                v1.planned_amount = planned_amount
                v1.approved_by = user.id
                v1.tx_hash = outcome.tx_hash
            db.commit()

            return BudgetIssueResponse(
                id=row.id,
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
            # 선점 규칙: ALREADY_ISSUED의 failed_tx_hash는 이번 시도의 실패한 hash이므로 tx_issue에 남기지 않는다
            if outcome.failed_tx_hash and row.tx_issue == outcome.failed_tx_hash:
                row.tx_issue = prev_tx_issue if prev_tx_issue != outcome.failed_tx_hash else None

            existing = outcome.existing
            actual_amount = existing.issued if existing is not None else planned_amount
            actual_expires = existing.expires_at if existing is not None else expires_at
            actual_version = existing.version if existing is not None else 1
            existing_id = existing.id if existing is not None else row.id

            if existing is None or existing.id == row.id:
                row.expires_at = datetime.fromtimestamp(actual_expires, tz=timezone.utc)
                v1 = (
                    db.query(DBBudgetVersion)
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
                    db.add(v1)
                elif v1.tx_hash is None and row.tx_issue is not None:
                    v1.tx_hash = row.tx_issue
            db.commit()

            return BudgetIssueResponse(
                id=existing_id,
                term_id=term_id,
                term_code=term_code,
                category=category,
                category_hash=cat_hash,
                planned_amount=actual_amount,
                expires_at=actual_expires,
                version=actual_version,
                status="ALREADY_ISSUED",
                issue_status="alreadyIssued",
                tx_hash=row.tx_issue,
                reason=outcome.reason,
                existing_id=existing_id,
                message="이미 온체인에 발행된 예산 항목입니다.",
            )

        if outcome.status == BudgetRelayStatus.NO_RESPONSE:
            if outcome.tx_hash is not None:
                row.tx_issue = outcome.tx_hash
            elif outcome.failed_tx_hash and row.tx_issue == outcome.failed_tx_hash:
                row.tx_issue = prev_tx_issue if prev_tx_issue != outcome.failed_tx_hash else None
            db.commit()

            return BudgetIssueResponse(
                id=row.id,
                term_id=term_id,
                term_code=term_code,
                category=category,
                category_hash=cat_hash,
                planned_amount=planned_amount,
                expires_at=expires_at,
                version=1,
                status="NO_RESPONSE",
                issue_status="noResponse",
                tx_hash=row.tx_issue,
                reason=outcome.reason,
                existing_id=None,
                message="체인 응답을 확인하지 못했습니다. 수정하지 말고 같은 값으로 다시 요청해 결과를 확인하세요.",
            )

        if outcome.status == BudgetRelayStatus.NOT_SENT:
            if outcome.failed_tx_hash and row.tx_issue == outcome.failed_tx_hash:
                row.tx_issue = prev_tx_issue if prev_tx_issue != outcome.failed_tx_hash else None
                db.commit()
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail=outcome.detail or "블록체인 릴레이어가 전송할 수 없는 상태입니다.",
            )

        # BudgetRelayStatus.REJECTED
        if outcome.failed_tx_hash and row.tx_issue == outcome.failed_tx_hash:
            row.tx_issue = prev_tx_issue if prev_tx_issue != outcome.failed_tx_hash else None
            db.commit()

        if outcome.reason == MALFORMED_SIGNATURE:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=outcome.detail or "유효하지 않은 서명 형식입니다.",
            )

        return BudgetIssueResponse(
            id=row.id,
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
    except HTTPException:
        raise
    except SQLAlchemyError as e:
        db.rollback()
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
    DB의 최신 예산 버전(BudgetVersion)과 스마트 컨트랙트 BudgetToken의 실시간 잔량(remaining)을 결합해 반환합니다.
    """
    try:
        query = db.query(DBBudget)
        if term_id is not None:
            query = query.filter(DBBudget.term_id == term_id)
        db_budgets = query.order_by(DBBudget.id.asc()).all()

        spent_rows = (
            db.query(
                DBEntry.budget_id,
                func.coalesce(func.sum(DBEntry.amount), 0),
            )
            .filter(
                DBEntry.status == "CONFIRMED",
                DBEntry.kind == "EXPENSE",
                DBEntry.budget_id.isnot(None),
            )
            .group_by(DBEntry.budget_id)
            .all()
        )
        spent_by_budget: Dict[int, int] = {int(b_id): int(total) for b_id, total in spent_rows}
    except SQLAlchemyError as e:
        logger.exception("예산 목록 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    result: List[BudgetResponse] = []
    is_fake_chain = isinstance(chain, FakeChainClient)

    for b in db_budgets:
        chain_budget = None
        try:
            chain_budget = await chain.get_budget(b.id)
        except ChainError as e:
            logger.warning("체인 예산(id=%s) 조회 실패 — DB 집계로 폴백: %s", b.id, e)

        # 기기 서명 제출 전인 순수 초안(tx_issue=None 이고 BudgetVersion도 없으며 체인에도 없는 행)은 제외
        if b.tx_issue is None and not b.versions and chain_budget is None:
            continue

        latest_ver = max(b.versions, key=lambda v: v.version) if b.versions else None
        if latest_ver is not None:
            planned_amount = int(latest_ver.planned_amount)
            version = int(latest_ver.version)
            revision_reason = latest_ver.revision_reason
        elif chain_budget is not None:
            planned_amount = int(chain_budget.issued)
            version = int(chain_budget.version)
            revision_reason = None
        else:
            planned_amount = 0
            version = 1
            revision_reason = None

        db_spent = max(0, spent_by_budget.get(b.id, 0))
        if chain_budget is not None:
            if not is_fake_chain or chain_budget.spent > 0 or db_spent == 0:
                remaining_amount = max(0, int(chain_budget.issued) - int(chain_budget.spent))
            else:
                # FakeChainClient는 confirm_entry 시 _budgets.spent를 갱신하지 않으므로 DB 확정 지출액을 반영
                remaining_amount = max(0, planned_amount - db_spent)
        else:
            remaining_amount = max(0, planned_amount - db_spent)

        spent_amount = max(0, planned_amount - remaining_amount)
        execution_rate = round(spent_amount / planned_amount, 4) if planned_amount > 0 else 0.0

        result.append(
            BudgetResponse(
                id=b.id,
                term_id=b.term_id,
                category=b.category,
                planned_amount=planned_amount,
                remaining_amount=remaining_amount,
                execution_rate=execution_rate,
                version=version,
                expires_at=_to_unix_seconds(b.expires_at),
                revision_reason=revision_reason,
            )
        )

    return result


@router.post(
    "",
    response_model=BudgetIssueResponse,
    status_code=status.HTTP_201_CREATED,
    summary="예산 최초 편성 및 조건부 예산 토큰 발행 (회장 전용)",
)
@router.post(
    "/",
    response_model=BudgetIssueResponse,
    status_code=status.HTTP_201_CREATED,
    include_in_schema=False,
)
async def create_or_issue_budget(
    req: BudgetIssueCreate,
    db: Session = Depends(get_db),
    chain: ChainClient = Depends(get_chain_client),
    user: User = Depends(require_roles(Role.PRESIDENT)),
):
    """학기 초 회장이 항목별 예산을 편성하고 조건부 예산 토큰(BudgetToken.issue)을 발행합니다.

    - `signature`·`deadline` 없이 호출하면 서명 대상 `budget_id`를 먼저 발급(`status='DRAFT'`)합니다.
    - `signature`·`deadline`을 함께 전달하면 회장 서명자 대조(`signer_of`) 후 `relay_issue`로 체인 발행을 수행합니다.
    """
    try:
        cat_hash = category_hash(req.category)
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(e),
        )

    if (req.signature is None) != (req.deadline is None):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="서명(signature)과 유효 시한(deadline)은 함께 전달해야 합니다.",
        )

    try:
        term = db.query(DBTerm).filter(DBTerm.id == req.term_id).first()
        if term is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"ID {req.term_id}에 해당하는 학기를 찾을 수 없습니다.",
            )

        if req.id is not None:
            by_id = db.query(DBBudget).filter(DBBudget.id == req.id).first()
            if by_id is not None and (by_id.term_id != req.term_id or by_id.category != req.category):
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=f"ID {req.id}는 이미 다른 예산 항목({by_id.category})에서 사용 중입니다.",
                )

        budget = (
            db.query(DBBudget)
            .filter(DBBudget.term_id == req.term_id, DBBudget.category == req.category)
            .first()
        )
        if req.id is not None and budget is not None and budget.id != req.id:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"해당 학기·카테고리 예산은 이미 ID {budget.id}로 존재합니다.",
            )

        expires_dt = datetime.fromtimestamp(req.expires_at, tz=timezone.utc)

        # 1단계: 서명 없이 budget_id 채번만 요청한 경우
        if req.signature is None:
            if budget is not None:
                if budget.tx_issue is not None and any(v.tx_hash is not None for v in budget.versions):
                    latest_ver = max(budget.versions, key=lambda v: v.version)
                    return BudgetIssueResponse(
                        id=budget.id,
                        term_id=budget.term_id,
                        term_code=term.term_code,
                        category=budget.category,
                        category_hash=cat_hash,
                        planned_amount=int(latest_ver.planned_amount),
                        expires_at=_to_unix_seconds(budget.expires_at),
                        version=int(latest_ver.version),
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
                    id=req.id,
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
                expires_at=req.expires_at,
                version=1,
                status="DRAFT",
                issue_status=None,
                tx_hash=budget.tx_issue,
                reason=None,
                existing_id=None,
                message="예산 초안 ID가 준비되었습니다. 회장 기기 서명을 제출해 주세요.",
            )

        # 서명 포함 발행: 예산 행이 아직 없으면 flush로 ID만 먼저 확보하고 서명 검증 통과 시 commit
        if budget is None:
            budget = DBBudget(
                id=req.id,
                term_id=req.term_id,
                category=req.category,
                expires_at=expires_dt,
                tx_issue=None,
            )
            db.add(budget)
            db.flush()
            prev_tx_issue = None
        else:
            prev_tx_issue = budget.tx_issue
            if budget.tx_issue is None:
                budget.expires_at = expires_dt
                db.flush()

        budget_id = int(budget.id)
        term_code = int(term.term_code)
    except HTTPException:
        raise
    except SQLAlchemyError as e:
        db.rollback()
        logger.exception("예산 편성 준비 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    return await _execute_budget_issue(
        db=db,
        chain=chain,
        user=user,
        budget_id=budget_id,
        term_id=req.term_id,
        term_code=term_code,
        category=req.category,
        cat_hash=cat_hash,
        planned_amount=req.planned_amount,
        expires_at=req.expires_at,
        deadline=int(req.deadline),
        signature=req.signature,
        prev_tx_issue=prev_tx_issue,
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

        try:
            cat_hash = category_hash(budget.category)
        except ValueError as e:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=str(e),
            )

        prev_tx_issue = budget.tx_issue
        expires_at = req.expires_at if req.expires_at is not None else _to_unix_seconds(budget.expires_at)
        if budget.tx_issue is None and req.expires_at is not None:
            budget.expires_at = datetime.fromtimestamp(req.expires_at, tz=timezone.utc)
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
