"""이의 제기(`/objections`) API 라우터.

- 조회(`GET /objections`, `GET /objections/open-count`): `query_router` (student_api + council_api 양쪽 탑재)
- 쓰기(`POST /objections`, `POST /objections/{id}/prepare-answer`, `POST /objections/{id}/answer`):
  `command_router` (council_api 전용 — 릴레이어 키 및 DB 쓰기 권한 분리 원칙 PRD §9.1 준수)
"""
from datetime import datetime, timezone
import logging
import time
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Path, Query, status
from sqlalchemy import func
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.auth import User, require_roles
from app.auth.deps import get_student_for_objection
from app.chain.client import ChainClient
from app.chain.deployment import DeploymentError, load_deployment
from app.chain.eip712 import ANSWER_REQUEST_FIELDS
from app.chain.models import (
    AnswerRequest,
    ChainRevert,
    ChainSetupError,
    ChainUnavailable,
    ObjectionRevertReason,
)
from app.chain.provider import get_chain_client
from app.database import get_db
from app.models import (
    Entry as DBEntry,
    Objection as DBObjection,
    Term as DBTerm,
    User as DBUser,
)
from app.schemas.auth import Role
from app.schemas.objection import (
    INT64_MAX,
    ObjectionAnswerPrepareRequest,
    ObjectionAnswerPrepareResponse,
    ObjectionAnswerSubmitRequest,
    ObjectionCreateRequest,
    ObjectionOpenCountResponse,
    ObjectionResponse,
    ObjectionStatus,
)
from app.services.student_wallet import WalletDerivationError, student_address
from app.utils.hashing import canonical_text, text_hash, validate_multiline_text_for_hash

logger = logging.getLogger(__name__)

query_router = APIRouter(prefix="/objections", tags=["Objections"])
command_router = APIRouter(prefix="/objections", tags=["Objections"])

responder_only = require_roles(Role.AUDITOR, Role.PRESIDENT)


def _to_unix(dt: Optional[datetime]) -> Optional[int]:
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


def _to_schema(obj: DBObjection) -> ObjectionResponse:
    answered = obj.status == ObjectionStatus.ANSWERED.value
    return ObjectionResponse(
        id=obj.id,
        entry_id=obj.entry_id,
        user_id=obj.user_id,
        content=obj.content,
        answer=obj.answer if answered else None,
        answered_by=obj.answered_by if answered else None,
        status=ObjectionStatus(obj.status),
        raised_at=_to_unix(obj.raised_at) or 0,
        answered_at=_to_unix(obj.answered_at) if answered else None,
        tx_raise=obj.tx_raise,
        tx_answer=obj.tx_answer if answered else None,
    )


def _normalize_multiline(raw: str, field_name: str, empty_detail: str) -> str:
    try:
        validate_multiline_text_for_hash(raw, field_name)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))
    normalized = canonical_text(raw)
    if not normalized:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=empty_detail)
    return normalized


def _objection_domain_dict() -> dict:
    try:
        deployment = load_deployment()
        domain = deployment.eip712.get("ObjectionRegistry")
        if domain is not None:
            return {
                "name": domain.name,
                "version": domain.version,
                "chainId": domain.chain_id,
                "verifyingContract": domain.verifying_contract,
            }
        chain_id = deployment.chain_id
    except (DeploymentError, ChainSetupError):
        chain_id = 31337
    return {
        "name": "ObjectionRegistry",
        "version": "1",
        "chainId": chain_id,
        "verifyingContract": "0x" + "0" * 40,
    }


