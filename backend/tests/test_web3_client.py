"""Web3ChainClient 의 연결·시작 점검과 provider 의 구현 선택.

@pytest.mark.chain 테스트는 로컬 Hardhat 노드가 필요하고, 노드가 없으면 건너뛴다 (conftest 의 node 픽스처).
노드를 띄운 뒤 contracts 에서 npm run deploy:local 로 한 번 배포해 두면 돈다. 노드의 상태는 바꾸지 않는다.
"""
import asyncio
import gc
import json
import logging
import shutil
import subprocess
import sys
import threading
import time
import warnings
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from types import SimpleNamespace

import pytest
from eth_account import Account

from app.chain import ChainSetupError, FakeChainClient, RecordRequest
from app.chain import provider
from app.chain import web3_client
from app.chain.deployment import DEFAULT_PATH, DeploymentError, Eip712Domain, domain_separator, load_abi, load_deployment
from app.chain.models import KIND_ORDER
from app.chain.provider import close_chain_client, get_chain_client, reset_chain_client
from app.chain.web3_client import BUDGET_TOKEN, CONTRACTS, LEDGER, ROLE_MANAGER, Web3ChainClient, _link_problem
from app.main import app
from chain_support import RELAYER_KEY, RPC_URL, TREASURER_KEY, UNREACHABLE

BACKEND = Path(__file__).resolve().parents[1]
VECTORS = json.loads((Path(__file__).parent / "fixtures" / "eip712_vectors.json").read_text(encoding="utf-8"))["vectors"]
DEPLOYMENT = load_deployment(DEFAULT_PATH)


@pytest.fixture(autouse=True)
def clean(clean_chain_env):
    # 셸·.env 의 체인 설정을 지우고, provider 가 만들어 둔 클라이언트를 테스트마다 버린다
    reset_chain_client()
    yield
    reset_chain_client()


def connect(key: str, deployment_file: Path = DEFAULT_PATH, rpc_url: str = RPC_URL) -> Web3ChainClient:
    """연결해서 점검까지 한 뒤 닫는다. 점검 결과만 본다."""

    async def run():
        client = await Web3ChainClient.connect(rpc_url, key, deployment_file)
        await client.close()
        return client

    return asyncio.run(run())


def offline_client(key: str = RELAYER_KEY, w3=None) -> Web3ChainClient:
    """노드 없이 만든 클라이언트. 체인을 부르는 기능은 w3 자리에 가짜를 넣어 쓴다."""
    contracts = {
        name: SimpleNamespace(abi=load_abi(DEPLOYMENT.contracts[name], DEFAULT_PATH), address=DEPLOYMENT.contracts[name].address)
        for name in CONTRACTS
    }
    return Web3ChainClient(w3, Account.from_key(key), DEPLOYMENT, contracts, DEFAULT_PATH)


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


def edit_abi(name: str, edit):
    def change_abi(abi_dir):
        path = abi_dir / f"{name}.json"
        path.write_text(json.dumps(edit(json.loads(path.read_text(encoding="utf-8")))), encoding="utf-8")

    return change_abi


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


@pytest.mark.parametrize(
    "bad_item, problem",
    [
        ({"type": "error", "inputs": []}, "error 에 name 이 없음"),
        (5, "type 이 없음"),
        ({"type": "function", "name": "f", "inputs": [5]}, "inputs 형식이 맞지 않음"),
        ({"type": "function", "name": "f", "inputs": [], "outputs": [5]}, "outputs 형식이 맞지 않음"),
        ({"type": "function", "name": "f", "inputs": [{"type": "tuple", "components": [7]}]}, "inputs 형식이 맞지 않음"),
    ],
)
def test_malformed_abi_is_a_deployment_error_before_connecting(tmp_path, bad_item, problem):
    # web3·해석기 안에서 KeyError 등으로 터지면 503 이 아니라 500 이 된다. 읽을 때 배포 문제로 막는다
    path = deployment_variant(tmp_path, change_abi=edit_abi(LEDGER, lambda abi: abi + [bad_item]))
    with pytest.raises(DeploymentError, match=problem):
        connect(RELAYER_KEY, path, rpc_url=UNREACHABLE)


def test_abi_without_a_known_error_is_refused_before_connecting(tmp_path):
    # 컨트랙트 에러 이름이 바뀌면 revert 가 전부 UNKNOWN 이 된다. 노드에 붙기 전에 막는다
    drop = edit_abi(LEDGER, lambda abi: [item for item in abi if item.get("name") != "SignatureExpired"])
    with pytest.raises(ChainSetupError, match="원장 ABI 에 백엔드가 아는 에러가 없다: SignatureExpired"):
        connect(RELAYER_KEY, deployment_variant(tmp_path, change_abi=drop), rpc_url=UNREACHABLE)


