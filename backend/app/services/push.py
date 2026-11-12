"""FCM 푸시 (PRD §4.8, docs/NOTIFICATION_API.md 「푸시」).

보낼지 판정은 서버(알림 기록·확정·계좌 대조)가 하고, 이 모듈은 보내기만 한다.

- **commit 뒤에만 보낸다.** 보낼 것은 세션(session.info)에 모아 두고, commit 이 끝나면 전송 대기열에 넣는다.
  롤백되면 버린다 — 체인이 실패했는데 「확정됨」 푸시가 나가면 안 된다
- **전송은 전용 스레드 하나가 한다.** 요청 응답을 늦추지 않는다. 실패해도 처리 결과는 그대로다. 재시도하지 않는다 —
  알림 행은 이미 있으니 앱의 폴링이 받는다
- FCM 이 「등록되지 않은 토큰」으로 응답하면 그 토큰을 해제한다
- 실제 전송 모듈(FCM)은 장정아 담당이다. 앱이 시작할 때 set_sender 로 끼운다. 끼우기 전에는 로그만 남긴다
- 전송 모듈과 서비스 계정 키는 학생회 서버에만 둔다. 학생 서버는 이 모듈로 아무것도 보내지 않는다
"""
import logging
import queue
import threading
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable, Dict, List, Optional, Protocol, Union

from sqlalchemy import event, update
from sqlalchemy.orm import Session

from app.models import DeviceToken, Notification

logger = logging.getLogger(__name__)

TITLE = "학생회 회계"
QUEUE_SIZE = 1000  # 전송 스레드가 없거나 막혀도 메모리가 끝없이 늘지 않게 한다. 넘치면 버리고 경고한다


@dataclass(frozen=True)
class PushMessage:
    title: str
    body: str
    data: Dict[str, str] = field(default_factory=dict)  # FCM data 는 문자열 값만 받는다


class PushSender(Protocol):
    """FCM 전송 모듈의 모양 (장정아). 둘 다 블로킹 호출이고, 전송 스레드에서만 불린다."""

    def send_to_tokens(self, tokens: List[str], message: PushMessage) -> List[str]:
        """기기 토큰들로 보낸다. FCM 이 등록되지 않은 토큰이라고 응답한 것만 돌려준다 (서버가 해제한다)."""
        ...

    def send_to_topic(self, topic: str, message: PushMessage) -> None:
        """토픽(students_{학기 코드})으로 보낸다."""
        ...


class LoggingSender:
    """실제 전송 모듈을 끼우기 전의 기본값. 보내지 않고 로그만 남긴다."""

    def send_to_tokens(self, tokens: List[str], message: PushMessage) -> List[str]:
        logger.info("푸시(전송 모듈 없음) → 기기 %d대: %s", len(tokens), message.body)
        return []

    def send_to_topic(self, topic: str, message: PushMessage) -> None:
        logger.info("푸시(전송 모듈 없음) → 토픽 %s: %s", topic, message.body)


_sender: PushSender = LoggingSender()


def set_sender(sender: PushSender) -> None:
    """FCM 전송 모듈을 끼운다. 학생회 서버가 시작할 때 한 번 부른다."""
    global _sender
    _sender = sender


def get_sender() -> PushSender:
    return _sender


# ---------------------------------------------------------------- 보낼 것 (커밋 전)


@dataclass(frozen=True)
class UserPush:
    """임원 한 명의 기기 전부로 보낸다."""

    user_id: int
    message: PushMessage


@dataclass(frozen=True)
class TopicPush:
    topic: str
    message: PushMessage


Job = Union[UserPush, TopicPush]

_UNFLUSHED = "push_unflushed"  # 아직 id 가 없는 Notification. flush 뒤에 Job 으로 바꾼다
_READY = "push_ready"  # commit 되면 대기열에 넣을 Job


def notification_message(n: Notification) -> PushMessage:
    data = {"notification_id": str(n.id), "kind": n.kind}
    if n.entry_id is not None:
        data["entry_id"] = str(n.entry_id)
    if n.budget_revision_request_id is not None:
        data["budget_revision_request_id"] = str(n.budget_revision_request_id)
    return PushMessage(TITLE, n.body, data)


def queue_notification(db: Session, notification: Notification) -> None:
    """알림 행을 받는 사람의 기기로 보낸다. 같은 세션이 commit 되면 보낸다."""
    if notification.id is None:
        db.info.setdefault(_UNFLUSHED, []).append(notification)
    else:
        queue_job(db, UserPush(notification.user_id, notification_message(notification)))