async def _reconcile_pending_raise(
    db: Session, chain: ChainClient, obj: DBObjection
) -> bool:
    """'?...' 인플라이트 표기가 남은 이의 제기의 온체인 등록 여부를 확인해 복구한다.

    아직 체인 조회 결과가 None 이면 채굴 대기 중일 수 있으므로 기존 해시·본문을 삭제하지 않고 보존한다.
    """
    if not obj.tx_raise or not obj.tx_raise.startswith("?"):
        return bool(obj.tx_raise and obj.tx_raise.startswith("0x"))

    inflight_hash = "0x" + obj.tx_raise[1:]
    try:
        onchain = await chain.get_objection(obj.id)
    except (ChainUnavailable, ChainSetupError) as e:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"이전 이의 제기 트랜잭션 결과를 확인할 수 없습니다: {e}",
        )

    if onchain is not None and onchain.content_hash.lower() == text_hash(obj.content):
        obj.tx_raise = inflight_hash
        db.commit()
        db.refresh(obj)
        return True

    return False


async def _reconcile_pending_answer(
    db: Session, chain: ChainClient, obj: DBObjection
) -> tuple[DBObjection, bool]:
    """OPEN 상태에서 tx_answer 선점이 남아 있는 항목의 온체인 안착 여부를 확인해 DB를 복구한다.

    체인 상태가 아직 OPEN 이면 채굴 대기 중일 수 있으므로 보존된 답변 본문·해시를 삭제하지 않는다.

    Returns:
        (갱신된 obj, 방금 복구되어 ANSWERED로 전환되었는지 여부)
    """
    if obj.status != ObjectionStatus.OPEN.value or obj.tx_answer is None:
        return obj, False

    try:
        onchain = await chain.get_objection(obj.id)
    except (ChainUnavailable, ChainSetupError) as e:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"이전 답변 트랜잭션 결과를 확인할 수 없습니다: {e}",
        )

    if (
        onchain is not None
        and onchain.status == ObjectionStatus.ANSWERED.value
        and obj.answer is not None
        and obj.answered_by is not None
        and obj.answered_at is not None
        and onchain.answer_hash.lower() == text_hash(obj.answer)
    ):
        obj.status = ObjectionStatus.ANSWERED.value
        db.commit()
        db.refresh(obj)
        return obj, True

    return obj, False


