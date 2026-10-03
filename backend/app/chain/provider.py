"""요청에서 쓸 ChainClient 를 고른다. FastAPI 의존성으로 쓴다: chain: ChainClient = Depends(get_chain_client).

CHAIN_RPC_URL 이 비어 있으면 FakeChainClient, 있으면 Web3ChainClient(RELAYER_PRIVATE_KEY 필요)다. 호출하는 쪽 코드는 같다.
가짜는 체인에 아무것도 남기지 않고 가짜 서명도 통과시키므로, 고를 때 로그로 경고한다 (JWT_SECRET 기본값과 같은 방식).

실제 클라이언트는 첫 요청 때 연결·점검하고 재사용한다. 서버 시작 때 붙지 않는 이유 — 노드가 꺼져 있어도
인증·목록처럼 체인을 쓰지 않는 API 는 돌아야 하고, 노드 없이 일하는 팀원도 서버를 띄울 수 있어야 한다.
요청마다 is_current() 로 재배포·노드 재시작을 확인해, 낡았으면 닫고 새로 만든다.
연결이 실패하면 그 시도를 기다리던 요청들은 같은 실패를 받고(각자 다시 시도하지 않는다), 그 뒤에 온 요청이 다시 시도한다.
실패는 ChainSetupError(배포 기록 문제는 하위 클래스 DeploymentError)로 올라가고 API 는 503 으로 바꾼다.
"""
import asyncio
import logging
import os
import time
from typing import Optional

from app.chain.client import ChainClient
from app.chain.fake import FakeChainClient
from app.chain.models import ChainSetupError

logger = logging.getLogger(__name__)

_client: Optional[ChainClient] = None
# (실패한 시각, 예외 종류, 메시지). 예외 객체를 들고 있으면 traceback 과 요청 프레임이 다음 성공까지 살아 있고,
# 기다리던 요청들이 같은 객체를 다시 던질 때마다 traceback 이 길어진다. 종류와 메시지만 두고 매번 새로 만든다
_failure: Optional[tuple[float, type, str]] = None
_lock: Optional[asyncio.Lock] = None
_lock_loop: Optional[asyncio.AbstractEventLoop] = None


def _loop_lock() -> asyncio.Lock:
    # asyncio.Lock 은 처음 경합한 이벤트 루프에 묶인다. 루프가 바뀌면(테스트마다 asyncio.run 등) 새로 만든다
    global _lock, _lock_loop
    loop = asyncio.get_running_loop()
    if _lock is None or _lock_loop is not loop:
        _lock, _lock_loop = asyncio.Lock(), loop
    return _lock


async def _is_current(client: ChainClient) -> bool:
    check = getattr(client, "is_current", None)  # 가짜는 낡을 것이 없다
    return True if check is None else await check()


async def _close(client: ChainClient) -> None:
    close = getattr(client, "close", None)
    if close is not None:
        await close()


async def _create() -> ChainClient:
    rpc_url = os.environ.get("CHAIN_RPC_URL", "").strip()
    if not rpc_url:
        logger.warning(
            "CHAIN_RPC_URL 미설정: FakeChainClient 를 씁니다. 체인에 아무것도 기록되지 않고 가짜 서명도 통과합니다. "
            "개발·테스트 전용이니 실제 체인에 붙이려면 CHAIN_RPC_URL 과 RELAYER_PRIVATE_KEY 를 설정하세요."
        )
        return FakeChainClient()
    from app.chain.web3_client import Web3ChainClient  # 노드를 쓸 때만 web3 를 불러온다

    return await Web3ChainClient.connect(rpc_url, os.environ.get("RELAYER_PRIVATE_KEY", "").strip())


async def get_chain_client() -> ChainClient:
    global _client, _failure
    seen = _client
    # 확인하는 동안 다른 요청이 교체했을 수 있다. 버려진(닫힌) 클라이언트를 돌려주지 않는다
    if seen is not None and await _is_current(seen) and _client is seen:
        return seen
    arrived = time.monotonic()
    async with _loop_lock():
        if _client is not None and _client is not seen:
            return _client  # 기다리는 동안 다른 요청이 새로 만들었다
        if _failure is not None and _failure[0] >= arrived:
            # 기다리는 동안 다른 요청이 연결을 시도했다가 실패했다. 같은 결과를 받는다
            _, kind, message = _failure
            raise (kind if issubclass(kind, ChainSetupError) else ChainSetupError)(message)
        stale, _client = _client, None
        if stale is not None:
            await _close(stale)
        try:
            _client = await _create()
        except Exception as e:
            _failure = (time.monotonic(), type(e), str(e))
            raise
        _failure = None
        return _client


async def close_chain_client() -> None:
    """만들어 둔 클라이언트를 닫고 버린다. 서버 종료 때 부른다 (app/main.py)."""
    global _client, _failure
    client, _client, _failure = _client, None, None
    if client is not None:
        await _close(client)


def reset_chain_client() -> None:
    """만들어 둔 클라이언트를 닫지 않고 버린다. 이벤트 루프 밖에서 부르는 테스트용 — 실제 연결은 close_chain_client 로 닫는다."""
    global _client, _failure, _lock, _lock_loop
    _client, _failure, _lock, _lock_loop = None, None, None, None
