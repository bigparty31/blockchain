"""재알림 작업 (PRD §4.1, §4.8, docs/NOTIFICATION_API.md 「재알림과 읽음」).

API 프로세스 안에서 돈다 (§4.8 — 릴레이어 때문에 워커가 어차피 하나다). 별도 크론·스케줄러는 두지 않는다.
학생회 서버에서만 켠다. 학생 서버는 읽기 전용 DB 라 켜지 않는다 (NOTIFICATION_WORKER=0).

한 번 돌 때(run_once) 하는 일:
1. 재알림 — next_remind_at 이 지난 열린 알림을 다시 알린다. 읽음을 비우고 remind_count 를 올리고 notified_at 을 갱신한다.
   최대 3회이고, 3회째에 next_remind_at 을 비운다. 기기로도 다시 푸시한다
2. 서명 시한 임박 — 회장 서명(PRESIDENT_SIGNED) 뒤 시한이 NOTIFICATION_DEADLINE_NEAR_SECONDS(기본 6시간) 안으로 들어온
   증액 요청을 감사 전원에게 한 번 알린다
3. 서명 시한 만료 정리 — 시한이 지난 PRESIDENT_SIGNED 를 PENDING 으로 되돌리고 회장에게 재서명을 알린다 (§4.1).
   김경윤 님의 expire_budget_revision_if_needed 를 그대로 부른다 (Lazy Update 와 같은 함수)

어느 단계든 조건부 UPDATE·존재 확인으로 반영하므로 두 번 돌아도 한 번만 반영된다.
한 단계가 실패해도 다음 단계와 다음 주기는 돈다 — 실패는 로그로 남긴다.
"""
import asyncio
import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Callable, Dict, Optional

from sqlalchemy import update
from sqlalchemy.orm import Session

from app.models import BudgetRevisionRequest, Notification
from app.services import push
from app.services.notifications import NotificationKind, create_notification, remind_interval

logger = logging.getLogger(__name__)

MAX_REMINDS = 3  # §4.8 「이후 24시간마다 최대 3회」
PRESIDENT_SIGNED = "PRESIDENT_SIGNED"

_ENABLED_ENV = "NOTIFICATION_WORKER"
_TICK_ENV = "NOTIFICATION_TICK_SECONDS"
_NEAR_ENV = "NOTIFICATION_DEADLINE_NEAR_SECONDS"


