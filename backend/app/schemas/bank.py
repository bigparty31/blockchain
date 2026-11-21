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


# ---------------------------------------------------------------- 학생 화면 S11 (GET /snapshots/latest)


class UnrecordedTransaction(BaseModel):
    """계좌에서 나갔는데 원장에 없는 거래 한 건. 학생에게는 금액·거래처·일시만 보인다 (거래 원문·잔액은 뺀다)."""

    amount: int = Field(..., description="출금액 (원, 양수)")
    counterparty: str = Field(..., description="은행 거래내역의 적요(거래처)")
    occurred_at: int = Field(..., description="거래 일시 (Unix 초, KST 로 읽은 거래일·시각)")


class StudentSnapshot(BaseModel):
    """학생 홈 계좌 대조 카드 (docs/backend_requests.md §1-5). 앱이 파싱하는 키 그대로다 — 이름을 바꾸면 못 읽는다.

    학생 화면에 필요 없는 file_hash·uploaded_by·거래 원문과 반대 방향 대조(unbacked_entries)는 싣지 않는다.
    """

    id: int = Field(..., description="스냅샷 ID")
    term_id: int
    bank_balance: int = Field(..., description="거래내역 마지막 거래의 거래후잔액")
    snapshot_at: int = Field(..., description="스냅샷 일시 (Unix 초)")
    tx_hash: Optional[str] = Field(None, description="온체인 기록 TX 해시 (아직 컨트랙트가 없어 null)")
    unrecorded: List[UnrecordedTransaction]


# ---------------------------------------------------------------- 카드 승인 문자 (저장하지 않는 확인)


class CardSmsCheckRequest(BaseModel):
    term_id: int = Field(..., gt=0, description="학기 ID")
    text: str = Field(..., min_length=1, max_length=20000, description="붙여넣은 카드 승인·취소 문자 (여러 건 가능)")


class SmsStatus(str, Enum):
    MATCHED = "MATCHED"
    MATCHED_PENDING = "MATCHED_PENDING"
    UNREGISTERED = "UNREGISTERED"      # 카드로 결제됐는데 장부에 없음
    CANCELLED_PAIR = "CANCELLED_PAIR"  # 같은 붙여넣기 안의 승인·취소가 서로 상쇄 — 대조에서 뺌
    OUT_OF_TERM = "OUT_OF_TERM"        # 날짜가 학기 기간 밖
    UNREADABLE = "UNREADABLE"          # 형식을 읽지 못함


class CardSmsItem(BaseModel):
    msg_no: int = Field(..., description="붙여넣은 순서 (1부터)")
    status: SmsStatus
    company: Optional[str] = None
    kind: Optional[str] = Field(None, description="APPROVAL | CANCEL")
    tran_date: Optional[str] = None
    tran_time: Optional[str] = None
    merchant: Optional[str] = None
    amount: Optional[int] = None
    approval_no: Optional[str] = None
    entry_id: Optional[int] = None
    reason: Optional[str] = Field(None, description="UNREADABLE 일 때 이유")


class CardSmsSummary(BaseModel):
    total: int
    matched: int
    matched_pending: int
    unregistered: int
    unregistered_amount: int = Field(..., description="미등록 승인 합계 — 카드로 나갔는데 장부에 없는 돈")
    unreadable: int


class CardSmsCheckResponse(BaseModel):
    term_id: int
    text_hash: str = Field(..., description="붙여넣은 원문(UTF-8 바이트) SHA-256. 저장하지 않으므로 앱이 보관한다")
    summary: CardSmsSummary
    items: List[CardSmsItem]
