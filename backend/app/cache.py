"""학생 서버 조회 캐시 (PRD v0.15 §9.1 — Redis, TTL 30초).

왜 필요한가: 학생 조회는 결산 공개 푸시 직후 1~2분에 몰린다(피크 동시 150). 그 1~2분 동안
모두가 **같은 것**을 본다 — 같은 잔액, 같은 내역 목록, 같은 예산. 캐시가 없으면 같은 쿼리와
같은 체인 조회(`/budgets` 는 예산마다 `get_budget` 을 부른다)를 150번 반복한다.

**캐시는 켜고 끌 수 있어야 한다.** 평가 산출물이 「캐시 켜고/끄고 비교」라서 둘 다 재야 하고,
무엇보다 캐시 때문에 틀린 값이 보이는지 확인하려면 끈 쪽과 대조할 수 있어야 한다.

쓰지 않는 곳:
- **쓰기 경로에는 쓰지 않는다.** 학생 서버는 조회 전용이고, 이 모듈도 읽기 결과만 담는다.
- **개인별 응답은 담지 않는다** (`/auth/me`, `/memberships/me`). 키에 사용자를 넣는 것을 깜빡하면
  남의 회원권이 보인다. 공개 장부(잔액·내역·예산·학기)만 담는다.

Redis 가 없거나 꺼져 있으면 **조용히 통과한다** — 캐시는 성능 장치지 정확성 장치가 아니다.
"""
import asyncio
import json
import logging
import os
from typing import Any, Awaitable, Callable, Optional

logger = logging.getLogger(__name__)

_ENABLED_ENV = "CACHE_ENABLED"
_URL_ENV = "REDIS_URL"
_TTL_ENV = "CACHE_TTL_SECONDS"

DEFAULT_TTL_SECONDS = 30


def enabled() -> bool:
    """캐시를 쓰는가. 기본은 **꺼짐** — 켜는 쪽을 명시하게 한다.

    학생 서버 compose 만 `CACHE_ENABLED=1` 로 올린다. 임원 서버는 쓰기 직후 바로 읽는 화면이
    많아 캐시가 오히려 틀린 값을 보여 줄 수 있어서, 기본값이 켜짐이면 안 된다.
    """
    return os.environ.get(_ENABLED_ENV, "").strip() in ("1", "true", "True")


def ttl_seconds() -> int:
    raw = os.environ.get(_TTL_ENV, "").strip()
    if not raw:
        return DEFAULT_TTL_SECONDS
    try:
        value = int(raw)
    except ValueError:
        logger.warning("%s 가 숫자가 아니다(%r). 기본값 %d 초를 쓴다", _TTL_ENV, raw, DEFAULT_TTL_SECONDS)
        return DEFAULT_TTL_SECONDS
    return value if value > 0 else DEFAULT_TTL_SECONDS


_client = None
_unavailable = False
_inflight: dict[str, asyncio.Future] = {}
_inflight_loop: Optional[asyncio.AbstractEventLoop] = None


def _inflight_map() -> dict[str, asyncio.Future]:
    """진행 중(in-flight) 키별 Future 맵. 요청 완료 시 즉시 키를 제거해 메모리 누적을 막는다."""
    global _inflight_loop
    loop = asyncio.get_running_loop()
    if _inflight_loop is not loop:
        _inflight.clear()
        _inflight_loop = loop
    return _inflight


def _get_client():
    """Redis 연결. 없거나 실패하면 None 이고, 다시 시도하지 않는다.

    매 요청마다 연결을 재시도하면 Redis 가 죽었을 때 **캐시가 없는 것보다 느려진다** —
    요청마다 연결 타임아웃을 기다리게 된다.
    """
    global _client, _unavailable
    if _unavailable:
        return None
    if _client is not None:
        return _client
    url = os.environ.get(_URL_ENV, "").strip()
    if not url:
        logger.info("%s 가 없어 캐시를 쓰지 않는다", _URL_ENV)
        _unavailable = True
        return None
    try:
        import redis.asyncio as redis  # 선택 의존성 — 없으면 캐시 없이 돈다
    except ImportError:
        logger.warning("redis 패키지가 없어 캐시를 쓰지 않는다 (requirements.txt 의 redis)")
        _unavailable = True
        return None
    try:
        _client = redis.from_url(url, socket_connect_timeout=1, socket_timeout=1)
    except Exception as e:  # 주소 형식 오류 등
        logger.warning("Redis 연결을 만들지 못했다(%s). 캐시 없이 돈다", e)
        _unavailable = True
        return None
    return _client


