"""Web3ChainClient 의 record_pending·get_entry.

@pytest.mark.chain 테스트는 로컬 노드에 실제로 보낸다. 전부 evm_snapshot 안에서 하고 되돌려 노드 상태를 남기지 않는다.
단위 테스트는 전송 실패 분류와 receipt 실패 재현처럼 노드에서 일부러 만들기 어려운 경우를 본다.
"""
import asyncio

import pytest
from eth_account import Account
from eth_utils import keccak
from web3.contract.async_contract import AsyncContractFunction
from web3.exceptions import ContractCustomError, Web3RPCError

from app.chain import ChainRevert, ChainSetupError, ChainUnavailable, RecordRequest, RevertReason
from app.chain.deployment import DEFAULT_PATH, load_abi, load_deployment
from app.chain.models import BlockReason
from app.chain.revert import RevertDecoder
from app.chain.web3_client import LEDGER, Web3ChainClient, _send_failure
from app.schemas.entry import EntryKind, EntryStatus
from chain_support import (
    KST_MIDNIGHT,
    RELAYER_KEY,
    TEST_ID_BASE,
    TREASURER,
    TREASURER_KEY,
    on_chain,
    sign_as_app,
)

DEPLOYMENT = load_deployment(DEFAULT_PATH)
DECODER = RevertDecoder(load_abi(DEPLOYMENT.contracts[LEDGER], DEFAULT_PATH))
R = TEST_ID_BASE + 100_000  # 항목 id. 공용 노드의 실제 기록과 겹치지 않는 구간 (chain_support)


@pytest.fixture(autouse=True)
def isolated(clean_chain_env):
    yield


def request(entry_id: int, deadline: int, **override) -> RecordRequest:
    fields = dict(
        id=entry_id,
        hash="0x" + keccak(text=f"record-{entry_id}").hex(),
        amount=500_000,
        kind=EntryKind.INCOME,
        term=20262,
        occurred_at=KST_MIDNIGHT,
        budget_id=0,
        corrects_id=0,
        deadline=deadline,
    )
    return RecordRequest(**{**fields, **override})


def sign(req: RecordRequest, key: str = TREASURER_KEY) -> str:
    """앱이 하는 서명. 총무 키로 EIP-712 서명한다."""
    return sign_as_app(req, DEPLOYMENT.eip712[LEDGER], key)


async def nonce(client) -> int:
    return await client._w3.eth.get_transaction_count(client.relayer_address, "latest")


# ---------------------------------------------------------------- 정상 경로


@pytest.mark.chain
def test_income_is_recorded_as_pending(node):
    async def body(client, now):
        result = await client.record_pending(request(R + 1001, now + 600), sign(request(R + 1001, now + 600)))
        return result, await client.get_entry(R + 1001)

    result, entry = on_chain(body)
    assert result.status is EntryStatus.PENDING and result.block_reason is None
    assert len(result.tx_hash) == 66 and result.tx_hash == result.tx_hash.lower()
    assert (entry.status, entry.amount, entry.kind, entry.registrant) == (EntryStatus.PENDING, 500_000, EntryKind.INCOME, TREASURER)


@pytest.mark.chain
def test_expense_without_budget_is_blocked_not_an_error(node):
    # BLOCKED 는 예외가 아니다. 트랜잭션은 성공했고 예산 위반이 기록됐다 (CHAIN_CLIENT §4)
    async def body(client, now):
        req = request(R + 1002, now + 600, kind=EntryKind.EXPENSE, amount=35_000)
        return await client.record_pending(req, sign(req)), await client.get_entry(R + 1002)

    result, entry = on_chain(body)
    assert (result.status, result.block_reason) == (EntryStatus.BLOCKED, BlockReason.BUDGET_NOT_FOUND)
    assert entry.status is EntryStatus.BLOCKED


