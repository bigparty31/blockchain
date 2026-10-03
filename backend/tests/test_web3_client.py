"""Web3ChainClient 의 연결·시작 점검과 provider 의 구현 선택.

@pytest.mark.chain 테스트는 로컬 Hardhat 노드가 필요하고, 127.0.0.1:8545 에 노드가 없으면 건너뛴다.
노드를 띄운 뒤 contracts 에서 npm run deploy:local 로 한 번 배포해 두면 돈다. 노드의 상태는 바꾸지 않는다.
키는 Hardhat 기본 니모닉에서 유도한다 (공개된 테스트 키라 파일에 적지 않는다). 계정 번호는 contracts/scripts/deploy.ts 배치와 같다.
"""
import asyncio
import json
import logging
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

import pytest
from eth_account import Account

from app.chain import ChainSetupError, FakeChainClient, RecordRequest
from app.chain import provider
from app.chain.deployment import DEFAULT_PATH, DeploymentError, Eip712Domain, domain_separator, load_abi, load_deployment
from app.chain.models import KIND_ORDER
from app.chain.provider import close_chain_client, get_chain_client, reset_chain_client
from app.chain.web3_client import BUDGET_TOKEN, LEDGER, ROLE_MANAGER, Web3ChainClient
from app.main import app

RPC_URL = "http://127.0.0.1:8545"
UNREACHABLE = "http://127.0.0.1:1"
HARDHAT_MNEMONIC = "test test test test test test test test test test test junk"
BACKEND = Path(__file__).resolve().parents[1]

Account.enable_unaudited_hdwallet_features()


def hardhat_key(index: int) -> str:
    return "0x" + bytes(Account.from_mnemonic(HARDHAT_MNEMONIC, account_path=f"m/44'/60'/0'/0/{index}").key).hex()


RELAYER_KEY = hardhat_key(4)
TREASURER_KEY = hardhat_key(2)

VECTORS = json.loads((Path(__file__).parent / "fixtures" / "eip712_vectors.json").read_text(encoding="utf-8"))["vectors"]


@pytest.fixture(autouse=True)
def clean(monkeypatch):
    # 셸·.env 의 체인 설정이 결과를 바꾸지 않게 하고, provider 가 만들어 둔 클라이언트를 테스트마다 버린다
    for name in ("CHAIN_RPC_URL", "RELAYER_PRIVATE_KEY", "DEPLOYMENTS_FILE"):
        monkeypatch.delenv(name, raising=False)
    reset_chain_client()
    yield
    reset_chain_client()


@pytest.fixture
def node():
    request = urllib.request.Request(
        RPC_URL,
        data=b'{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}',
        headers={"Content-Type": "application/json"},
    )
    try:
        urllib.request.urlopen(request, timeout=1).read()
    except OSError:
        pytest.skip("로컬 Hardhat 노드가 없다 (contracts 에서 npx hardhat node → npm run deploy:local)")


def connect(key: str, deployment_file: Path = DEFAULT_PATH, rpc_url: str = RPC_URL) -> Web3ChainClient:
    """연결해서 점검까지 한 뒤 닫는다. 점검 결과만 본다."""

    async def run():
        client = await Web3ChainClient.connect(rpc_url, key, deployment_file)
        await client.close()
        return client

    return asyncio.run(run())


def offline_client(key: str = RELAYER_KEY) -> Web3ChainClient:
    """노드 없이 만든 클라이언트. 체인을 부르지 않는 기능만 쓴다."""
    contracts = {LEDGER: None, ROLE_MANAGER: None}
    return Web3ChainClient(None, Account.from_key(key), load_deployment(DEFAULT_PATH), contracts, DEFAULT_PATH)


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


def move_contract(name: str, address: str):
    def change(raw):
        raw["contracts"][name]["address"] = address
        raw["eip712"][name]["verifyingContract"] = address

    return change


# ---------------------------------------------------------------- 키