async def _read_cached(client, key: str) -> tuple[bool, Any]:
    """캐시 조회. (적중 여부, 역직렬화 값) 반환. Redis 오류는 호출자가 fail-open 처리한다."""
    hit = await client.get(key)
    if hit is None:
        return False, None
    try:
        return True, json.loads(hit)
    except Exception as e:
        logger.warning("캐시 역직렬화 실패(%s). 원본을 다시 읽는다: %s", key, e)
        return False, None


async def get_or_set(
    key: str,
    produce: Callable[[], Awaitable[Any]],
    ttl: Optional[int] = None,
    *,
    should_cache: Optional[Callable[[Any], bool]] = None,
) -> Any:
    """[key] 에 담긴 값을 돌려주고, 없으면 [produce] 를 불러 담는다.

    - 같은 키가 만료된 직후 동시에 여러 요청이 몰려도 프로세스 내 진행 중(in-flight) Future 로
      한 요청만 [produce] 를 실행하고, 나머지 대기자는 그 결과를 공유한다(stampede·직렬 대기 방지).
    - 완료 시 in-flight 키를 즉시 제거해 존재하지 않는 term_id 등으로 인한 메모리 누적을 막는다.
    - [should_cache] 가 False 를 반환하면(예: 체인 조회 일부 실패로 불완전한 응답) Redis 에는
      저장하지 않되, 동시에 기다리던 요청끼리는 이번 조회 결과를 공유한다.
    - **Redis 가 말을 안 들으면 [produce] 결과를 그대로 돌려준다.** 캐시 장애가 조회 장애가
      되면 안 된다 — 학생 화면이 통째로 멈춘다.

    담는 값은 JSON 으로 직렬화할 수 있어야 한다. 직렬화에 실패하면 담지 않고 값만 돌려준다.
    """
    if not enabled():
        return await produce()
    client = _get_client()
    if client is None:
        return await produce()

    try:
        found, cached = await _read_cached(client, key)
        if found:
            return cached
    except Exception as e:
        logger.warning("캐시 조회 실패(%s). 원본을 읽는다: %s", key, e)
        return await produce()

    inflight = _inflight_map()
    existing = inflight.get(key)
    if existing is not None:
        return await asyncio.shield(existing)

    loop = asyncio.get_running_loop()
    future: asyncio.Future = loop.create_future()
    inflight[key] = future
    try:
        value = await produce()
        if should_cache is None or should_cache(value):
            try:
                await client.set(key, json.dumps(value, default=str), ex=ttl or ttl_seconds())
            except TypeError as e:
                logger.warning("캐시에 담을 수 없는 값(%s): %s", key, e)
            except Exception as e:
                logger.warning("캐시 저장 실패(%s): %s", key, e)
    except asyncio.CancelledError:
        if not future.done():
            future.cancel()
        raise
    except BaseException as exc:
        if not future.done():
            future.set_exception(exc)
            future.exception()
        raise
    else:
        if not future.done():
            future.set_result(value)
        return value
    finally:
        if inflight.get(key) is future:
            inflight.pop(key, None)


async def close() -> None:
    """프로세스를 내릴 때 Redis 연결과 진행 중 Future 맵을 정리한다 (`main_student.py` lifespan 종료 시 호출)."""
    global _client, _inflight_loop
    if _client is not None:
        try:
            await _client.aclose()
        except Exception:
            pass
        _client = None
    _inflight.clear()
    _inflight_loop = None
