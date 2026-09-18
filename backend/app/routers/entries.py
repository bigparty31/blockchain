import os
from typing import List, Optional, Dict
from fastapi import APIRouter, HTTPException, status
from app.schemas.entry import (
    EntryResponse,
    EntryCreate,
    EntryCreateResponse,
    DraftSubmitRequest,
    DraftSubmitResponse,
    SignPayload,
    Eip712Domain,
    SignMessage,
    EntryKind,
    EntryStatus,
    OCRStatus,
)
from app.hashing import prepare_field, meta_hash
from app.chain.factory import create_chain_services
from app.chain.models import Role
from app.relay.registration import RegistrationRelay
from app.relay.store import InMemoryDraftStore
from app.relay.models import DraftStatus, OPEN_STATUSES, RelayError

router = APIRouter(prefix="/entries", tags=["Entries"])

# ---------------------------------------------------------------- 체인 릴레이어 및 저장소 초기화
services = create_chain_services({"CHAIN_CLIENT": os.environ.get("CHAIN_CLIENT", "fake")})
draft_store = InMemoryDraftStore(start_id=4)
relay = RegistrationRelay(
    chain=services.ledger,
    store=draft_store,
    recover_signer=services.recover_signer,
    roles=services.roles,
)

# 테스트/목업 기본 총무 지갑 주소
DEFAULT_TREASURER_WALLET = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
if hasattr(services.ledger, "grant_role"):
    services.ledger.grant_role(Role.TREASURER, DEFAULT_TREASURER_WALLET)

# 초안 입력값 임시 보존용 (RECORDED 전이 시 EntryResponse 생성용)
DRAFT_INPUTS: Dict[int, EntryCreate] = {}

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


def check_ocr_duplication(entry: EntryCreate):
    """영수증 중복 검사:
    1. 이미 등록된 entries 검사
    2. 열린 초안(DRAFT, SUBMITTING, FAILED) 검사 (종인 님 강조 사항)
    """
    if not (entry.ocr_approval_no and entry.ocr_paid_at):
        return

    # 1. entries 목록 검사
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

    # 2. 열린 초안 검사 (DRAFT, SUBMITTING, FAILED)
    for draft_id, draft in draft_store._drafts.items():
        if draft.status in OPEN_STATUSES:
            draft_input = DRAFT_INPUTS.get(draft_id)
            if (
                draft_input
                and draft_input.ocr_approval_no == entry.ocr_approval_no
                and draft_input.ocr_paid_at == entry.ocr_paid_at
                and draft_input.amount == entry.amount
            ):
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=f"동일한 영수증으로 처리 중인 초안이 존재합니다 (초안 ID: {draft_id}, 상태: {draft.status.value}).",
                )


@router.get("", response_model=List[EntryResponse], summary="수입·지출 내역 목록 조회")
@router.get("/", response_model=List[EntryResponse], include_in_schema=False)
async def get_entries():
    """모바일 앱 '내역 목록' 및 '대시보드'에서 호출하는 수입·지출 내역 목록 API입니다.
    체인에 기록된 온체인 항목(PENDING, CONFIRMED 등)만 제공되며 미완성 초안은 제외됩니다.
    """
    return DUMMY_ENTRIES


@router.post(
    "/drafts",
    response_model=EntryCreateResponse,
    status_code=status.HTTP_201_CREATED,
    summary="수입·지출 1단계 초안 생성 (ID 예약 및 EIP-712 서명 페이로드 발급)",
)
@router.post(
    "",
    response_model=EntryCreateResponse,
    status_code=status.HTTP_201_CREATED,
    include_in_schema=False,
)
@router.post(
    "/",
    response_model=EntryCreateResponse,
    status_code=status.HTTP_201_CREATED,
    include_in_schema=False,
)
async def open_entry_draft(entry: EntryCreate):
    """1단계: 임원(총무/회장)이 거래 내역과 영수증 정보를 전송하여 초안을 생성하고 고유 ID를 예약받습니다."""
    # 1. OCR 중복 검사
    check_ocr_duplication(entry)

    # 2. 텍스트 정규화 및 meta_hash 계산
    try:
        norm_counterparty = prepare_field(entry.counterparty, "counterparty")
        norm_purpose = prepare_field(entry.purpose, "purpose")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))

    computed_meta_hash = meta_hash(
        amount=entry.amount,
        counterparty=norm_counterparty,
        purpose=norm_purpose,
        occurred_at=entry.occurred_at,
        receipt_hash=entry.receipt_hash,
    )

    # 3. 릴레이어를 통해 초안 등록 및 ID 예약
    try:
        draft = await relay.open_draft(
            created_by=2,  # 총무 User ID
            registrant=DEFAULT_TREASURER_WALLET,
            meta_hash=computed_meta_hash,
            amount=entry.amount,
            kind=entry.kind,
            occurred_at=entry.occurred_at,
            budget_id=entry.budget_id,
            corrects_id=entry.corrects_entry_id,
        )
    except RelayError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"초안 생성 실패: {e.code.value} - {e.detail}",
        )

    # 입력값 보존
    DRAFT_INPUTS[draft.id] = entry

    # 4. 서명용 EIP-712 페이로드 구성
    domain = Eip712Domain(
        name="AccountingLedger",
        version="1",
        chainId=80002,
        verifyingContract="0x0000000000000000000000000000000000000001",
    )
    message = SignMessage(
        id=draft.id,
        hash=draft.hash,
        amount=draft.amount,
        kind=1 if draft.kind == EntryKind.EXPENSE else 0,
        occurredAt=draft.occurred_at,
        budgetId=draft.budget_id,
        correctsId=draft.corrects_id,
    )

    return EntryCreateResponse(
        id=draft.id,
        sign=SignPayload(domain=domain, message=message),
        message="지출/수입 초안이 성공적으로 등록되었습니다. 기기 서명을 진행해 주세요.",
    )


