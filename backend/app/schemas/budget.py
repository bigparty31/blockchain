from typing import Optional
from pydantic import BaseModel, Field, ConfigDict, field_validator

from app.utils.hashing import canonical, validate_text_for_hash

CATEGORY_MAX_LENGTH = 50


class BudgetCreate(BaseModel):
    term_id: int = Field(1, description="학기 ID")
    category: str = Field(..., min_length=1, max_length=CATEGORY_MAX_LENGTH, description="예산 카테고리 (최대 50자)")
    planned_amount: int = Field(..., gt=0, description="최초 편성 예산액 (원 단위 양의 정수)")
    expires_at: int = Field(..., gt=0, description="예산 만료 시점 (Unix Timestamp)")

    @field_validator("category", mode="before")
    @classmethod
    def _normalize_category_before_length(cls, v):
        if isinstance(v, str):
            return canonical(v)
        return v

    @field_validator("category", mode="after")
    @classmethod
    def _reject_disallowed_chars(cls, v: str) -> str:
        validate_text_for_hash(v, "category")
        return v


class BudgetResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int = Field(..., description="예산 고유 ID (BudgetToken ID)")
    term_id: int = Field(..., description="학기 ID")
    category: str = Field(..., max_length=CATEGORY_MAX_LENGTH, description="예산 카테고리 (행사비, 사업비, 운영비 등)")
    planned_amount: int = Field(..., description="총 편성 예산액 (원 단위)")
    remaining_amount: int = Field(..., description="현재 집행 가능한 잔여 예산 (원 단위)")
    execution_rate: float = Field(..., description="집행률 ((편성액 - 잔량) / 편성액)")
    version: int = Field(1, description="예산 버전 (개정 시 1씩 증가)")
    expires_at: int = Field(..., description="예산 만료 시점 (Unix Timestamp)")
    revision_reason: Optional[str] = Field(None, description="예산 개정 사유")
