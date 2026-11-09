"""알림 기록 (docs/NOTIFICATION_API.md, PRD §4.8).

상태 변경과 같은 세션으로 부르고 호출한 쪽이 함께 commit 한다 — 롤백되면 알림도 남지 않는다.
한 처리에서 둘 다 부르면 resolve_notifications 를 먼저 부른다. 증액은 다음 단계 알림도 재알림 대상이라,
순서가 바뀌면 방금 만든 REVISION_PRESIDENT_SIGNED 까지 닫힌다.

- 받는 사람은 kind 로 정한다 (§4.8 표). 역할로 받는 사람은 같은 세션의 users 테이블에서 찾는다 — Notification.user_id 의
  외래키와 출처가 같아야 시드가 덜 된 DB 에서도 상태 변경이 외래키 오류로 롤백되지 않는다. 「총무」는 그 건의 등록자다
- 문구(body)는 인자로 받지 않는다. 만들 때 kind 와 대상 건의 값으로 만들어 저장한다. 앱은 받은 문구를 그대로 표시한다
- 잘못 부르면(대상 id 누락, 없는 건) ValueError 다. 조용히 넘기면 알림이 빠진 것을 아무도 모른다
- 만든 알림은 받는 사람의 기기로도 푸시한다. 같은 세션이 commit 된 뒤에만 나간다 (app/services/push.py)
- 학생에게는 행을 만들지 않고 토픽(students_{학기 코드})으로만 보낸다: 확정(notify_students_confirmed),
  장부–계좌 차이(notify_students_balance_mismatch, 계좌 대조에서 부른다)
"""
import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Iterable, List, Optional

from sqlalchemy import update
from sqlalchemy.orm import Session

from app.models import NOTIFICATION_REMIND_KINDS, BudgetRevisionRequest, Entry, Notification, Term, User
from app.schemas.auth import Role
from app.schemas.notification import NotificationKind
from app.services import push

__all__ = [
    "NotificationKind",
    "REMIND_KINDS",
    "create_notification",
    "resolve_notifications",
    "remind_interval",
    "notify_students_confirmed",
    "notify_students_balance_mismatch",
    "student_topic",
]

logger = logging.getLogger(__name__)

K = NotificationKind

# 재알림 대상 — 임원이 처리할 건 (§4.8). 처리되면 받는 사람 전원에게서 닫힌다
REMIND_KINDS = frozenset(NotificationKind(value) for value in NOTIFICATION_REMIND_KINDS)

_ENTRY_KINDS = frozenset(
    {
        K.ENTRY_REGISTERED,
        K.ENTRY_EDIT_REQUESTED,
        K.ENTRY_CONFIRMED,
        K.ENTRY_REJECTED,
        K.ENTRY_CONFIRM_FAILED,
        K.ENTRY_BLOCKED,
        K.RECLASSIFY_PAIR_UNCONFIRMED,
    }
)
_REVISION_KINDS = frozenset(
    {K.REVISION_REQUESTED, K.REVISION_PRESIDENT_SIGNED, K.REVISION_APPROVED, K.REVISION_REJECTED, K.SIGNATURE_DEADLINE_NEAR}
)
# 표만으로 받는 사람이 정해지지 않는 종류 — 호출하는 쪽이 user_ids 를 넘긴다
_EXPLICIT_KINDS = frozenset({K.ROLE_CHANGE_REQUESTED, K.RECLASSIFY_PAIR_UNCONFIRMED})

# §4.8 표. "registrant" 는 그 건을 등록한 총무다
_RECIPIENTS = {
    K.ENTRY_REGISTERED: (Role.AUDITOR, Role.PRESIDENT),
    K.ENTRY_EDIT_REQUESTED: (Role.AUDITOR, Role.PRESIDENT),
    K.ENTRY_CONFIRMED: ("registrant",),
    K.ENTRY_REJECTED: ("registrant",),
    K.ENTRY_CONFIRM_FAILED: ("registrant",),
    K.ENTRY_BLOCKED: ("registrant", Role.PRESIDENT),
    K.REVISION_REQUESTED: (Role.PRESIDENT,),
    K.REVISION_PRESIDENT_SIGNED: (Role.AUDITOR,),
    K.REVISION_APPROVED: ("registrant", Role.PRESIDENT),
    K.REVISION_REJECTED: ("registrant", Role.PRESIDENT),
    K.SIGNATURE_DEADLINE_NEAR: (Role.AUDITOR,),
    K.PRESIDENT_RECOVERY_PROPOSED: (Role.PRESIDENT, Role.AUDITOR),
}

