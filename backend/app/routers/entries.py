import asyncio
import inspect
import logging
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session
from sqlalchemy.exc import SQLAlchemyError

logger = logging.getLogger(__name__)

from app.auth import User, require_roles
from app.auth.approval import ensure_not_self_approval
from app.chain import (
    ChainClient,
    ChainRevert,
    ChainSetupError,
    ChainUnavailable,
    ConfirmApproval,
    RecordRequest,
    RejectDecision,
    entry_commit,
)
from app.chain.provider import get_chain_client
from app.chain.models import BlockReason as ChainBlockReason
from app.services.chain_tx import (
    EntryConflict,
    relay_confirm,
    relay_record,
    relay_reject,
)
from app.database import get_db
from app.models import Budget as DBBudget, Entry as DBEntry, Term as DBTerm, User as DBUser
from app.schemas.auth import Role
from app.schemas.entry import (
    BlockReason,
    EntryConfirmRequest,
    EntryConfirmResponse,
    EntryCreate,
    EntryCreateResponse,
    EntryKind,
    EntryRejectRequest,
    EntryRejectResponse,
    EntryResponse,
    EntryStatus,
    EntrySubmitRequest,
    EntrySubmitResponse,
    OCRStatus,
    OnChainEntryResponse,
)
from app.utils.hashing import (
    calculate_meta_hash,
    canonical,
    canonical_text,
    text_hash,
    validate_text_for_hash,
)

# PRD §8/§9 기준 경고 판정 대상 OCR 상태 (MATCH, NO_NUMBER, None 은 정상)
WARNING_OCR_STATUSES = {
    OCRStatus.MISMATCH.value,
    OCRStatus.DUPLICATE.value,
    OCRStatus.UNREADABLE.value,
}

router = APIRouter(prefix="/entries", tags=["Entries"])

# 등록·서명 제출은 총무만 가능 (컨트랙트 NotRegistrant)
treasurer_only = require_roles(Role.TREASURER)
# 승인·반려는 감사와 회장만 가능
approver_only = require_roles(Role.AUDITOR, Role.PRESIDENT)

async def _get_chain_registrant(entry_id: int, chain: ChainClient) -> str:
    """온체인에서 항목의 등록자 지갑 주소를 조회합니다.
    체인 통신/설정 오류는 503, 체인에 없는 건은 404를 반환합니다.
    """
    try:
        chain_entry = await chain.get_entry(entry_id)
    except (ChainUnavailable, ChainSetupError) as e:
        logger.exception("체인 항목(%d) 등록자 조회 중 오류: %s", entry_id, e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="블록체인 네트워크와 통신할 수 없습니다.",
        )

    if not chain_entry:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"체인에서 항목(id={entry_id})을 찾을 수 없습니다.",
        )

    if not chain_entry.registrant:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"항목(id={entry_id})의 체인 등록자 지갑 주소를 찾을 수 없습니다.",
        )

    return chain_entry.registrant


