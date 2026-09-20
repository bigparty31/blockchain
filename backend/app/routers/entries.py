from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, status
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
from app.utils.hashing import (
    validate_canonical_input,
    canonical,
    calculate_meta_hash,
)
from app.chain.services import RegistrationRelay, get_registration_relay
from app.chain.models import ChainRevert, ChainUnavailable

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
    체인에 기록된 건(status is not None)만 반환하며, 기기 서명 미제출 초안은 제외됩니다.
    """
    return [e for e in DUMMY_ENTRIES if e.status is not None]


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
    # 1차 입력값 검증 (금지 제어문자 및 보이지 않는 공백 차단)
    try:
        validate_canonical_input(entry.counterparty)
        validate_canonical_input(entry.purpose)
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"입력값 검증 실패: {e}",
        )

    # occurred_at KST 자정 검사
    if entry.occurred_at % 86400 != 54000:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="occurred_at은 사용일의 KST 자정(Unix 초 % 86400 == 54000)이어야 합니다 (docs/HASHING.md §1.3).",
        )

    # 금액 규칙 (정정이 아닌 경우 양수)
    if not entry.corrects_entry_id and entry.amount <= 0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="정정 항목이 아닌 경우 금액은 0보다 커야 합니다.",
        )

    canonical_counterparty = canonical(entry.counterparty)
    canonical_purpose = canonical(entry.purpose)

    # 영수증 중복 검사 (기존 체인 등록 건 및 열려 있는 초안 모두 포함)
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

    computed_meta_hash = calculate_meta_hash(
        amount=entry.amount,
        counterparty=canonical_counterparty,
        purpose=canonical_purpose,
        occurred_at=entry.occurred_at,
        receipt_hash=entry.receipt_hash,
    )

    new_id = max([e.id for e in DUMMY_ENTRIES], default=0) + 1
    new_entry = EntryResponse(
        id=new_id,
        term_id=entry.term_id,
        kind=entry.kind,
        amount=entry.amount,
        counterparty=canonical_counterparty,
        purpose=canonical_purpose,
        budget_id=entry.budget_id,
        occurred_at=entry.occurred_at,
        receipt_path=entry.receipt_path,
        receipt_hash=entry.receipt_hash,
        meta_hash=computed_meta_hash,
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
    summary="초안 기기 서명 제출 및 온체인 등록 (2단계)",
)
@router.post(
    "/drafts/{id}/submit",
    response_model=EntrySubmitResponse,
    include_in_schema=False,
)
async def submit_entry(
    id: int,
    req: EntrySubmitRequest,
    relay: RegistrationRelay = Depends(get_registration_relay),
):
    """1단계에서 발급받은 초안 id에 대해 모바일 기기 서명을 제출하여 블록체인에 등록합니다.
    RegistrationRelay(FakeChainClient)를 통해 온체인 트랜잭션을 릴레이합니다.
    """
    target = next((e for e in DUMMY_ENTRIES if e.id == id), None)
    if not target:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"ID {id}에 해당하는 초안 내역을 찾을 수 없습니다.",
        )

    if target.status is not None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"ID {id} 항목은 이미 처리 완료(status={target.status.value})된 내역입니다.",
        )

    try:
        tx_res = await relay.submit_record(target, signature=req.signature, deadline=req.deadline)
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"서명 또는 요청 규격 오류: {e}",
        )
    except ChainRevert as e:
        # docs/CHAIN_CLIENT.md §4: ChainRevert 시 온체인에 상태가 남지 않으므로 DB의 status는 NULL 그대로 둔다
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"체인 트랜잭션 Revert ({e.reason.value}): {e.detail or e.reason.value}",
        )
    except ChainUnavailable as e:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"블록체인 노드 일시적 응답 불가: {e}",
        )

    target.status = tx_res.status
    target.tx_pending = tx_res.tx_hash
    if tx_res.block_reason:
        target.reject_reason = tx_res.block_reason.value

    message = "온체인에 성공적으로 기록되어 감사 승인 대기(PENDING) 상태가 되었습니다."
    if tx_res.status == EntryStatus.BLOCKED:
        message = "해당 예산 카테고리의 잔량 부족 등으로 지출 등록이 차단(BLOCKED)되었습니다."

    return EntrySubmitResponse(
        id=id,
        status=tx_res.status,
        tx_pending=tx_res.tx_hash,
        block_reason=tx_res.block_reason,
        message=message,
    )


@router.delete(
    "/{id}",
    summary="초안 폐기",
)
@router.delete(
    "/drafts/{id}",
    include_in_schema=False,
)
async def delete_draft(id: int):
    """서명 제출 전인 미완성 초안(status IS NULL)을 폐기합니다.
    이미 온체인에 제출된 항목은 삭제할 수 없습니다.
    """
    target = next((e for e in DUMMY_ENTRIES if e.id == id), None)
    if not target:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"ID {id}에 해당하는 초안 내역을 찾을 수 없습니다.",
        )

    if target.status is not None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="이미 온체인에 기록된 내역은 삭제할 수 없습니다.",
        )

    DUMMY_ENTRIES.remove(target)
    return {"id": id, "message": "초안이 성공적으로 폐기되었습니다."}
