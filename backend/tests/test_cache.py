"""학생 서버 조회 캐시 (`app/cache.py`) 시험.

이 모듈의 핵심 성질은 "빠르게 한다" 가 아니라 **"틀리게 하지 않는다"** 이다. 캐시는 성능 장치지
정확성 장치가 아니므로, Redis 가 없거나 죽거나 이상한 값을 주더라도 조회는 원본 값으로 끝까지
가야 한다. 아래 시험은 그 실패 경로를 전부 건드린다.

Redis 를 실제로 띄우지 않는다 — `redis` 패키지는 아직 `requirements.txt` 에 없고(선택 의존성),
연결 획득(`_get_client`)을 갈아끼우면 저장소 동작은 그대로 확인할 수 있다.
"""
import asyncio

import pytest

from app import cache


@pytest.fixture(autouse=True)
def _reset_cache_module():
    """모듈 전역(`_client`·`_unavailable`)을 시험마다 되돌린다.

    `_get_client` 는 한번 실패하면 `_unavailable` 을 세워 두고 다시 시도하지 않는다. 되돌리지
    않으면 앞 시험의 실패가 뒤 시험을 조용히 통과시킨다.
    """
    cache._client = None
    cache._unavailable = False
    cache._locks.clear()
    yield
    cache._client = None
    cache._unavailable = False
    cache._locks.clear()


class FakeRedis:
    """필요한 것만 흉내 낸다. `fail_on` 으로 특정 호출만 터뜨린다."""

    def __init__(self, *, initial=None, fail_on=()):
        self.store = dict(initial or {})
        self.fail_on = set(fail_on)
        self.sets = []          # (key, value, ex) 기록
        self.closed = False

    async def get(self, key):
        if "get" in self.fail_on:
            raise RuntimeError("redis get 실패")
        return self.store.get(key)

    async def set(self, key, value, ex=None):
        if "set" in self.fail_on:
            raise RuntimeError("redis set 실패")
        self.store[key] = value
        self.sets.append((key, value, ex))

    async def aclose(self):
        if "aclose" in self.fail_on:
            raise RuntimeError("redis close 실패")
        self.closed = True


def _counting_producer(value):
    """부른 횟수를 세는 produce. 캐시 적중이면 0 번이어야 한다."""
    calls = []

    async def produce():
        calls.append(1)
        return value

    return produce, calls


# ── enabled() ─────────────────────────────────────────────────────────

@pytest.mark.parametrize("raw", ["1", "true", "True", " 1 "])
def test_enabled_켜는_값(monkeypatch, raw):
    monkeypatch.setenv("CACHE_ENABLED", raw)
    assert cache.enabled() is True


@pytest.mark.parametrize("raw", ["", "0", "false", "False", "TRUE", "yes", "아무거나"])
def test_enabled_나머지는_모두_꺼짐(monkeypatch, raw):
    monkeypatch.setenv("CACHE_ENABLED", raw)
    assert cache.enabled() is False


def test_enabled_기본값은_꺼짐(monkeypatch):
    """임원 서버는 쓰기 직후 바로 읽는 화면이 많아, 기본이 켜짐이면 틀린 값을 보여 준다."""
    monkeypatch.delenv("CACHE_ENABLED", raising=False)
    assert cache.enabled() is False


# ── ttl_seconds() ─────────────────────────────────────────────────────

def test_ttl_기본값(monkeypatch):
    monkeypatch.delenv("CACHE_TTL_SECONDS", raising=False)
    assert cache.ttl_seconds() == cache.DEFAULT_TTL_SECONDS == 30


def test_ttl_정상값(monkeypatch):
    monkeypatch.setenv("CACHE_TTL_SECONDS", "5")
    assert cache.ttl_seconds() == 5


@pytest.mark.parametrize("raw", ["", "  ", "abc", "3.5", "0", "-1"])
def test_ttl_이상한_값이면_기본값(monkeypatch, raw):
    """TTL 이 0 이하이거나 숫자가 아니면 캐시를 영구 보관하거나 터지는 대신 기본값으로 간다."""
    monkeypatch.setenv("CACHE_TTL_SECONDS", raw)
    assert cache.ttl_seconds() == cache.DEFAULT_TTL_SECONDS