@router.post(
    "/drafts/{draft_id}/submit",
    response_model=DraftSubmitResponse,
    summary="수입·지출 2단계 모바일 앱 기기 서명 제출 및 온체인 기록",
)
@router.post(
    "/{draft_id}/submit",
    response_model=DraftSubmitResponse,
    include_in_schema=False,
)
async def submit_entry_draft(draft_id: int, request: DraftSubmitRequest):
    """2단계: 모바일 앱이 기기 서명(EIP-712) 결과를 제출하여 스마트 컨트랙트에 트랜잭션을 발행합니다."""
    try:
        draft = await relay.submit(
            draft_id=draft_id,
            meta_hash=request.meta_hash,
            deadline=request.deadline,
            signature=request.signature,
        )
    except RelayError as e:
        code_str = e.code.value
        if code_str == "DRAFT_NOT_FOUND":
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="초안을 찾을 수 없습니다.")
        elif code_str == "DRAFT_DISCARDED":
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="이미 폐기된 초안입니다.")
        elif code_str == "HASH_MISMATCH":
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="meta_hash가 서버 계산값과 일치하지 않습니다.")
        elif code_str == "INVALID_DEADLINE":
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="서명 유효 시한(deadline)이 올바르지 않습니다.")
        elif code_str in ("INVALID_SIGNATURE", "SIGNER_MISMATCH", "ROLE_MISSING"):
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=f"서명 검증 실패: {code_str}")
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=f"제출 실패: {code_str} - {e.detail}")

    # RECORDED 상태일 때 Entry 생성 및 목록 반영
    if draft.status == DraftStatus.RECORDED:
        draft_input = DRAFT_INPUTS.get(draft.id)
        new_entry = EntryResponse(
            id=draft.id,
            term_id=draft_input.term_id if draft_input else 1,
            kind=draft.kind,
            amount=draft.amount,
            counterparty=draft_input.counterparty if draft_input else "",
            purpose=draft_input.purpose if draft_input else "",
            budget_id=draft.budget_id if draft.budget_id != 0 else None,
            occurred_at=draft.occurred_at,
            receipt_path=draft_input.receipt_path if draft_input else None,
            receipt_hash=draft_input.receipt_hash if draft_input else None,
            meta_hash=draft.hash,
            ocr_amount=draft_input.ocr_amount if draft_input else None,
            ocr_approval_no=draft_input.ocr_approval_no if draft_input else None,
            ocr_paid_at=draft_input.ocr_paid_at if draft_input else None,
            ocr_status=draft_input.ocr_status if draft_input else None,
            category_warning=False,
            warning_ack_reason=None,
            status=draft.entry_status or EntryStatus.PENDING,
            created_by=draft.created_by,
            approved_by=None,
            reject_reason=None,
            tx_pending=draft.tx_hash,
            tx_confirm=None,
            corrects_entry_id=draft_input.corrects_entry_id if draft_input else None,
            correction_reason=draft_input.correction_reason if draft_input else None,
        )
        if not any(e.id == new_entry.id for e in DUMMY_ENTRIES):
            DUMMY_ENTRIES.append(new_entry)

        return DraftSubmitResponse(
            id=draft.id,
            status=draft.entry_status or EntryStatus.PENDING,
            tx_pending=draft.tx_hash,
            message="온체인에 성공적으로 기록되어 PENDING 상태가 되었습니다.",
        )

    elif draft.status == DraftStatus.SUBMITTING:
        return DraftSubmitResponse(
            id=draft.id,
            status=EntryStatus.PENDING,
            tx_pending=None,
            message="체인에 전송 중이며 트랜잭션 확정 대기 상태입니다.",
        )
    else:  # FAILED
        return DraftSubmitResponse(
            id=draft.id,
            status=EntryStatus.REJECTED,
            fail_reason=draft.fail_reason,
            message=f"체인 기록에 실패했습니다: {draft.fail_reason}",
        )


@router.delete(
    "/drafts/{draft_id}",
    summary="초안 폐기 (DISCARDED 전이)",
)
async def discard_entry_draft(draft_id: int):
    """서명을 취소하거나 불필요해진 초안을 폐기합니다."""
    try:
        await relay.discard(draft_id, by_user=2)
        return {"id": draft_id, "status": "DISCARDED", "message": "초안이 정상적으로 폐기되었습니다."}
    except RelayError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=f"초안 폐기 실패: {e.code.value}")