def _to_schema(
    entry: DBEntry,
    chain_registrant: Optional[str] = None,
    block_number: Optional[int] = None,
) -> EntryResponse:
    """DB Entry ORM 모델을 EntryResponse 스키마로 변환"""
    # 선점 때 미리 적은 값이다. 체인에서 끝나기 전에는 내보내지 않는다 (실패하면 비워진다). 앱의 단건 검증은 체인 approver 가
    # 비어 있는데 approved_by 만 있으면 위조로 판정한다 (entry_verifier.dart)
    confirmed = entry.status == EntryStatus.CONFIRMED.value
    rejected = entry.status == EntryStatus.REJECTED.value

    # 온체인 등록자(chain_registrant)만 반환한다. 체인 미조회·실패 시 DB 등록자 지갑으로 대체하지 않고 None(null)을 유지하여
    # 앱이 서명 전 온체인 대조 불가 상태를 감지할 수 있게 한다.
    registrant = chain_registrant

    return EntryResponse(
        id=entry.id,
        term_id=entry.term_id,
        term_code=entry.term.term_code if getattr(entry, "term", None) else None,
        kind=EntryKind(entry.kind),
        amount=entry.amount,
        counterparty=entry.counterparty,
        purpose=entry.purpose,
        budget_id=entry.budget_id,
        occurred_at=entry.occurred_at,
        receipt_path=entry.receipt_path,
        receipt_hash=entry.receipt_hash,
        meta_hash=entry.meta_hash,
        hash_version=entry.hash_version,
        ocr_amount=entry.ocr_amount,
        ocr_approval_no=entry.ocr_approval_no,
        ocr_paid_at=entry.ocr_paid_at,
        ocr_status=OCRStatus(entry.ocr_status) if entry.ocr_status else None,
        category_warning=entry.category_warning,
        warning_ack_reason=entry.warning_ack_reason if confirmed else None,
        status=EntryStatus(entry.status) if entry.status else None,
        created_by=entry.created_by,
        approved_by=entry.approved_by if confirmed else None,
        rejected_by=entry.rejected_by if rejected else None,
        reject_reason=entry.reject_reason if rejected else None,
        tx_pending=entry.tx_pending,
        tx_confirm=entry.tx_confirm,
        registrant=registrant,
        block_number=block_number,
        corrects_entry_id=entry.corrects_entry_id,
        correction_reason=entry.correction_reason,
    )


async def _get_chain_client_safe(request: Request) -> Optional[ChainClient]:
    """보강 단계에서 체인 클라이언트를 안전하게 획득한다.

    노드 미기동·설정 미비(ChainSetupError) 등 클라이언트 초기화 실패 시
    503을 던지지 않고 None을 반환하여 DB 기본 데이터로 200 응답할 수 있도록 한다.
    """
    getter = request.app.dependency_overrides.get(get_chain_client, get_chain_client)
    try:
        res = getter()
        if inspect.isawaitable(res):
            res = await res
        return res
    except Exception:
        return None


