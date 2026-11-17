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
    yield
    cache._client = None
    cache._unavailable = False


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
