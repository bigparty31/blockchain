"""체인 테스트가 같이 쓰는 값. 노드 주소·계정 배치가 바뀌면 여기만 고친다.

키는 Hardhat 기본 니모닉에서 유도한다 (공개된 테스트 키라 파일에 적지 않는다). 계정 번호는 contracts/scripts/deploy.ts 배치와 같다.
노드를 쓰는 테스트는 conftest 의 node 픽스처를 받는다 — 노드가 없으면 건너뛴다.
"""
import json
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
