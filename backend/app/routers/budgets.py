from typing import List
from fastapi import APIRouter
from app.schemas.budget import BudgetResponse

router = APIRouter(prefix="/budgets", tags=["Budgets"])

DUMMY_BUDGETS: List[BudgetResponse] = [
    BudgetResponse(
        id=1,
        term_id=1,
        category="행사비",
        planned_amount=2500000,
        remaining_amount=2380000,
        execution_rate=0.048,
        version=1,
        expires_at=1767196799,
        revision_reason=None,
    ),
    BudgetResponse(
        id=2,
        term_id=1,
        category="사업비",
        planned_amount=1500000,
        remaining_amount=1465000,
        execution_rate=0.023,
        version=1,
        expires_at=1767196799,
        revision_reason=None,
    ),
    BudgetResponse(
        id=3,
        term_id=1,
        category="운영비",
        planned_amount=1000000,
        remaining_amount=1000000,
        execution_rate=0.0,
        version=1,
        expires_at=1767196799,
        revision_reason=None,
    ),
]


@router.get("", response_model=List[BudgetResponse], summary="항목별 예산 편성액 및 잔량 조회")
@router.get("/", response_model=List[BudgetResponse], include_in_schema=False)
async def get_budgets():
    """모바일 앱 '예산 현황' 및 집행률 그래프 화면에서 호출하는 카테고리별 예산 현황 API입니다.
    스마트 컨트랙트 BudgetToken의 조건부 예산 잔량 및 집행률 정보를 제공합니다.
    """
    return DUMMY_BUDGETS

