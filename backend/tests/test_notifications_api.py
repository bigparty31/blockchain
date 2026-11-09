"""알림 API (app/routers/notifications.py, docs/NOTIFICATION_API.md §1~5)."""
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.auth import users
from app.database import Base, get_db
from app.main import app
from app.models import DeviceToken, Entry, Notification, Term, User
from app.schemas.auth import Role

client = TestClient(app)

TREASURER, AUDITOR, PRESIDENT = 2, 3, 4
NOW = datetime.now(timezone.utc).replace(microsecond=0)

_session = None


@pytest.fixture(autouse=True)
def setup(tmp_path):
    global _session
    engine = create_engine(f"sqlite:///{tmp_path / 'api.db'}", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    _session = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    with _session() as db:
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
        db.add(Entry(id=10, term_id=1, kind="INCOME", amount=1000, counterparty="x", purpose="p", occurred_at=NOW, created_by=TREASURER))
        db.commit()

    def override():
        db = _session()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override
    yield
    app.dependency_overrides.pop(get_db, None)
    engine.dispose()


def add(user_id: int, body: str, minutes_ago: int, read: bool = False, resolved: bool = False, kind: str = "ENTRY_REGISTERED") -> int:
    at = NOW - timedelta(minutes=minutes_ago)
    with _session() as db:
        n = Notification(
            user_id=user_id,
            kind=kind,
            entry_id=10,
            body=body,
            created_at=at,
            notified_at=at,
            read_at=at if read else None,
            resolved_at=at if resolved else None,
        )
        db.add(n)
        db.commit()
        return n.id


def bodies(response) -> list:
    assert response.status_code == 200, response.text
    return [n["body"] for n in response.json()]


# ---------------------------------------------------------------- 권한


@pytest.mark.parametrize(
    "method, path",
    [
        ("get", "/notifications"),
        ("get", "/notifications/unread-count"),
        ("post", "/notifications/1/read"),
        ("delete", "/notifications/device-tokens/abc"),
    ],
)
def test_students_and_anonymous_are_refused(auth_header, method, path):
    # 학생에게는 알림 행이 없다 (학생은 토픽 푸시만). 학생회 서버는 학생 토큰을 받지 않는다
    assert getattr(client, method)(path).status_code == 401
    assert getattr(client, method)(path, headers=auth_header(Role.STUDENT)).status_code == 403
    response = client.post("/notifications/device-tokens", json={"platform": "android", "token": "t"}, headers=auth_header(Role.STUDENT))
    assert response.status_code == 403


# ---------------------------------------------------------------- 목록·안 읽은 수


def test_list_puts_unread_first_then_latest_notified(auth_header):
    add(AUDITOR, "읽음-최근", 1, read=True)
    add(AUDITOR, "안읽음-오래됨", 30)
    add(AUDITOR, "안읽음-최근", 5)
    add(AUDITOR, "닫힘", 2, resolved=True)  # 다른 승인자가 처리한 건은 빠진다
    add(PRESIDENT, "회장 것", 0)  # 남의 알림은 안 보인다
    response = client.get("/notifications", headers=auth_header(Role.AUDITOR))
    assert bodies(response) == ["안읽음-최근", "안읽음-오래됨", "읽음-최근"]
    first = response.json()[0]
    assert set(first) == {"id", "kind", "entry_id", "budget_revision_request_id", "body", "created_at", "notified_at", "read_at", "remind_count"}
    assert first["kind"] == "ENTRY_REGISTERED" and first["entry_id"] == 10 and first["read_at"] is None
    assert first["notified_at"] == int((NOW - timedelta(minutes=5)).timestamp())


def test_reminded_notification_moves_up(auth_header):
    older = add(AUDITOR, "재알림 온 것", 60)
    add(AUDITOR, "새 것", 10)
    with _session() as db:
        db.get(Notification, older).notified_at = NOW
        db.commit()
    assert bodies(client.get("/notifications", headers=auth_header(Role.AUDITOR))) == ["재알림 온 것", "새 것"]


def test_list_filters_and_limits(auth_header):
    for i in range(3):
        add(AUDITOR, f"안읽음{i}", 10 - i)
    add(AUDITOR, "읽음", 0, read=True)
    assert bodies(client.get("/notifications?unread_only=true", headers=auth_header(Role.AUDITOR))) == ["안읽음2", "안읽음1", "안읽음0"]
    assert len(bodies(client.get("/notifications?limit=2", headers=auth_header(Role.AUDITOR)))) == 2
    assert client.get("/notifications?limit=101", headers=auth_header(Role.AUDITOR)).status_code == 422
    assert client.get("/notifications?limit=0", headers=auth_header(Role.AUDITOR)).status_code == 422


def test_unread_count_skips_read_resolved_and_others(auth_header):
    add(AUDITOR, "a", 3)
    add(AUDITOR, "b", 2)
    add(AUDITOR, "읽음", 1, read=True)
    add(AUDITOR, "닫힘", 1, resolved=True)
    add(PRESIDENT, "회장 것", 1)
    assert client.get("/notifications/unread-count", headers=auth_header(Role.AUDITOR)).json() == {"count": 2}
    assert client.get("/notifications/unread-count", headers=auth_header(Role.TREASURER)).json() == {"count": 0}


# ---------------------------------------------------------------- 읽음


def test_marking_read_is_idempotent(auth_header):
    notification_id = add(AUDITOR, "a", 3)
    first = client.post(f"/notifications/{notification_id}/read", headers=auth_header(Role.AUDITOR))
    assert first.status_code == 200 and first.json()["id"] == notification_id
    again = client.post(f"/notifications/{notification_id}/read", headers=auth_header(Role.AUDITOR))
    assert again.status_code == 200 and again.json() == first.json()
    assert client.get("/notifications/unread-count", headers=auth_header(Role.AUDITOR)).json() == {"count": 0}


def test_someone_elses_or_missing_notification_is_404(auth_header):
    notification_id = add(PRESIDENT, "회장 것", 3)
    assert client.post(f"/notifications/{notification_id}/read", headers=auth_header(Role.AUDITOR)).status_code == 404
    assert client.post("/notifications/9999/read", headers=auth_header(Role.AUDITOR)).status_code == 404
    with _session() as db:
        assert db.get(Notification, notification_id).read_at is None


# ---------------------------------------------------------------- 기기 토큰


def tokens() -> list:
    with _session() as db:
        return [(t.user_id, t.token, t.revoked_at is None) for t in db.query(DeviceToken).order_by(DeviceToken.id)]


def register(auth_header, role: Role, token: str = "fcm-1", platform: str = "android"):
    return client.post("/notifications/device-tokens", json={"platform": platform, "token": token}, headers=auth_header(role))


def test_registering_twice_keeps_one_row(auth_header):
    first = register(auth_header, Role.AUDITOR)
    again = register(auth_header, Role.AUDITOR)
    assert first.status_code == again.status_code == 200
    assert first.json() == again.json()
    assert tokens() == [(AUDITOR, "fcm-1", True)]


def test_token_moves_to_whoever_logs_in_on_the_device(auth_header):
    register(auth_header, Role.AUDITOR)
    assert register(auth_header, Role.PRESIDENT).status_code == 200
    assert tokens() == [(PRESIDENT, "fcm-1", True)]  # 이전 사람의 알림이 이 기기로 가지 않는다


@pytest.mark.parametrize("platform", ["ios", "ANDROID", "web"])
def test_only_android_is_accepted(auth_header, platform):
    response = register(auth_header, Role.AUDITOR, platform=platform)
    assert response.status_code == 400 and tokens() == []


def test_late_revoke_does_not_touch_the_token_someone_took_over(auth_header):
    # 감사가 로그아웃하는 사이 회장이 같은 기기로 로그인해 토큰을 넘겨받았다. 늦게 온 감사의 해제는 회장 토큰을 건드리지 않는다
    register(auth_header, Role.AUDITOR)
    register(auth_header, Role.PRESIDENT)
    response = client.delete("/notifications/device-tokens/fcm-1", headers=auth_header(Role.AUDITOR))
    assert response.json() == {"revoked": False}
    assert tokens() == [(PRESIDENT, "fcm-1", True)]


def test_takeover_survives_a_revoke_that_lands_after_it_read_the_row(auth_header, monkeypatch):
    # 반대 순서 경합 (#78 codex 2차). 회장의 등록이 감사의 활성 토큰을 읽은 직후, 감사의 해제(로그아웃)가 먼저 커밋됐다.
    # 회장 쪽이 revoked_at=None 을 ORM 속성 대입으로만 하면 읽을 때 값도 None 이라 UPDATE 에서 빠지고, 토큰이 해제된 채 남는다
    from app.routers import notifications as router_module

    register(auth_header, Role.AUDITOR)
    real = router_module.datetime
    fired = []

    class RevokeAfterRead:
        """_register 가 행을 읽은 다음 처음 부르는 datetime.now() 에서 감사의 해제를 다른 세션으로 커밋한다."""

        @staticmethod
        def now(tz=None):
            if not fired:
                fired.append(True)
                with _session() as other:
                    other.query(DeviceToken).filter(
                        DeviceToken.token == "fcm-1", DeviceToken.user_id == AUDITOR, DeviceToken.revoked_at.is_(None)
                    ).update({DeviceToken.revoked_at: real.now(timezone.utc)}, synchronize_session=False)
                    other.commit()
            return real.now(tz)

    monkeypatch.setattr(router_module, "datetime", RevokeAfterRead)
    assert register(auth_header, Role.PRESIDENT).status_code == 200
    assert fired == [True]
    assert tokens() == [(PRESIDENT, "fcm-1", True)]  # 회장 토큰은 살아 있어야 푸시가 간다


def test_revoking_is_200_whatever_happens(auth_header):
    register(auth_header, Role.AUDITOR, token="mine")
    register(auth_header, Role.PRESIDENT, token="theirs")
    assert client.delete("/notifications/device-tokens/theirs", headers=auth_header(Role.AUDITOR)).json() == {"revoked": False}
    assert client.delete("/notifications/device-tokens/none", headers=auth_header(Role.AUDITOR)).json() == {"revoked": False}
    assert client.delete("/notifications/device-tokens/mine", headers=auth_header(Role.AUDITOR)).json() == {"revoked": True}
    assert client.delete("/notifications/device-tokens/mine", headers=auth_header(Role.AUDITOR)).json() == {"revoked": False}
    assert tokens() == [(AUDITOR, "mine", False), (PRESIDENT, "theirs", True)]
    register(auth_header, Role.AUDITOR, token="mine")  # 다시 로그인하면 되살린다
    assert tokens()[0] == (AUDITOR, "mine", True)