def test_deployment_error_is_a_setup_error():
    # 503 처리기 하나(ChainSetupError)가 배포 기록 문제까지 받는다
    assert issubclass(DeploymentError, ChainSetupError)


def test_setup_errors_become_503():
    handler = app.exception_handlers[ChainSetupError]
    response = asyncio.run(handler(None, DeploymentError("배포 기록이 없습니다 (x.json)")))
    assert response.status_code == 503
    assert json.loads(response.body) == {"detail": "배포 기록이 없습니다 (x.json)"}


# ---------------------------------------------------------------- 시작 점검 (노드 없이)


def test_html_instead_of_json_rpc_is_a_setup_error_without_the_body():
    # 잘못된 포트나 프록시 점검 페이지. JSONDecodeError 는 ValueError 라 그대로 두면 500 이 되고 본문이 메시지에 실린다
    class Html(BaseHTTPRequestHandler):
        def do_POST(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(b"<html>maintenance SECRET-BODY</html>")

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Html)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with pytest.raises(ChainSetupError, match="JSON-RPC 응답을 주지 않는다") as error:
            connect(RELAYER_KEY, rpc_url=f"http://127.0.0.1:{server.server_port}")
    finally:
        server.shutdown()
    assert "SECRET-BODY" not in str(error.value)


def test_links_must_match_the_deployment():
    links = {
        (LEDGER, "roleManager"): DEPLOYMENT.contracts[ROLE_MANAGER].address,
        (LEDGER, "budgetToken"): DEPLOYMENT.contracts[BUDGET_TOKEN].address.lower(),
        (BUDGET_TOKEN, "ledger"): DEPLOYMENT.contracts[LEDGER].address,
        (BUDGET_TOKEN, "roleManager"): DEPLOYMENT.contracts[ROLE_MANAGER].address,
    }
    assert _link_problem(DEPLOYMENT, links) is None
    # 원장만 다시 배포하면 BudgetToken 은 옛 원장을 가리킨다 (setLedger 는 한 번만)
    stale = {**links, (BUDGET_TOKEN, "ledger"): "0x" + "56" * 20}
    assert "BudgetToken.ledger() 가 배포 기록의 AccountingLedger 와 다르다" in _link_problem(DEPLOYMENT, stale)


# ---------------------------------------------------------------- is_current·전송 lock


class FakeEth:
    def __init__(self, code=b"\x60", error=None):
        self.code, self.error, self.calls = code, error, 0

    async def get_code(self, address):
        self.calls += 1
        if self.error:
            raise self.error
        return self.code


def stale_client(eth: FakeEth) -> Web3ChainClient:
    client = offline_client(w3=SimpleNamespace(eth=eth))
    client._code_checked_at = time.monotonic() - web3_client.CODE_CHECK_SECONDS - 1
    return client


@pytest.mark.parametrize("error", [OSError("refused"), TimeoutError(), json.JSONDecodeError("x", "<html>", 0)])
def test_is_current_keeps_the_client_when_the_node_cannot_be_reached(error):
    # 확인할 수 없는 것과 낡은 것은 다르다. 일시적 실패로 교체하면 보내던 트랜잭션과 엇갈린다
    assert asyncio.run(stale_client(FakeEth(error=error)).is_current()) is True


def test_is_current_is_false_when_the_ledger_code_is_gone():
    assert asyncio.run(stale_client(FakeEth(code=b"")).is_current()) is False


def test_is_current_does_not_reread_files_or_ask_the_node_every_time(monkeypatch):
    eth = FakeEth()
    client = offline_client(w3=SimpleNamespace(eth=eth))

    def must_not_be_called(*args, **kwargs):
        raise AssertionError("파일이 그대로인데 배포 기록을 다시 읽었다")

    monkeypatch.setattr(web3_client, "load_deployment", must_not_be_called)
    for _ in range(3):
        assert asyncio.run(client.is_current()) is True
    assert eth.calls == 0  # CODE_CHECK_SECONDS 안이라 노드에 묻지 않는다


def test_rewritten_but_identical_files_keep_the_client(tmp_path):
    # 노드 재시작 뒤 다시 배포하면 deployedAt 만 바뀌고 주소·ABI 는 같다
    path = deployment_variant(tmp_path)
    contracts = {name: SimpleNamespace(abi=load_abi(DEPLOYMENT.contracts[name], path)) for name in CONTRACTS}
    contracts[LEDGER].address = DEPLOYMENT.contracts[LEDGER].address
    client = Web3ChainClient(SimpleNamespace(eth=FakeEth()), Account.from_key(RELAYER_KEY), load_deployment(path), contracts, path)
    raw = json.loads(path.read_text(encoding="utf-8"))
    raw["deployedAt"] = "2099-01-01T00:00:00.000Z"
    path.write_text(json.dumps(raw), encoding="utf-8")
    assert asyncio.run(client.is_current()) is True


