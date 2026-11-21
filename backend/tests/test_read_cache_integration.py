"""학생 조회 엔드포인트(/balance, /entries, /budgets) Redis 읽기 캐시 통합 테스트.

검증 항목:
1. CACHE_ENABLED=0(기본값, 임원 서버)에서는 매 요청마다 원본 DB/체인을 직접 조회한다.
2. CACHE_ENABLED=1(학생 서버)에서는 첫 호출에서 Redis에 저장하고 두 번째 호출에서 캐시 적중(원본 미호출)하며
   응답 JSON 포맷이 히트/미스 간 완전히 동일하다.
3. term_id 쿼리 파라미터에 따라 캐시 키가 분리된다(all vs 1 vs 2).
4. 원본 조회 중 오류(503)가 발생하면 캐시에 저장하지 않는다.
5. main_student.py lifespan 종료 시 cache.close()가 호출된다.
"""
from datetime import datetime, timezone
from types import SimpleNamespace

from fastapi.testclient import TestClient
import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app import cache
from app.chain import ChainError, get_chain_client
from app.database import Base, get_db
from app.main_student import app as student_app
from app.models import Budget as DBBudget
from app.models import Entry as DBEntry
from app.models import Term as DBTerm
from app.models import User as DBUser


class FakeRedis:
    """실제 Redis 없이 get/set/aclose 동작과 호출 기록을 추적하는 테스트용 저장소."""

    def __init__(self):
        self.store: dict[str, str] = {}
        self.sets: list[tuple[str, str, int | None]] = []
        self.closed = False

    async def get(self, key: str):
        return self.store.get(key)

    async def set(self, key: str, value: str, ex: int | None = None):
        self.store[key] = value
        self.sets.append((key, value, ex))

    async def aclose(self):
        self.closed = True


class FakeChainClient:
    """체인 RPC 호출 횟수를 추적하는 스텁."""

    def __init__(self, *, fail_budget: bool = False):
        self.fail_budget = fail_budget
        self.entry_calls = 0
        self.budget_calls = 0

    async def get_entry(self, entry_id: int):
        self.entry_calls += 1
        return SimpleNamespace(registrant="0x1111111111111111111111111111111111111111")

    async def get_budget(self, budget_id: int):
        self.budget_calls += 1
        if self.fail_budget:
            raise ChainError("simulated chain error")
        return SimpleNamespace(
            issued=1_000_000,
            remaining=750_000,
            version=1,
            expires_at=1_900_000_000,
        )


@pytest.fixture(autouse=True)
def _reset_cache_state():
    cache._client = None
    cache._unavailable = False
    yield
    cache._client = None
    cache._unavailable = False


@pytest.fixture()
def db_session_factory():
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

    db = SessionLocal()
    try:
        treasurer = DBUser(
            id=1,
            student_no="20200001",
            password_hash="x",
            name="총무",
            role="TREASURER",
            wallet_address="0x1111111111111111111111111111111111111111",
        )
        term1 = DBTerm(
            id=1,
            term_code=20261,
            name="2026-1학기",
            started_at=datetime(2026, 3, 1, tzinfo=timezone.utc),
            ended_at=datetime(2026, 8, 31, tzinfo=timezone.utc),
        )
        term2 = DBTerm(
            id=2,
            term_code=20262,
            name="2026-2학기",
            started_at=datetime(2026, 9, 1, tzinfo=timezone.utc),
            ended_at=datetime(2027, 2, 28, tzinfo=timezone.utc),
        )
        budget1 = DBBudget(
            id=1,
            term_id=1,
            category="행사비",
            expires_at=datetime(2026, 8, 31, tzinfo=timezone.utc),
            tx_issue="0x" + "1" * 64,
        )
        budget2 = DBBudget(
            id=2,
            term_id=2,
            category="복지비",
            expires_at=datetime(2027, 2, 28, tzinfo=timezone.utc),
            tx_issue="0x" + "2" * 64,
        )
        entry1 = DBEntry(
            id=1,
            term_id=1,
            budget_id=None,
            kind="INCOME",
            amount=500_000,
            counterparty="학생회비 납부",
            purpose="1학기 회비",
            occurred_at=1_773_100_800,
            meta_hash="0x" + "a" * 64,
            status="CONFIRMED",
            created_by=1,
        )
        entry2 = DBEntry(
            id=2,
            term_id=2,
            budget_id=2,
            kind="EXPENSE",
            amount=100_000,
            counterparty="마트",
            purpose="2학기 간식",
            occurred_at=1_789_000_000,
            meta_hash="0x" + "b" * 64,
            status="CONFIRMED",
            created_by=1,
        )
        db.add_all([treasurer, term1, term2, budget1, budget2, entry1, entry2])
        db.commit()
    finally:
        db.close()

    yield SessionLocal
    Base.metadata.drop_all(bind=engine)
    engine.dispose()