_REMIND_ENV = "NOTIFICATION_REMIND_SECONDS"
_DEFAULT_REMIND_SECONDS = 24 * 3600


def remind_interval() -> timedelta:
    """재알림 간격. 기본 24시간이고 시연에서는 환경변수로 줄인다 (§4.8)."""
    raw = os.environ.get(_REMIND_ENV, "").strip()
    if not raw:
        return timedelta(seconds=_DEFAULT_REMIND_SECONDS)
    try:
        seconds = int(raw)
    except ValueError:
        raise ValueError(f"{_REMIND_ENV} 는 초 단위 양의 정수여야 합니다: {raw!r}") from None
    if seconds <= 0:
        raise ValueError(f"{_REMIND_ENV} 는 초 단위 양의 정수여야 합니다: {raw!r}")
    return timedelta(seconds=seconds)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def create_notification(
    db: Session,
    kind: NotificationKind,
    *,
    entry_id: Optional[int] = None,
    budget_revision_request_id: Optional[int] = None,
    user_ids: Optional[Iterable[int]] = None,
) -> None:
    """알림 행을 db 세션에 추가한다. commit 하지 않는다. 받는 사람은 kind 로 정하고, user_ids 는 표만으로 정해지지 않을 때만 넘긴다."""
    kind = NotificationKind(kind)
    entry, revision = _target(db, kind, entry_id, budget_revision_request_id)
    recipients = _recipients(db, kind, entry, revision, user_ids)
    if kind is K.ENTRY_CONFIRM_FAILED:
        # 같은 건의 확정 실패를 아직 읽지 않았으면 다시 만들지 않는다. 읽은 뒤 다시 실패하면 한 번 더 알린다
        unread = _unread_confirm_failed(db, entry_id)
        recipients = [user_id for user_id in recipients if user_id not in unread]
    if not recipients:
        logger.warning("알림 %s 를 받을 사람이 없다 (entry_id=%s, revision_id=%s)", kind.value, entry_id, budget_revision_request_id)
        return

    now = _now()
    body = _body(kind, entry, revision)
    next_remind_at = now + remind_interval() if kind in REMIND_KINDS else None
    for user_id in recipients:
        values = dict(
            user_id=user_id,
            kind=kind.value,
            entry_id=entry_id,
            budget_revision_request_id=budget_revision_request_id,
            body=body,
            created_at=now,
            notified_at=now,
            remind_count=0,
            next_remind_at=next_remind_at,
        )
        if kind is K.ENTRY_CONFIRM_FAILED:
            # 위의 조회와 INSERT 사이에 같은 실패가 먼저 기록될 수 있다 (확정 요청 두 개가 브로드캐스트 전에 함께 revert).
            # uq_notifications_confirm_failed_unread 에 걸리면 건너뛴다
            new_id = _insert_unless_unread_exists(db, values)
            if new_id is None:
                continue  # 이미 기록됐다. 푸시도 그쪽이 보낸다
            notification = db.get(Notification, new_id)
        else:
            notification = Notification(**values)
            db.add(notification)
        push.queue_notification(db, notification)


def _unread_confirm_failed(db: Session, entry_id: int) -> set:
    """entry_id 의 확정 실패 알림을 아직 읽지 않은 사람."""
    return {
        user_id
        for (user_id,) in db.query(Notification.user_id).filter(
            Notification.kind == K.ENTRY_CONFIRM_FAILED.value,
            Notification.entry_id == entry_id,
            Notification.read_at.is_(None),
        )
    }