@pytest.mark.parametrize("key", ["", "0x1234", "ab" * 32, "0x" + "zz" * 32])
def test_private_key_format_is_checked_before_connecting(key):
    with pytest.raises(ChainSetupError, match="0x \\+ hex 64자") as error:
        connect(key, rpc_url=UNREACHABLE)
    if key:
        assert key not in str(error.value)


@pytest.mark.parametrize("key", ["0x" + "00" * 32, "0x" + "ff" * 32])
def test_private_key_out_of_range_is_a_setup_error(key):
    # 형식은 맞지만 개인키가 아닌 값. 맨 ValueError 로 새면 503 처리기를 지나쳐 500 이 된다
    with pytest.raises(ChainSetupError, match="유효한 개인키 범위") as error:
        connect(key, rpc_url=UNREACHABLE)
    assert key not in str(error.value)


def test_repr_does_not_show_the_key():
    client = offline_client()
    assert RELAYER_KEY[2:] not in repr(client).lower()
    assert client.relayer_address in repr(client)


def test_signer_of_recovers_with_the_ledger_domain():
    vector = next(v for v in VECTORS if v["name"] == "record_income")
    m = vector["message"]
    request = RecordRequest(
        id=m["id"],
        hash=m["hash"],
        amount=m["amount"],
        kind=KIND_ORDER[m["kind"]],
        term=m["term"],
        occurred_at=m["occurredAt"],
        budget_id=m["budgetId"],
        corrects_id=m["correctsId"],
        deadline=m["deadline"],
    )
    assert offline_client().signer_of(request, vector["signature"]) == vector["signer"]


# ---------------------------------------------------------------- 배포 기록·ABI


@pytest.mark.parametrize("abi_path", ["/etc/hosts", "../secret.json", "abi/../../x.json", "C:\\x.json", ""])
def test_abi_path_must_stay_inside_the_deployments_folder(tmp_path, abi_path):
    def change(raw):
        raw["contracts"][LEDGER]["abi"] = abi_path

    with pytest.raises(DeploymentError, match="상대 경로") as error:
        load_deployment(deployment_variant(tmp_path, change))
    assert str(tmp_path) not in str(error.value)


def test_broken_abi_reports_the_line_like_the_deployment_file(tmp_path):
    def corrupt(abi_dir):
        (abi_dir / f"{LEDGER}.json").write_text("[\n{,]", encoding="utf-8")

    path = deployment_variant(tmp_path, change_abi=corrupt)
    with pytest.raises(DeploymentError, match="JSON 형식 오류 .*2행") as error:
        load_abi(load_deployment(path).contracts[LEDGER], path)
    assert str(tmp_path) not in str(error.value)


def test_deployment_error_is_a_setup_error():
    # 503 처리기 하나(ChainSetupError)가 배포 기록 문제까지 받는다
    assert issubclass(DeploymentError, ChainSetupError)


def test_setup_errors_become_503():
    handler = app.exception_handlers[ChainSetupError]
    response = asyncio.run(handler(None, DeploymentError("배포 기록이 없습니다 (x.json)")))
    assert response.status_code == 503
    assert json.loads(response.body) == {"detail": "배포 기록이 없습니다 (x.json)"}


# ---------------------------------------------------------------- provider


def test_without_rpc_url_the_fake_is_used_with_a_warning(caplog, monkeypatch):
    # alembic/env.py 의 fileConfig 가 같은 프로세스의 기존 로거를 끈다 (test_migrations 가 먼저 돌면). 다시 켜 둔다
    monkeypatch.setattr(logging.getLogger("app.chain.provider"), "disabled", False)
    with caplog.at_level(logging.WARNING, logger="app.chain.provider"):
        first = asyncio.run(get_chain_client())
    assert isinstance(first, FakeChainClient)
    assert "CHAIN_RPC_URL 미설정" in caplog.text
    assert asyncio.run(get_chain_client()) is first


def test_provider_does_not_import_web3_for_the_fake():
    # 노드 없이 일하는 팀원은 web3 를 불러올 이유가 없다. 새 프로세스에서 확인한다
    code = "import sys, app.chain.provider; print('web3' in sys.modules)"
    out = subprocess.run([sys.executable, "-c", code], cwd=BACKEND, capture_output=True, text=True, check=True)
    assert out.stdout.strip() == "False"