@pytest.fixture()
def test_env(db_session_factory, monkeypatch):
    fake_redis = FakeRedis()
    fake_chain = FakeChainClient()

    def _override_db():
        db = db_session_factory()
        try:
            yield db
        finally:
            db.close()

    student_app.dependency_overrides[get_db] = _override_db
    student_app.dependency_overrides[get_chain_client] = lambda: fake_chain
    monkeypatch.setattr(cache, "_get_client", lambda: fake_redis)
    monkeypatch.setattr("app.main_student.check_chain_config", lambda: None)

    client = TestClient(student_app)
    try:
        yield SimpleNamespace(
            client=client,
            redis=fake_redis,
            chain=fake_chain,
            SessionLocal=db_session_factory,
        )
    finally:
        student_app.dependency_overrides.clear()


def test_balance_cache_disabled_always_reads_fresh_db(test_env, monkeypatch):
    monkeypatch.setenv("CACHE_ENABLED", "0")

    r1 = test_env.client.get("/balance")
    assert r1.status_code == 200
    assert r1.json() == {"balance": 400_000, "income": 500_000, "expense": 100_000}

    # DB에 확정 수입 추가
    db = test_env.SessionLocal()
    try:
        db.add(
            DBEntry(
                id=3,
                term_id=1,
                budget_id=None,
                kind="INCOME",
                amount=200_000,
                counterparty="추가 납부자",
                purpose="추가 회비",
                occurred_at=1_774_000_000,
                meta_hash="0x" + "c" * 64,
                status="CONFIRMED",
                created_by=1,
            )
        )
        db.commit()
    finally:
        db.close()

    r2 = test_env.client.get("/balance")
    assert r2.status_code == 200
    assert r2.json() == {"balance": 600_000, "income": 700_000, "expense": 100_000}
    assert test_env.redis.sets == []


def test_balance_cache_enabled_hits_and_separates_term_id(test_env, monkeypatch):
    monkeypatch.setenv("CACHE_ENABLED", "1")
    monkeypatch.setenv("CACHE_TTL_SECONDS", "30")

    # 1) 전체 잔액 미스 -> 저장
    r1 = test_env.client.get("/balance")
    assert r1.status_code == 200
    assert r1.json() == {"balance": 400_000, "income": 500_000, "expense": 100_000}
    assert "balance:all" in test_env.redis.store

    # DB 변경 후에도 전체 잔액은 캐시 적중으로 이전 값 유지
    db = test_env.SessionLocal()
    try:
        db.add(
            DBEntry(
                id=3,
                term_id=1,
                budget_id=None,
                kind="INCOME",
                amount=200_000,
                counterparty="추가 납부자",
                purpose="추가 회비",
                occurred_at=1_774_000_000,
                meta_hash="0x" + "c" * 64,
                status="CONFIRMED",
                created_by=1,
            )
        )
        db.commit()
    finally:
        db.close()

    r2 = test_env.client.get("/balance")
    assert r2.status_code == 200
    assert r2.json() == r1.json()

    # 2) term_id=1 은 별도 키(balance:1)로 원본 조회
    r_term1 = test_env.client.get("/balance?term_id=1")
    assert r_term1.status_code == 200
    assert r_term1.json() == {"balance": 700_000, "income": 700_000, "expense": 0}
    assert "balance:1" in test_env.redis.store


def test_entries_cache_hits_and_skips_chain_rpc(test_env, monkeypatch):
    monkeypatch.setenv("CACHE_ENABLED", "1")

    r1 = test_env.client.get("/entries")
    assert r1.status_code == 200
    assert len(r1.json()) == 2
    assert "entries:all" in test_env.redis.store
    first_rpc_calls = test_env.chain.entry_calls
    assert first_rpc_calls == 2

    # 2번째 호출은 캐시 적중 -> 체인 RPC 추가 호출 없음, JSON 동일
    r2 = test_env.client.get("/entries")
    assert r2.status_code == 200
    assert r2.json() == r1.json()
    assert test_env.chain.entry_calls == first_rpc_calls

    # term_id=2 는 별도 키(entries:2)로 분리 조회
    r_term2 = test_env.client.get("/entries?term_id=2")
    assert r_term2.status_code == 200
    assert len(r_term2.json()) == 1
    assert r_term2.json()[0]["term_id"] == 2
    assert "entries:2" in test_env.redis.store


