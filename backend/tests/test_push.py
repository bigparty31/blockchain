"""푸시 (app/services/push.py): commit 뒤에만 보내기, 기기 토큰, 무효 토큰 해제, 학생 토픽, 전송 스레드."""
import logging
import time
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.auth import users
from app.models import Base, DeviceToken, Entry, Term, User
from app.services import push
from app.services.notifications import NotificationKind, create_notification, notify_students_balance_mismatch, notify_students_confirmed

TREASURER, AUDITOR, PRESIDENT, AUDITOR2 = 2, 3, 4, 5
NOW = datetime.now(timezone.utc)


class Recorder:
    """전송 모듈 대역. 받은 것을 기록하고, 지정한 토큰은 무효라고 답한다."""

    def __init__(self, invalid=(), fail=False):
        self.tokens, self.topics, self.invalid, self.fail = [], [], list(invalid), fail

    def send_to_tokens(self, tokens, message):
        if self.fail:
            raise RuntimeError("FCM 응답 없음")
        self.tokens.append((sorted(tokens), message))
        return [t for t in tokens if t in self.invalid]

    def send_to_topic(self, topic, message):
        self.topics.append((topic, message))


@pytest.fixture
def factory(tmp_path):
    engine = create_engine(f"sqlite:///{tmp_path / 'push.db'}", connect_args={"check_same_thread": False})
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
        db.commit()  # 관계가 없어 한 번에 넣으면 외래키 순서가 보장되지 않는다
        db.add(Term(id=1, term_code=20262, name="2026-2", started_at=NOW - timedelta(days=60), ended_at=NOW + timedelta(days=90)))
        db.add(Entry(id=10, term_id=1, kind="EXPENSE", amount=35_000, counterparty="x", purpose="현수막", occurred_at=NOW, created_by=TREASURER, status="CONFIRMED"))
        db.commit()
        db.add(DeviceToken(user_id=AUDITOR, platform="android", token="auditor-phone"))
        db.add(DeviceToken(user_id=AUDITOR, platform="android", token="auditor-tablet"))
        db.add(DeviceToken(user_id=PRESIDENT, platform="android", token="president-old", revoked_at=NOW))
        db.commit()
    yield make
    engine.dispose()


def register(factory) -> None:
    with factory() as db:
        create_notification(db, NotificationKind.ENTRY_REGISTERED, entry_id=10)
        db.commit()


def test_notification_is_pushed_only_after_commit(factory):
    with factory() as db:
        create_notification(db, NotificationKind.ENTRY_REGISTERED, entry_id=10)
        db.flush()  # id 가 정해져도 commit 전에는 보내지 않는다
        assert push.drain(factory, Recorder()) == 0
        db.commit()
    sender = Recorder()
    assert push.drain(factory, sender) == 3  # 감사 2명, 회장
    # 감사 한 명의 기기 2대로 한 번에 보낸다. 해제된 회장 토큰과, 기기가 없는 감사에게는 보내지 않는다
    assert [tokens for tokens, _ in sender.tokens] == [["auditor-phone", "auditor-tablet"]]
    message = sender.tokens[0][1]
    assert message.title == push.TITLE and "현수막" in message.body
    assert message.data["kind"] == "ENTRY_REGISTERED" and message.data["entry_id"] == "10" and message.data["notification_id"].isdigit()


@pytest.mark.parametrize("flush", [False, True])
def test_rolled_back_notification_is_not_pushed(factory, flush):
    with factory() as db:
        create_notification(db, NotificationKind.ENTRY_REGISTERED, entry_id=10)
        if flush:
            db.flush()
        db.rollback()
        db.commit()  # 롤백 뒤 빈 commit 이 버린 것을 되살리지 않는다
    assert push.drain(factory, Recorder()) == 0


def test_unregistered_tokens_are_revoked(factory):
    register(factory)
    push.drain(factory, Recorder(invalid=["auditor-tablet"]))
    with factory() as db:
        active = {t.token for t in db.query(DeviceToken).filter(DeviceToken.revoked_at.is_(None))}
    assert active == {"auditor-phone"}


def test_send_failure_does_not_escape(factory, caplog):
    register(factory)
    with caplog.at_level(logging.ERROR):
        assert push.drain(factory, Recorder(fail=True)) == 3
    assert "푸시를 보내지 못했다" in caplog.text


def test_students_get_a_topic_push_without_rows(factory):
    with factory() as db:
        notify_students_confirmed(db, 10)
        notify_students_balance_mismatch(db, 1)
        db.commit()
    sender = Recorder()
    push.drain(factory, sender)
    assert [topic for topic, _ in sender.topics] == ["students_20262", "students_20262"]  # 학기 코드다. Term.id 가 아니다
    confirmed, mismatch = (message for _, message in sender.topics)
    assert confirmed.body == "지출 「현수막」 35,000원이 확정되었습니다." and confirmed.data == {"term_code": "20262", "entry_id": "10"}
    assert mismatch.body == "장부와 계좌 잔액이 다릅니다." and mismatch.data == {"term_code": "20262"}
    assert sender.tokens == []


def test_full_queue_drops_with_a_warning(caplog):
    job = push.TopicPush("students_20262", push.PushMessage(push.TITLE, "x"))
    for _ in range(push.QUEUE_SIZE):
        push._enqueue(job)
    with caplog.at_level(logging.WARNING):
        push._enqueue(job)
    assert "가득 차" in caplog.text


def test_dispatcher_thread_delivers_and_stops(factory, monkeypatch):
    sender = Recorder()
    monkeypatch.setattr(push, "_sender", sender)
    push.start_dispatcher(factory)
    try:
        register(factory)
        deadline = time.monotonic() + 5
        while not sender.tokens and time.monotonic() < deadline:
            time.sleep(0.01)
    finally:
        push.stop_dispatcher()
    assert sender.tokens and push._thread is None


def test_default_sender_only_logs(caplog):
    with caplog.at_level(logging.INFO):
        assert push.LoggingSender().send_to_tokens(["t"], push.PushMessage(push.TITLE, "본문")) == []
        push.LoggingSender().send_to_topic("students_20262", push.PushMessage(push.TITLE, "본문"))
    assert "전송 모듈 없음" in caplog.text


def test_session_without_pushes_is_untouched(factory):
    with factory() as db:
        db.get(Entry, 10)
        db.commit()
    assert push.drain(factory, Recorder()) == 0