def test_failed_connect_is_not_kept(monkeypatch):
    # 노드가 꺼져 있던 동안의 실패를 붙잡아 두지 않는다. 설정이 바뀌면 다음 요청에서 새로 고른다
    monkeypatch.setenv("CHAIN_RPC_URL", UNREACHABLE)
    monkeypatch.setenv("RELAYER_PRIVATE_KEY", RELAYER_KEY)
    with pytest.raises(ChainSetupError, match="노드에 연결할 수 없다"):
        asyncio.run(get_chain_client())
    monkeypatch.delenv("CHAIN_RPC_URL")
    assert isinstance(asyncio.run(get_chain_client()), FakeChainClient)


def test_concurrent_requests_share_one_failed_attempt(monkeypatch):
    # 노드가 응답하지 않을 때 기다리던 요청이 각자 다시 연결하면 N 번째 요청은 N 배를 기다린다
    attempts = []

    async def slow_failure(*args, **kwargs):
        attempts.append(1)
        await asyncio.sleep(0.05)
        raise ChainSetupError("노드에 연결할 수 없다 (테스트)")

    monkeypatch.setenv("CHAIN_RPC_URL", UNREACHABLE)
    monkeypatch.setattr(Web3ChainClient, "connect", slow_failure)

    async def three():
        return await asyncio.gather(*(get_chain_client() for _ in range(3)), return_exceptions=True)

    results = asyncio.run(three())
    assert all(isinstance(r, ChainSetupError) for r in results)
    assert len(attempts) == 1


def test_lock_works_across_event_loops(monkeypatch):
    # 테스트·도구가 asyncio.run 을 여러 번 써도 reset 없이 경합할 수 있어야 한다
    async def slow_failure(*args, **kwargs):
        await asyncio.sleep(0.01)
        raise ChainSetupError("노드에 연결할 수 없다 (테스트)")

    monkeypatch.setenv("CHAIN_RPC_URL", UNREACHABLE)
    monkeypatch.setattr(Web3ChainClient, "connect", slow_failure)

    async def three():
        return await asyncio.gather(*(get_chain_client() for _ in range(3)), return_exceptions=True)

    for _ in range(2):
        assert all(isinstance(r, ChainSetupError) for r in asyncio.run(three()))


def test_stale_client_is_closed_and_replaced(monkeypatch):
    class Stale:
        closed = False

        async def is_current(self):
            return False

        async def close(self):
            self.closed = True

    stale = Stale()
    monkeypatch.setattr(provider, "_client", stale)
    replacement = asyncio.run(get_chain_client())
    assert stale.closed and isinstance(replacement, FakeChainClient)


def test_close_chain_client_closes_the_client(monkeypatch):
    class Closable:
        closed = False

        async def close(self):
            self.closed = True

    client = Closable()
    monkeypatch.setattr(provider, "_client", client)
    asyncio.run(close_chain_client())
    assert client.closed and provider._client is None


# ---------------------------------------------------------------- 로컬 노드


@pytest.mark.chain
def test_connects_with_the_relayer_key(node):
    accounts = json.loads(DEFAULT_PATH.read_text(encoding="utf-8"))["accounts"]
    assert connect(RELAYER_KEY).relayer_address == accounts["relayer"]


@pytest.mark.chain
def test_officer_key_is_refused(node):
    # 서버가 임원 키를 가지면 승인 없이 확정을 올릴 수 있다 (PRD §9.2)
    with pytest.raises(ChainSetupError, match="임원 롤을 가진 주소"):
        connect(TREASURER_KEY)


@pytest.mark.chain
def test_relayer_without_balance_is_refused(node):
    empty = "0x" + bytes(Account.create().key).hex()
    with pytest.raises(ChainSetupError, match="잔액이 0"):
        connect(empty)