@router.get("", response_model=List[EntryResponse], summary="수입·지출 내역 목록 조회")
@router.get("/", response_model=List[EntryResponse], include_in_schema=False)
async def get_entries(
    request: Request,
    db: Session = Depends(get_db),
):
    """모바일 앱 '내역 목록' 및 '대시보드'에서 호출하는 수입·지출 내역 목록 API입니다.
    체인에 기록된 건(status IS NOT NULL)만 반환하며, 기기 서명 미제출 초안은 제외됩니다.
    """
    try:
        db_entries = db.query(DBEntry).filter(DBEntry.status.isnot(None)).all()
    except SQLAlchemyError as e:
        logger.exception("수입·지출 내역 목록 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    # RPC 호출 부하 및 앱 타임아웃(3초) 방지:
    # 목록 조회에서는 최대 1.5초 이내로 온체인 등록자 조회를 시도하고,
    # 노드 응답 지연/오류 시 DB 값으로 위장하지 않고 registrant=null(None)로 반환하여 앱이 미검증 상태를 식별할 수 있게 합니다.
    chain_registrants: dict[int, str] = {}

    if db_entries:
        try:
            async def _fetch_all():
                chain = await _get_chain_client_safe(request)
                if chain is None:
                    return
                tasks = [chain.get_entry(e.id) for e in db_entries]
                fetched = await asyncio.gather(*tasks, return_exceptions=True)
                for e, res in zip(db_entries, fetched):
                    if not isinstance(res, Exception) and res and res.registrant:
                        chain_registrants[e.id] = res.registrant

            await asyncio.wait_for(_fetch_all(), timeout=1.5)
        except Exception:
            pass

    results = [
        _to_schema(e, chain_registrant=chain_registrants.get(e.id))
        for e in db_entries
    ]
    return results


@router.get("/{id}", response_model=EntryResponse, summary="수입·지출 내역 단건 상세 조회")
async def get_entry_by_id(
    id: int,
    request: Request,
    db: Session = Depends(get_db),
):
    """내역 ID로 특정 수입/지출 내역의 상세 정보를 조회합니다."""
    try:
        entry = db.query(DBEntry).filter(DBEntry.id == id, DBEntry.status.isnot(None)).first()
    except SQLAlchemyError as e:
        logger.exception("수입·지출 내역 단건 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    if not entry:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"ID {id}에 해당하는 내역을 찾을 수 없습니다.",
        )

    chain_registrant = None
    block_num = None
    try:
        async def _fetch_entry_chain_detail():
            nonlocal chain_registrant, block_num
            chain = await _get_chain_client_safe(request)
            if chain is None:
                return
            chain_entry = await chain.get_entry(id)
            if chain_entry and chain_entry.registrant:
                chain_registrant = chain_entry.registrant
            tx_hash = entry.tx_confirm or entry.tx_pending
            if tx_hash:
                tx_detail = await chain.entry_tx_detail(tx_hash, id)
                if tx_detail:
                    block_num = tx_detail.block_number

        await asyncio.wait_for(_fetch_entry_chain_detail(), timeout=2.0)
    except Exception:
        pass

    return _to_schema(entry, chain_registrant=chain_registrant, block_number=block_num)


@router.get("/{id}/onchain", response_model=OnChainEntryResponse, summary="온체인 원장 항목 조회")
async def get_onchain_entry(
    id: int,
    db: Session = Depends(get_db),
    chain: ChainClient = Depends(get_chain_client),
):
    """체인에 기록된 항목(getEntry)과 트랜잭션 기록(entry_tx_detail)을 조회합니다.
    체인에 없거나 미기록 상태면 404를 반환합니다.
    """
    try:
        chain_entry = await chain.get_entry(id)
    except (ChainUnavailable, ChainSetupError) as e:
        logger.exception("온체인 항목(%d) 조회 중 체인 오류: %s", id, e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="블록체인 네트워크와 통신할 수 없습니다.",
        )

    if not chain_entry:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"체인에서 항목(id={id})을 찾을 수 없습니다.",
        )

    if (
        chain_entry.amount == 0
        and (not chain_entry.hash or chain_entry.hash == "0x" + "00" * 32)
        and (not chain_entry.registrant or chain_entry.registrant == "0x" + "00" * 20)
    ):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"체인에서 항목(id={id})을 찾을 수 없습니다.",
        )

    tx_detail = None
    try:
        entry = db.query(DBEntry).filter(DBEntry.id == id).first()
        if entry:
            tx_hash = entry.tx_confirm or entry.tx_pending
            if tx_hash:
                tx_detail = await chain.entry_tx_detail(tx_hash, id)
    except Exception as e:
        logger.warning("체인 트랜잭션 상세 조회 실패: %s", e)

    return OnChainEntryResponse(
        id=chain_entry.id,
        hash=chain_entry.hash,
        amount=chain_entry.amount,
        kind=EntryKind(chain_entry.kind.value if hasattr(chain_entry.kind, "value") else chain_entry.kind),
        status=EntryStatus(chain_entry.status.value if hasattr(chain_entry.status, "value") else chain_entry.status),
        term=chain_entry.term,
        occurred_at=chain_entry.occurred_at,
        budget_id=chain_entry.budget_id,
        corrects_id=chain_entry.corrects_id,
        registrant=chain_entry.registrant,
        approver=chain_entry.approver,
        had_warning=tx_detail.had_warning if tx_detail else None,
        reason_hash=tx_detail.reason_hash if tx_detail else None,
        block_number=tx_detail.block_number if tx_detail else None,
        block_reason=BlockReason(tx_detail.block_reason.value if hasattr(tx_detail.block_reason, "value") else tx_detail.block_reason) if tx_detail and tx_detail.block_reason else None,
        tx_hash=tx_detail.tx_hash if tx_detail else None,
    )


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
async def create_entry(
    entry: EntryCreate,
    user: User = Depends(treasurer_only),
    db: Session = Depends(get_db),
):
    """총무가 모바일 앱에서 영수증과 지출 내역을 입력 후 초안을 등록할 때 호출하는 API입니다.
    1단계에서는 온체인 트랜잭션 없이 고유 ID만 발급되며, 2단계 submit 호출을 통해 기기 서명 검증 후 온체인에 기록됩니다.
    총무(TREASURER)만 호출할 수 있습니다 (컨트랙트 NotRegistrant).
    """
    # 1. 텍스트 제어문자 및 공백류 검사 (docs/HASHING.md §1.1, §5)
    try:
        validate_text_for_hash(entry.counterparty, "counterparty")
        validate_text_for_hash(entry.purpose, "purpose")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))

    # 2. 텍스트 정규화 (NFC, U+0020 trim)
    canonical_counterparty = canonical(entry.counterparty)
    canonical_purpose = canonical(entry.purpose)

    if not canonical_counterparty or not canonical_purpose:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="거래처와 지출 목적은 빈 문자열일 수 없습니다.",
        )

    # 3. KST 자정 타임스탬프 검사
    if entry.occurred_at < 0 or entry.occurred_at % 86400 != 54000:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="occurred_at은 사용일의 KST 자정(00:00:00 KST) Unix timestamp 초 단위여야 합니다.",
        )

    # 4. 수입 내역 예산 연결 차단 (DB 제약 ck_entries_income_no_budget 사전 검증)
    if entry.kind == EntryKind.INCOME and entry.budget_id is not None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="수입 내역에는 예산을 연결할 수 없습니다.",
        )

    # 5. 영수증 중복 검사 (DB)
    if entry.ocr_approval_no and entry.ocr_paid_at:
        try:
            existing_db = (
                db.query(DBEntry)
                .filter(
                    DBEntry.ocr_approval_no == entry.ocr_approval_no,
                    DBEntry.ocr_paid_at == entry.ocr_paid_at,
                    DBEntry.amount == entry.amount,
                )
                .first()
            )
        except SQLAlchemyError as e:
            logger.exception("영수증 중복 조회 중 데이터베이스 오류: %s", e)
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="데이터베이스 처리 중 오류가 발생했습니다.",
            )

        if existing_db:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"이미 등록된 영수증입니다 (내역 ID: {existing_db.id}, 승인번호: {entry.ocr_approval_no}).",
            )

    # 6. meta_hash 계산
    computed_meta_hash = calculate_meta_hash(
        amount=entry.amount,
        counterparty=canonical_counterparty,
        purpose=canonical_purpose,
        occurred_at=entry.occurred_at,
        receipt_hash=entry.receipt_hash,
    )

    # 7. DB 초안 생성 (쓰기 경로는 실제 DB 전용)
    try:
        db_entry = DBEntry(
            term_id=entry.term_id,
            kind=entry.kind.value,
            amount=entry.amount,
            counterparty=canonical_counterparty,
            purpose=canonical_purpose,
            budget_id=entry.budget_id,
            occurred_at=entry.occurred_at,
            receipt_path=entry.receipt_path,
            receipt_hash=entry.receipt_hash,
            meta_hash=computed_meta_hash,
            hash_version=1,
            ocr_amount=entry.ocr_amount,
            ocr_approval_no=entry.ocr_approval_no,
            ocr_paid_at=entry.ocr_paid_at,
            ocr_status=entry.ocr_status.value if entry.ocr_status else None,
            category_warning=False,
            warning_ack_reason=None,
            status=None,
            created_by=user.id,
            approved_by=None,
            rejected_by=None,
            reject_reason=None,
            tx_pending=None,
            tx_confirm=None,
            corrects_entry_id=entry.corrects_entry_id,
            correction_reason=entry.correction_reason.value if entry.correction_reason else None,
        )
        db.add(db_entry)
        db.commit()
        db.refresh(db_entry)
    except SQLAlchemyError as e:
        db.rollback()
        logger.exception("초안 등록 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    return EntryCreateResponse(
        id=db_entry.id,
        message="지출/수입 초안이 등록되었으며, 기기 서명 제출 대기 상태입니다.",
    )


