from typing import Optional
from pydantic import BaseModel, Field, ConfigDict


class BudgetResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int = Field(..., description="예산 고유 ID (BudgetToken ID)")
    term_id: int = Field(..., description="학기 ID")
    category: str = Field(..., description="예산 카테고리 (행사비, 사업비, 운영비 등)")
    planned_amount: int = Field(..., description="총 편성 예산액 (원 단위)")
    remaining_amount: int = Field(..., description="현재 집행 가능한 잔여 예산 (원 단위)")
    execution_rate: float = Field(..., description="집행률 ((편성액 - 잔량) / 편성액)")
    version: int = Field(1, description="예산 버전 (개정 시 1씩 증가)")
    expires_at: int = Field(..., description="예산 만료 시점 (Unix Timestamp)")
    revision_reason: Optional[str] = Field(None, description="예산 개정 사유")
