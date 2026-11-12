"""회원권 조회 — 학생 화면 S5 (본인 SBT 보유 표시 + 입장 QR).

조회 전용이라 학생 서버에 붙는다 (PRD §9.1). DB 에 쓰지 않는다.
보유 여부는 체인으로 확인하고(app/services/membership.py), 응답은 docs/backend_requests.md §1-4 의 약속을 따른다:
- 미보유는 200 + 본문 null. 404 를 쓰지 않는다 — 앱은 404 를 '조회 실패'로 읽는다
- 확인하지 못했으면 503. 미보유와 다르게 안내한다 (납부한 학생에게 「납부 확인이 필요합니다」를 띄우지 않는다)
"""
import logging
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.auth import User, get_current_user
from app.chain.client import ChainClient
from app.chain.provider import get_chain_client
from app.database import get_db
from app.models import Term as DBTerm
from app.schemas.auth import Role
from app.schemas.membership import MembershipResponse
from app.services.membership import MembershipUnavailable, current_term, membership_of

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/memberships", tags=["Memberships"])
query_router = router


@router.get("/me", response_model=Optional[MembershipResponse], summary="내 학기 회원권(SBT)과 입장 QR")
async def get_my_membership(
    term_id: Optional[int] = Query(None, ge=1, description="학기 ID. 없으면 진행 중인 학기"),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    chain: ChainClient = Depends(get_chain_client),
):
    """그 학기의 회원권을 보유 중이면 회원권 정보와 QR, 아니면 null.

    임원 계정은 회원권을 가질 수 없어 항상 null 이다. 진행 중인 학기가 없어도 null 이다.
    """
    if user.role != Role.STUDENT:
        return None
    try:
        if term_id is None:
            term = current_term(db)
            if term is None:
                return None
        else:
            term = db.get(DBTerm, term_id)
            if term is None:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"ID {term_id}에 해당하는 학기를 찾을 수 없습니다.")
        view = await membership_of(db, chain, user.id, term)
    except MembershipUnavailable as e:
        logger.warning("회원권 확인 불가: user=%s %s", user.id, e)
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="회원권을 확인할 수 없습니다. 잠시 후 다시 시도해 주세요.")
    except SQLAlchemyError as e:
        logger.exception("회원권 조회 중 데이터베이스 오류: %s", e)
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="데이터베이스 처리 중 오류가 발생했습니다.")

    if view is None:
        return None
    return MembershipResponse(
        id=view.id,
        user_id=view.user_id,
        term_id=view.term_id,
        token_id=view.token_id,
        minted_at=int(_utc(view.minted_at).timestamp()) if view.minted_at is not None else None,
        burned_at=None,
        qr_payload=view.qr_payload,
    )


def _utc(dt: datetime) -> datetime:
    # SQLite 는 시간대를 저장하지 않는다. 저장할 때 UTC 로 넣으므로 시간대가 없으면 UTC 로 본다
    return dt if dt.tzinfo is not None else dt.replace(tzinfo=timezone.utc)
