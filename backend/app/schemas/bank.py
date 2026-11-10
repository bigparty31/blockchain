"""계좌 대조 API 스키마 — PRD v0.15 §4.6, docs/BANK_CSV.md."""
from datetime import datetime
from enum import Enum
from typing import List, Optional

from pydantic import BaseModel, Field


class BankUploadRequest(BaseModel):
    term_id: int = Field(..., gt=0, description="학기 ID")
    # python-multipart 가 requirements 에 없어 OCR 과 같이 JSON + base64 로 받는다
    file_base64: str = Field(..., description="은행에서 받은 CSV 원본 바이트의 base64")
    file_hash: Optional[str] = Field(
        None,
        pattern=r"^0x[0-9a-f]{64}$",
        description="앱이 계산한 원본 바이트 SHA-256 (소문자 hex, 0x 포함). 주면 서버 재계산과 대조한다 (HASHING.md §4)",
    )


class RowStatus(str, Enum):
    MATCHED = "MATCHED"                  # 확정 원장 항목과 짝
    MATCHED_PENDING = "MATCHED_PENDING"  # 승인 대기 항목과 짝 — 확정 전이라 판단 보류
    UNREGISTERED = "UNREGISTERED"        # 계좌에는 있는데 원장에 없음 (미등록 의심)


class BankRowResult(BaseModel):
    id: int
    tran_date: str
    tran_time: Optional[str]
    description: str
    direction: str
    amount: int
    balance_after: int
    status: Optional[RowStatus] = Field(None, description="이후 업로드로 대체된 스냅샷이면 null")
    entry_id: Optional[int] = Field(None, description="짝이 된 원장 항목 ID")


class UnbackedEntry(BaseModel):
    """원장에는 확정돼 있는데 이 거래내역(기간 안)에 대응 거래가 없음 — 가짜 등록 의심."""

    entry_id: int
    kind: str
    amount: int = Field(..., description="정정을 반영한 순금액")
    date: str
    counterparty: str
    purpose: str


class ReconcileSummary(BaseModel):
    total: int
    matched: int
    matched_pending: int
    unregistered: int
    unregistered_out_amount: int = Field(..., description="미등록 출금 합계 — 장부에 없이 나간 돈")
    unregistered_in_amount: int
    unbacked: int


class ReconciliationReport(BaseModel):
    snapshot_id: int
    term_id: int
    file_hash: Optional[str]
    bank_balance: int = Field(..., description="거래내역 마지막 거래의 거래후잔액")
    snapshot_at: datetime
    period_start: str
    period_end: str
    superseded: bool = Field(..., description="같은 학기에 더 최근 업로드가 있음. 대조 결과는 최신 스냅샷에서 본다")
    summary: Optional[ReconcileSummary]
    transactions: List[BankRowResult]
    unbacked_entries: List[UnbackedEntry]


class SnapshotItem(BaseModel):
    id: int
    term_id: int
    file_hash: Optional[str]
    bank_balance: int
    snapshot_at: datetime
    uploaded_by: Optional[int]
    superseded: bool
