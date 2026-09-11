from enum import Enum
from typing import Optional
from pydantic import BaseModel, Field, ConfigDict


class EntryKind(str, Enum):
    INCOME = "INCOME"
    EXPENSE = "EXPENSE"


class EntryStatus(str, Enum):
    PENDING = "PENDING"
    CONFIRMED = "CONFIRMED"
    REJECTED = "REJECTED"
    BLOCKED = "BLOCKED"


class OCRStatus(str, Enum):
    MATCH = "MATCH"
    MISMATCH = "MISMATCH"
    DUPLICATE = "DUPLICATE"
    NO_NUMBER = "NO_NUMBER"
    UNREADABLE = "UNREADABLE"


class CorrectionReason(str, Enum):
    INPUT_ERROR = "INPUT_ERROR"
    RECEIPT_RECHECK = "RECEIPT_RECHECK"
    REFUND = "REFUND"
    RECLASSIFY = "RECLASSIFY"


class EntryResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int = Field(..., description="내역 고유 ID")
    term_id: int = Field(..., description="학기 ID")
    kind: EntryKind = Field(..., description="수입/지출 구분 (INCOME | EXPENSE)")
    amount: int = Field(..., description="금액 (원 단위, int256 호환 정수)")
    counterparty: str = Field(..., description="거래처 또는 납부자")
    purpose: str = Field(..., description="지출 목적 또는 수입 사유")
    budget_id: Optional[int] = Field(None, description="연관 예산 항목 ID (지출 시 필수, 수입 시 null)")
    occurred_at: int = Field(..., description="거래 발생 일시 (Unix Timestamp 초 단위)")
    receipt_path: Optional[str] = Field(None, description="영수증 이미지 파일 저장 경로")
    receipt_hash: Optional[str] = Field(None, description="영수증 원본 SHA-256 해시 (0x...)")
    meta_hash: str = Field(..., description="메타데이터 조합 SHA-256 해시")
    ocr_amount: Optional[int] = Field(None, description="OCR 인식 금액")
    ocr_approval_no: Optional[str] = Field(None, description="영수증 카드 승인번호")
    ocr_paid_at: Optional[int] = Field(None, description="OCR 인식 결제 일시")
    ocr_status: Optional[OCRStatus] = Field(None, description="OCR 대조 상태")
    category_warning: bool = Field(False, description="예산 카테고리 불일치 경고 여부")
    warning_ack_reason: Optional[str] = Field(None, description="경고 무시 승인 사유")
    status: EntryStatus = Field(..., description="장부 상태 (PENDING | CONFIRMED | REJECTED | BLOCKED)")
    created_by: int = Field(..., description="등록자 User ID (총무/회장)")
    approved_by: Optional[int] = Field(None, description="승인자 User ID (감사)")
    reject_reason: Optional[str] = Field(None, description="반려 사유")
    tx_pending: Optional[str] = Field(None, description="Pending 등록 트랜잭션 해시")
    tx_confirm: Optional[str] = Field(None, description="Confirmed 승인 트랜잭션 해시")
    corrects_entry_id: Optional[int] = Field(None, description="정정 대상 원본 Entry ID")
    correction_reason: Optional[CorrectionReason] = Field(None, description="정정 사유 유형")


class EntryCreate(BaseModel):
    term_id: int = Field(1, description="학기 ID")
    kind: EntryKind = Field(EntryKind.EXPENSE, description="수입/지출 구분")
    amount: int = Field(..., description="금액 (원 단위, 정수)")
    counterparty: str = Field(..., description="거래처 (상호명)")
    purpose: str = Field(..., description="사용 목적")
    budget_id: Optional[int] = Field(None, description="배정 예산 ID")
    occurred_at: int = Field(..., description="거래 일시 (Unix Timestamp)")
    receipt_hash: Optional[str] = Field(None, description="영수증 SHA-256 해시")
    corrects_entry_id: Optional[int] = Field(None, description="정정 등록 시 대상 Entry ID")
    correction_reason: Optional[CorrectionReason] = Field(None, description="정정 사유")


class EntryCreateResponse(BaseModel):
    id: int = Field(..., description="생성된 Entry ID")
    status: EntryStatus = Field(EntryStatus.PENDING, description="초기 상태 (PENDING)")
    message: str = Field("지출/수입 내역이 성공적으로 PENDING 상태로 등록되었습니다.")
