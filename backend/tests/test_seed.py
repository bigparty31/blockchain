"""시드 스크립트(scripts/seed.py) 멱등성·제약조건·외래키 연동 검증 테스트."""
import os
import time

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, event
from sqlalchemy.orm import sessionmaker

from app.auth import users
from app.chain import FakeChainClient, fake_signature, get_chain_client
from app.database import get_db
from app.main import app
from app.models import Budget, BudgetVersion, Entry, Term, User
from app.schemas.auth import Role
from scripts.seed import SeedResult, seed_database


def _make_engine(db_file):
    engine = create_engine(
        f"sqlite:///{db_file.as_posix()}",
        connect_args={"check_same_thread": False},
    )

    @event.listens_for(engine, "connect")
    def _enable_fk(dbapi_connection, _):
        cur = dbapi_connection.cursor()
        cur.execute("PRAGMA foreign_keys=ON")
        cur.close()

    return engine


def _run_migrations(db_file):
    backend_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ini_path = os.path.join(backend_dir, "alembic.ini")
    cfg = Config(ini_path)
    cfg.set_main_option("sqlalchemy.url", f"sqlite:///{db_file.as_posix()}")
    command.upgrade(cfg, "head")


def test_seed_after_alembic_upgrade_is_idempotent_and_enables_entry_flow(tmp_path, auth_header):
    """빈 마이그레이션 DB에 시드 후:
    1) users(5)·terms(1)·budgets(3)·budget_versions(4) 생성 확인, entries 는 기본 0건
    2) 재실행 시 중복 생성 없이 0건 반환(멱등성)
    3) 외래키 강제 상태에서 총무 등록 -> 서명 제출 -> 감사 확정까지 정상 동작 확인
    """
    db_file = tmp_path / "seeded.db"
    _run_migrations(db_file)
    engine = _make_engine(db_file)
    SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

    with SessionLocal() as db:
        first = seed_database(db)
        assert first == SeedResult(
            users_created=len(users.SEED_USERS),
            terms_created=1,
            budgets_created=3,
            budget_versions_created=4,
            entries_created=0,
        )

        # 지갑 주소 소문자 정규화 및 SEED_USERS 매칭 확인
        db_users = db.query(User).order_by(User.id).all()
        assert [u.id for u in db_users] == [u.id for u in users.SEED_USERS]
        for db_u, seed_u in zip(db_users, users.SEED_USERS):
            if seed_u.wallet_address is None:
                assert db_u.wallet_address is None
            else:
                assert db_u.wallet_address == seed_u.wallet_address.lower()

        assert db.query(Term).count() == 1
        assert db.query(Budget).count() == 3
        assert db.query(BudgetVersion).count() == 4
        assert db.query(Entry).count() == 0

        # 2회차 실행 시 아무것도 새로 만들지 않아야 함 (멱등성)
        second = seed_database(db)
        assert second == SeedResult()

    # 시드된 DB로 실제 API 등록·제출·확정 흐름 검증
    fake_chain = FakeChainClient()

    def override_get_db():
        s = SessionLocal()
        try:
            yield s
        finally:
            s.close()

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_chain_client] = lambda: fake_chain
    try:
        test_client = TestClient(app)
        now = int(time.time())
        treasurer_wallet = next(u.wallet_address for u in users.SEED_USERS if u.role == Role.TREASURER)
        auditor_wallet = next(u.wallet_address for u in users.SEED_USERS if u.role == Role.AUDITOR)

        res_draft = test_client.post(
            "/entries",
            json={
                "term_id": 1,
                "kind": "EXPENSE",
                "amount": 25000,
                "counterparty": "시드검증문구",
                "purpose": "빈 DB 시드 후 외래키 통과 확인",
                "budget_id": 1,
                "occurred_at": 1788793200,
            },
            headers=auth_header(Role.TREASURER),
        )
        assert res_draft.status_code == 201
        entry_id = res_draft.json()["id"]

        res_submit = test_client.post(
            f"/entries/{entry_id}/submit",
            json={"deadline": now + 600, "signature": fake_signature(treasurer_wallet)},
            headers=auth_header(Role.TREASURER),
        )
        assert res_submit.status_code == 200
        assert res_submit.json()["status"] == "PENDING"

        res_confirm = test_client.post(
            f"/entries/{entry_id}/confirm",
            json={"deadline": now + 600, "signature": fake_signature(auditor_wallet)},
            headers=auth_header(Role.AUDITOR),
        )
        assert res_confirm.status_code == 200
        assert res_confirm.json()["status"] == "CONFIRMED"
    finally:
        app.dependency_overrides.clear()
        engine.dispose()