def _insert_unless_unread_exists(db: Session, values: dict) -> Optional[int]:
    """INSERT ... ON CONFLICT DO NOTHING. 넣었으면 새 id, 이미 있었으면 None.

    IntegrityError 를 세이브포인트로 잡지 않는다 — 세이브포인트 롤백도 세션의 after_rollback 을 일으켜
    같은 세션에 쌓인 푸시(app/services/push.py)까지 버린다.
    """
    dialect = db.get_bind().dialect.name
    if dialect == "postgresql":
        from sqlalchemy.dialects.postgresql import insert
    elif dialect == "sqlite":
        from sqlalchemy.dialects.sqlite import insert
    else:
        raise RuntimeError(f"지원하지 않는 DB 다: {dialect}")
    stmt = insert(Notification).values(**values).on_conflict_do_nothing().returning(Notification.id)
    return db.execute(stmt).scalar_one_or_none()


def resolve_notifications(
    db: Session,
    *,
    entry_id: Optional[int] = None,
    budget_revision_request_id: Optional[int] = None,
) -> None:
    """처리된 건의 알림 중 재알림 대상 종류만 받는 사람 전원에게서 닫는다. commit 하지 않는다.

    확정·반려 같은 결과 통보는 닫지 않는다. 한 처리에서 create_notification 도 부르면 이 함수를 먼저 부른다 —
    순서가 바뀌면 방금 만든 다음 단계 알림(REVISION_PRESIDENT_SIGNED 등)까지 닫힌다.
    """
    if (entry_id is None) == (budget_revision_request_id is None):
        raise ValueError("entry_id 와 budget_revision_request_id 중 하나만 넘긴다")
    target = Notification.entry_id == entry_id if entry_id is not None else Notification.budget_revision_request_id == budget_revision_request_id
    db.execute(
        update(Notification)
        .where(target, Notification.kind.in_(NOTIFICATION_REMIND_KINDS), Notification.resolved_at.is_(None))
        .values(resolved_at=_now(), next_remind_at=None)
        .execution_options(synchronize_session=False)
    )


def student_topic(term_code: int) -> str:
    """학생 앱이 로그인할 때 구독하는 토픽. 학기 코드(YYYYS)다 — DB 의 Term.id 가 아니다."""
    return f"students_{term_code}"


def notify_students_confirmed(db: Session, entry_id: int) -> None:
    """확정된 항목을 그 학기 학생 전원에게 토픽으로 알린다 (금액과 사용처, 공개 정보). commit 된 뒤에 나간다."""
    entry = db.get(Entry, entry_id)
    if entry is None:
        raise ValueError(f"항목이 없다 (entry_id={entry_id})")
    term_code = _term_code(db, entry.term_id)
    message = push.PushMessage(push.TITLE, f"{_entry_label(entry)}이 확정되었습니다.", {"term_code": str(term_code), "entry_id": str(entry.id)})
    push.queue_job(db, push.TopicPush(student_topic(term_code), message))


def notify_students_balance_mismatch(db: Session, term_id: int) -> None:
    """계좌 대조에서 장부와 계좌 잔액이 다를 때 그 학기 학생 전원에게 알린다 (문승준, 계좌 대조). commit 된 뒤에 나간다."""
    term_code = _term_code(db, term_id)
    message = push.PushMessage(push.TITLE, "장부와 계좌 잔액이 다릅니다.", {"term_code": str(term_code)})
    push.queue_job(db, push.TopicPush(student_topic(term_code), message))


def _term_code(db: Session, term_id: int) -> int:
    term = db.get(Term, term_id)
    if term is None:
        raise ValueError(f"학기가 없다 (term_id={term_id})")
    return term.term_code


# ---------------------------------------------------------------- 받는 사람·문구


def _target(db: Session, kind: NotificationKind, entry_id: Optional[int], revision_id: Optional[int]):
    if entry_id is not None and revision_id is not None:
        raise ValueError(f"{kind.value}: entry_id 와 budget_revision_request_id 를 함께 넘길 수 없다")
    entry = revision = None
    if kind in _ENTRY_KINDS:
        if entry_id is None:
            raise ValueError(f"{kind.value} 는 entry_id 가 필요하다")
        entry = db.get(Entry, entry_id)
        if entry is None:
            raise ValueError(f"{kind.value}: 항목이 없다 (entry_id={entry_id})")
    elif kind in _REVISION_KINDS:
        if revision_id is None:
            raise ValueError(f"{kind.value} 는 budget_revision_request_id 가 필요하다")
        revision = db.get(BudgetRevisionRequest, revision_id)
        if revision is None:
            raise ValueError(f"{kind.value}: 증액 요청이 없다 (id={revision_id})")
    elif entry_id is not None or revision_id is not None:
        raise ValueError(f"{kind.value} 는 대상 건이 없는 알림이다")
    return entry, revision


