"""학기 회원권(SBT) 확인 — `GET /memberships/me` 와 행사 입장 판정이 같이 쓴다 (PRD §10).

보유 여부의 기준은 체인이다 (MembershipSBT.hasValidMembership). DB `Membership` 행은 화면에 보일 발급 정보(id·발급 시각)를 채우는 데만 쓴다.
DB 만 보면 서버가 주소를 바꿔 발행해도 학생이 알아챌 수 없다 — 학생이 자기 화면에서 체인의 보유를 확인하는 것이 그 대응이다 (PRD §13).

확인하지 못한 것(노드 장애, MembershipSBT 미배포, 지갑 파생 설정 없음)은 '없음'이 아니라 '모름'이다.
MembershipUnavailable 로 올리고, 부른 쪽은 미보유와 다르게 다룬다 — 입장 판정은 UNVERIFIABLE, 조회 API 는 503.
학생이 아니거나 지갑 index 가 없으면 회원권을 가질 수 없으므로 '없음'이다.
"""
import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

from sqlalchemy.orm import Session

from app.chain.client import ChainClient
from app.chain.models import ChainError
from app.models import Membership, Term, User
from app.schemas.auth import Role
from app.services.student_wallet import WalletDerivationError, student_address

logger = logging.getLogger(__name__)


class MembershipUnavailable(Exception):
    """회원권 보유 여부를 확인하지 못했다. 미보유가 아니라 '모름'이다."""


@dataclass(frozen=True)
class MembershipView:
    """보유 중인 회원권. 체인에서 확인된 경우에만 만든다."""

    id: Optional[int]  # DB Membership.id. 체인에는 있는데 DB 기록이 없으면 None
    user_id: int
    term_id: int
    token_id: int
    minted_at: Optional[datetime]
    qr_payload: str


def qr_payload(user_id: int, term_code: int) -> str:
    """입장 QR 문자열 "SCA:<학기>:U<학생 ID>" (docs/backend_requests.md §1-4).

    자격 정보는 담지 않는다 — 캡처를 전달해 대리 입장하지 못하게 스캐너가 매번 조회한다 (PRD §4.2).
    학기 부분은 표시용이다. 입장 판정은 QR 의 학기가 아니라 행사의 학기로 한다.
    """
    return f"SCA:{term_code // 10}-{term_code % 10}:U{user_id:06d}"


async def check_membership(db: Session, chain: ChainClient, user_id: int, term_id: int) -> bool:
    """user_id 학생이 term_id 학기의 유효한 회원권을 가졌는가.

    Raises:
        MembershipUnavailable: 체인·설정 문제로 확인하지 못했다.
    """
    user = db.get(User, user_id)
    term = db.get(Term, term_id)
    address = _address_of(user)
    if address is None or term is None:
        return False
    return await _has_valid(chain, address, term.term_code)


async def membership_of(db: Session, chain: ChainClient, user_id: int, term: Term) -> Optional[MembershipView]:
    """조회 화면용. 보유 중이면 MembershipView, 아니면 None.

    Raises:
        MembershipUnavailable: 체인·설정 문제로 확인하지 못했다.
    """
    address = _address_of(db.get(User, user_id))
    if address is None or not await _has_valid(chain, address, term.term_code):
        return None
    try:
        token_id = await chain.membership_token_of(address, term.term_code)
    except ChainError as e:
        raise MembershipUnavailable(f"회원권 tokenId 를 읽지 못했다: {e}") from e
    if token_id == 0:
        # 두 조회 사이에 소각됐다 (두 호출은 같은 블록이라는 보장이 없다). 0 은 유효한 tokenId 가 아니다
        return None

    row = (
        db.query(Membership)
        .filter(Membership.user_id == user_id, Membership.term_id == term.id, Membership.burned_at.is_(None))
        .first()
    )
    if row is not None and row.token_id != token_id:
        # DB 와 체인이 어긋났다. 보유의 기준은 체인이라 체인 tokenId 를 보이고, DB 행은 같은 회원권이 아니므로 쓰지 않는다
        logger.warning(
            "회원권 tokenId 불일치: user=%s term=%s db=%s chain=%s", user_id, term.id, row.token_id, token_id
        )
        row = None
    return MembershipView(
        id=row.id if row is not None else None,
        user_id=user_id,
        term_id=term.id,
        token_id=token_id,
        minted_at=row.minted_at if row is not None else None,
        qr_payload=qr_payload(user_id, term.term_code),
    )


def current_term(db: Session, now: Optional[datetime] = None) -> Optional[Term]:
    """지금 진행 중인 학기. 없으면 이미 시작한 학기 중 가장 최근 것. 그것도 없으면 None."""
    now = now or datetime.now(timezone.utc)
    started = [t for t in db.query(Term).all() if _aware(t.started_at) <= now]
    ongoing = [t for t in started if now <= _aware(t.ended_at)]
    pool = ongoing or started
    return max(pool, key=lambda t: _aware(t.started_at)) if pool else None


def _address_of(user: Optional[User]) -> Optional[str]:
    if user is None or user.role != Role.STUDENT.value or user.wallet_index is None:
        return None
    try:
        return student_address(user.wallet_index)
    except WalletDerivationError as e:
        raise MembershipUnavailable(f"학생 지갑 주소를 만들 수 없다: {e}") from e


async def _has_valid(chain: ChainClient, address: str, term_code: int) -> bool:
    try:
        return await chain.has_valid_membership(address, term_code)
    except ChainError as e:
        raise MembershipUnavailable(f"회원권을 확인하지 못했다: {e}") from e


def _aware(dt: datetime) -> datetime:
    # SQLite 는 시간대를 저장하지 않는다. 저장할 때 UTC 로 넣으므로 시간대가 없으면 UTC 로 본다
    return dt if dt.tzinfo is not None else dt.replace(tzinfo=timezone.utc)
