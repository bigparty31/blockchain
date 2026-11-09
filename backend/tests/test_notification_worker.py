"""재알림 작업 (app/services/notification_worker.py): 재알림, 서명 시한 임박, 서명 시한 만료 정리, 주기 실행."""
import asyncio
import time
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.auth import users
from app.models import Base, BudgetRevisionRequest, Entry, Notification, Term, User
from app.services import notification_worker as worker
from app.services import notifications, push
from app.services.notifications import NotificationKind, create_notification

K = NotificationKind
TREASURER, AUDITOR, PRESIDENT, AUDITOR2 = 2, 3, 4, 5
T0 = datetime.now(timezone.utc).replace(microsecond=0)
DAY = timedelta(hours=24)


@pytest.fixture
def factory(tmp_path, monkeypatch):
    monkeypatch.delenv("NOTIFICATION_REMIND_SECONDS", raising=False)
    monkeypatch.delenv("NOTIFICATION_DEADLINE_NEAR_SECONDS", raising=False)
    monkeypatch.setattr(notifications, "_now", lambda: T0)
    engine = create_engine(f"sqlite:///{tmp_path / 'worker.db'}", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    make = sessionmaker(bind=engine, autoflush=False)
    with make() as db:
        for u in users.SEED_USERS:
            db.add(
                User(
                    id=u.id,
                    student_no=u.student_no,
                    password_hash=u.password_hash,
                    name=u.name,
                    role=u.role.value,
                    wallet_index=u.wallet_index,
                    wallet_address=u.wallet_address.lower() if u.wallet_address else None,
                )
            )
        db.commit()
        db.add(Term(id=1, term_code=20262, name="2026-2", started_at=T0 - timedelta(days=60), ended_at=T0 + timedelta(days=90)))
        db.commit()
        db.add(Entry(id=10, term_id=1, kind="EXPENSE", amount=35_000, counterparty="x", purpose="현수막", occurred_at=T0, created_by=TREASURER, status="PENDING"))
        db.commit()
    yield make
    engine.dispose()


def rows(factory, **target):
    with factory() as db:
        return db.query(Notification).filter_by(**target).order_by(Notification.user_id).all()


def registered(factory) -> None:
    with factory() as db:
        create_notification(db, K.ENTRY_REGISTERED, entry_id=10)
        create_notification(db, K.ENTRY_CONFIRMED, entry_id=10)  # 결과 통보는 재알림하지 않는다
        db.commit()
    push.clear()


def naive(value: datetime) -> datetime:
    return value.replace(tzinfo=None)  # SQLite 는 시간대 없이 돌려준다


# ---------------------------------------------------------------- 재알림


def test_nothing_is_reminded_before_24_hours(factory):
    registered(factory)
    assert worker.remind(factory, T0 + DAY - timedelta(seconds=1)) == 0


def test_reminder_reopens_and_moves_up(factory):
    registered(factory)
    with factory() as db:
        db.query(Notification).update({"read_at": T0 + timedelta(hours=1)})
        db.commit()
    assert worker.remind(factory, T0 + DAY) == 3  # 감사 2명, 회장
    for n in rows(factory, kind="ENTRY_REGISTERED"):
        assert (n.read_at, n.remind_count, n.notified_at, n.next_remind_at) == (None, 1, naive(T0 + DAY), naive(T0 + 2 * DAY))
    assert all(n.read_at is not None for n in rows(factory, kind="ENTRY_CONFIRMED"))
    assert push.drain(factory) == 3  # 기기로도 다시 보낸다


def test_running_twice_reminds_once(factory):
    registered(factory)
    assert worker.remind(factory, T0 + DAY) == 3
    assert worker.remind(factory, T0 + DAY) == 0


def test_at_most_three_reminders(factory):
    registered(factory)
    for day in (1, 2, 3):
        assert worker.remind(factory, T0 + day * DAY) == 3
    assert all((n.remind_count, n.next_remind_at) == (3, None) for n in rows(factory, kind="ENTRY_REGISTERED"))
    assert worker.remind(factory, T0 + 10 * DAY) == 0


def test_handled_notifications_are_not_reminded(factory):
    registered(factory)
    with factory() as db:
        notifications.resolve_notifications(db, entry_id=10)
        db.commit()
    assert worker.remind(factory, T0 + DAY) == 0


def test_interval_is_a_setting(factory, monkeypatch):
    monkeypatch.setenv("NOTIFICATION_REMIND_SECONDS", "60")  # 시연값
    registered(factory)
    assert worker.remind(factory, T0 + timedelta(seconds=60)) == 3


# ---------------------------------------------------------------- 서명 시한


REJECTED = {"status": "REJECTED", "resolved_by": AUDITOR, "resolved_at": T0, "reject_reason": "근거 부족"}


def signed_revision(factory, deadline: datetime, revision_id: int = 20, tx_increase=None) -> int:
    with factory() as db:
        db.add(
            BudgetRevisionRequest(
                id=revision_id,
                term_id=1,
                category="행사비",
                requested_amount=500_000,
                reason="축제",
                requested_by=TREASURER,
                status="PRESIDENT_SIGNED",
                president_signed_by=PRESIDENT,
                president_signature="0x" + "11" * 65,
                president_signed_at=T0,
                signature_deadline=int(deadline.timestamp()),
                signed_version=1,
                tx_increase=tx_increase,
            )
        )
        db.commit()
    return revision_id


def test_auditors_hear_once_when_the_deadline_is_near(factory):
    revision_id = signed_revision(factory, T0 + timedelta(hours=5))
    assert worker.notify_deadline_near(factory, T0) == 1
    assert [n.user_id for n in rows(factory, kind="SIGNATURE_DEADLINE_NEAR")] == [AUDITOR, AUDITOR2]
    assert worker.notify_deadline_near(factory, T0 + timedelta(hours=1)) == 0
    assert rows(factory, budget_revision_request_id=revision_id)[0].body.endswith("시한 안에 승인해 주세요.")


@pytest.mark.parametrize(
    "deadline, tx_increase",
    [
        (T0 + timedelta(hours=7), None),  # 아직 멀다
        (T0 - timedelta(minutes=1), None),  # 이미 지났다 — 만료 정리가 맡는다
        (T0 + timedelta(hours=1), "0x" + "ab" * 32),  # 증액이 이미 나갔다
    ],
)
def test_no_deadline_notice(factory, deadline, tx_increase):
    signed_revision(factory, deadline, tx_increase=tx_increase)
    assert worker.notify_deadline_near(factory, T0) == 0


@pytest.mark.parametrize(
    "change",
    [
        REJECTED,  # 감사가 반려했다
        {"tx_increase": "0x" + "cd" * 32},  # 감사가 승인해 증액이 나갔다
        {"status": "PENDING", "signature_deadline": None},  # 시한 만료로 되돌아갔다
        None,  # 시드 정리로 지워졌다
    ],
)
def test_no_deadline_notice_when_the_request_ends_after_it_was_picked(factory, monkeypatch, change):
    # 후보를 고른 뒤 알림을 만들기 전에 다른 요청이 그 건을 끝내고 커밋한 경우. 끝난 건에 열린 임박 알림이 남으면 재알림까지 간다
    revision_id = signed_revision(factory, T0 + timedelta(hours=5))
    pick = worker._deadline_candidates

    def picked_then_changed(db, now_ts, until):
        candidates = pick(db, now_ts, until)
        with factory() as other:
            if change is None:
                other.delete(other.get(BudgetRevisionRequest, revision_id))
            else:
                other.query(BudgetRevisionRequest).filter_by(id=revision_id).update(change)
                notifications.resolve_notifications(other, budget_revision_request_id=revision_id)
            other.commit()
        return candidates

    monkeypatch.setattr(worker, "_deadline_candidates", picked_then_changed)
    assert worker.notify_deadline_near(factory, T0) == 0
    assert rows(factory, kind="SIGNATURE_DEADLINE_NEAR") == []


def test_deadline_notice_goes_on_for_the_other_requests(factory, monkeypatch):
    # 한 건이 중간에 끝나도 다른 건은 알린다
    signed_revision(factory, T0 + timedelta(hours=5), revision_id=20)
    signed_revision(factory, T0 + timedelta(hours=4), revision_id=21)
    pick = worker._deadline_candidates

    def picked_then_rejected(db, now_ts, until):
        candidates = pick(db, now_ts, until)
        with factory() as other:
            other.query(BudgetRevisionRequest).filter_by(id=20).update(REJECTED)
            other.commit()
        return candidates

    monkeypatch.setattr(worker, "_deadline_candidates", picked_then_rejected)
    assert worker.notify_deadline_near(factory, T0) == 1
    assert {n.budget_revision_request_id for n in rows(factory, kind="SIGNATURE_DEADLINE_NEAR")} == {21}


def test_threshold_is_a_setting(factory, monkeypatch):
    monkeypatch.setenv("NOTIFICATION_DEADLINE_NEAR_SECONDS", str(8 * 3600))
    signed_revision(factory, T0 + timedelta(hours=7))
    assert worker.notify_deadline_near(factory, T0) == 1


def test_expired_signature_goes_back_to_the_president(factory):
    # 만료 판정은 김경윤 님 함수가 실제 시각으로 한다. 실제로 지난 시한을 준다
    now = datetime.now(timezone.utc)
    revision_id = signed_revision(factory, now - timedelta(minutes=1))
    with factory() as db:
        create_notification(db, K.SIGNATURE_DEADLINE_NEAR, budget_revision_request_id=revision_id)
        db.commit()
    assert worker.expire_signatures(factory, now) == 1
    with factory() as db:
        revision = db.get(BudgetRevisionRequest, revision_id)
        assert (revision.status, revision.president_signature, revision.signature_deadline) == ("PENDING", None, None)
    assert all(n.resolved_at is not None for n in rows(factory, kind="SIGNATURE_DEADLINE_NEAR"))
    assert [n.user_id for n in rows(factory, kind="REVISION_REQUESTED")] == [PRESIDENT]  # 재서명 요청
    assert worker.expire_signatures(factory, now) == 0


def test_increase_in_flight_is_not_rolled_back(factory):
    now = datetime.now(timezone.utc)
    revision_id = signed_revision(factory, now - timedelta(minutes=1), tx_increase="0x" + "ab" * 32)
    assert worker.expire_signatures(factory, now) == 0
    with factory() as db:
        assert db.get(BudgetRevisionRequest, revision_id).status == "PRESIDENT_SIGNED"


# ---------------------------------------------------------------- 주기 실행


def test_one_failing_step_does_not_stop_the_others(factory, monkeypatch):
    registered(factory)

    def broken(*args):
        raise RuntimeError("단계 실패")

    monkeypatch.setattr(worker, "notify_deadline_near", broken)
    assert worker.run_once(factory, T0 + DAY) == {"reminded": 3, "deadline_near": -1, "expired": 0}


def test_loop_keeps_going_after_a_failure(monkeypatch):
    calls = []

    def run_once(session_factory):
        calls.append(1)
        if len(calls) == 1:
            raise RuntimeError("첫 주기 실패")

    monkeypatch.setattr(worker, "run_once", run_once)
    monkeypatch.setattr(worker, "tick_seconds", lambda: 0)

    async def body():
        task = asyncio.create_task(worker.run_forever(lambda: None))
        while len(calls) < 3:
            await asyncio.sleep(0.01)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    asyncio.run(asyncio.wait_for(body(), timeout=5))


@pytest.mark.parametrize(
    "name, value",
    [
        ("NOTIFICATION_WORKER", "yes"),
        ("NOTIFICATION_TICK_SECONDS", "0"),
        ("NOTIFICATION_DEADLINE_NEAR_SECONDS", "6h"),
        ("NOTIFICATION_REMIND_SECONDS", "-1"),
    ],
)
def test_wrong_settings_stop_the_server_from_starting(monkeypatch, name, value):
    monkeypatch.setenv(name, value)
    with pytest.raises(ValueError, match=name):
        worker.check_config()


def test_empty_settings_use_the_defaults(monkeypatch):
    # .env.example 을 그대로 복사하면 빈 값이 들어온다. 서버가 떠야 한다
    for name in ("NOTIFICATION_WORKER", "NOTIFICATION_REMIND_SECONDS", "NOTIFICATION_TICK_SECONDS", "NOTIFICATION_DEADLINE_NEAR_SECONDS"):
        monkeypatch.setenv(name, "")
    worker.check_config()
    assert worker.enabled() and worker.tick_seconds() == 60 and worker.deadline_near() == timedelta(hours=6)
    assert notifications.remind_interval() == DAY


def test_disabled_worker_starts_nothing(monkeypatch):
    monkeypatch.setenv("NOTIFICATION_WORKER", "0")
    assert worker.start(lambda: None) is None


def test_app_starts_and_stops_the_worker(monkeypatch):
    # 학생회 서버(main.py)는 시작할 때 작업과 전송 스레드를 띄우고, 끝날 때 멈춘다
    from app.main import app

    ran = []
    monkeypatch.setenv("NOTIFICATION_WORKER", "1")
    monkeypatch.setenv("CHAIN_FAKE", "1")
    monkeypatch.delenv("CHAIN_RPC_URL", raising=False)
    monkeypatch.setattr(worker, "run_once", lambda session_factory: ran.append(1))
    with TestClient(app):
        deadline = time.monotonic() + 5
        while not ran and time.monotonic() < deadline:
            time.sleep(0.01)
        assert ran and push._thread is not None and push._thread.is_alive()
    assert push._thread is None