def _seconds(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        raise ValueError(f"{name} 는 초 단위 양의 정수여야 합니다: {raw!r}") from None
    if value <= 0:
        raise ValueError(f"{name} 는 초 단위 양의 정수여야 합니다: {raw!r}")
    return value


def tick_seconds() -> int:
    """작업이 도는 간격. 기본 60초."""
    return _seconds(_TICK_ENV, 60)


def deadline_near() -> timedelta:
    """서명 시한까지 이만큼 남으면 감사에게 알린다. 기본 6시간. 시연에서는 줄인다."""
    return timedelta(seconds=_seconds(_NEAR_ENV, 6 * 3600))


def enabled() -> bool:
    raw = os.environ.get(_ENABLED_ENV, "").strip() or "1"  # .env.example 을 복사한 빈 값은 기본(켬)이다
    if raw not in ("0", "1"):
        raise ValueError(f"{_ENABLED_ENV} 는 1(켬) 또는 0(끔)이어야 합니다: {raw!r}")
    return raw == "1"


def check_config() -> None:
    """서버가 뜰 때 설정을 미리 확인한다. 틀린 값으로 떠서 작업만 조용히 죽는 일을 막는다."""
    enabled()
    tick_seconds()
    deadline_near()
    remind_interval()


# ---------------------------------------------------------------- 한 번 돌기


def run_once(session_factory: Callable[[], Session], now: Optional[datetime] = None) -> Dict[str, int]:
    """세 단계를 한 번 돌린다. 단계마다 반영한 건수를 돌려준다."""
    now = now or datetime.now(timezone.utc)
    counts = {}
    for name, step in (("reminded", remind), ("deadline_near", notify_deadline_near), ("expired", expire_signatures)):
        try:
            counts[name] = step(session_factory, now)
        except Exception:
            logger.exception("재알림 작업 %s 단계가 실패했다", name)
            counts[name] = -1
    return counts


def remind(session_factory: Callable[[], Session], now: datetime) -> int:
    interval = remind_interval()
    reminded = 0
    with session_factory() as db:
        due = (
            db.query(Notification)
            .filter(Notification.next_remind_at <= now, Notification.resolved_at.is_(None))
            .order_by(Notification.id)
            .all()
        )
        for n in due:
            count = n.remind_count + 1
            rows = db.execute(
                update(Notification)
                .where(
                    Notification.id == n.id,
                    Notification.next_remind_at == n.next_remind_at,  # 다른 실행이 먼저 했으면 0행
                    Notification.resolved_at.is_(None),
                )
                .values(
                    read_at=None,
                    remind_count=count,
                    notified_at=now,
                    next_remind_at=now + interval if count < MAX_REMINDS else None,
                )
                .execution_options(synchronize_session=False)
            ).rowcount
            if rows == 1:
                push.queue_job(db, push.UserPush(n.user_id, push.notification_message(n)))
                reminded += 1
        db.commit()
    return reminded


def notify_deadline_near(session_factory: Callable[[], Session], now: datetime) -> int:
    now_ts = int(now.timestamp())
    until = now_ts + int(deadline_near().total_seconds())
    created = 0
    with session_factory() as db:
        revisions = (
            db.query(BudgetRevisionRequest)
            .filter(
                BudgetRevisionRequest.status == PRESIDENT_SIGNED,
                BudgetRevisionRequest.signature_deadline > now_ts,
                BudgetRevisionRequest.signature_deadline <= until,
                BudgetRevisionRequest.tx_increase.is_(None),
            )
            .order_by(BudgetRevisionRequest.id)
            .all()
        )
        for revision in revisions:
            # 열린 임박 알림이 있으면 이미 알렸다. 시한 만료로 되돌아가면 닫히므로, 다시 서명하면 새로 알린다
            open_notice = (
                db.query(Notification.id)
                .filter(
                    Notification.kind == NotificationKind.SIGNATURE_DEADLINE_NEAR.value,
                    Notification.budget_revision_request_id == revision.id,
                    Notification.resolved_at.is_(None),
                )
                .first()
            )
            if open_notice is None:
                create_notification(db, NotificationKind.SIGNATURE_DEADLINE_NEAR, budget_revision_request_id=revision.id)
                created += 1
        db.commit()
    return created


def expire_signatures(session_factory: Callable[[], Session], now: datetime) -> int:
    # 라우터의 Lazy Update 와 같은 함수를 쓴다. 판정 시각은 그 함수가 직접 읽는다 (now 인자는 후보를 고르는 데만 쓴다)
    from app.routers.budget_revisions import expire_budget_revision_if_needed

    now_ts = int(now.timestamp())
    with session_factory() as db:
        ids = [
            revision_id
            for (revision_id,) in db.query(BudgetRevisionRequest.id).filter(
                BudgetRevisionRequest.status == PRESIDENT_SIGNED,
                BudgetRevisionRequest.signature_deadline <= now_ts,
                BudgetRevisionRequest.tx_increase.is_(None),
            )
        ]
    expired = 0
    for revision_id in ids:
        with session_factory() as db:
            revision = db.get(BudgetRevisionRequest, revision_id)
            if revision is not None and expire_budget_revision_if_needed(revision, db):  # 되돌리면 그 함수가 commit 한다
                expired += 1
    return expired


# ---------------------------------------------------------------- 주기 실행


async def run_forever(session_factory: Callable[[], Session]) -> None:
    """tick_seconds 마다 run_once 를 스레드에서 돌린다. 취소될 때까지 돈다."""
    tick = tick_seconds()
    while True:
        try:
            await asyncio.to_thread(run_once, session_factory)
        except Exception:
            logger.exception("재알림 작업이 실패했다. 다음 주기에 다시 돈다")
        await asyncio.sleep(tick)


def start(session_factory: Callable[[], Session]) -> Optional[asyncio.Task]:
    """푸시 전송 스레드와 재알림 작업을 띄운다. NOTIFICATION_WORKER=0 이면 아무것도 하지 않는다."""
    if not enabled():
        logger.info("NOTIFICATION_WORKER=0: 재알림 작업과 푸시 전송을 켜지 않는다")
        return None
    push.start_dispatcher(session_factory)
    return asyncio.create_task(run_forever(session_factory), name="notification-worker")


async def stop(task: Optional[asyncio.Task]) -> None:
    if task is None:
        return
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass
    await asyncio.to_thread(push.stop_dispatcher)