@pytest.mark.chain
def test_get_entry_reads_every_field_by_name(node):
    async def body(client, now):
        req = request(R + 1003, now + 600, kind=EntryKind.EXPENSE, amount=12_345, budget_id=0)
        await client.record_pending(req, sign(req))
        return req, await client.get_entry(R + 1003)

    req, entry = on_chain(body)
    assert entry.model_dump() == {
        "id": R + 1003,
        "hash": req.hash,
        "amount": 12_345,
        "kind": EntryKind.EXPENSE,
        "status": EntryStatus.BLOCKED,
        "term": 20262,
        "occurred_at": KST_MIDNIGHT,
        "budget_id": 0,
        "corrects_id": 0,
        "registrant": TREASURER,
        "approver": "0x" + "0" * 40,
    }


@pytest.mark.chain
@pytest.mark.parametrize("entry_id", [0, 987_654_321, -1, 2**256])
def test_unknown_or_impossible_id_is_none(node, entry_id):
    # getEntry 는 없는 id 에도 0 으로 채운 구조체(PENDING)를 준다. exists 를 먼저 봐서 None
    async def body(client, now):
        return await client.get_entry(entry_id)

    assert on_chain(body) is None


# ---------------------------------------------------------------- before_broadcast


@pytest.mark.chain
def test_before_broadcast_gets_the_hash_before_sending(node):
    seen = []

    async def body(client, now):
        before = await nonce(client)

        async def claim(tx_hash):
            seen.append((tx_hash, await nonce(client)))  # 아직 보내지 않았으면 nonce 가 그대로다

        result = await client.record_pending(request(R + 1004, now + 600), sign(request(R + 1004, now + 600)), claim)
        return before, result

    before, result = on_chain(body)
    assert seen == [(result.tx_hash, before)]


@pytest.mark.chain
def test_failing_callback_means_nothing_is_sent(node):
    # 선점 실패 = 다른 요청이 이미 처리 중. 보내지 않고 그 예외를 그대로 올린다
    class Claimed(Exception):
        pass

    async def body(client, now):
        before = await nonce(client)

        async def claim(tx_hash):
            raise Claimed()

        with pytest.raises(Claimed):
            await client.record_pending(request(R + 1005, now + 600), sign(request(R + 1005, now + 600)), claim)
        return before, await nonce(client), await client.get_entry(R + 1005)

    before, after, entry = on_chain(body)
    assert after == before and entry is None


# ---------------------------------------------------------------- revert


@pytest.mark.chain
def test_revert_in_simulation_costs_nothing_and_skips_the_callback(node):
    called = []

    async def body(client, now):
        before = await nonce(client)

        async def claim(tx_hash):
            called.append(tx_hash)

        with pytest.raises(ChainRevert) as error:
            await client.record_pending(request(R + 1006, 1), sign(request(R + 1006, 1)), claim)
        return error.value, before, await nonce(client)

    revert, before, after = on_chain(body)
    assert revert.reason is RevertReason.SIGNATURE_EXPIRED
    assert after == before and called == []  # 시뮬레이션에서 걸려 보내지 않았다


@pytest.mark.chain
def test_same_id_twice_is_entry_already_exists(node):
    async def body(client, now):
        req = request(R + 1007, now + 600)
        await client.record_pending(req, sign(req))
        with pytest.raises(ChainRevert) as error:
            await client.record_pending(req, sign(req))
        return error.value

    assert on_chain(body).reason is RevertReason.ENTRY_ALREADY_EXISTS


@pytest.mark.chain
def test_signature_from_someone_without_the_role_is_not_registrant(node):
    async def body(client, now):
        req = request(R + 1008, now + 600)
        with pytest.raises(ChainRevert) as error:
            await client.record_pending(req, sign(req, RELAYER_KEY))
        return error.value

    assert on_chain(body).reason is RevertReason.NOT_REGISTRANT