# ── _get_client() ─────────────────────────────────────────────────────

def test_REDIS_URL_이_없으면_연결하지_않는다(monkeypatch):
    monkeypatch.delenv("REDIS_URL", raising=False)
    assert cache._get_client() is None
    assert cache._unavailable is True


def test_한번_실패하면_다시_시도하지_않는다(monkeypatch):
    """매 요청마다 재시도하면 Redis 가 죽었을 때 캐시가 없는 것보다 느려진다."""
    monkeypatch.delenv("REDIS_URL", raising=False)
    assert cache._get_client() is None

    # 주소가 생겨도 이미 포기한 뒤라 다시 붙지 않는다
    monkeypatch.setenv("REDIS_URL", "redis://localhost:6379/0")
    assert cache._get_client() is None


# ── get_or_set() — 정상 경로 ──────────────────────────────────────────

def test_꺼져_있으면_캐시를_건드리지_않는다(monkeypatch):
    monkeypatch.setenv("CACHE_ENABLED", "0")
    touched = []
    monkeypatch.setattr(cache, "_get_client", lambda: touched.append(1))

    produce, calls = _counting_producer({"balance": 1000})
    assert asyncio.run(cache.get_or_set("balance", produce)) == {"balance": 1000}
    assert len(calls) == 1
    assert touched == []  # 연결 시도조차 하지 않는다


def test_캐시_적중이면_produce_를_부르지_않는다(monkeypatch):
    monkeypatch.setenv("CACHE_ENABLED", "1")
    fake = FakeRedis(initial={"balance": '{"balance": 1000}'})
    monkeypatch.setattr(cache, "_get_client", lambda: fake)

    produce, calls = _counting_producer({"balance": 9999})
    assert asyncio.run(cache.get_or_set("balance", produce)) == {"balance": 1000}
    assert calls == []


def test_캐시_불발이면_produce_결과를_TTL_과_함께_담는다(monkeypatch):
    monkeypatch.setenv("CACHE_ENABLED", "1")
    monkeypatch.setenv("CACHE_TTL_SECONDS", "7")
    fake = FakeRedis()
    monkeypatch.setattr(cache, "_get_client", lambda: fake)

    produce, calls = _counting_producer({"balance": 1000})
    assert asyncio.run(cache.get_or_set("balance", produce)) == {"balance": 1000}
    assert len(calls) == 1
    assert fake.sets == [("balance", '{"balance": 1000}', 7)]


def test_ttl_인자가_환경변수보다_우선한다(monkeypatch):
    monkeypatch.setenv("CACHE_ENABLED", "1")
    monkeypatch.setenv("CACHE_TTL_SECONDS", "30")
    fake = FakeRedis()
    monkeypatch.setattr(cache, "_get_client", lambda: fake)

    produce, _ = _counting_producer([1, 2])
    asyncio.run(cache.get_or_set("k", produce, ttl=3))
    assert fake.sets[0][2] == 3


# ── get_or_set() — 실패 경로. 전부 원본 값으로 끝나야 한다 ────────────

def test_연결이_없으면_원본을_읽는다(monkeypatch):
    monkeypatch.setenv("CACHE_ENABLED", "1")
    monkeypatch.setattr(cache, "_get_client", lambda: None)

    produce, calls = _counting_producer({"balance": 1000})
    assert asyncio.run(cache.get_or_set("balance", produce)) == {"balance": 1000}
    assert len(calls) == 1


def test_조회가_터져도_원본을_읽는다(monkeypatch):
    """캐시 장애가 조회 장애가 되면 학생 화면이 통째로 멈춘다."""
    monkeypatch.setenv("CACHE_ENABLED", "1")
    fake = FakeRedis(fail_on={"get"})
    monkeypatch.setattr(cache, "_get_client", lambda: fake)

    produce, calls = _counting_producer({"balance": 1000})
    assert asyncio.run(cache.get_or_set("balance", produce)) == {"balance": 1000}
    assert len(calls) == 1
    assert fake.sets == []  # 조회가 깨졌으면 저장도 하지 않는다


