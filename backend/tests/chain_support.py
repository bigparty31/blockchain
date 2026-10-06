"""체인 테스트가 같이 쓰는 값과 도우미.

노드 주소·계정 배치·서명 방식은 scripts/local_chain.py 가 정본이다 (스모크 스크립트와 같이 쓴다). 바뀌면 거기만 고친다.
노드를 쓰는 테스트는 conftest 의 node 픽스처를 받는다 — 노드가 없으면 건너뛴다.
"""
import asyncio
import json
import shutil
import urllib.request
from pathlib import Path
from typing import Optional

from eth_account import Account
from eth_utils import keccak

from app.chain.deployment import DEFAULT_PATH, Eip712Domain, domain_separator, load_abi, load_deployment
from app.chain.eip712 import typed_data
from app.chain.models import ZERO_BYTES32, ChainEntry, ConfirmApproval
from app.chain.revert import RevertDecoder
from app.chain.web3_client import Web3ChainClient
from scripts.local_chain import (
    AUDITOR_INDEX,
    LOCAL_RPC_URL,
    PRESIDENT_INDEX,
    RELAYER_INDEX,
    TREASURER_INDEX,
    approval_from_entry,
    chain_now,
    hardhat_key,
    sign_as_app,
    sign_typed_data,
)

RPC_URL = LOCAL_RPC_URL
UNREACHABLE = "http://127.0.0.1:1"

# 스냅샷 안 테스트가 쓰는 항목·예산 id 구간. 공용 노드에는 등록 API·예산 화면이 DB id(1부터)로 남긴 기록과
# 스모크 기록(8000억 + 실행 시각(밀리초) × 10, 지금은 18조대)이 있다. 둘과 겹치면 ENTRY_ALREADY_EXISTS·BudgetAlreadyExists 로 거짓 실패한다
def unchecked(payload, **changes):
    """모델 검증을 건너뛰고 값을 바꾼 요청 (pydantic 의 model_copy(update=...) 는 검증하지 않는다).

    모델은 컨트랙트가 거부할 값(hash 0, 금액 0 등)을 만들 때 막는다 (app/chain/models.py). 그 아래 층
    — EIP-712 인코딩, FakeChainClient, 컨트랙트 — 도 같은 값을 스스로 거부하는지 볼 때만 쓴다.
    """
    return payload.model_copy(update=changes)


TEST_ID_BASE = 900_000_000_000
KST_MIDNIGHT = 1790694000  # 2026-09-30 00:00 KST. 테스트 항목의 사용일

RELAYER_KEY = hardhat_key(RELAYER_INDEX)
TREASURER_KEY = hardhat_key(TREASURER_INDEX)
AUDITOR_KEY = hardhat_key(AUDITOR_INDEX)
PRESIDENT_KEY = hardhat_key(PRESIDENT_INDEX)
RELAYER = Account.from_key(RELAYER_KEY).address
TREASURER = Account.from_key(TREASURER_KEY).address
AUDITOR = Account.from_key(AUDITOR_KEY).address
PRESIDENT = Account.from_key(PRESIDENT_KEY).address