@pytest.mark.chain
def test_revert_after_sending_is_still_a_revert(node, monkeypatch):
    # 시뮬레이션과 채굴 사이에 결과가 달라지는 경우 (Hardhat 은 최신 블록 시각으로 시뮬레이션하고 실제 시각으로 채굴한다).
    # 시뮬레이션을 건너뛰어 같은 상황을 만든다. 보냈으니 콜백은 불렸고, Hardhat 은 실패한 트랜잭션도 블록에 넣는다
    async def no_simulation(self, *args, **kwargs):
        return 300_000

    monkeypatch.setattr(AsyncContractFunction, "estimate_gas", no_simulation)
    called = []

    async def body(client, now):
        before = await nonce(client)

        async def claim(tx_hash):
            called.append(tx_hash)

        with pytest.raises(ChainRevert) as error:
            await client.record_pending(request(R + 1009, 1), sign(request(R + 1009, 1)), claim)
        return error.value, before, await nonce(client), await client.get_entry(R + 1009)

    revert, before, after, entry = on_chain(body)
    assert revert.reason is RevertReason.SIGNATURE_EXPIRED
    assert len(called) == 1 and after == before + 1 and entry is None  # nonce 만 쓰였고 원장은 그대로


# ---------------------------------------------------------------- 동시 전송


@pytest.mark.chain
def test_concurrent_records_get_consecutive_nonces(node):
    # 릴레이어 키 하나로 동시에 보내면 nonce 가 겹친다. lock 으로 한 줄로 세운다
    async def body(client, now):
        before = await nonce(client)
        reqs = [request(R + 1010 + i, now + 600) for i in range(3)]
        results = await asyncio.gather(*(client.record_pending(r, sign(r)) for r in reqs))
        return results, before, await nonce(client)

    results, before, after = on_chain(body)
    assert all(r.status is EntryStatus.PENDING for r in results)
    assert len({r.tx_hash for r in results}) == 3 and after == before + 3


# ---------------------------------------------------------------- 전송 실패 분류 (노드 없이)


def rpc_error(code: int, message: str, data=None) -> Web3RPCError:
    error = {"code": code, "message": message, **({"data": data} if data is not None else {})}
    return Web3RPCError(str(error), rpc_response={"jsonrpc": "2.0", "id": 1, "error": error})


def test_send_revert_is_a_chain_revert():
    data = "0x" + (keccak(text="SignatureExpired(uint256)")[:4] + (1).to_bytes(32, "big")).hex()
    failure = _send_failure(rpc_error(3, "reverted with custom error", data), DECODER)
    assert isinstance(failure, ChainRevert) and failure.reason is RevertReason.SIGNATURE_EXPIRED


@pytest.mark.parametrize(
    "message, expected",
    [
        ("Sender doesn't have enough funds to send tx", "잔액이 부족"),
        ("insufficient funds for gas * price + value", "잔액이 부족"),
        ("Nonce too low. Expected nonce to be 3 but got 2.", "워커를 1개로"),
        # 확정적인 거절인데 "들어갔는지 모름" 으로 두면 선점(②)이 풀리지 않아 그 항목을 다시 제출할 수 없다
        ("replacement transaction underpriced", "수수료"),
        ("max fee per gas less than block base fee: address 0x..., maxFeePerGas: 1, baseFee: 7", "수수료"),
        ("transaction underpriced: tip needed 1, tip permitted 0", "수수료"),
        ("intrinsic gas too low: have 21000, want 53000", "가스 한도"),
        ("exceeds block gas limit", "가스 한도"),
    ],
)
def test_rejections_are_setup_errors(message, expected):
    # 노드가 전송 자체를 거절했다. 들어가지 않았고, 릴레이어 운영 문제라 503
    failure = _send_failure(rpc_error(-32000, message), DECODER)
    assert isinstance(failure, ChainSetupError) and expected in str(failure)


def test_already_known_means_wait_for_the_receipt():
    assert _send_failure(rpc_error(-32000, "already known"), DECODER) is None