def queue_job(db: Session, job: Job) -> None:
    """id 가 필요 없는 Job (토픽, 재알림). 같은 세션이 commit 되면 보낸다."""
    db.info.setdefault(_READY, []).append(job)


@event.listens_for(Session, "after_flush_postexec")
def _snapshot(session: Session, flush_context) -> None:
    # commit 뒤에는 SQL 을 낼 수 없어 속성을 읽지 못한다. id 가 정해진 flush 직후에 값만 옮겨 둔다
    pending = session.info.get(_UNFLUSHED)
    if not pending:
        return
    left = []
    for n in pending:
        if n.id is None:
            left.append(n)
        else:
            session.info.setdefault(_READY, []).append(UserPush(n.user_id, notification_message(n)))
    session.info[_UNFLUSHED] = left


@event.listens_for(Session, "after_commit")
def _release(session: Session) -> None:
    jobs = session.info.pop(_READY, [])
    session.info.pop(_UNFLUSHED, None)
    for job in jobs:
        _enqueue(job)


@event.listens_for(Session, "after_rollback")
def _discard(session: Session) -> None:
    session.info.pop(_READY, None)
    session.info.pop(_UNFLUSHED, None)


# ---------------------------------------------------------------- 대기열과 전송 스레드

_queue: "queue.Queue[Optional[Job]]" = queue.Queue(maxsize=QUEUE_SIZE)
_thread: Optional[threading.Thread] = None


def _enqueue(job: Job) -> None:
    try:
        _queue.put_nowait(job)
    except queue.Full:
        logger.warning("푸시 대기열이 가득 차 버린다 (%s). 앱은 폴링으로 받는다", job)


def deliver(job: Job, session_factory: Callable[[], Session], sender: Optional[PushSender] = None) -> None:
    """Job 하나를 보낸다. 어떤 실패도 밖으로 던지지 않는다 — 전송 실패는 처리 결과를 바꾸지 않는다."""
    sender = sender or _sender
    try:
        if isinstance(job, TopicPush):
            sender.send_to_topic(job.topic, job.message)
            return
        with session_factory() as db:
            tokens = [
                token
                for (token,) in db.query(DeviceToken.token).filter(
                    DeviceToken.user_id == job.user_id, DeviceToken.revoked_at.is_(None)
                )
            ]
        if not tokens:
            return  # 앱을 설치하지 않았거나 로그아웃했다. 폴링이 받는다
        invalid = sender.send_to_tokens(tokens, job.message)
        if invalid:
            _revoke(session_factory, invalid)
    except Exception:
        logger.exception("푸시를 보내지 못했다 (%s)", job)


def _revoke(session_factory: Callable[[], Session], tokens: List[str]) -> None:
    with session_factory() as db:
        db.execute(
            update(DeviceToken)
            .where(DeviceToken.token.in_(tokens), DeviceToken.revoked_at.is_(None))
            .values(revoked_at=datetime.now(timezone.utc))
            .execution_options(synchronize_session=False)
        )
        db.commit()


def drain(session_factory: Callable[[], Session], sender: Optional[PushSender] = None) -> int:
    """대기열에 있는 것을 지금 이 스레드에서 모두 보낸다. 시험용. 보낸 수를 돌려준다."""
    sent = 0
    while True:
        try:
            job = _queue.get_nowait()
        except queue.Empty:
            return sent
        if job is not None:
            deliver(job, session_factory, sender)
            sent += 1


def clear() -> None:
    """대기열을 비운다. 시험용."""
    while True:
        try:
            _queue.get_nowait()
        except queue.Empty:
            return


def start_dispatcher(session_factory: Callable[[], Session]) -> None:
    """전송 스레드를 띄운다. 이미 떠 있으면 그대로 둔다."""
    global _thread
    if _thread is not None and _thread.is_alive():
        return

    def run() -> None:
        while True:
            job = _queue.get()
            if job is None:
                return
            deliver(job, session_factory)

    _thread = threading.Thread(target=run, name="push-dispatcher", daemon=True)
    _thread.start()


def stop_dispatcher(timeout: float = 5.0) -> None:
    """남은 것을 보내고 전송 스레드를 멈춘다."""
    global _thread
    if _thread is None:
        return
    try:
        _queue.put(None, timeout=timeout)
    except queue.Full:
        logger.warning("푸시 대기열이 가득 차 전송 스레드에 종료를 알리지 못했다")
    _thread.join(timeout)
    _thread = None