@query_router.get("", response_model=List[ObjectionResponse], summary="이의 제기 목록 조회")
@query_router.get("/", response_model=List[ObjectionResponse], include_in_schema=False)
async def list_objections(
    entry_id: Optional[int] = Query(None, ge=1, le=INT64_MAX, description="특정 원장 항목 ID 필터"),
    status_filter: Optional[ObjectionStatus] = Query(None, alias="status", description="상태 필터 (OPEN | ANSWERED)"),
    db: Session = Depends(get_db),
):
    """특정 회계 항목 또는 전체 이의 제기 목록을 조회합니다 (온체인 등록 완료된 건만 반환)."""
    try:
        q = db.query(DBObjection).filter(DBObjection.tx_raise.like("0x%"))
        if entry_id is not None:
            q = q.filter(DBObjection.entry_id == entry_id)
        if status_filter is not None:
            q = q.filter(DBObjection.status == status_filter.value)
        rows = q.order_by(DBObjection.id.asc()).all()
    except SQLAlchemyError as e:
        logger.exception("이의 제기 목록 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )
    return [_to_schema(row) for row in rows]


@query_router.get("/open-count", response_model=ObjectionOpenCountResponse, summary="미답변(OPEN) 이의 제기 건수 조회")
async def get_open_objection_count(db: Session = Depends(get_db)):
    """임원 홈 화면 배지 표시용 미답변(OPEN) 이의 제기 건수를 조회합니다."""
    try:
        count = (
            db.query(func.count(DBObjection.id))
            .filter(
                DBObjection.tx_raise.like("0x%"),
                DBObjection.status == ObjectionStatus.OPEN.value,
            )
            .scalar()
            or 0
        )
    except SQLAlchemyError as e:
        logger.exception("미답변 이의 건수 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )
    return ObjectionOpenCountResponse(count=int(count))


@query_router.get("/{objection_id}", response_model=ObjectionResponse, summary="이의 제기 단건 상세 조회")
async def get_objection_by_id(
    objection_id: int = Path(..., ge=1, le=INT64_MAX),
    db: Session = Depends(get_db),
):
    """이의 제기 ID로 단건 상세 정보를 조회합니다 (온체인 등록 완료된 건만 반환)."""
    try:
        obj = (
            db.query(DBObjection)
            .filter(DBObjection.id == objection_id, DBObjection.tx_raise.like("0x%"))
            .first()
        )
    except SQLAlchemyError as e:
        logger.exception("이의 제기 단건 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )
    if obj is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"이의 제기(id={objection_id})를 찾을 수 없습니다.",
        )
    return _to_schema(obj)


@command_router.post(
    "",
    response_model=ObjectionResponse,
    status_code=status.HTTP_201_CREATED,
    summary="이의 제기 등록 (학생 전용)",
)
@command_router.post(
    "/",
    response_model=ObjectionResponse,
    status_code=status.HTTP_201_CREATED,
    include_in_schema=False,
)
async def raise_objection(
    req: ObjectionCreateRequest,
    user: User = Depends(get_student_for_objection),
    db: Session = Depends(get_db),
    chain: ChainClient = Depends(get_chain_client),
):
    """학생이 확정(CONFIRMED) 회계 항목에 대해 이의를 제기하고 온체인에 contentHash를 기록합니다."""
    normalized = _normalize_multiline(req.content, "content", "이의 제기 본문은 공백일 수 없습니다.")
    content_hash = text_hash(normalized)

    try:
        entry = db.query(DBEntry).filter(DBEntry.id == req.entry_id).first()
        if entry is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"대상 회계 항목(id={req.entry_id})을 찾을 수 없습니다.",
            )
        if entry.status not in ("CONFIRMED", "PENDING"):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="확정(CONFIRMED) 또는 대기 중(PENDING) 상태의 회계 항목에만 이의를 제기할 수 있습니다.",
            )

        term = db.get(DBTerm, entry.term_id)
        if term is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"대상 학기(id={entry.term_id})를 찾을 수 없습니다.",
            )

        db_user = db.get(DBUser, user.id)
        if db_user is None or db_user.wallet_index is None:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="학생 지갑 인덱스가 설정되어 있지 않습니다.",
            )
        raiser_wallet = student_address(db_user.wallet_index)

        # 해당 학기 SBT 보유 여부 fail-closed 확인 (지갑 파생 및 DB 조회 중복 제거)
        has_sbt = await chain.has_valid_membership(raiser_wallet, term.term_code)
        if not has_sbt:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="해당 학기 학생회비 납부 확인(MembershipSBT 보유)이 필요합니다.",
            )

        # 이전 요청에서 ChainUnavailable 등으로 남은 미확정 행(tx_raise IS NULL 또는 '?...' 선점)을 먼저 확인·복구한다.
        # 채굴 대기 중인 다른 질문 행의 해시나 본문은 절대 삭제·덮어쓰지 않고 보존한다.
        inflight_rows = (
            db.query(DBObjection)
            .filter(
                DBObjection.user_id == user.id,
                DBObjection.status == ObjectionStatus.OPEN.value,
                DBObjection.tx_raise.like("?%"),
            )
            .order_by(DBObjection.id.desc())
            .all()
        )
        obj: Optional[DBObjection] = None
        for cand in inflight_rows:
            landed = await _reconcile_pending_raise(db, chain, cand)
            if cand.entry_id == entry.id and cand.content == normalized:
                if landed:
                    return _to_schema(cand)
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="이전 이의 제기 트랜잭션이 처리 중입니다. 잠시 후 다시 확인해 주세요.",
                )

        if obj is None:
            unrecorded_rows = (
                db.query(DBObjection)
                .filter(
                    DBObjection.user_id == user.id,
                    DBObjection.entry_id == entry.id,
                    DBObjection.content == normalized,
                    DBObjection.status == ObjectionStatus.OPEN.value,
                    DBObjection.tx_raise.is_(None),
                )
                .order_by(DBObjection.id.desc())
                .all()
            )
            for cand in unrecorded_rows:
                onchain = await chain.get_objection(cand.id)
                if onchain is None:
                    obj = cand
                    break

        if obj is None:
            obj = DBObjection(
                entry_id=entry.id,
                user_id=user.id,
                content=normalized,
                status=ObjectionStatus.OPEN.value,
                raised_at=datetime.now(timezone.utc),
                tx_raise=None,
            )
            db.add(obj)
            db.commit()
            db.refresh(obj)
    except (ChainUnavailable, ChainSetupError) as e:
        logger.warning("이의 제기 사전 체인 확인 불가: user=%s %s", user.id, e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="블록체인 상태를 확인할 수 없어 이의를 제기할 수 없습니다. 잠시 후 다시 시도해 주세요.",
        )
    except WalletDerivationError as e:
        logger.warning("학생 지갑 파생 실패: user=%s %s", user.id, e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="학생 지갑 주소를 확인할 수 없습니다.",
        )
    except SQLAlchemyError as e:
        db.rollback()
        logger.exception("이의 제기 사전 조회/채번 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    claimed_tx: Optional[str] = None

    async def _claim_tx_raise(tx_hash: str) -> None:
        nonlocal claimed_tx
        inflight_marker = "?" + tx_hash[2:]
        rows = (
            db.query(DBObjection)
            .filter(DBObjection.id == obj.id, DBObjection.tx_raise.is_(None))
            .update({DBObjection.tx_raise: inflight_marker}, synchronize_session=False)
        )
        if rows == 0:
            db.rollback()
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="이미 처리 중인 이의 제기 요청입니다.",
            )
        db.commit()
        claimed_tx = tx_hash

    def _clear_tx_raise() -> None:
        if claimed_tx is None:
            return
        try:
            db.query(DBObjection).filter(DBObjection.id == obj.id).update(
                {DBObjection.tx_raise: None}, synchronize_session=False
            )
            db.commit()
        except SQLAlchemyError:
            db.rollback()

    try:
        tx_result = await chain.raise_objection(
            obj.id, entry.id, content_hash, raiser_wallet, before_broadcast=_claim_tx_raise
        )
        obj.tx_raise = tx_result.tx_hash
        db.commit()
        db.refresh(obj)
    except HTTPException:
        raise
    except ChainRevert as e:
        _clear_tx_raise()
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"온체인 이의 제기 기록이 거절되었습니다: {e}",
        )
    except ChainSetupError as e:
        _clear_tx_raise()
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"블록체인 네트워크와 통신할 수 없습니다: {e}",
        )
    except ChainUnavailable as e:
        if claimed_tx is not None:
            try:
                onchain = await chain.get_objection(obj.id)
                if onchain is not None:
                    obj.tx_raise = claimed_tx
                    db.commit()
                    db.refresh(obj)
                    return _to_schema(obj)
            except (ChainUnavailable, ChainSetupError, SQLAlchemyError):
                db.rollback()
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"블록체인 네트워크와 통신할 수 없습니다: {e}",
        )
    except SQLAlchemyError as e:
        db.rollback()
        logger.exception("이의 제기 저장 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    return _to_schema(obj)


@command_router.post(
    "/{objection_id}/prepare-answer",
    response_model=ObjectionAnswerPrepareResponse,
    summary="임원 답변 서명 준비 (1단계)",
)
async def prepare_answer_objection(
    req: ObjectionAnswerPrepareRequest,
    objection_id: int = Path(..., ge=1, le=INT64_MAX),
    user: User = Depends(responder_only),
    db: Session = Depends(get_db),
    chain: ChainClient = Depends(get_chain_client),
):
    """답변 본문을 정본화·해시하고, 임원 기기가 서명할 EIP-712 AnswerRequest 값을 내려줍니다."""
    normalized = _normalize_multiline(req.answer, "answer", "답변 본문은 비어 있거나 공백만 있을 수 없습니다.")
    try:
        obj = db.query(DBObjection).filter(DBObjection.id == objection_id).first()
    except SQLAlchemyError as e:
        logger.exception("이의 제기 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    if obj is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"이의 제기(id={objection_id})를 찾을 수 없습니다.",
        )

    try:
        if obj.tx_raise and obj.tx_raise.startswith("?"):
            await _reconcile_pending_raise(db, chain, obj)
        if not obj.tx_raise or not obj.tx_raise.startswith("0x"):
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"이의 제기(id={objection_id})를 찾을 수 없습니다.",
            )
        obj, _ = await _reconcile_pending_answer(db, chain, obj)
    except HTTPException:
        raise
    except SQLAlchemyError as e:
        db.rollback()
        logger.exception("이의 답변 선점 복구 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    if obj.status != ObjectionStatus.OPEN.value or obj.tx_answer is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="이미 답변이 완료되었거나 답변 트랜잭션이 처리 중인 이의 제기입니다.",
        )

    answer_hash = text_hash(normalized)
    deadline = int(time.time()) + 600
    domain = _objection_domain_dict()
    types = {"AnswerRequest": [{"name": n, "type": t} for n, t in ANSWER_REQUEST_FIELDS]}
    message = {"objectionId": obj.id, "answerHash": answer_hash, "deadline": deadline}
    return ObjectionAnswerPrepareResponse(
        objection_id=obj.id,
        answer_hash=answer_hash,
        deadline=deadline,
        domain=domain,
        types=types,
        message=message,
    )