@router.post(
    "/{id}/submit",
    response_model=EntrySubmitResponse,
    summary="초안 기기 서명 제출 및 온체인 등록 (2단계)",
)
async def submit_entry(
    id: int,
    req: EntrySubmitRequest,
    user: User = Depends(treasurer_only),
    db: Session = Depends(get_db),
    chain: ChainClient = Depends(get_chain_client),
):
    """1단계에서 발급받은 초안 id에 대해 모바일 기기 서명을 제출하여 블록체인에 등록합니다.
    초안을 등록한 총무 본인만 호출할 수 있습니다.
    체인 릴레이 전에 ChainClient.signer_of 로 서명자 지갑 주소를 기대 지갑(총무 지갑)과 대조합니다.
    불일치하거나 서명 형식이 틀리면 400 Bad Request를 반환합니다.
    """
    # 1. 초안 조회 (DB 전용)
    try:
        target = db.query(DBEntry).filter(DBEntry.id == id).first()
    except SQLAlchemyError as e:
        logger.exception("초안 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    if not target:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"ID {id}에 해당하는 초안 내역을 찾을 수 없습니다.",
        )

    created_by = target.created_by
    current_status = target.status
    current_tx = target.tx_pending

    # 2. 본인 확인 (다른 사람이면 즉시 403)
    if created_by != user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="본인이 등록한 초안만 제출할 수 있습니다.",
        )

    # 3. 이미 제출된 건인지 확인 (상태 ②인 경우 relay_record에서 복구하도록 status만 검사)
    if current_status is not None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="이미 온체인에 제출된 내역입니다.",
        )

    # 4. 온체인 학기 코드(term_code, YYYYS) 조회
    db_term = None
    try:
        db_term = db.query(DBTerm).filter(DBTerm.id == target.term_id).first()
    except SQLAlchemyError as e:
        logger.exception("학기 정보 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )
    if not db_term or not db_term.term_code:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"해당 항목(term_id={target.term_id})의 유효한 학기 코드(term_code)를 찾을 수 없습니다.",
        )
    term_code = db_term.term_code

    # 5. RecordRequest 구성
    target_kind = EntryKind(target.kind)
    target_amount = target.amount
    target_hash = target.meta_hash
    target_occurred_at = target.occurred_at
    target_budget_id = target.budget_id or 0
    target_corrects_id = (
        getattr(target, "corrects_entry_id", None)
        or getattr(target, "corrects_id", None)
        or 0
    )

    try:
        record_req = RecordRequest(
            id=id,
            hash=target_hash,
            amount=target_amount,
            kind=target_kind,
            term=term_code,
            occurred_at=target_occurred_at,
            budget_id=target_budget_id,
            corrects_id=target_corrects_id,
            deadline=req.deadline,
        )
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))

    # 6. 서명자 복구 및 기대 지갑(총무 지갑) 대조 (CHAIN_CLIENT.md §4)
    try:
        recovered_signer = chain.signer_of(record_req, req.signature)
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"유효하지 않은 서명 형식입니다: {e}",
        )

    expected_wallet = user.wallet_address
    if not expected_wallet:
        try:
            db_u = db.query(DBUser).filter(DBUser.id == user.id).first()
            if db_u and db_u.wallet_address:
                expected_wallet = db_u.wallet_address
        except SQLAlchemyError:
            pass

    if not expected_wallet or recovered_signer.lower() != expected_wallet.lower():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="서명자가 등록자와 일치하지 않습니다.",
        )

    # 7. 체인 릴레이 호출 및 상태 갱신 (chain_tx 서비스 연동)
    try:
        db.commit()
    except SQLAlchemyError as e:
        logger.exception("체인 릴레이 전 데이터베이스 커밋 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    try:
        tx_result = await relay_record(db, chain, record_req, req.signature)
    except EntryConflict as e:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(e))
    except ChainRevert as e:
        reason_code = e.reason.value if hasattr(e.reason, "value") else str(e.reason)
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content={
                "detail": f"온체인 등록이 거부되었습니다 ({reason_code}).",
                "fail_reason": reason_code,
            },
        )
    except ChainUnavailable:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="블록체인 네트워크와 통신할 수 없습니다.",
        )
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))
    except LookupError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))

    new_status = tx_result.status
    tx_hash = tx_result.tx_hash
    b_reason = tx_result.block_reason

    msg = (
        "온체인에 성공적으로 기록되어 감사 승인 대기(PENDING) 상태가 되었습니다."
        if new_status == EntryStatus.PENDING
        else "해당 예산 카테고리의 잔량이 부족하여 지출 등록이 차단(BLOCKED)되었습니다."
    )

    return EntrySubmitResponse(
        id=id,
        status=new_status,
        tx_pending=tx_hash,
        block_reason=b_reason,
        message=msg,
    )