@pytest.mark.parametrize("error", [OSError("reset"), TimeoutError(), rpc_error(-32603, "internal error")])
def test_other_send_failures_are_unknown(error):
    # 들어갔는지 모른다. 호출하는 쪽이 get_entry 로 확인한다 (CHAIN_CLIENT §4)
    assert isinstance(_send_failure(error, DECODER), ChainUnavailable)


def test_failed_receipt_is_replayed_for_the_reason():
    # Hardhat 외 노드는 실패한 트랜잭션도 받아 주고 receipt 의 status 만 0 이다. 그 블록 직전 상태로 다시 불러 사유를 얻는다
    data = "0x" + (keccak(text="EntryAlreadyExists(uint256)")[:4] + (7).to_bytes(32, "big")).hex()
    asked = []

    class Call:
        async def call(self, tx, block_identifier):
            asked.append(block_identifier)
            raise ContractCustomError(data, data=data)

    class Quiet:
        async def call(self, tx, block_identifier):
            return None

    client = Web3ChainClient.__new__(Web3ChainClient)
    client._reverts, client._account = DECODER, Account.from_key(RELAYER_KEY)
    receipt = {"blockNumber": 9, "status": 0}
    revert = asyncio.run(client._replay_failure(Call(), "0x" + "01" * 32, receipt))
    assert (revert.reason, asked) == (RevertReason.ENTRY_ALREADY_EXISTS, [8])
    unknown = asyncio.run(client._replay_failure(Quiet(), "0x" + "01" * 32, receipt))
    assert unknown.reason is RevertReason.UNKNOWN and "0x" + "01" * 32 in unknown.detail


def test_unknown_transaction_type_is_not_already_known():
    # "known transaction" 은 "rlp: unknown transaction type" 같은 거절에도 들어 있다. 기다리지 않고 바로 실패를 올린다
    for message in ("rlp: unknown transaction type", "unknown transaction"):
        assert isinstance(_send_failure(rpc_error(-32000, message), DECODER), ChainUnavailable)
    for message in ("already known", "known transaction: 0xabc"):
        assert _send_failure(rpc_error(-32000, message), DECODER) is None


# ---------------------------------------------------------------- get_entry·예외 (노드 없이)


class StubCall:
    def __init__(self, result=None, error=None):
        self.result, self.error = result, error

    async def call(self):
        if self.error:
            raise self.error
        return self.result


class StubFunctions:
    """원장 함수 자리. 불린 함수 이름을 남긴다."""

    def __init__(self, result=None, error=None):
        self.result, self.error, self.called = result, error, []

    def __getattr__(self, name):
        def function(*args):
            self.called.append(name)
            return StubCall(self.result, self.error)

        return function


def stub_client(functions: StubFunctions) -> Web3ChainClient:
    from types import SimpleNamespace

    from app.chain.web3_client import CONTRACTS

    contracts = {
        name: SimpleNamespace(abi=load_abi(DEPLOYMENT.contracts[name], DEFAULT_PATH), address=DEPLOYMENT.contracts[name].address)
        for name in CONTRACTS
    }
    contracts[LEDGER].functions = functions
    return Web3ChainClient(None, Account.from_key(RELAYER_KEY), DEPLOYMENT, contracts, DEFAULT_PATH)


def test_get_entry_asks_the_node_once():
    # 원장의 exists() 는 registrant != 0 이다. getEntry 결과로 같은 판정을 해 왕복을 한 번으로 줄인다
    empty = (b"\x00" * 32, 0, 0, 0, "0x" + "0" * 40, 0, 0, "0x" + "0" * 40, 0, 0)
    functions = StubFunctions(result=empty)
    assert asyncio.run(stub_client(functions).get_entry(5)) is None
    assert functions.called == ["getEntry"]


