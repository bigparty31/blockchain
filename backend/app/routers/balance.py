from fastapi import APIRouter
from app.schemas.balance import BalanceResponse

router = APIRouter(prefix="/balance", tags=["Balance"])


@router.get("", response_model=BalanceResponse, summary="장부 잔액 요약 조회")
@router.get("/", response_model=BalanceResponse, include_in_schema=False)
async def get_balance():
    """모바일 앱 메인 대시보드 상단에 표시되는 계좌/장부 잔액 및 총 수입·지출 합계 조회 API입니다.
    PRD §7.4 산출식 (장부잔액 = 확정수입 - 확정지출)을 따릅니다.
    """
    return BalanceResponse(
        balance=4965000,
        income=5000000,
        expense=35000,
    )