def test_저장이_터져도_값은_돌려준다(monkeypatch):
    monkeypatch.setenv("CACHE_ENABLED", "1")
    fake = FakeRedis(fail_on={"set"})
    monkeypatch.setattr(cache, "_get_client", lambda: fake)

    produce, calls = _counting_producer({"balance": 1000})
    assert asyncio.run(cache.get_or_set("balance", produce)) == {"balance": 1000}
    assert len(calls) == 1


def test_직렬화할_수_없는_값은_담지_않고_돌려준다(monkeypatch):
    """`json.dumps(default=str)` 로도 안 되는 값이면 담기를 포기하고 값만 넘긴다."""
    monkeypatch.setenv("CACHE_ENABLED", "1")
    fake = FakeRedis()
    monkeypatch.setattr(cache, "_get_client", lambda: fake)

    unserializable = {(1, 2): "튜플 키는 JSON 이 안 된다"}
    produce, calls = _counting_producer(unserializable)
    assert asyncio.run(cache.get_or_set("k", produce)) is unserializable
    assert len(calls) == 1
    assert fake.sets == []


def test_깨진_JSON_이_담겨_있으면_원본을_읽는다(monkeypatch):
    """남이 같은 키에 쓰레기를 넣었더라도 조회가 500 이 되면 안 된다."""
    monkeypatch.setenv("CACHE_ENABLED", "1")
    fake = FakeRedis(initial={"balance": "{깨진 JSON"})
    monkeypatch.setattr(cache, "_get_client", lambda: fake)

    produce, calls = _counting_producer({"balance": 1000})
    assert asyncio.run(cache.get_or_set("balance", produce)) == {"balance": 1000}
    assert len(calls) == 1


# ── close() ───────────────────────────────────────────────────────────

def test_close_는_연결을_닫고_비운다():
    fake = FakeRedis()
    cache._client = fake
    asyncio.run(cache.close())
    assert fake.closed is True
    assert cache._client is None


def test_close_는_연결이_없어도_안전하다():
    cache._client = None
    asyncio.run(cache.close())  # 던지지 않는다
    assert cache._client is None


def test_close_중_오류가_나도_비운다():
    """프로세스를 내리는 중이라 닫기 실패로 종료가 막히면 안 된다."""
    cache._client = FakeRedis(fail_on={"aclose"})
    asyncio.run(cache.close())
    assert cache._client is None


# ── 만료 순간 중복 생성 막기 (single-flight) ──────────────────────────
#
# 이 성질이 없으면 TTL 이 끝나는 순간 그때 들어온 요청 전부가 미스가 되어 한꺼번에 produce 로
# 들어간다. k6 로 실제로 재 보니 그 구간에서 인스턴스가 통째로 멈췄다 — `/entries` 의 produce 가
# DB 커넥션을 쥔 채 체인 조회를 기다리고(최대 1.5초), 동시 요청이 풀(5+10)을 넘으면 남은 요청이
# 커넥션을 **이벤트 루프 위에서** 기다려서 DB 를 쓰지 않는 `/` 까지 30초 타임아웃이 됐다.

def _slow_producer(value, *, delay=0.01):
    """늦게 끝나는 produce. 잠금이 없으면 이 시간 동안 다른 요청이 전부 밀려든다."""
    calls = []

    async def produce():
        calls.append(1)
        await asyncio.sleep(delay)
        return value

    return produce, calls


def test_만료_순간_동시_요청이_몰려도_produce_는_한_번만(monkeypatch):
    monkeypatch.setenv("CACHE_ENABLED", "1")
    fake = FakeRedis()  # 비어 있다 = 막 만료된 상태
    monkeypatch.setattr(cache, "_get_client", lambda: fake)
    produce, calls = _slow_producer({"balance": 1000})

    async def run():
        return await asyncio.gather(
            *(cache.get_or_set("balance:all", produce) for _ in range(50))
        )

    results = asyncio.run(run())

    assert len(calls) == 1, f"produce 가 {len(calls)}번 돌았다 (1번이어야 한다)"
    assert all(r == {"balance": 1000} for r in results)
    assert len(fake.sets) == 1, "저장도 한 번만 일어나야 한다"


