"""알림 기록 (app/services/notifications.py, docs/NOTIFICATION_API.md).

kind 이름, 받는 사람(§4.8 표), 문구, 재알림 시각, 닫기 범위, 확정 실패 중복 방지, 잘못된 호출을 본다.
"""
import re
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

from app.auth import users
from app.models import Base, BudgetRevisionRequest, Entry, Notification, Term, User
from app.services import notifications
from app.services.notifications import REMIND_KINDS, NotificationKind, create_notification, remind_interval, resolve_notifications

K = NotificationKind
STUDENT, TREASURER, AUDITOR, PRESIDENT, AUDITOR2 = 1, 2, 3, 4, 5
NOW = datetime(2026, 11, 7, 3, 0, tzinfo=timezone.utc)


def test_kinds_match_enums_doc():
    doc = (Path(__file__).parents[2] / "docs" / "enums.md").read_text(encoding="utf-8")
    section = doc.split("## notification kind", 1)[1].split("\n## ", 1)[0]
    assert re.findall(r"^\| `([A-Z_]+)` \|", section, re.MULTILINE) == [kind.value for kind in NotificationKind]


def test_remind_kinds_are_the_documented_five():
    assert REMIND_KINDS == {
        K.ENTRY_REGISTERED,
        K.ENTRY_EDIT_REQUESTED,
        K.REVISION_REQUESTED,
        K.REVISION_PRESIDENT_SIGNED,
        K.SIGNATURE_DEADLINE_NEAR,
    }


def test_migrated_db_accepts_every_kind_and_nothing_else(tmp_path):
    # 마이그레이션의 CHECK 는 손으로 적은 목록이다. NotificationKind 와 어긋나면 그 kind 는 저장할 때 터진다
    db_file = tmp_path / "migrated.db"
    config = Config(str(Path(__file__).parents[1] / "alembic.ini"))
    config.set_main_option("sqlalchemy.url", f"sqlite:///{db_file.as_posix()}")
    command.upgrade(config, "head")
    conn = sqlite3.connect(db_file)
    conn.execute("PRAGMA foreign_keys=OFF")
    for kind in NotificationKind:
        conn.execute("INSERT INTO notifications(user_id, kind, body) VALUES (1, ?, 'x')", (kind.value,))
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("INSERT INTO notifications(user_id, kind, body) VALUES (1, 'BOGUS', 'x')")
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("INSERT INTO notifications(user_id, kind, body, entry_id, budget_revision_request_id) VALUES (1, 'ENTRY_REGISTERED', 'x', 1, 1)")
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("INSERT INTO device_tokens(user_id, platform, token) VALUES (2, 'ios', 't')")
    conn.execute("INSERT INTO device_tokens(user_id, platform, token) VALUES (2, 'android', 't')")
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("INSERT INTO device_tokens(user_id, platform, token) VALUES (3, 'android', 't')")
    row = conn.execute("SELECT remind_count, created_at IS NOT NULL, notified_at IS NOT NULL FROM notifications LIMIT 1").fetchone()
    assert row == (0, 1, 1)
    conn.close()


# ---------------------------------------------------------------- DB


@pytest.fixture
def engine(tmp_path, monkeypatch):
    monkeypatch.setattr(notifications, "_now", lambda: NOW)
    monkeypatch.delenv("NOTIFICATION_REMIND_SECONDS", raising=False)
    engine = create_engine(f"sqlite:///{tmp_path / 'n.db'}")
    Base.metadata.create_all(engine)
    with Session(engine) as db:
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
        db.add(Term(id=1, term_code=20262, name="2026-2", started_at=NOW - timedelta(days=60), ended_at=NOW + timedelta(days=90)))
        db.add(
            Entry(
                id=10,
                term_id=1,
                kind="EXPENSE",
                amount=35_000,
                counterparty="문구점",
                purpose="  행사 현수막\n제작  ",
                occurred_at=NOW,
                created_by=TREASURER,
                status="PENDING",
            )
        )
        db.add(
            Entry(
                id=11,
                term_id=1,
                kind="EXPENSE",
                amount=2_000_000,
                counterparty="업체",
                purpose="축제 무대 설치",
                occurred_at=NOW,
                created_by=TREASURER,
                status="BLOCKED",
                block_reason="BUDGET_EXCEEDED",
            )
        )
        db.add(
            BudgetRevisionRequest(
                id=20,
                term_id=1,
                category="행사비",
                requested_amount=500_000,
                reason="축제 무대",
                requested_by=TREASURER,
            )
        )
        db.commit()
    yield engine
    engine.dispose()


