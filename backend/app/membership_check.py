"""행사 입장 판정에 쓰는 회원권(SBT) 보유 확인.

PRD v0.15 §10: 손종인의 `GET /memberships/me` 와 입장 판정은 같은 확인 함수(DB Membership + 체인
hasValidMembership)를 써야 한다. 그 함수가 생기기 전까지는 DB 만 본다. 라우터는 get_membership_checker
의존성으로 받으므로, 공용 함수가 나오면 이 파일의 get_membership_checker 만 바꾸면 된다.
"""
from typing import Callable

from sqlalchemy.orm import Session

from app.models import Membership


class MembershipUnavailable(Exception):
    """회원권 보유 여부를 확인하지 못함 (체인 RPC 장애 등). '없음'이 아니라 '모름'이다 — 입장 API 는 UNVERIFIABLE 로 답한다."""


# (db, user_id, term_id) -> 보유 여부. 확인을 못 하면 MembershipUnavailable 을 던진다
MembershipChecker = Callable[[Session, int, int], bool]


def db_membership_checker(db: Session, user_id: int, term_id: int) -> bool:
    """그 학기 회원권 중 소각(환불 회수·탈퇴)되지 않은 것이 있으면 보유."""
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
