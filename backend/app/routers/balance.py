import logging
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.database import get_db
from app.models import Entry as DBEntry
from app.schemas.balance import BalanceResponse

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/balance", tags=["Balance"])
query_router = router


@router.get("", response_model=BalanceResponse, summary="장부 잔액 요약 조회")
@router.get("/", response_model=BalanceResponse, include_in_schema=False)
async def get_balance(
    term_id: Optional[int] = Query(None, ge=1, description="조회할 학기 ID (미지정 시 전체 학기)"),
    db: Session = Depends(get_db),
):
    """모바일 앱 메인 대시보드 상단에 표시되는 계좌/장부 잔액 및 총 수입·지출 합계 조회 API입니다.
    PRD §7.4 산출식 (장부잔액 = Σ확정수입 - Σ확정지출)을 따르며, CONFIRMED 상태 건(정정 포함)만 집계합니다.
    """
    try:
        base_filter = [DBEntry.status == "CONFIRMED"]
        if term_id is not None:
            base_filter.append(DBEntry.term_id == term_id)

        rows = (
            db.query(
                DBEntry.kind,
                func.coalesce(func.sum(DBEntry.amount), 0),
            )
            .filter(*base_filter)
            .group_by(DBEntry.kind)
            .all()
        )
        totals = {str(kind): int(total) for kind, total in rows}
    except SQLAlchemyError as e:
        logger.exception("장부 잔액 요약 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    income = totals.get("INCOME", 0)
    expense = totals.get("EXPENSE", 0)
    return BalanceResponse(
        balance=income - expense,
        income=income,
        expense=expense,
    )