def test_seed_with_demo_entries_is_optional_and_idempotent(tmp_path):
    """--with-demo-entries 옵션 사용 시 예시 내역 3건이 추가되고 재실행 시 중복되지 않음"""
    db_file = tmp_path / "demo_seeded.db"
    _run_migrations(db_file)
    engine = _make_engine(db_file)
    SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    try:
        with SessionLocal() as db:
            first = seed_database(db, with_demo_entries=True)
            assert first.entries_created == 3
            assert db.query(Entry).count() == 3

            second = seed_database(db, with_demo_entries=True)
            assert second.entries_created == 0
            assert db.query(Entry).count() == 3
    finally:
        engine.dispose()


def test_seed_without_migrations_raises_clear_error(tmp_path):
    """마이그레이션 전 빈 파일에 시드를 실행하면 안내 메시지와 함께 RuntimeError 발생"""
    db_file = tmp_path / "unmigrated.db"
    engine = _make_engine(db_file)
    SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    try:
        with SessionLocal() as db:
            with pytest.raises(RuntimeError, match="alembic upgrade head"):
                seed_database(db)
    finally:
        engine.dispose()


def test_seed_raises_on_conflicting_user_and_rolls_back(tmp_path):
    """다른 id가 시드 지갑·학번을 선점했거나 같은 id에 다른 계정 정보가 있으면 RuntimeError로 중단·롤백해야 함"""
    db_file = tmp_path / "conflict_user.db"
    _run_migrations(db_file)
    engine = _make_engine(db_file)
    SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    try:
        treasurer_seed = next(u for u in users.SEED_USERS if u.role == Role.TREASURER)
        with SessionLocal() as db:
            # 리뷰 재현 시나리오: id=20 이 총무 지갑을 먼저 점유한 상태
            db.add(
                User(
                    id=20,
                    student_no="20990020",
                    password_hash=treasurer_seed.password_hash,
                    name="충돌총무",
                    role="TREASURER",
                    wallet_address=treasurer_seed.wallet_address.lower(),
                )
            )
            db.commit()

            with pytest.raises(RuntimeError, match="시드 사용자 불일치 충돌"):
                seed_database(db)

            # 앞선 루프에서 추가하려던 id=1 학생까지 포함해 전체 롤백되어야 함
            remaining_ids = [u.id for u in db.query(User).order_by(User.id).all()]
            assert remaining_ids == [20]

            # 같은 id(2)에 다른 학번·지갑이 들어 있는 경우에도 중단해야 함
            db.query(User).delete()
            db.add(
                User(
                    id=2,
                    student_no="20990002",
                    password_hash=treasurer_seed.password_hash,
                    name="다른계정",
                    role="TREASURER",
                    wallet_address="0x" + "a" * 40,
                )
            )
            db.commit()

            with pytest.raises(RuntimeError, match="시드 사용자 불일치 충돌"):
                seed_database(db)
    finally:
        engine.dispose()


def test_seed_raises_on_conflicting_term_or_budget(tmp_path):
    """학기(id/term_code/name)나 예산(id/term_id/category)이 일부만 일치하면 엉뚱한 행에 연결하지 않고 중단해야 함"""
    from datetime import datetime, timezone

    db_file = tmp_path / "conflict_term_budget.db"
    _run_migrations(db_file)
    engine = _make_engine(db_file)
    SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    try:
        with SessionLocal() as db:
            # 1) 학기명은 같지만 id·term_code가 다른 행이 있는 경우
            db.add(
                Term(
                    id=10,
                    term_code=20264,
                    name="2026-2학기",
                    started_at=datetime(2026, 9, 1, tzinfo=timezone.utc),
                    ended_at=datetime(2027, 2, 28, tzinfo=timezone.utc),
                )
            )
            db.commit()

            with pytest.raises(RuntimeError, match="시드 학기 불일치 충돌"):
                seed_database(db)

            assert db.query(User).count() == 0

            # 2) 학기는 정상이지만 id=1 예산에 "행사비" 대신 "사업비"가 들어 있는 경우
            db.query(Term).delete()
            db.add(
                Term(
                    id=1,
                    term_code=20262,
                    name="2026-2학기",
                    started_at=datetime(2026, 9, 1, tzinfo=timezone.utc),
                    ended_at=datetime(2027, 2, 28, tzinfo=timezone.utc),
                )
            )
            db.add(
                Budget(
                    id=1,
                    term_id=1,
                    category="사업비",
                    expires_at=datetime(2026, 12, 14, tzinfo=timezone.utc),
                )
            )
            db.commit()

            with pytest.raises(RuntimeError, match="시드 예산 불일치 충돌"):
                seed_database(db)

            assert db.query(BudgetVersion).count() == 0
    finally:
        engine.dispose()


