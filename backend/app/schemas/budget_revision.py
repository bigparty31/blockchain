from datetime import datetime
from typing import Optional
from pydantic import BaseModel, Field, ConfigDict


class BudgetRevisionRequestCreate(BaseModel):
    term_id: int = Field(..., description="학기 ID")
    category: str = Field(..., description="예산 카테고리 (운영비, 행사비, 사업비 등)")
    requested_amount: int = Field(..., gt=0, description="증액 요청액 (원 단위 증액분, > 0)")
    reason: str = Field(..., min_length=1, description="증액 요청 사유")
    budget_id: Optional[int] = Field(None, description="기존 예산 ID (미지정 시 term_id+category로 자동 매핑)")
    blocked_entry_id: Optional[int] = Field(None, description="근거가 된 차단 지출 ID (BLOCKED 상태)")


class BudgetRevisionSignRequest(BaseModel):
    president_signature: str = Field(..., max_length=132, description="회장의 EIP-712 IncreaseRequest 서명값 (0x...)")
    signature_deadline: int = Field(..., gt=0, description="서명 만료 시한 (Unix Timestamp)")
    signed_version: int = Field(..., ge=1, description="서명 당시 예산 버전")


class BudgetRevisionRejectRequest(BaseModel):
    reject_reason: str = Field(..., min_length=1, max_length=500, description="반려 사유")


class BudgetRevisionApproveRequest(BaseModel):
    auditor_signature: Optional[str] = Field(None, max_length=132, description="감사의 EIP-712 서명값 (0x...)")


class BudgetRevisionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int = Field(..., description="증액 요청 ID")
    term_id: int = Field(..., description="학기 ID")
    category: str = Field(..., description="예산 카테고리")
    budget_id: Optional[int] = Field(None, description="대상 예산 ID")
    blocked_entry_id: Optional[int] = Field(None, description="연계된 차단 지출 ID")
    requested_amount: int = Field(..., description="증액 요청액 (증액분)")
    reason: str = Field(..., description="증액 사유")
    requested_by: int = Field(..., description="요청 총무 User ID")
    requested_at: datetime = Field(..., description="요청 일시")
    status: str = Field(..., description="요청 상태 (PENDING, PRESIDENT_SIGNED, APPROVED, REJECTED)")
    president_signed_by: Optional[int] = Field(None, description="서명 회장 User ID")
    president_signature: Optional[str] = Field(None, description="회장 EIP-712 서명값 (0x...)")
    president_signed_at: Optional[datetime] = Field(None, description="회장 서명 일시")
    signature_deadline: Optional[int] = Field(None, description="회장 서명 시한 (Unix timestamp)")
    signed_version: Optional[int] = Field(None, description="서명 당시 예산 버전")
    tx_increase: Optional[str] = Field(None, description="온체인 증액 트랜잭션 해시")
    resolved_by: Optional[int] = Field(None, description="최종 처리자 (감사) User ID")
    resolved_at: Optional[datetime] = Field(None, description="최종 처리 일시")
    reject_reason: Optional[str] = Field(None, description="반려 사유")
    created_at: datetime = Field(..., description="생성 일시")