def saved(engine, **target) -> list:
    """(받는 사람, kind, 닫혔나) — 받는 사람·종류 순."""
    with Session(engine) as db:
        rows = db.query(Notification).filter_by(**target).order_by(Notification.user_id, Notification.kind)
        return [(n.user_id, n.kind, n.resolved_at is not None) for n in rows]


def notify(engine, kind, **kwargs) -> None:
    with Session(engine) as db:
        create_notification(db, kind, **kwargs)
        db.commit()


@pytest.mark.parametrize(
    "kind, target, expected",
    [
        (K.ENTRY_REGISTERED, {"entry_id": 10}, [AUDITOR, PRESIDENT, AUDITOR2]),
        (K.ENTRY_EDIT_REQUESTED, {"entry_id": 10}, [AUDITOR, PRESIDENT, AUDITOR2]),
        (K.ENTRY_CONFIRMED, {"entry_id": 10}, [TREASURER]),
        (K.ENTRY_REJECTED, {"entry_id": 10}, [TREASURER]),
        (K.ENTRY_CONFIRM_FAILED, {"entry_id": 10}, [TREASURER]),
        (K.ENTRY_BLOCKED, {"entry_id": 11}, [TREASURER, PRESIDENT]),
        (K.REVISION_REQUESTED, {"budget_revision_request_id": 20}, [PRESIDENT]),
        (K.REVISION_PRESIDENT_SIGNED, {"budget_revision_request_id": 20}, [AUDITOR, AUDITOR2]),
        (K.REVISION_APPROVED, {"budget_revision_request_id": 20}, [TREASURER, PRESIDENT]),
        (K.REVISION_REJECTED, {"budget_revision_request_id": 20}, [TREASURER, PRESIDENT]),
        (K.SIGNATURE_DEADLINE_NEAR, {"budget_revision_request_id": 20}, [AUDITOR, AUDITOR2]),
        (K.PRESIDENT_RECOVERY_PROPOSED, {}, [AUDITOR, PRESIDENT, AUDITOR2]),
    ],
)
def test_recipients_follow_the_prd_table(engine, kind, target, expected):
    # 「총무」는 그 건의 등록자, 「감사」는 감사 전원이다. 학생은 받지 않는다
    notify(engine, kind, **target)
    assert sorted(user_id for user_id, _, _ in saved(engine, kind=kind.value)) == sorted(expected)


def test_explicit_recipients_are_used_as_given(engine):
    notify(engine, K.ROLE_CHANGE_REQUESTED, user_ids=[PRESIDENT, AUDITOR, PRESIDENT])
    notify(engine, K.RECLASSIFY_PAIR_UNCONFIRMED, entry_id=10, user_ids=[AUDITOR])
    assert saved(engine, kind="ROLE_CHANGE_REQUESTED") == [(AUDITOR, "ROLE_CHANGE_REQUESTED", False), (PRESIDENT, "ROLE_CHANGE_REQUESTED", False)]
    assert saved(engine, kind="RECLASSIFY_PAIR_UNCONFIRMED") == [(AUDITOR, "RECLASSIFY_PAIR_UNCONFIRMED", False)]


