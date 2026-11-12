"""회원권 일괄 발행 API — 임원 화면 A3 (docs/API.md 「회원권 2」, PRD v0.16 §4.2).

쓰기라 학생회 서버에 붙는다 (PRD §9.1). 조회 전용인 GET /memberships/me(app/routers/memberships.py)와 파일을 나눠 둔다 —
서버를 나눌 때 이 라우터만 학생회 서버에 등록하면 된다.
회장·감사만 쓴다. 제출은 준비한 임원 본인만 할 수 있다 (nonce 가 서명자마다 따로다).
"""
import logging
from datetime import datetime, timezone
from typing import List

from fastapi import APIRouter, Depends, HTTPException, Path, status
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.auth import User, require_roles
from app.chain.client import ChainClient
from app.chain.provider import get_chain_client
from app.database import get_db
from app.models import MembershipMintBatch
from app.schemas.auth import Role
from app.schemas.membership import (
    MintBatchPrepareRequest,
    MintBatchResponse,
    MintBatchSubmitRequest,
    MintExcludedResponse,
    MintTargetResponse,
)
from app.services import membership_mint as mint
from app.services.membership_mint import Excluded, MintError, NothingToMint

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/memberships/mint-batches", tags=["Memberships"])

approver_only = require_roles(Role.PRESIDENT, Role.AUDITOR)


@router.post("", response_model=MintBatchResponse, status_code=status.HTTP_201_CREATED, summary="회원권 일괄 발행 준비 (1단계)")
async def prepare_mint_batch(
    req: MintBatchPrepareRequest,
    user: User = Depends(approver_only),
    db: Session = Depends(get_db),
    chain: ChainClient = Depends(get_chain_client),
):
    """학번 목록을 학생 지갑 주소로 바꾸고 이미 보유한 학생 등을 뺀 뒤, 서명할 값(term_code·nonce·recipients)을 돌려줍니다."""
    try:
        prepared = await mint.prepare(db, chain, user, req.term_id, req.student_nos)
    except NothingToMint as e:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"message": e.message, "excluded": [_excluded(x).model_dump() for x in e.excluded]},
        )
    except MintError as e:
        db.rollback()
        raise HTTPException(status_code=e.code, detail=e.message)
    except SQLAlchemyError as e:
        db.rollback()
        logger.exception("회원권 발행 준비 중 데이터베이스 오류: %s", e)
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="데이터베이스 처리 중 오류가 발생했습니다.")
    n = len(prepared.batch.targets)
    return _response(prepared.batch, prepared.excluded, f"{n}명에게 발행할 준비가 되었습니다. 기기에서 서명해 제출해 주세요.")


@router.post("/{batch_id}/submit", response_model=MintBatchResponse, summary="회원권 일괄 발행 서명 제출 (2단계)")
async def submit_mint_batch(
    req: MintBatchSubmitRequest,
    batch_id: int = Path(..., ge=1),
    user: User = Depends(approver_only),
    db: Session = Depends(get_db),
    chain: ChainClient = Depends(get_chain_client),
):
    """서명자를 확인하고 체인에 보냅니다. 결과는 MINTED · REJECTED · NO_RESPONSE 입니다."""
    try:
        batch = await mint.submit(db, chain, user, batch_id, req.deadline, req.signature)
    except MintError as e:
        db.rollback()
        raise HTTPException(status_code=e.code, detail=e.message)
    except SQLAlchemyError as e:
        db.rollback()
        logger.exception("회원권 발행 제출 중 데이터베이스 오류: %s", e)
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="데이터베이스 처리 중 오류가 발생했습니다.")
    return _response(batch, [], _message(batch))


@router.get("/{batch_id}", response_model=MintBatchResponse, summary="회원권 일괄 발행 요청 조회")
async def get_mint_batch(
    batch_id: int = Path(..., ge=1),
    user: User = Depends(approver_only),
    db: Session = Depends(get_db),
    chain: ChainClient = Depends(get_chain_client),
):
    """요청과 학생별 결과. 결과를 모르는 상태(SUBMITTING·NO_RESPONSE)면 저장된 tx hash 로 체인 결과를 확인해 반영합니다."""
    try:
        batch = await mint.refresh(db, chain, batch_id)
    except MintError as e:
        db.rollback()
        raise HTTPException(status_code=e.code, detail=e.message)
    except SQLAlchemyError as e:
        db.rollback()
        logger.exception("회원권 발행 요청 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="데이터베이스 처리 중 오류가 발생했습니다.")
    return _response(batch, [], _message(batch))


# ---------------------------------------------------------------- 응답


def _response(batch: MembershipMintBatch, excluded: List[Excluded], message: str) -> MintBatchResponse:
    targets = sorted(batch.targets, key=lambda t: t.position)
    return MintBatchResponse(
        id=batch.id,
        term_id=batch.term_id,
        term_code=batch.term.term_code,
        status=batch.status,
        signer_address=_checksum(batch.signer_address),
        nonce=batch.nonce,
        recipients=[t.address for t in targets],
        deadline=batch.deadline,
        tx_hash=batch.tx_hash,
        reason=batch.reason,
        targets=[
            MintTargetResponse(
                student_no=t.user.student_no,
                user_id=t.user_id,
                name=t.user.name,
                address=t.address,
                status=t.status,
                token_id=t.token_id,
                membership_id=t.membership_id,
            )
            for t in targets
        ],
        excluded=[_excluded(x) for x in excluded],
        created_at=int(_utc(batch.created_at).timestamp()),
        message=message,
    )


def _excluded(x: Excluded) -> MintExcludedResponse:
    return MintExcludedResponse(student_no=x.student_no, user_id=x.user_id, name=x.name, status=x.status)


def _message(batch: MembershipMintBatch) -> str:
    if batch.status == "MINTED":
        minted = sum(1 for t in batch.targets if t.status == "MINTED")
        skipped = sum(1 for t in batch.targets if t.status == "SKIPPED")
        if skipped:
            return f"{minted}명에게 발행했고 {skipped}명은 이미 보유해 건너뛰었습니다."
        return f"{minted}명에게 발행했습니다."
    if batch.status == "REJECTED":
        return f"체인이 발행을 거부했습니다 ({batch.reason})."
    if batch.status == "NO_RESPONSE":
        return "체인의 응답을 받지 못했습니다. 같은 서명을 다시 보내지 말고 잠시 후 조회해 주세요."
    if batch.status == "SUBMITTING":
        return "체인에 보내는 중입니다. 잠시 후 조회해 주세요."
    return "발행할 준비가 되었습니다. 기기에서 서명해 제출해 주세요."


def _checksum(address: str) -> str:
    from eth_utils import to_checksum_address

    return to_checksum_address(address)


def _utc(dt: datetime) -> datetime:
    # SQLite 는 시간대를 저장하지 않는다. 저장할 때 UTC 로 넣으므로 시간대가 없으면 UTC 로 본다
    return dt if dt.tzinfo is not None else dt.replace(tzinfo=timezone.utc)
