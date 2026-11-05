from typing import Optional
from pydantic import BaseModel, Field, ConfigDict

UINT64_MAX = (1 << 64) - 1
UINT256_MAX = (1 << 256) - 1
MAX_AMOUNT = 10**15
# Python datetime.fromtimestamp 상한 (9999-12-31 23:59:59 UTC)
MAX_UNIX_SECONDS = 253_402_300_799


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


class BudgetIssueCreate(BaseModel):
    """예산 최초 편성 1단계 초안 ID 발급 요청 스키마"""

    term_id: int = Field(..., ge=1, description="학기 ID (terms.id)")
    category: str = Field(..., min_length=1, max_length=50, description="예산 지출 항목명 (docs/CONTRACTS.md EXPENSE 8종)")
    planned_amount: int = Field(..., gt=0, le=MAX_AMOUNT, description="최초 편성 금액 (원 단위 양의 정수)")
    expires_at: int = Field(..., ge=0, le=MAX_UNIX_SECONDS, description="예산 집행 유효 만료 시각 (Unix 초)")


class BudgetIssueSubmit(BaseModel):
    """1단계로 채번된 예산 ID에 대한 회장 기기 서명 제출 스키마"""

    planned_amount: int = Field(..., gt=0, le=MAX_AMOUNT, description="최초 편성 금액 (원 단위 양의 정수)")
    expires_at: Optional[int] = Field(None, ge=0, le=MAX_UNIX_SECONDS, description="예산 만료 시각 Unix 초 (미지정 시 저장된 만료일 사용)")
    deadline: int = Field(..., ge=0, le=UINT256_MAX, description="EIP-712 IssueRequest 서명 유효 시한 (Unix 초)")
    signature: str = Field(..., description="회장의 EIP-712 IssueRequest 서명값 (0x + 130자리 hex)")


class BudgetIssueResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int = Field(..., description="예산 고유 ID (BudgetToken budgetId)")
    term_id: int = Field(..., description="학기 ID (terms.id)")
    term_code: int = Field(..., description="온체인 학기 코드 (YYYYS)")
    category: str = Field(..., description="예산 항목명")
    category_hash: str = Field(..., description="온체인 항목 해시 (keccak256(utf8(category)))")
    planned_amount: int = Field(..., description="편성 예산액 (원 단위)")
    expires_at: int = Field(..., description="예산 만료 시각 (Unix 초)")
    version: int = Field(1, description="온체인 예산 버전")
    status: str = Field(..., description="DRAFT | ISSUED | ALREADY_ISSUED | REJECTED | NO_RESPONSE")
    issue_status: Optional[str] = Field(
        None,
        description="앱 BudgetIssueStatus 매핑 (issued | alreadyIssued | rejected | noResponse)",
    )
    tx_hash: Optional[str] = Field(None, description="발행 트랜잭션 해시")
    reason: Optional[str] = Field(None, description="거부 또는 이미 발행 판정 시 체인 사유")
    existing_id: Optional[int] = Field(None, description="ALREADY_ISSUED 시 온체인에 등록된 실제 budgetId")
    message: Optional[str] = Field(None, description="결과 안내 메시지")