def test_body_is_made_from_the_target_and_saved(engine):
    notify(engine, K.ENTRY_REGISTERED, entry_id=10)
    notify(engine, K.ENTRY_BLOCKED, entry_id=11)
    notify(engine, K.REVISION_PRESIDENT_SIGNED, budget_revision_request_id=20)
    with Session(engine) as db:
        bodies = {n.kind: n.body for n in db.query(Notification)}
    assert bodies["ENTRY_REGISTERED"] == "지출 「행사 현수막 제작」 35,000원이 등록되었습니다. 승인이 필요합니다."
    assert bodies["ENTRY_BLOCKED"] == "지출 「축제 무대 설치」 2,000,000원이 예산 잔량을 넘어 차단되었습니다."
    assert bodies["REVISION_PRESIDENT_SIGNED"] == "회장이 행사비 예산 증액 500,000원 요청에 서명했습니다. 감사 승인이 필요합니다."


def test_every_kind_has_a_body(engine):
    for kind in NotificationKind:
        target = {"entry_id": 10} if kind in notifications._ENTRY_KINDS else {}
        if kind in notifications._REVISION_KINDS:
            target = {"budget_revision_request_id": 20}
        if kind in notifications._EXPLICIT_KINDS:
            target["user_ids"] = [AUDITOR]
        notify(engine, kind, **target)
    with Session(engine) as db:
        assert {n.kind for n in db.query(Notification) if n.body} == {kind.value for kind in NotificationKind}


def test_only_remind_kinds_are_scheduled(engine):
    notify(engine, K.ENTRY_REGISTERED, entry_id=10)
    notify(engine, K.ENTRY_CONFIRMED, entry_id=10)
    with Session(engine) as db:
        schedule = {n.kind: (n.remind_count, n.next_remind_at, n.created_at, n.notified_at) for n in db.query(Notification)}
    plain = lambda value: value.replace(tzinfo=None)  # SQLite 는 시간대 없이 돌려준다
    assert schedule["ENTRY_REGISTERED"] == (0, plain(NOW + timedelta(hours=24)), plain(NOW), plain(NOW))
    assert schedule["ENTRY_CONFIRMED"] == (0, None, plain(NOW), plain(NOW))


def test_remind_interval_is_a_setting(monkeypatch):
    monkeypatch.setenv("NOTIFICATION_REMIND_SECONDS", "90")
    assert remind_interval() == timedelta(seconds=90)
    for bad in ("0", "-5", "1.5", "하루"):
        monkeypatch.setenv("NOTIFICATION_REMIND_SECONDS", bad)
        with pytest.raises(ValueError, match="NOTIFICATION_REMIND_SECONDS"):
            remind_interval()


def test_resolving_closes_only_remind_kinds_of_that_target(engine):
    notify(engine, K.ENTRY_REGISTERED, entry_id=10)
    notify(engine, K.ENTRY_EDIT_REQUESTED, entry_id=10)
    notify(engine, K.ENTRY_CONFIRMED, entry_id=10)
    notify(engine, K.ENTRY_BLOCKED, entry_id=11)
    notify(engine, K.REVISION_REQUESTED, budget_revision_request_id=20)
    with Session(engine) as db:
        resolve_notifications(db, entry_id=10)
        db.commit()
    closed = {(kind, done) for _, kind, done in saved(engine)}
    assert closed == {
        ("ENTRY_REGISTERED", True),
        ("ENTRY_EDIT_REQUESTED", True),
        ("ENTRY_CONFIRMED", False),  # 결과 통보는 처리할 일이 아니라 남는다
        ("ENTRY_BLOCKED", False),
        ("REVISION_REQUESTED", False),  # 다른 건
    }
    with Session(engine) as db:
        assert all(n.next_remind_at is None for n in db.query(Notification).filter(Notification.resolved_at.isnot(None)))


