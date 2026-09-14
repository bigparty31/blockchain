from typing import List
from fastapi import APIRouter, status
from app.schemas.entry import (
    EntryResponse,
    EntryCreate,
    EntryCreateResponse,
    EntryKind,
    EntryStatus,
    OCRStatus,
)

router = APIRouter(prefix="/entries", tags=["Entries"])

# PRD §8 규격에 맞춘 초기 목업 더미 데이터 3건
DUMMY_ENTRIES: List[EntryResponse] = [
    EntryResponse(
        id=1,
        term_id=1,
        kind=EntryKind.EXPENSE,
        amount=35000,
        counterparty="한결문구",
        purpose="신입생 환영회 명찰 및 필기구 구매",
        budget_id=2,
        occurred_at=1757300000,
        receipt_path="/receipts/sample_01.jpg",
        receipt_hash="0xabc1234567890abcdef1234567890abcdef1234567890abcdef1234567890abc",
        meta_hash="0x456def1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        ocr_amount=35000,
        ocr_approval_no="12345678",
        ocr_paid_at=1757300000,
        ocr_status=OCRStatus.MATCH,
        category_warning=False,
        warning_ack_reason=None,
        status=EntryStatus.CONFIRMED,
        created_by=2,
        approved_by=3,
        reject_reason=None,
        tx_pending="0x1111111111111111111111111111111111111111111111111111111111111111",
        tx_confirm="0x2222222222222222222222222222222222222222222222222222222222222222",
        corrects_entry_id=None,
        correction_reason=None,
    ),
    EntryResponse(
        id=2,
        term_id=1,
        kind=EntryKind.EXPENSE,
        amount=120000,
        counterparty="청년피자",
        purpose="개강총회 다과 주문",
        budget_id=1,
        occurred_at=1757386400,
        receipt_path="/receipts/sample_02.jpg",
        receipt_hash="0xdef4567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
        meta_hash="0x789abc1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        ocr_amount=120000,
        ocr_approval_no="87654321",
        ocr_paid_at=1757386400,
        ocr_status=OCRStatus.MATCH,
        category_warning=False,
        warning_ack_reason=None,
        status=EntryStatus.PENDING,
        created_by=2,
        approved_by=None,
        reject_reason=None,
        tx_pending="0x3333333333333333333333333333333333333333333333333333333333333333",
        tx_confirm=None,
        corrects_entry_id=None,
        correction_reason=None,
    ),
    EntryResponse(
        id=3,
        term_id=1,
        kind=EntryKind.INCOME,
        amount=5000000,
        counterparty="컴퓨터공학과 학생회비 일괄 납부",
        purpose="2026-2학기 학과 학생회비 수납",
        budget_id=None,
        occurred_at=1757100000,
        receipt_path=None,
        receipt_hash=None,
        meta_hash="0x9990001234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        ocr_amount=None,
        ocr_approval_no=None,
        ocr_paid_at=None,
        ocr_status=None,
        category_warning=False,
        warning_ack_reason=None,
        status=EntryStatus.CONFIRMED,
        created_by=2,
        approved_by=3,
        reject_reason=None,
        tx_pending="0x4444444444444444444444444444444444444444444444444444444444444444",
        tx_confirm="0x5555555555555555555555555555555555555555555555555555555555555555",
        corrects_entry_id=None,
        correction_reason=None,
    ),
]


@router.get("", response_model=List[EntryResponse], summary="수입·지출 내역 목록 조회")
@router.get("/", response_model=List[EntryResponse], include_in_schema=False)
async def get_entries():
    """모바일 앱 '내역 목록' 및 '대시보드'에서 호출하는 수입·지출 내역 목록 API입니다.
    초기에는 목업 더미 데이터 3건이 제공되며, POST로 등록된 신규 내역도 메모리에 누적 반영됩니다.
    """
    return DUMMY_ENTRIES


@router.post(
    "",
    response_model=EntryCreateResponse,
    status_code=status.HTTP_201_CREATED,
    summary="수입·지출 내역 신규 등록 (PENDING 생성)",
)
@router.post(
    "/",
    response_model=EntryCreateResponse,
    status_code=status.HTTP_201_CREATED,
    include_in_schema=False,
)
async def create_entry(entry: EntryCreate):
    """임원(총무/회장)이 모바일 앱에서 영수증과 지출 내역을 입력 후 등록할 때 호출하는 API입니다.
    등록 직후에는 PENDING 상태가 되며, 앱 화면 테스트를 위해 인메모리 목록에도 자동 추가됩니다.
    """
    new_id = max([e.id for e in DUMMY_ENTRIES], default=0) + 1
    new_entry = EntryResponse(
        id=new_id,
        term_id=entry.term_id,
        kind=entry.kind,
        amount=entry.amount,
        counterparty=entry.counterparty,
        purpose=entry.purpose,
        budget_id=entry.budget_id,
        occurred_at=entry.occurred_at,
        receipt_path=None,
        receipt_hash=entry.receipt_hash,
        meta_hash=f"0x{new_id:064x}",
        ocr_amount=None,
        ocr_approval_no=None,
        ocr_paid_at=None,
        ocr_status=None,
        category_warning=False,
        warning_ack_reason=None,
        status=EntryStatus.PENDING,
        created_by=2,
        approved_by=None,
        reject_reason=None,
        tx_pending=f"0x{new_id:064x}",
        tx_confirm=None,
        corrects_entry_id=entry.corrects_entry_id,
        correction_reason=entry.correction_reason,
    )
    DUMMY_ENTRIES.append(new_entry)

    return EntryCreateResponse(
        id=new_id,
        status=EntryStatus.PENDING,
        message="지출/수입 내역이 성공적으로 PENDING 상태로 등록되었습니다.",
    )