@command_router.post(
    "/{objection_id}/answer",
    response_model=ObjectionResponse,
    summary="임원 답변 기기 서명 제출 및 온체인 기록 (2단계)",
)
async def answer_objection(
    req: ObjectionAnswerSubmitRequest,
    objection_id: int = Path(..., ge=1, le=INT64_MAX),
    user: User = Depends(responder_only),
    db: Session = Depends(get_db),
    chain: ChainClient = Depends(get_chain_client),
):
    """감사·회장의 EIP-712 AnswerRequest 기기 서명을 검증한 뒤 온체인에 답변을 기록합니다."""
    normalized = _normalize_multiline(req.answer, "answer", "답변 본문은 비어 있거나 공백만 있을 수 없습니다.")
    computed_hash = text_hash(normalized)
    if computed_hash != req.answer_hash.lower():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="답변 본문 해시가 서명 대상(answer_hash)과 일치하지 않습니다.",
        )

    try:
        obj = db.query(DBObjection).filter(DBObjection.id == objection_id).first()
        db_user = db.get(DBUser, user.id)
    except SQLAlchemyError as e:
        logger.exception("이의 제기 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    if obj is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"이의 제기(id={objection_id})를 찾을 수 없습니다.",
        )

    try:
        if obj.tx_raise and obj.tx_raise.startswith("?"):
            await _reconcile_pending_raise(db, chain, obj)
        if not obj.tx_raise or not obj.tx_raise.startswith("0x"):
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"이의 제기(id={objection_id})를 찾을 수 없습니다.",
            )
        obj, recovered_now = await _reconcile_pending_answer(db, chain, obj)
    except HTTPException:
        raise
    except SQLAlchemyError as e:
        db.rollback()
        logger.exception("이의 답변 선점 복구 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    if recovered_now and obj.answer == normalized:
        return _to_schema(obj)

    if obj.status != ObjectionStatus.OPEN.value or obj.tx_answer is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="이미 답변이 완료되었거나 답변 트랜잭션이 처리 중인 이의 제기입니다.",
        )
    if db_user is None or not db_user.wallet_address:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="임원 계정에 등록된 지갑 주소가 없습니다.",
        )

    try:
        answer_req = AnswerRequest(
            objection_id=obj.id,
            answer_hash=computed_hash,
            deadline=req.deadline,
        )
        recovered = chain.signer_of(answer_req, req.signature)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))

    if recovered.lower() != db_user.wallet_address.lower():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="서명자 지갑 주소가 로그인한 임원의 지갑 주소와 일치하지 않습니다.",
        )

    now = datetime.now(timezone.utc)
    raised_utc = obj.raised_at if obj.raised_at.tzinfo else obj.raised_at.replace(tzinfo=timezone.utc)
    if now < raised_utc:
        now = raised_utc

    claimed = False

    async def _claim_tx_answer(tx_hash: str) -> None:
        nonlocal claimed
        rows = (
            db.query(DBObjection)
            .filter(
                DBObjection.id == obj.id,
                DBObjection.status == ObjectionStatus.OPEN.value,
                DBObjection.tx_answer.is_(None),
            )
            .update(
                {
                    DBObjection.tx_answer: tx_hash,
                    DBObjection.answer: normalized,
                    DBObjection.answered_by: user.id,
                    DBObjection.answered_at: now,
                },
                synchronize_session=False,
            )
        )
        if rows == 0:
            db.rollback()
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="이미 답변이 완료되었거나 다른 요청이 처리 중입니다.",
            )
        db.commit()
        claimed = True

    def _clear_claimed_tx() -> None:
        if not claimed:
            return
        try:
            db.query(DBObjection).filter(
                DBObjection.id == obj.id,
                DBObjection.status == ObjectionStatus.OPEN.value,
            ).update(
                {
                    DBObjection.tx_answer: None,
                    DBObjection.answer: None,
                    DBObjection.answered_by: None,
                    DBObjection.answered_at: None,
                },
                synchronize_session=False,
            )
            db.commit()
        except SQLAlchemyError:
            db.rollback()

    try:
        tx_result = await chain.answer_objection(answer_req, req.signature, before_broadcast=_claim_tx_answer)
    except HTTPException:
        raise
    except ChainRevert as e:
        _clear_claimed_tx()
        code = (
            status.HTTP_409_CONFLICT
            if e.reason == ObjectionRevertReason.OBJECTION_ALREADY_ANSWERED
            else status.HTTP_400_BAD_REQUEST
        )
        raise HTTPException(status_code=code, detail=f"온체인 답변 기록이 거절되었습니다: {e}")
    except ChainSetupError as e:
        _clear_claimed_tx()
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"블록체인 네트워크와 통신할 수 없습니다: {e}",
        )
    except ChainUnavailable as e:
        if claimed:
            try:
                onchain = await chain.get_objection(obj.id)
                if (
                    onchain is not None
                    and onchain.status == ObjectionStatus.ANSWERED.value
                    and onchain.answer_hash.lower() == computed_hash
                ):
                    db.query(DBObjection).filter(DBObjection.id == obj.id).update(
                        {DBObjection.status: ObjectionStatus.ANSWERED.value},
                        synchronize_session=False,
                    )
                    db.commit()
                    db.refresh(obj)
                    return _to_schema(obj)
            except (ChainUnavailable, ChainSetupError, SQLAlchemyError):
                pass
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"블록체인 네트워크와 통신할 수 없습니다: {e}",
        )

    try:
        updated = (
            db.query(DBObjection)
            .filter(DBObjection.id == obj.id, DBObjection.status == ObjectionStatus.OPEN.value)
            .update(
                {
                    DBObjection.answer: normalized,
                    DBObjection.answered_by: user.id,
                    DBObjection.answered_at: now,
                    DBObjection.status: ObjectionStatus.ANSWERED.value,
                    DBObjection.tx_answer: tx_result.tx_hash,
                },
                synchronize_session=False,
            )
        )
        if updated == 0:
            db.rollback()
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="이미 답변이 완료된 이의 제기입니다.",
            )
        db.commit()
        db.refresh(obj)
    except HTTPException:
        raise
    except SQLAlchemyError as e:
        db.rollback()
        logger.exception("이의 답변 저장 중 데이터베이스 오류: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    return _to_schema(obj)
