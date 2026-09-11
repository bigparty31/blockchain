from pydantic import BaseModel, Field, ConfigDict


class BalanceResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    balance: int = Field(..., description="현재 장부 잔액 (원 단위, income - expense)")
    income: int = Field(..., description="총 확정 수입 합계 (원 단위)")
    expense: int = Field(..., description="총 확정 지출 합계 (원 단위)")
