from typing import List, Optional
from fastapi import APIRouter, HTTPException, status
from app.schemas.entry import (
    EntryResponse,
    EntryCreate,
    EntryCreateResponse,
    EntrySubmitRequest,
    EntrySubmitResponse,
    EntryKind,
    EntryStatus,
    OCRStatus,
    BlockReason,
)

router = APIRouter(prefix="/entries", tags=["Entries"])

# PRD §8 및 docs/HASHING.md 규격에 맞춘 초기 목업 더미 데이터 3건 (KST 자정 타임스탬프 준수)
DUMMY_ENTRIES: List[EntryResponse] = [
    EntryResponse(
        id=1,
        term_id=1,
        kind=EntryKind.EXPENSE,
        amount=35000,
        counterparty="한결문구",
        purpose="신입생 환영회 명찰 및 필기구 구매",
        budget_id=2,
        occurred_at=1788793200,  # 2026-09-08 00:00:00 KST (% 86400 == 54000)
        receipt_path="/receipts/sample_01.jpg",
        receipt_hash="0xabc1234567890abcdef1234567890abcdef1234567890abcdef1234567890abc",
        meta_hash="0x24ae73988d927fb39f45eb6024e9ff8ffa19e8501603565bd82710ea8df4b937",
        ocr_amount=35000,
        ocr_approval_no="12345678",
        ocr_paid_at=1788825820,  # 2026-09-08 09:03:40 KST (실제 결제 시각)
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
        occurred_at=1788706800,  # 2026-09-07 00:00:00 KST (% 86400 == 54000)
        receipt_path="/receipts/sample_02.jpg",
        receipt_hash="0xdef4567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
        meta_hash="0x622fc1b357c04032e65bc1855c73aaff6d519464d69bf22b10761f3b26a1b793",
        ocr_amount=120000,
        ocr_approval_no="87654321",
        ocr_paid_at=1788775450,  # 2026-09-07 19:04:10 KST (실제 결제 시각)
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
        occurred_at=1788620400,  # 2026-09-06 00:00:00 KST (% 86400 == 54000)
        receipt_path=None,
        receipt_hash=None,
        meta_hash="0x74c9740556d857575586251e71fa24091ffaece5c01c4f889d7c1224ce7af3a9",
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
    온체인 트랜잭션이 발행된 건(tx_pending is not None)만 반환하며, 기기 서명 미제출 초안은 제외됩니다.
    """
    return [e for e in DUMMY_ENTRIES if e.tx_pending is not None]


@router.post(
    "",
    response_model=EntryCreateResponse,
    status_code=status.HTTP_201_CREATED,
    summary="수입·지출 초안 등록 (1단계)",
)
@router.post(
    "/",
    response_model=EntryCreateResponse,
    status_code=status.HTTP_201_CREATED,
    include_in_schema=False,
)
@router.post(
    "/drafts",
    response_model=EntryCreateResponse,
    status_code=status.HTTP_201_CREATED,
    include_in_schema=False,
)
async def create_entry(entry: EntryCreate):
    """임원(총무/회장)이 모바일 앱에서 영수증과 지출 내역을 입력 후 초안을 등록할 때 호출하는 API입니다.
    1단계에서는 온체인 트랜잭션 없이 고유 ID만 발급되며, 2단계 submit 호출을 통해 기기 서명 검증 후 온체인에 기록됩니다.
    """
    # 영수증 중복 검사
    if entry.ocr_approval_no and entry.ocr_paid_at:
        for existing in DUMMY_ENTRIES:
            if (
                existing.ocr_approval_no == entry.ocr_approval_no
                and existing.ocr_paid_at == entry.ocr_paid_at
                and existing.amount == entry.amount
            ):
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=f"이미 등록된 영수증입니다 (내역 ID: {existing.id}, 승인번호: {entry.ocr_approval_no}).",
                )

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
        receipt_path=entry.receipt_path,
        receipt_hash=entry.receipt_hash,
        meta_hash=f"0x{new_id:064x}",
        ocr_amount=entry.ocr_amount,
        ocr_approval_no=entry.ocr_approval_no,
        ocr_paid_at=entry.ocr_paid_at,
        ocr_status=entry.ocr_status,
        category_warning=False,
        warning_ack_reason=None,
        status=None,  # 초안은 status=None (온체인 미등록)
        created_by=2,
        approved_by=None,
        reject_reason=None,
        tx_pending=None,  # 초안은 tx_pending=None
        tx_confirm=None,
        corrects_entry_id=entry.corrects_entry_id,
        correction_reason=entry.correction_reason,
    )
    DUMMY_ENTRIES.append(new_entry)

    return EntryCreateResponse(
        id=new_id,
        message="지출/수입 초안이 등록되었으며, 기기 서명 제출 대기 상태입니다.",
    )


@router.post(
    "/{id}/submit",
    response_model=EntrySubmitResponse,
    summary="초안 기기 서명 제출 및 온체인 등록 (2단계 목업)",
)
@router.post(
    "/drafts/{id}/submit",
    response_model=EntrySubmitResponse,
    include_in_schema=False,
)
async def submit_entry(id: int, req: EntrySubmitRequest):
    """1단계에서 발급받은 초안 id에 대해 모바일 기기 서명을 제출하여 블록체인에 등록합니다.
    현재는 목업 수준으로 고정값을 반환하며, 다음 주에 손종인 ChainClient 실구현으로 교체될 자리입니다.
    """
    target = next((e for e in DUMMY_ENTRIES if e.id == id), None)
    if not target:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"ID {id}에 해당하는 초안 내역을 찾을 수 없습니다.",
        )

    # 예산 초과(BLOCKED) 케이스 시뮬레이션: budget_id가 999이거나 금액이 10,000,000 이상인 경우
    if target.budget_id == 999 or target.amount >= 10_000_000:
        target.status = EntryStatus.BLOCKED
        target.tx_pending = None
        return EntrySubmitResponse(
            id=id,
            status=EntryStatus.BLOCKED,
            tx_pending=None,
            block_reason=BlockReason.BUDGET_EXCEEDED,
            message="해당 예산 카테고리의 잔량이 부족하여 지출 등록이 차단(BLOCKED)되었습니다.",
        )

    # 정상 PENDING 등록 시뮬레이션
    target.status = EntryStatus.PENDING
    target.tx_pending = f"0x{id:064x}"

    return EntrySubmitResponse(
        id=id,
        status=EntryStatus.PENDING,
        tx_pending=target.tx_pending,
        block_reason=None,
        message="온체인에 성공적으로 기록되어 감사 승인 대기(PENDING) 상태가 되었습니다.",
    )