@router.post(
    "/{id}/confirm",
    response_model=EntryConfirmResponse,
    summary="수입·지출 내역 승인 (온체인 confirmEntry)",
)
async def confirm_entry(
    id: int,
    req: EntryConfirmRequest,
    user: User = Depends(approver_only),
    db: Session = Depends(get_db),
    chain: ChainClient = Depends(get_chain_client),
):
    """감사 또는 회장이 PENDING 상태의 항목에 대해 기기 서명을 제출하여 최종 확정(CONFIRMED)합니다.
    자기 승인(등록자 본인의 승인)은 403으로 차단됩니다.
    체인 릴레이 전에 signer_of 로 승인자의 지갑 주소를 대조합니다.
    """
    # 1. 항목 조회 (DB 전용)
    try:
        target = db.query(DBEntry).filter(DBEntry.id == id).first()
    except SQLAlchemyError as e:
        logger.exception("내역 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    if not target:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"ID {id}에 해당하는 내역을 찾을 수 없습니다.",
        )

    ensure_not_self_approval(target.created_by, user)

    current_status = target.status
    if current_status != EntryStatus.PENDING.value and current_status != EntryStatus.PENDING:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="PENDING 상태의 항목만 확정할 수 있습니다.",
        )

    # 반려가 선점 중이면 체인을 읽기 전에 409 (노드가 죽은 ② 에서도 503 이 아니다). 내 확정의 재시도는 relay_confirm 이 결과를 확인한다
    if target.tx_confirm and target.rejected_by is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="반려 처리 중인 내역은 확정할 수 없습니다.",
        )

    # 학기 코드 조회
    db_term = None
    try:
        db_term = db.query(DBTerm).filter(DBTerm.id == target.term_id).first()
    except SQLAlchemyError as e:
        logger.exception("학기 정보 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )
    if not db_term or not db_term.term_code:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"해당 항목(term_id={target.term_id})의 유효한 학기 코드(term_code)를 찾을 수 없습니다.",
        )
    term_code = db_term.term_code

    target_kind = EntryKind(target.kind)
    target_amount = target.amount
    target_hash = target.meta_hash
    target_occurred_at = target.occurred_at
    target_budget_id = target.budget_id or 0
    target_corrects_id = (
        getattr(target, "corrects_entry_id", None)
        or getattr(target, "corrects_id", None)
        or 0
    )

    registrant_addr = await _get_chain_registrant(id, chain)

    commit_hash = entry_commit(
        hash=target_hash,
        amount=target_amount,
        kind=target_kind,
        term=term_code,
        occurred_at=target_occurred_at,
        budget_id=target_budget_id,
        corrects_id=target_corrects_id,
        registrant=registrant_addr,
    )

    # 경고 승인 판정 (카테고리 불일치 경고 또는 OCR 불일치/미인식 건)
    # PRD §8/§9 기준: MISMATCH, DUPLICATE, UNREADABLE 만 경고 대상이며, MATCH, NO_NUMBER, None 은 정상
    ocr_status_val = target.ocr_status.value if hasattr(target.ocr_status, "value") else target.ocr_status
    has_ocr_warning = bool(ocr_status_val in WARNING_OCR_STATUSES)
    had_warning = bool(target.category_warning or has_ocr_warning)

    # 경고 항목인데 사유가 비어 있으면 선제 400 차단 (체인 ReasonRequired 방지)
    if had_warning and not (req.warning_reason and req.warning_reason.strip()):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="경고 항목 승인 시에는 경고 무시 사유(warning_reason)가 필수입니다.",
        )
    if not had_warning and req.warning_reason and req.warning_reason.strip():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="경고 항목이 아닌 경우 경고 무시 사유(warning_reason)를 제출할 수 없습니다.",
        )

    clean_reason = canonical_text(req.warning_reason) if had_warning and req.warning_reason else None
    warning_reason_hash = (
        text_hash(clean_reason)
        if had_warning and clean_reason
        else "0x" + "0" * 64
    )

    try:
        approval = ConfirmApproval(
            id=id,
            hash=target_hash,
            entry_commit=commit_hash,
            had_warning=had_warning,
            warning_reason_hash=warning_reason_hash,
            deadline=req.deadline,
        )
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))

    # 서명자 대조
    try:
        recovered = chain.signer_of(approval, req.signature)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=f"서명 형식 오류: {e}")

    if not user.wallet_address or recovered.lower() != user.wallet_address.lower():
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="서명자가 승인권자와 일치하지 않습니다.")

    # 체인 릴레이 호출 및 상태 갱신 (chain_tx 서비스 연동)
    try:
        db.commit()
    except SQLAlchemyError as e:
        logger.exception("체인 릴레이 전 데이터베이스 커밋 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    try:
        tx_res = await relay_confirm(
            db=db,
            chain=chain,
            approval=approval,
            signature=req.signature,
            approver_id=user.id,
            warning_reason=clean_reason,
        )
    except EntryConflict as e:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(e))
    except ChainRevert as e:
        reason_code = e.reason.value if hasattr(e.reason, "value") else str(e.reason)
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content={
                "detail": f"온체인 승인이 거부되었습니다 ({reason_code}).",
                "fail_reason": reason_code,
            },
        )
    except ChainUnavailable:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="블록체인 네트워크와 통신할 수 없습니다.")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))
    except LookupError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))
    except SQLAlchemyError as e:
        logger.exception("체인 릴레이 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다. 다시 요청하면 결과를 확인합니다.",
        )

    return EntryConfirmResponse(
        id=id,
        status=EntryStatus.CONFIRMED,
        tx_confirm=tx_res.tx_hash,
        message="온체인에 성공적으로 확정(CONFIRMED) 기록되었습니다.",
    )


