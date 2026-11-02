"""알림 기록 (docs/NOTIFICATION_API.md, PRD §4.8).

지금은 호출 자리를 먼저 잡는 빈 함수다. Notification 테이블이 생기면(11/7) 같은 시그니처로 채운다.
상태 변경과 같은 세션으로 부르고 호출한 쪽이 함께 commit 한다 — 롤백되면 알림도 남지 않는다.
"""
from enum import Enum
from typing import Iterable, Optional

from sqlalchemy.orm import Session


class NotificationKind(str, Enum):
    ENTRY_REGISTERED = "ENTRY_REGISTERED"
    ENTRY_REVISION_REQUESTED = "ENTRY_REVISION_REQUESTED"
    ENTRY_CONFIRMED = "ENTRY_CONFIRMED"
    ENTRY_REJECTED = "ENTRY_REJECTED"
    ENTRY_CONFIRM_FAILED = "ENTRY_CONFIRM_FAILED"
    ENTRY_BLOCKED = "ENTRY_BLOCKED"
    REVISION_REQUESTED = "REVISION_REQUESTED"
    REVISION_PRESIDENT_SIGNED = "REVISION_PRESIDENT_SIGNED"
    REVISION_APPROVED = "REVISION_APPROVED"
    REVISION_REJECTED = "REVISION_REJECTED"
    ROLE_CHANGE_REQUESTED = "ROLE_CHANGE_REQUESTED"
    PRESIDENT_RECOVERY_PROPOSED = "PRESIDENT_RECOVERY_PROPOSED"
    RECLASSIFY_PAIR_UNCONFIRMED = "RECLASSIFY_PAIR_UNCONFIRMED"
    SIGNATURE_DEADLINE_NEAR = "SIGNATURE_DEADLINE_NEAR"


def create_notification(
    db: Session,
    kind: NotificationKind,
    *,
    entry_id: Optional[int] = None,
    budget_revision_request_id: Optional[int] = None,
    user_ids: Optional[Iterable[int]] = None,
) -> None:
    """알림 행을 db 세션에 추가한다. commit 하지 않는다. 받는 사람은 kind 로 정하고, user_ids 는 표만으로 정해지지 않을 때만 넘긴다."""


def resolve_notifications(
    db: Session,
    *,
    entry_id: Optional[int] = None,
    budget_revision_request_id: Optional[int] = None,
) -> None:
    """처리된 건의 알림을 받는 사람 전원에게서 닫는다. commit 하지 않는다."""