def test_기다린_쪽은_먼저_채워진_값을_읽는다(monkeypatch):
    """잠금을 잡은 뒤 **한 번 더 조회**하지 않으면 기다린 요청들이 produce 를 다시 돈다."""
    monkeypatch.setenv("CACHE_ENABLED", "1")
    fake = FakeRedis()
    monkeypatch.setattr(cache, "_get_client", lambda: fake)
    produce, calls = _slow_producer([1, 2, 3])

    async def run():
        first = asyncio.create_task(cache.get_or_set("entries:all", produce))
        await asyncio.sleep(0)  # 첫 요청이 잠금을 잡게 한다
        later = await asyncio.gather(
            *(cache.get_or_set("entries:all", produce) for _ in range(5))
        )
        return await first, later

    head, later = asyncio.run(run())

    assert len(calls) == 1
    assert head == [1, 2, 3]
    assert later == [[1, 2, 3]] * 5


def test_키가_다르면_서로_막지_않는다(monkeypatch):
    """잠금은 키별이어야 한다. 하나로 묶으면 `/balance` 가 `/entries` 생성을 기다린다."""
    monkeypatch.setenv("CACHE_ENABLED", "1")
    fake = FakeRedis()
    monkeypatch.setattr(cache, "_get_client", lambda: fake)

    started = []

    def tracking_producer(name):
        async def produce():
            started.append(name)
            await asyncio.sleep(0.02)
            return name

        return produce

    async def run():
        return await asyncio.gather(
            cache.get_or_set("entries:all", tracking_producer("entries")),
            cache.get_or_set("balance:all", tracking_producer("balance")),
            cache.get_or_set("budgets:all", tracking_producer("budgets")),
        )

    results = asyncio.run(run())

    assert sorted(results) == ["balance", "budgets", "entries"]
    # 셋이 모두 시작했다 = 서로 기다리지 않았다
    assert sorted(started) == ["balance", "budgets", "entries"]
    assert len(cache._locks) == 3


def test_꺼져_있으면_잠금으로_직렬화하지_않는다(monkeypatch):
    """캐시를 끈 측정(CACHE_ENABLED=0)에서 잠금이 걸리면 OFF 수치가 느려져 비교가 깨진다."""
    monkeypatch.setenv("CACHE_ENABLED", "0")
    produce, calls = _slow_producer("v")

    async def run():
        return await asyncio.gather(
            *(cache.get_or_set("entries:all", produce) for _ in range(10))
        )

    results = asyncio.run(run())

    assert len(calls) == 10, "꺼져 있으면 요청마다 원본을 읽는다"
    assert results == ["v"] * 10
    assert cache._locks == {}


def test_재조회가_터지면_원본을_돌려준다(monkeypatch):
    """잠금을 잡은 뒤의 재조회도 실패할 수 있다. 그때도 조회는 끝까지 가야 한다."""
    monkeypatch.setenv("CACHE_ENABLED", "1")

    class FailSecondGet(FakeRedis):
        def __init__(self):
            super().__init__()
            self.gets = 0

        async def get(self, key):
            self.gets += 1
            if self.gets >= 2:
                raise RuntimeError("redis 가 중간에 죽었다")
            return None

    fake = FailSecondGet()
    monkeypatch.setattr(cache, "_get_client", lambda: fake)
    produce, calls = _counting_producer({"ok": True})

    assert asyncio.run(cache.get_or_set("budgets:all", produce)) == {"ok": True}
    assert len(calls) == 1


def test_close_는_잠금도_비운다(monkeypatch):
    """잠금은 이벤트 루프에 묶여 있다. 루프가 바뀐 뒤 그대로 쓰면 엉뚱한 곳에서 기다린다."""
    monkeypatch.setenv("CACHE_ENABLED", "1")
    fake = FakeRedis()
    monkeypatch.setattr(cache, "_get_client", lambda: fake)
    produce, _ = _counting_producer(1)

    asyncio.run(cache.get_or_set("balance:all", produce))
    assert cache._locks

    cache._client = fake
    asyncio.run(cache.close())
    assert cache._locks == {}