def test_budgets_cache_hits_and_does_not_cache_503_error(test_env, monkeypatch):
    monkeypatch.setenv("CACHE_ENABLED", "1")

    # 체인 오류 시 503 반환 및 캐시 미저장
    test_env.chain.fail_budget = True
    r_err = test_env.client.get("/budgets")
    assert r_err.status_code == 503
    assert "budgets:all" not in test_env.redis.store

    # 복구 후 첫 호출에서 캐시 저장
    test_env.chain.fail_budget = False
    calls_before = test_env.chain.budget_calls
    r1 = test_env.client.get("/budgets")
    assert r1.status_code == 200
    assert len(r1.json()) == 2
    assert "budgets:all" in test_env.redis.store
    assert test_env.chain.budget_calls == calls_before + 2

    # 두 번째 호출은 캐시 적중 -> 체인 RPC 미호출
    calls_after_first = test_env.chain.budget_calls
    r2 = test_env.client.get("/budgets")
    assert r2.status_code == 200
    assert r2.json() == r1.json()
    assert test_env.chain.budget_calls == calls_after_first

    # term_id=1 별도 키 검증
    r_term1 = test_env.client.get("/budgets?term_id=1")
    assert r_term1.status_code == 200
    assert len(r_term1.json()) == 1
    assert r_term1.json()[0]["category"] == "행사비"
    assert "budgets:1" in test_env.redis.store


def test_student_lifespan_closes_cache_on_shutdown(monkeypatch):
    fake_redis = FakeRedis()
    cache._client = fake_redis
    monkeypatch.setattr("app.main_student.check_chain_config", lambda: None)

    with TestClient(student_app) as client:
        res = client.get("/")
        assert res.status_code == 200

    assert fake_redis.closed is True
    assert cache._client is None


def test_budgets_cache_hit_skips_chain_provider_even_if_provider_fails(test_env, monkeypatch):
    """Codex 1차 회귀: 유효 캐시가 있으면 체인 provider 를 호출하지 않고, provider 실패 상태에서도 200 을 반환한다."""
    import json
    from app.chain import ChainSetupError

    monkeypatch.setenv("CACHE_ENABLED", "1")
    cached_payload = [
        {
            "id": 1,
            "term_id": 1,
            "category": "행사비",
            "planned_amount": 1_000_000,
            "remaining_amount": 750_000,
            "execution_rate": 0.25,
            "version": 1,
            "expires_at": 1_900_000_000,
            "revision_reason": None,
        }
    ]
    test_env.redis.store["budgets:all"] = json.dumps(cached_payload)

    provider_calls = 0

    async def _failing_provider():
        nonlocal provider_calls
        provider_calls += 1
        raise ChainSetupError("simulated chain provider init failure")

    student_app.dependency_overrides[get_chain_client] = _failing_provider

    # 1) 캐시 적중 경로: provider 를 아예 호출하지 않고 200 반환
    r_hit = test_env.client.get("/budgets")
    assert r_hit.status_code == 200
    assert r_hit.json() == cached_payload
    assert provider_calls == 0

    # 2) 캐시 미스 경로: provider 호출 후 503 반환, 오류는 캐시에 저장하지 않음
    r_miss = test_env.client.get("/budgets?term_id=1")
    assert r_miss.status_code == 503
    assert provider_calls == 1
    assert "budgets:1" not in test_env.redis.store


def test_entries_does_not_cache_when_chain_registrant_lookup_fails(test_env, monkeypatch):
    """PR #134 리뷰 #1: 체인 조회 실패/부분 실패로 registrant=null 이 섞인 /entries 응답은 캐시에 저장하지 않는다."""
    monkeypatch.setenv("CACHE_ENABLED", "1")

    orig_get_entry = test_env.chain.get_entry

    async def _failing_get_entry(entry_id: int):
        raise RuntimeError("simulated RPC timeout")

    monkeypatch.setattr(test_env.chain, "get_entry", _failing_get_entry)

    # 1) 체인 실패 시 200 (registrant=None) 응답은 주되, 캐시에 저장하지 않음
    r_degraded = test_env.client.get("/entries")
    assert r_degraded.status_code == 200
    assert len(r_degraded.json()) == 2
    assert all(item["registrant"] is None for item in r_degraded.json())
    assert "entries:all" not in test_env.redis.store

    # 2) 체인 복구 후 다음 요청은 실제 registrant 를 채워 반환하고 캐시에 저장
    monkeypatch.setattr(test_env.chain, "get_entry", orig_get_entry)
    r_ok = test_env.client.get("/entries")
    assert r_ok.status_code == 200
    assert all(item["registrant"] == "0x1111111111111111111111111111111111111111" for item in r_ok.json())
    assert "entries:all" in test_env.redis.store