@pytest.mark.chain
def test_other_chain_is_refused(node, tmp_path):
    def change(raw):
        raw["chainId"] = 80002
        for domain in raw["eip712"].values():
            domain["chainId"] = 80002

    with pytest.raises(ChainSetupError, match=r"연결한 체인\(31337\)이 배포 기록의 체인\(80002\)과 다르다"):
        connect(RELAYER_KEY, deployment_variant(tmp_path, change))


@pytest.mark.chain
def test_empty_chain_asks_for_redeploy(node, tmp_path):
    # 노드를 재시작하면 체인이 비어 원장 주소에 코드가 없다. 같은 상황을 아무 코드도 없는 주소로 만든다
    with pytest.raises(ChainSetupError, match="원장 주소에 컨트랙트가 없다"):
        connect(RELAYER_KEY, deployment_variant(tmp_path, move_contract(LEDGER, "0x" + "12" * 20)))


@pytest.mark.chain
def test_stale_budget_token_in_the_deployment_is_refused(node, tmp_path):
    with pytest.raises(ChainSetupError, match="BudgetToken 가 배포 기록과 다르다"):
        connect(RELAYER_KEY, deployment_variant(tmp_path, move_contract(BUDGET_TOKEN, "0x" + "34" * 20)))


@pytest.mark.chain
def test_stale_abi_is_not_reported_as_a_dead_node(node, tmp_path):
    def drop_domain_separator(abi_dir):
        path = abi_dir / f"{LEDGER}.json"
        abi = [item for item in json.loads(path.read_text(encoding="utf-8")) if item.get("name") != "DOMAIN_SEPARATOR"]
        path.write_text(json.dumps(abi), encoding="utf-8")

    with pytest.raises(ChainSetupError, match="배포 기록·ABI 가 지금 체인의 컨트랙트와 맞지 않는다"):
        connect(RELAYER_KEY, deployment_variant(tmp_path, change_abi=drop_domain_separator))


@pytest.mark.chain
def test_is_current_notices_a_changed_deployment_file(node, tmp_path):
    path = deployment_variant(tmp_path)

    async def run():
        client = await Web3ChainClient.connect(RPC_URL, RELAYER_KEY, path)
        try:
            before = await client.is_current()
            raw = json.loads(path.read_text(encoding="utf-8"))
            raw["network"] = "redeployed"
            path.write_text(json.dumps(raw), encoding="utf-8")
            return before, await client.is_current()
        finally:
            await client.close()

    assert asyncio.run(run()) == (True, False)


@pytest.mark.chain
def test_is_current_notices_a_changed_abi(node, tmp_path):
    # 컨트랙트를 고쳐 같은 주소에 다시 배포하면 배포 기록은 그대로고 ABI 만 바뀐다
    path = deployment_variant(tmp_path)

    async def run():
        client = await Web3ChainClient.connect(RPC_URL, RELAYER_KEY, path)
        try:
            abi_path = tmp_path / "abi" / f"{LEDGER}.json"
            abi = json.loads(abi_path.read_text(encoding="utf-8"))
            abi.append({"type": "function", "name": "added", "inputs": [], "outputs": [], "stateMutability": "view"})
            abi_path.write_text(json.dumps(abi), encoding="utf-8")
            return await client.is_current()
        finally:
            await client.close()

    assert asyncio.run(run()) is False


@pytest.mark.chain
def test_provider_reconnects_after_the_deployment_file_changes(node, tmp_path, monkeypatch):
    path = deployment_variant(tmp_path)
    monkeypatch.setenv("CHAIN_RPC_URL", RPC_URL)
    monkeypatch.setenv("RELAYER_PRIVATE_KEY", RELAYER_KEY)
    monkeypatch.setenv("DEPLOYMENTS_FILE", str(path))

    async def run():
        first = await get_chain_client()
        raw = json.loads(path.read_text(encoding="utf-8"))
        raw["network"] = "redeployed"
        path.write_text(json.dumps(raw), encoding="utf-8")
        second = await get_chain_client()
        await close_chain_client()
        return first, second

    first, second = asyncio.run(run())
    assert isinstance(first, Web3ChainClient) and second is not first