def _recipients(db: Session, kind: NotificationKind, entry, revision, user_ids: Optional[Iterable[int]]) -> List[int]:
    if user_ids is not None:
        chosen = list(user_ids)
    elif kind in _EXPLICIT_KINDS:
        raise ValueError(f"{kind.value} 는 받는 사람(user_ids)을 넘긴다")
    else:
        chosen = []
        for who in _RECIPIENTS[kind]:
            if who == "registrant":
                chosen.append(entry.created_by if entry is not None else revision.requested_by)
            else:
                chosen.extend(user_id for (user_id,) in db.query(User.id).filter(User.role == who.value).order_by(User.id))
    return list(dict.fromkeys(chosen))  # 순서를 지키며 중복 제거 (등록자가 회장인 경우 등)


def _won(amount: int) -> str:
    return f"{amount:,}원"


def _short(text: str, limit: int = 30) -> str:
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _entry_label(entry: Entry) -> str:
    kind = "정정" if entry.corrects_entry_id is not None else ("수입" if entry.kind == "INCOME" else "지출")
    return f"{kind} 「{_short(entry.purpose)}」 {_won(entry.amount)}"


_BLOCK_REASONS = {
    "BUDGET_EXCEEDED": "예산 잔량을 넘어",
    "BUDGET_EXPIRED": "예산 마감이 지나",
    "BUDGET_NOT_FOUND": "연결된 예산이 없어",
}


def _body(kind: NotificationKind, entry: Optional[Entry], revision: Optional[BudgetRevisionRequest]) -> str:
    if entry is not None:
        label = _entry_label(entry)
        if kind is K.ENTRY_REGISTERED:
            return f"{label}이 등록되었습니다. 승인이 필요합니다."
        if kind is K.ENTRY_EDIT_REQUESTED:
            return f"총무가 {label}의 수정을 요청했습니다. 반려해 주세요."
        if kind is K.ENTRY_CONFIRMED:
            return f"{label}이 확정되었습니다."
        if kind is K.ENTRY_REJECTED:
            return f"{label}이 반려되었습니다."
        if kind is K.ENTRY_CONFIRM_FAILED:
            return f"{label}을 확정하지 못했습니다. 예산 잔량과 마감을 확인해 주세요."
        if kind is K.ENTRY_BLOCKED:
            reason = _BLOCK_REASONS.get(entry.block_reason or "", "예산 규칙에 맞지 않아")
            return f"{label}이 {reason} 차단되었습니다."
        if kind is K.RECLASSIFY_PAIR_UNCONFIRMED:
            return f"{label}의 재분류 짝이 아직 확정되지 않았습니다."
    if revision is not None:
        label = f"{_short(revision.category, 20)} 예산 증액 {_won(revision.requested_amount)}"
        if kind is K.REVISION_REQUESTED:
            return f"{label} 요청에 회장 서명이 필요합니다."
        if kind is K.REVISION_PRESIDENT_SIGNED:
            return f"회장이 {label} 요청에 서명했습니다. 감사 승인이 필요합니다."
        if kind is K.REVISION_APPROVED:
            return f"{label}이 승인되었습니다."
        if kind is K.REVISION_REJECTED:
            return f"{label}이 반려되었습니다."
        if kind is K.SIGNATURE_DEADLINE_NEAR:
            return f"{label} 요청의 회장 서명 시한이 곧 끝납니다. 시한 안에 승인해 주세요."
    if kind is K.ROLE_CHANGE_REQUESTED:
        return "롤 변경 서명 요청이 있습니다."
    if kind is K.PRESIDENT_RECOVERY_PROPOSED:
        return "회장 복구가 제안되었습니다."
    raise ValueError(f"{kind.value} 의 문구를 만들 수 없다")
