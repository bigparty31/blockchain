"""행사 입장 판정에 쓰는 회원권(SBT) 보유 확인.

PRD v0.15 §10: `GET /memberships/me` 와 입장 판정은 같은 확인 함수를 써야 한다. 공용 함수는
app/services/membership.py 의 check_membership(db, chain, user_id, term_id) 이고 체인을 읽어 async 다.
라우터는 get_membership_checker 의존성으로 받는다 — 공용 함수 연결은 이 함수 하나만 바꾸면 된다 (#68 리뷰, 손종인).

규칙 (공용 함수와 같다)
- async (db, user_id, term_id) -> bool
- 확인하지 못하면 MembershipUnavailable 을 던진다. 예외 클래스도 공용 것을 그대로 쓴다 —
  따로 두면 공용 함수가 던진 예외를 라우터가 못 잡아 '판정 불가'가 500 이 된다
"""
from typing import Awaitable, Callable

from sqlalchemy.orm import Session

from app.models import Membership
from app.services.membership import MembershipUnavailable

__all__ = ["MembershipChecker", "MembershipUnavailable", "db_membership_checker", "get_membership_checker"]

# (db, user_id, term_id) -> 보유 여부. 확인을 못 하면 MembershipUnavailable 을 던진다
MembershipChecker = Callable[[Session, int, int], Awaitable[bool]]


async def db_membership_checker(db: Session, user_id: int, term_id: int) -> bool:
    """공용 함수를 연결하기 전 임시 기본값: 그 학기 회원권 중 소각되지 않은 DB 행이 있으면 보유."""
    row = (
        db.query(Membership.id)
        .filter(
            Membership.user_id == user_id,
            Membership.term_id == term_id,
            Membership.burned_at.is_(None),
        )
        .first()
    )
    return row is not None


def get_membership_checker() -> MembershipChecker:
    return db_membership_checker
