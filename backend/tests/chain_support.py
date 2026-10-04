"""체인 테스트가 같이 쓰는 값과 도우미.

노드 주소·계정 배치·서명 방식은 scripts/local_chain.py 가 정본이다 (스모크 스크립트와 같이 쓴다). 바뀌면 거기만 고친다.
노드를 쓰는 테스트는 conftest 의 node 픽스처를 받는다 — 노드가 없으면 건너뛴다.
"""
import json
import shutil
import urllib.request
from pathlib import Path

from eth_account import Account

from app.chain.deployment import DEFAULT_PATH, Eip712Domain, domain_separator
from scripts.local_chain import LOCAL_RPC_URL, RELAYER_INDEX, TREASURER_INDEX, chain_now, hardhat_key, sign_as_app

RPC_URL = LOCAL_RPC_URL
UNREACHABLE = "http://127.0.0.1:1"

RELAYER_KEY = hardhat_key(RELAYER_INDEX)
TREASURER_KEY = hardhat_key(TREASURER_INDEX)
RELAYER = Account.from_key(RELAYER_KEY).address

__all__ = [
    "RPC_URL",
    "UNREACHABLE",
    "RELAYER_KEY",
    "TREASURER_KEY",
    "RELAYER",
    "chain_now",
    "sign_as_app",
    "rpc",
    "node_available",
    "in_snapshot",
    "deployment_variant",
]


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


async def in_snapshot(w3, body):
    """body() 를 실행하고 체인 상태를 되돌린다. 실제로 보내는 테스트가 노드를 오염시키지 않게 한다."""
    snapshot = (await w3.provider.make_request("evm_snapshot", []))["result"]
    try:
        return await body()
    finally:
        await w3.provider.make_request("evm_revert", [snapshot])


def deployment_variant(tmp_path: Path, change=None, change_abi=None) -> Path:
    """배포 기록을 바꾼 사본. 도메인 해시를 다시 계산해 load_deployment 의 일관성 검사는 통과시킨다."""
    raw = json.loads(DEFAULT_PATH.read_text(encoding="utf-8"))
    if change:
        change(raw)
    for domain in raw["eip712"].values():
        domain["domainSeparator"] = domain_separator(Eip712Domain.model_validate(domain))
    path = tmp_path / "localhost.json"
    path.write_text(json.dumps(raw), encoding="utf-8")
    shutil.copytree(DEFAULT_PATH.parent / "abi", tmp_path / "abi")
    if change_abi:
        change_abi(tmp_path / "abi")
    return path
