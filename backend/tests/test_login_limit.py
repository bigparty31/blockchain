"""로그인 실패 제한 (PRD v0.15 §9.1, §9.2 · docs/API.md 인증 §1)."""
import threading

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.auth import login_limit
from app.auth.users import SEED_PASSWORD
from app.database import get_db
from app.main import app
from app.models import LoginAttempt
from app.routers import auth as auth_router

pytestmark = pytest.mark.usefixtures("login_db")

client = TestClient(app)

EXISTING = "20240003"  # 이감사
UNKNOWN = "99999999"
T0 = 1_800_000_000


@pytest.fixture
def clock(monkeypatch):
    """login_limit 의 시계. clock.t 를 바꾸면 그 시각이 된다."""

    class Clock:
        t = T0

    c = Clock()
    monkeypatch.setattr(login_limit, "now", lambda: c.t)
    return c


def login(student_no, password=SEED_PASSWORD, c=client):
    return c.post("/auth/login", json={"student_no": student_no, "password": password})


def fail(student_no, times):
    return [login(student_no, "wrong-password") for _ in range(times)]


def row(engine, student_no):
    with sessionmaker(bind=engine)() as db:
        return db.get(LoginAttempt, student_no)


# ---------------------------------------------------------------- 잠금


def test_fifth_failure_locks_and_right_password_is_refused(clock):
    results = fail(EXISTING, login_limit.MAX_FAILURES)
    assert [r.status_code for r in results] == [401] * login_limit.MAX_FAILURES

    res = login(EXISTING)  # 맞는 비밀번호
    assert res.status_code == 429
    assert res.json() == {"detail": "로그인 시도가 너무 많습니다. 잠시 후 다시 시도해 주세요."}
    assert res.headers["retry-after"] == str(login_limit.LOCK_SECONDS)


def test_unknown_student_no_locks_the_same_way(clock):
    # 없는 학번만 안 잠기면 잠기는지로 가입 여부를 알아낼 수 있다
    known = fail(EXISTING, 6)
    unknown = fail(UNKNOWN, 6)
    assert [(r.status_code, r.json(), r.headers.get("retry-after")) for r in known] == [
        (r.status_code, r.json(), r.headers.get("retry-after")) for r in unknown
    ]


def test_lock_is_per_student_no(clock):
    fail(EXISTING, login_limit.MAX_FAILURES)
    assert login("20240002").status_code == 200


def test_lock_expires(clock):
    fail(EXISTING, login_limit.MAX_FAILURES)
    clock.t += login_limit.LOCK_SECONDS - 1
    assert login(EXISTING).status_code == 429
    clock.t += 1
    assert login(EXISTING).status_code == 200


def test_after_lock_expires_counting_starts_over(clock):
    fail(EXISTING, login_limit.MAX_FAILURES)
    clock.t += login_limit.LOCK_SECONDS
    # 풀린 직후 한 번 틀렸다고 다시 잠기지 않는다
    assert [r.status_code for r in fail(EXISTING, login_limit.MAX_FAILURES - 1)] == [401] * (login_limit.MAX_FAILURES - 1)
    assert login(EXISTING).status_code == 200


def test_hammering_while_locked_does_not_extend_the_lock(clock):
    fail(EXISTING, login_limit.MAX_FAILURES)
    clock.t += 600
    res = login(EXISTING, "wrong-password")
    assert res.status_code == 429
    assert res.headers["retry-after"] == str(login_limit.LOCK_SECONDS - 600)


# ---------------------------------------------------------------- 초기화


def test_success_resets_the_count(clock, login_db):
    fail(EXISTING, login_limit.MAX_FAILURES - 1)
    assert login(EXISTING).status_code == 200
    assert row(login_db, EXISTING) is None
    assert [r.status_code for r in fail(EXISTING, login_limit.MAX_FAILURES - 1)] == [401] * (login_limit.MAX_FAILURES - 1)
    assert login(EXISTING).status_code == 200


def test_old_failures_are_forgotten(clock):
    # 몇 주 전 오타 4번과 오늘 1번이 합쳐 잠기지 않는다
    fail(EXISTING, login_limit.MAX_FAILURES - 1)
    clock.t += login_limit.RESET_SECONDS
    assert [r.status_code for r in fail(EXISTING, login_limit.MAX_FAILURES - 1)] == [401] * (login_limit.MAX_FAILURES - 1)
    assert login(EXISTING).status_code == 200


def test_recent_failures_are_kept(clock):
    fail(EXISTING, login_limit.MAX_FAILURES - 1)
    clock.t += login_limit.RESET_SECONDS - 1
    assert login(EXISTING, "wrong-password").status_code == 401
    assert login(EXISTING).status_code == 429


# ---------------------------------------------------------------- 동시 요청


def test_concurrent_attempts_check_the_password_at_most_max_times(login_db, monkeypatch):
    # 확인 → bcrypt → 기록 순서였다면 동시에 들어온 요청이 모두 확인을 통과해 전부 검사된다.
    # 시도를 먼저 세므로 비밀번호 검사는 MAX_FAILURES 번을 넘지 않는다
    checks = []
    lock = threading.Lock()
    real_verify = auth_router.verify_password

    def counting_verify(password, password_hash):
        with lock:
            checks.append(password)
        return real_verify(password, password_hash)

    monkeypatch.setattr(auth_router, "verify_password", counting_verify)

    n = 12
    barrier = threading.Barrier(n)
    statuses = []

    def worker():
        c = TestClient(app)
        barrier.wait()
        res = login(EXISTING, "wrong-password", c=c)
        with lock:
            statuses.append(res.status_code)

    threads = [threading.Thread(target=worker) for _ in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert len(checks) == login_limit.MAX_FAILURES
    assert sorted(statuses) == [401] * login_limit.MAX_FAILURES + [429] * (n - login_limit.MAX_FAILURES)
    assert login(EXISTING).status_code == 429


# ---------------------------------------------------------------- 입력·오류


@pytest.mark.parametrize("student_no", ["", "1" * 21])
def test_student_no_out_of_bounds_is_422(student_no):
    assert login(student_no).status_code == 422


def test_db_error_is_503_not_a_free_pass(tmp_path):
    # 실패 횟수를 확인할 수 없으면 로그인도 받지 않는다 (테이블이 없는 DB)
    engine = create_engine(f"sqlite:///{tmp_path / 'empty.db'}", connect_args={"check_same_thread": False})
    session = sessionmaker(bind=engine)

    def broken():
        db = session()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = broken
    try:
        res = login(EXISTING)
    finally:
        engine.dispose()
    # login_db 픽스처가 끝날 때 override 를 지운다
    assert res.status_code == 503