def test_clients_of_one_relayer_share_the_send_lock_and_close_waits_for_it():
    # 교체 전후의 클라이언트가 같은 키로 동시에 보내면 nonce 가 겹친다
    closed = []

    class Provider:
        async def disconnect(self):
            closed.append(True)

    async def run():
        old = offline_client(w3=SimpleNamespace(provider=Provider()))
        new = offline_client(w3=SimpleNamespace(provider=Provider()))
        assert old._send_lock is new._send_lock
        async with old._send_lock:  # old 로 보내는 중
            closing = asyncio.create_task(old.close())
            await asyncio.sleep(0.01)
            assert not closed  # 보내는 동안에는 닫지 않는다
        await closing
        assert closed == [True] and await old.is_current() is False
        with pytest.raises(ChainSetupError, match="교체됐다"):
            old._ensure_open()

    asyncio.run(run())


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


def failing_connect(monkeypatch, attempts: list, delay: float = 0.05):
    async def slow_failure(*args, **kwargs):
        attempts.append(1)
        await asyncio.sleep(delay)
        raise ChainSetupError("노드에 연결할 수 없다 (테스트)")

    monkeypatch.setenv("CHAIN_RPC_URL", UNREACHABLE)
    monkeypatch.setattr(Web3ChainClient, "connect", slow_failure)


async def three_requests():
    return await asyncio.gather(*(get_chain_client() for _ in range(3)), return_exceptions=True)


def test_concurrent_requests_share_one_failed_attempt(monkeypatch):
    # 노드가 응답하지 않을 때 기다리던 요청이 각자 다시 연결하면 N 번째 요청은 N 배를 기다린다
    attempts = []
    failing_connect(monkeypatch, attempts)
    results = asyncio.run(three_requests())
    assert all(isinstance(r, ChainSetupError) for r in results)
    assert len(attempts) == 1
    # 같은 예외 객체를 돌려 던지지 않는다 (traceback 이 쌓이고 프레임이 살아남는다)
    assert len({id(r) for r in results}) == 3
    assert provider._failure[1] is ChainSetupError and isinstance(provider._failure[2], str)


def test_lock_works_across_event_loops(monkeypatch):
    # 테스트·도구가 asyncio.run 을 여러 번 써도 reset 없이 경합할 수 있어야 한다
    failing_connect(monkeypatch, [], delay=0.01)
    for _ in range(2):
        assert all(isinstance(r, ChainSetupError) for r in asyncio.run(three_requests()))


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


def test_client_replaced_during_the_check_is_not_returned(monkeypatch):
    # is_current 를 기다리는 동안 다른 요청이 교체했으면, 버려진 클라이언트가 아니라 새 것을 돌려준다
    replacement = FakeChainClient()

    class Old:
        async def is_current(self):
            provider._client = replacement
            return True

    monkeypatch.setattr(provider, "_client", Old())
    assert asyncio.run(get_chain_client()) is replacement


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
@pytest.mark.parametrize("name", CONTRACTS)
def test_empty_chain_asks_for_redeploy(node, tmp_path, name):
    # 노드를 재시작하면 체인이 비어 주소에 코드가 없다. 같은 상황을 아무 코드도 없는 주소로 만든다
    with pytest.raises(ChainSetupError, match=f"{name} 주소에 컨트랙트가 없다"):
        connect(RELAYER_KEY, deployment_variant(tmp_path, move_contract(name, "0x" + "12" * 20)))


@pytest.mark.chain
def test_stale_abi_is_not_reported_as_a_dead_node(node, tmp_path):
    drop = edit_abi(LEDGER, lambda abi: [item for item in abi if item.get("name") != "DOMAIN_SEPARATOR"])
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        with pytest.raises(ChainSetupError, match="배포 기록·ABI 가 지금 체인의 컨트랙트와 맞지 않는다"):
            connect(RELAYER_KEY, deployment_variant(tmp_path, change_abi=drop))
        gc.collect()  # 기다려지지 않은 코루틴 경고는 수거될 때 난다
    assert not [w for w in caught if "never awaited" in str(w.message)]


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
    added = {"type": "function", "name": "added", "inputs": [], "outputs": [], "stateMutability": "view"}

    async def run():
        client = await Web3ChainClient.connect(RPC_URL, RELAYER_KEY, path)
        try:
            edit_abi(LEDGER, lambda abi: abi + [added])(tmp_path / "abi")
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