def test_cache_get_or_set_coalesces_concurrent_misses(monkeypatch):
    """PR #134 리뷰 #2: 캐시 미스·만료 순간 동시 요청이 몰려도 같은 키는 produce 를 1번만 실행한다."""
    import asyncio

    monkeypatch.setenv("CACHE_ENABLED", "1")
    fake_redis = FakeRedis()
    monkeypatch.setattr(cache, "_get_client", lambda: fake_redis)

    calls = 0

    async def _slow_produce():
        nonlocal calls
        calls += 1
        await asyncio.sleep(0.05)
        return {"balance": 400_000}

    async def _run_burst():
        return await asyncio.gather(*[cache.get_or_set("balance:all", _slow_produce) for _ in range(10)])

    results = asyncio.run(_run_burst())
    assert calls == 1
    assert all(r == {"balance": 400_000} for r in results)


def test_cache_hit_does_not_open_db_session(test_env, monkeypatch):
    """PR #134 참고: 캐시 적중 시 /balance, /entries, /budgets 모두 DB 세션을 열지 않는다."""
    monkeypatch.setenv("CACHE_ENABLED", "1")

    db_opens = 0

    def _counting_db():
        nonlocal db_opens
        db_opens += 1
        db = test_env.SessionLocal()
        try:
            yield db
        finally:
            db.close()

    student_app.dependency_overrides[get_db] = _counting_db

    # 1) 최초 호출(미스)로 캐시 워밍
    assert test_env.client.get("/balance").status_code == 200
    assert test_env.client.get("/entries").status_code == 200
    assert test_env.client.get("/budgets").status_code == 200
    assert db_opens == 3

    # 2) 캐시 적중 경로에서는 DB 세션 0회 오픈
    db_opens = 0
    assert test_env.client.get("/balance").status_code == 200
    assert test_env.client.get("/entries").status_code == 200
    assert test_env.client.get("/budgets").status_code == 200
    assert db_opens == 0


def test_cache_shares_uncached_degraded_result_and_cleans_up_inflight_keys(monkeypatch):
    """Codex 3차 회귀:
    1) should_cache=False(예: 체인 지연으로 불완전한 /entries)여도 동시 대기자는 직렬 재조회 없이 결과를 공유한다.
    2) 서로 다른 키를 대량 조회한 뒤에도 _inflight 맵에 키가 누적되지 않는다.
    """
    import asyncio

    monkeypatch.setenv("CACHE_ENABLED", "1")
    fake_redis = FakeRedis()
    monkeypatch.setattr(cache, "_get_client", lambda: fake_redis)

    calls = 0

    async def _slow_degraded_produce():
        nonlocal calls
        calls += 1
        await asyncio.sleep(0.05)
        return [{"id": 1, "registrant": None}]

    async def _run():
        # 1) 동시 10개 요청이 should_cache=False 여도 produce 는 1회만 호출되고 Redis 는 비어 있음
        results = await asyncio.gather(
            *[
                cache.get_or_set(
                    "entries:all",
                    _slow_degraded_produce,
                    should_cache=lambda _: False,
                )
                for _ in range(10)
            ]
        )
        assert calls == 1
        assert all(r == [{"id": 1, "registrant": None}] for r in results)
        assert "entries:all" not in fake_redis.store
        assert len(cache._inflight) == 0

        # 2) 서로 다른 키 200개 조회 완료 후에도 _inflight 는 완전히 비워짐
        for i in range(200):
            async def _p(idx=i):
                return {"term": idx}

            val = await cache.get_or_set(f"balance:{i}", _p)
            assert val == {"term": i}
        assert len(cache._inflight) == 0

    asyncio.run(_run())


def test_cache_waiter_recovers_when_leader_is_cancelled(monkeypatch):
    """PR #134 참고: 선행(leader) 요청이 취소돼도 대기자는 CancelledError로 연쇄 실패하지 않고 직접 조회한다."""
    import asyncio

    monkeypatch.setenv("CACHE_ENABLED", "1")
    fake_redis = FakeRedis()
    monkeypatch.setattr(cache, "_get_client", lambda: fake_redis)

    leader_started = asyncio.Event()
    calls = 0

    async def _produce():
        nonlocal calls
        calls += 1
        if calls == 1:
            leader_started.set()
            await asyncio.sleep(10)
        return {"balance": 777_000}

    async def _run():
        leader = asyncio.create_task(cache.get_or_set("balance:cancel-test", _produce))
        await leader_started.wait()

        waiters = [
            asyncio.create_task(cache.get_or_set("balance:cancel-test", _produce))
            for _ in range(3)
        ]
        # 대기자 3명이 모두 inflight future 를 잡도록 이벤트 루프 양보
        await asyncio.sleep(0)

        leader.cancel()
        with pytest.raises(asyncio.CancelledError):
            await leader

        results = await asyncio.gather(*waiters)
        assert results == [{"balance": 777_000}] * 3
        assert len(cache._inflight) == 0

    asyncio.run(_run())