def test_unexpected_errors_are_raised_without_a_self_cause():
    # 코드 결함 같은 예상 못 한 예외는 바꾸지 않고 올린다. 자기 자신을 원인으로 두면 원인 체인이 순환한다
    defect = TypeError("defect")
    with pytest.raises(TypeError) as error:
        asyncio.run(stub_client(StubFunctions(error=defect)).get_entry(5))
    assert error.value is defect and error.value.__cause__ is not error.value


# ---------------------------------------------------------------- 시뮬레이션 시점 (노드)


@pytest.mark.chain
def test_simulation_uses_the_next_block_time(node):
    # Hardhat 은 블록이 없으면 최신 블록 시각이 낡는다. 최신 블록으로 시뮬레이션하면 이미 만료된 서명이 통과해
    # 보낸 뒤에야 revert 한다(nonce 를 쓰고 콜백도 불린 뒤). 다음 블록(pending) 기준이면 보내기 전에 걸린다
    called = []

    async def body(client, now):
        before = await nonce(client)
        expired = (await client._w3.eth.get_block("pending"))["timestamp"] - 1  # 다음 블록에서는 이미 만료

        async def claim(tx_hash):
            called.append(tx_hash)

        with pytest.raises(ChainRevert) as error:
            await client.record_pending(request(R + 1020, expired), sign(request(R + 1020, expired)), claim)
        return error.value, before, await nonce(client)

    revert, before, after = on_chain(body)
    assert revert.reason is RevertReason.SIGNATURE_EXPIRED
    assert called == [] and after == before


# ---------------------------------------------------------------- 전송 경로의 경계 (노드)


@pytest.mark.chain
@pytest.mark.parametrize("inside", ["record", "close"])
def test_using_the_relayer_from_inside_before_broadcast_fails_fast(node, inside):
    # 콜백은 릴레이어 lock 을 쥔 채 불린다. 그 안에서 같은 릴레이어로 보내거나 닫으면 영원히 기다리니 바로 오류다
    async def body(client, now):
        async def nested(tx_hash):
            if inside == "record":
                await client.record_pending(request(R + 1031, now + 600), sign(request(R + 1031, now + 600)))
            else:
                await client.close()

        with pytest.raises(RuntimeError, match="before_broadcast 안에서"):
            await asyncio.wait_for(client.record_pending(request(R + 1030, now + 600), sign(request(R + 1030, now + 600)), nested), 5)
        return await client.get_entry(R + 1030)

    assert on_chain(body) is None  # 콜백이 실패했으니 보내지 않았다


@pytest.mark.chain
def test_code_defect_while_sending_is_not_hidden_as_unavailable(node, monkeypatch):
    # 코드 결함을 "들어갔는지 모름" 으로 바꾸면 호출하는 쪽이 get_entry 확인·재시도로 빠지고 원인이 묻힌다
    from web3.eth import AsyncEth

    async def defect(self, *args, **kwargs):
        raise TypeError("defect")

    monkeypatch.setattr(AsyncEth, "send_raw_transaction", defect)

    async def body(client, now):
        with pytest.raises(TypeError, match="defect"):
            await client.record_pending(request(R + 1032, now + 600), sign(request(R + 1032, now + 600)))

    on_chain(body)


@pytest.mark.chain
def test_node_without_a_pending_block_still_records(node, monkeypatch):
    # 일부 공개망 노드는 pending 블록을 null 로 준다. 그때는 수수료를 web3 가 채운다
    from web3.eth import AsyncEth

    original = AsyncEth.get_block

    async def no_pending(self, block_identifier, *args, **kwargs):
        if block_identifier == "pending":
            return None
        return await original(self, block_identifier, *args, **kwargs)

    monkeypatch.setattr(AsyncEth, "get_block", no_pending)

    async def body(client, now):
        req = request(R + 1033, now + 600)
        return await client.record_pending(req, sign(req))

    assert on_chain(body).status is EntryStatus.PENDING