def test_seed_coexists_with_non_conflicting_extra_users(tmp_path):
    """시드 범위(id=1..5)와 겹치지 않는 일반 사용자 행이 이미 있어도 정상 시드 및 재실행이 가능해야 함"""
    db_file = tmp_path / "extra_user.db"
    _run_migrations(db_file)
    engine = _make_engine(db_file)
    SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    try:
        student_seed = next(u for u in users.SEED_USERS if u.role == Role.STUDENT)
        with SessionLocal() as db:
            db.add(
                User(
                    id=20,
                    student_no="20259999",
                    password_hash=student_seed.password_hash,
                    name="추가학생",
                    role="STUDENT",
                    wallet_index=99,
                )
            )
            db.commit()

            result = seed_database(db)
            assert result.users_created == len(users.SEED_USERS)
            assert result.terms_created == 1
            assert result.budgets_created == 3
            assert result.budget_versions_created == 4
            assert [u.id for u in db.query(User).order_by(User.id).all()] == [1, 2, 3, 4, 5, 20]
    finally:
        engine.dispose()


def test_postgres_sequence_sync_advances_only_and_never_rewinds():
    """PostgreSQL 시퀀스 동기화가 뒤처진 시퀀스만 올리고, 빈 테이블이나 앞선 시퀀스는 되감지 않는지 검증"""
    from types import SimpleNamespace
    from scripts.seed import _sync_postgres_sequences

    # 테이블별 상태 시뮬레이션:
    # - users: MAX(id)=5, 시퀀스 초기 상태 (last_value=1, is_called=False) -> setval(5, true) 호출되어야 함
    # - terms: MAX(id)=1, 시퀀스 초기 상태 (last_value=1, is_called=False) -> setval(1, true) 호출되어야 함
    # - budgets: MAX(id)=3, 이미 시퀀스가 (last_value=3, is_called=True) -> 이미 다음 값 4이므로 건드리지 않음
    # - budget_versions: MAX(id)=4, 롤백 등으로 시퀀스가 앞서 있음 (last_value=9, is_called=True) -> 절대 되감지 않음
    # - entries: 빈 테이블 MAX(id)=None -> 절대 되감지 않음
    max_ids = {
        "users": 5,
        "terms": 1,
        "budgets": 3,
        "budget_versions": 4,
        "entries": None,
    }
    seq_states = {
        "public.users_id_seq": (1, False),
        "public.terms_id_seq": (1, False),
        "public.budgets_id_seq": (3, True),
        "public.budget_versions_id_seq": (9, True),
        "public.entries_id_seq": (7, True),
    }
    setval_calls = []

    class FakeResult:
        def __init__(self, val):
            self._val = val

        def scalar(self):
            return self._val

        def one(self):
            return self._val

    class FakePostgresSession:
        def get_bind(self):
            return SimpleNamespace(dialect=SimpleNamespace(name="postgresql"))

        def execute(self, stmt, params=None):
            sql = str(stmt)
            if sql.startswith("SELECT MAX(id) FROM "):
                tbl = sql.split("FROM ", 1)[1].strip()
                return FakeResult(max_ids[tbl])
            if "pg_get_serial_sequence" in sql:
                tbl = params["table_name"]
                return FakeResult(f"public.{tbl}_id_seq")
            if sql.startswith("SELECT last_value, is_called FROM "):
                seq = sql.split("FROM ", 1)[1].strip()
                return FakeResult(seq_states[seq])
            if "setval(" in sql:
                setval_calls.append((params["seq_name"], params["max_id"]))
                return FakeResult(params["max_id"])
            raise AssertionError(f"예상치 못한 SQL: {sql}")

    _sync_postgres_sequences(FakePostgresSession())
    assert setval_calls == [
        ("public.users_id_seq", 5),
        ("public.terms_id_seq", 1),
    ]