@router.post(
    "/{id}/reject",
    response_model=EntryRejectResponse,
    summary="수입·지출 내역 반려 (온체인 rejectEntry)",
)
async def reject_entry(
    id: int,
    req: EntryRejectRequest,
    user: User = Depends(approver_only),
    db: Session = Depends(get_db),
    chain: ChainClient = Depends(get_chain_client),
):
    """감사 또는 회장이 PENDING 상태의 항목에 대해 기기 서명을 제출하여 반려(REJECTED)합니다.
    자기 승인/반려는 403으로 차단됩니다.
    체인 릴레이 전에 signer_of 로 서명자 지갑 주소를 대조합니다.
    """
    # 1. 항목 조회 (DB 전용)
    try:
        target = db.query(DBEntry).filter(DBEntry.id == id).first()
    except SQLAlchemyError as e:
        logger.exception("내역 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    if not target:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"ID {id}에 해당하는 내역을 찾을 수 없습니다.",
        )

    ensure_not_self_approval(target.created_by, user)

    current_status = target.status
    if current_status != EntryStatus.PENDING.value and current_status != EntryStatus.PENDING:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="PENDING 상태의 항목만 반려할 수 있습니다.",
        )

    # 확정이 선점 중이면 체인을 읽기 전에 409 (노드가 죽은 ② 에서도 503 이 아니다). 내 반려의 재시도는 relay_reject 가 결과를 확인한다
    if target.tx_confirm and target.approved_by is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="확정 처리 중인 내역은 반려할 수 없습니다.",
        )

    canon_reason = canonical_text(req.reject_reason)
    if not canon_reason:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="반려 사유는 필수입니다.")

    reason_hash = text_hash(canon_reason)

    # 학기 코드 조회
    db_term = None
    try:
        db_term = db.query(DBTerm).filter(DBTerm.id == target.term_id).first()
    except SQLAlchemyError as e:
        logger.exception("학기 정보 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )
    if not db_term or not db_term.term_code:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"해당 항목(term_id={target.term_id})의 유효한 학기 코드(term_code)를 찾을 수 없습니다.",
        )
    term_code = db_term.term_code

    target_kind = EntryKind(target.kind)
    target_amount = target.amount
    target_hash = target.meta_hash
    target_occurred_at = target.occurred_at
    target_budget_id = target.budget_id or 0
    target_corrects_id = (
        getattr(target, "corrects_entry_id", None)
        or getattr(target, "corrects_id", None)
        or 0
    )

    registrant_addr = await _get_chain_registrant(id, chain)

    commit_hash = entry_commit(
        hash=target_hash,
        amount=target_amount,
        kind=target_kind,
        term=term_code,
        occurred_at=target_occurred_at,
        budget_id=target_budget_id,
        corrects_id=target_corrects_id,
        registrant=registrant_addr,
    )

    try:
        decision = RejectDecision(
            id=id,
            entry_commit=commit_hash,
            reason_hash=reason_hash,
            deadline=req.deadline,
        )
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))

    # 서명자 대조
    try:
        recovered = chain.signer_of(decision, req.signature)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=f"서명 형식 오류: {e}")

    if not user.wallet_address or recovered.lower() != user.wallet_address.lower():
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="서명자가 반려권자와 일치하지 않습니다.")

    # 체인 릴레이 (선점·상태 저장은 relay_reject 가 한다). 체인을 기다리는 동안 이 세션의 트랜잭션을 열어 두지 않는다
    try:
        db.commit()
    except SQLAlchemyError as e:
        logger.exception("체인 릴레이 전 데이터베이스 커밋 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    try:
        await relay_reject(
            db=db,
            chain=chain,
            decision=decision,
            signature=req.signature,
            rejecter_id=user.id,
            reason=canon_reason,
        )
    except EntryConflict as e:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(e))
    except ChainRevert as e:
        reason_code = e.reason.value if hasattr(e.reason, "value") else str(e.reason)
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content={
                "detail": f"온체인 반려가 거부되었습니다 ({reason_code}).",
                "fail_reason": reason_code,
            },
        )
    except ChainUnavailable:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="블록체인 네트워크와 통신할 수 없습니다.")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))
    except LookupError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))
    except SQLAlchemyError as e:
        logger.exception("체인 릴레이 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다. 다시 요청하면 결과를 확인합니다.",
        )

    return EntryRejectResponse(
        id=id,
        status=EntryStatus.REJECTED,
        message="온체인에 성공적으로 반려(REJECTED) 기록되었습니다.",
    )