__all__ = [
    "RPC_URL",
    "UNREACHABLE",
    "TEST_ID_BASE",
    "KST_MIDNIGHT",
    "on_chain",
    "RELAYER_KEY",
    "TREASURER_KEY",
    "RELAYER",
    "TREASURER",
    "AUDITOR",
    "AUDITOR_KEY",
    "PRESIDENT",
    "PRESIDENT_KEY",
    "approval_for_id",
    "issue_budget",
    "budget_remaining",
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


def on_chain(body):
    """연결 → 스냅샷 안에서 body(client, now) → 되돌림 → 닫기. now 는 체인 시각(다음 블록)."""

    async def run():
        client = await Web3ChainClient.connect(RPC_URL, RELAYER_KEY, DEFAULT_PATH)
        try:
            now = await chain_now(client._w3)
            return await in_snapshot(client._w3, lambda: body(client, now))
        finally:
            await client.close()

    return asyncio.run(run())


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


def approval_for_id(entry: Optional[ChainEntry], entry_id: int, deadline: int, **override) -> ConfirmApproval:
    """앱처럼 체인 값으로 만든 확정 요청 (scripts.local_chain.approval_from_entry).

    체인에 없는 id(entry 가 None)면 ENTRY_NOT_FOUND 를 보려고 임시 hash·commit 을 채운다.
    """
    if entry is not None:
        return approval_from_entry(entry, deadline, **override)
    fields = dict(
        id=entry_id,
        hash="0x" + "11" * 32,
        entry_commit="0x" + "22" * 32,
        had_warning=False,
        warning_reason_hash=ZERO_BYTES32,
        deadline=deadline,
    )
    return ConfirmApproval(**{**fields, **override})


# IBudgetToken 의 IssueRequest typehash 순서 (docs/CONTRACTS.md EIP-712 표)
_ISSUE_FIELDS = (
    ("budgetId", "uint256"),
    ("term", "uint256"),
    ("category", "bytes32"),
    ("amount", "uint256"),
    ("expiresAt", "uint256"),
    ("deadline", "uint256"),
)


def _budget_token(w3):
    deployment = load_deployment(DEFAULT_PATH)
    contract = deployment.contracts["BudgetToken"]
    return deployment, w3.eth.contract(address=contract.address, abi=load_abi(contract, DEFAULT_PATH))


async def issue_budget(w3, budget_id: int, amount: int, term: int = 20262, days: int = 30) -> None:
    """테스트 전용 — 회장이 IssueRequest 에 서명하고 릴레이어가 issue 를 보낸다. 반드시 in_snapshot 안에서 쓴다.

    공용 개발 노드에 예산을 남기면 "학기·항목당 예산 하나" 규칙 때문에 예산 편성 화면이 BudgetAlreadyIssued 로 막힌다.
    반대로 화면이 이미 발행한 예산과 겹치지 않게, budget_id 는 TEST_ID_BASE 구간을 쓰고 항목(category)은 앱이 쓰지 않는
    테스트 전용 이름("테스트 예산 {budget_id}")으로 만든다. 백엔드에는 아직 예산 릴레이가 없어(이번 범위는 원장) 여기서 직접 보낸다.
    """
    deployment, contract = _budget_token(w3)
    now = await chain_now(w3)
    message = {
        "budgetId": budget_id,
        "term": term,
        "category": "0x" + keccak(text=f"테스트 예산 {budget_id}").hex(),  # category 는 keccak256(utf8(이름)) (CONTRACTS.md)
        "amount": amount,
        "expiresAt": now + days * 86400,
        "deadline": now + 600,
    }
    signature = sign_typed_data(typed_data("IssueRequest", _ISSUE_FIELDS, deployment.eip712["BudgetToken"], message), PRESIDENT_KEY)
    call = contract.functions.issue(message, bytes.fromhex(signature[2:]))
    relayer = Account.from_key(RELAYER_KEY)
    try:
        gas = await call.estimate_gas({"from": relayer.address}, block_identifier="pending")
    except Exception as e:
        # 시뮬레이션에서 사유와 함께 멈춘다. Hardhat 은 revert 하는 전송에 에러만 돌려줘 receipt 로는 사유를 알 수 없다.
        # revert 가 아닌 실패(연결 끊김 등)는 그대로 올린다
        revert = RevertDecoder(contract.abi).from_web3_error(e)
        if revert is None:
            raise
        raise AssertionError(f"예산 발행이 revert 한다: {revert}") from e
    tx = await call.build_transaction(
        {"from": relayer.address, "nonce": await w3.eth.get_transaction_count(relayer.address, "pending"), "gas": gas * 2}
    )
    await w3.eth.wait_for_transaction_receipt(await w3.eth.send_raw_transaction(relayer.sign_transaction(tx).raw_transaction))


async def budget_remaining(w3, budget_id: int) -> int:
    _, contract = _budget_token(w3)
    return await contract.functions.remaining(budget_id).call()
