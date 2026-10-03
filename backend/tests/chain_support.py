"""체인 테스트가 같이 쓰는 값. 노드 주소·계정 배치가 바뀌면 여기만 고친다.

키는 Hardhat 기본 니모닉에서 유도한다 (공개된 테스트 키라 파일에 적지 않는다). 계정 번호는 contracts/scripts/deploy.ts 배치와 같다.
노드를 쓰는 테스트는 conftest 의 node 픽스처를 받는다 — 노드가 없으면 건너뛴다.
"""
import json
import time
import urllib.request

from eth_account import Account

RPC_URL = "http://127.0.0.1:8545"
UNREACHABLE = "http://127.0.0.1:1"
HARDHAT_MNEMONIC = "test test test test test test test test test test test junk"

Account.enable_unaudited_hdwallet_features()


def hardhat_key(index: int) -> str:
    return "0x" + bytes(Account.from_mnemonic(HARDHAT_MNEMONIC, account_path=f"m/44'/60'/0'/0/{index}").key).hex()


RELAYER_KEY = hardhat_key(4)
TREASURER_KEY = hardhat_key(2)
RELAYER = Account.from_key(RELAYER_KEY).address


def rpc(method: str, params: list = ()):
    """노드에 JSON-RPC 를 직접 보낸다. 연결되지 않으면 OSError."""
    request = urllib.request.Request(
        RPC_URL,
        data=json.dumps({"jsonrpc": "2.0", "method": method, "params": list(params), "id": 1}).encode(),
        headers={"Content-Type": "application/json"},
    )
    return json.loads(urllib.request.urlopen(request, timeout=1).read())["result"]


def node_available() -> bool:
    try:
        rpc("eth_chainId")
    except OSError:
        return False
    return True


async def chain_now(w3) -> int:
    """체인이 다음 블록에 쓸 시각. deadline 을 정할 때 쓴다.

    Hardhat 은 블록이 없으면 최신 블록 시각이 마지막 블록(예: 배포)에 머물고, 다음 블록은 실제 시각으로 채굴한다.
    pending 블록 시각이 그 "다음 채굴 시각" 이다 — evm_increaseTime 으로 앞당긴 양도 들어 있다.
    pending 블록을 주지 않는 노드면 최신 블록 시각과 실제 시각 중 늦은 쪽으로 대신한다.
    """
    pending = await w3.eth.get_block("pending")
    if pending is not None:
        return pending["timestamp"]
    return max((await w3.eth.get_block("latest"))["timestamp"], int(time.time()))


async def in_snapshot(w3, body):
    """body() 를 실행하고 체인 상태를 되돌린다. 실제로 보내는 테스트가 노드를 오염시키지 않게 한다."""
    snapshot = (await w3.provider.make_request("evm_snapshot", []))["result"]
    try:
        return await body()
    finally:
        await w3.provider.make_request("evm_revert", [snapshot])