def test_resolving_first_keeps_the_next_step_open(engine):
    # 회장 서명: REVISION_REQUESTED 를 닫고 REVISION_PRESIDENT_SIGNED 를 만든다. 순서가 바뀌면 방금 만든 것까지 닫힌다
    notify(engine, K.REVISION_REQUESTED, budget_revision_request_id=20)
    with Session(engine) as db:
        resolve_notifications(db, budget_revision_request_id=20)
        create_notification(db, K.REVISION_PRESIDENT_SIGNED, budget_revision_request_id=20)
        db.commit()
    assert {(kind, done) for _, kind, done in saved(engine)} == {("REVISION_REQUESTED", True), ("REVISION_PRESIDENT_SIGNED", False)}


def test_deleting_the_target_removes_its_notifications(engine):
    # 알림은 파생 데이터라 본 데이터 삭제를 막지 않는다 (예: 예산 발행이 시드 더미 증액 요청을 지울 때)
    notify(engine, K.REVISION_REQUESTED, budget_revision_request_id=20)
    notify(engine, K.ENTRY_REGISTERED, entry_id=10)
    with Session(engine) as db:
        db.delete(db.get(BudgetRevisionRequest, 20))
        db.commit()
    assert {kind for _, kind, _ in saved(engine)} == {"ENTRY_REGISTERED"}


def test_confirm_failure_is_not_repeated_while_unread(engine):
    notify(engine, K.ENTRY_CONFIRM_FAILED, entry_id=10)
    notify(engine, K.ENTRY_CONFIRM_FAILED, entry_id=10)
    assert len(saved(engine, kind="ENTRY_CONFIRM_FAILED")) == 1
    with Session(engine) as db:
        db.query(Notification).update({"read_at": NOW})
        db.commit()
    notify(engine, K.ENTRY_CONFIRM_FAILED, entry_id=10)
    assert len(saved(engine, kind="ENTRY_CONFIRM_FAILED")) == 2


def test_nothing_is_written_until_the_caller_commits(engine):
    with Session(engine) as db:
        create_notification(db, K.ENTRY_REGISTERED, entry_id=10)
        db.rollback()
    assert saved(engine) == []


def test_no_recipient_writes_nothing(engine, caplog):
    with Session(engine) as db:
        db.query(User).filter(User.role == "PRESIDENT").update({"role": "AUDITOR"})
        db.commit()
    notify(engine, K.REVISION_REQUESTED, budget_revision_request_id=20)
    assert saved(engine) == [] and "받을 사람이 없다" in caplog.text


@pytest.mark.parametrize(
    "kind, kwargs, message",
    [
        (K.ENTRY_REGISTERED, {}, "entry_id 가 필요하다"),
        (K.ENTRY_REGISTERED, {"entry_id": 999}, "항목이 없다"),
        (K.REVISION_REQUESTED, {"entry_id": 10}, "budget_revision_request_id 가 필요하다"),
        (K.REVISION_REQUESTED, {"budget_revision_request_id": 999}, "증액 요청이 없다"),
        (K.ENTRY_REGISTERED, {"entry_id": 10, "budget_revision_request_id": 20}, "함께 넘길 수 없다"),
        (K.ROLE_CHANGE_REQUESTED, {}, "user_ids"),
        (K.ROLE_CHANGE_REQUESTED, {"entry_id": 10, "user_ids": [AUDITOR]}, "대상 건이 없는"),
        (K.RECLASSIFY_PAIR_UNCONFIRMED, {"entry_id": 10}, "user_ids"),
        ("NOT_A_KIND", {"entry_id": 10}, "NOT_A_KIND"),
    ],
)
def test_wrong_calls_fail_loudly(engine, kind, kwargs, message):
    with Session(engine) as db:
        with pytest.raises(ValueError, match=message):
            create_notification(db, kind, **kwargs)


@pytest.mark.parametrize("kwargs", [{}, {"entry_id": 10, "budget_revision_request_id": 20}])
def test_resolving_needs_exactly_one_target(engine, kwargs):
    with Session(engine) as db:
        with pytest.raises(ValueError, match="하나만"):
            resolve_notifications(db, **kwargs)
