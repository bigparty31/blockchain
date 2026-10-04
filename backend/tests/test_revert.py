"""revert 데이터를 RevertReason 으로 해석하는지 확인한다.

단위 테스트는 원장 ABI 의 에러를 전부 eth_abi 로 인코딩해 되돌려 본다 — 손으로 고른 몇 개가 아니라 ABI 에서 만들어
RevertReason 하나라도 빠지면 드러난다. @pytest.mark.chain 테스트는 로컬 노드에 eth_call 로 실제 revert 를 일으킨다.
eth_call 은 시뮬레이션이라 체인 상태를 바꾸지 않는다.
"""
import asyncio
from typing import Optional

import pytest
from eth_abi import encode
from eth_account import Account
from eth_utils import keccak
from web3.exceptions import ContractCustomError, ContractLogicError, ProviderConnectionError, Web3RPCError

from app.chain import RecordRequest, RevertReason
from app.chain.deployment import DEFAULT_PATH, load_abi, load_deployment
from app.chain.eip712 import typed_data_for
from app.chain.revert import RevertDecoder
from app.chain.web3_client import LEDGER, Web3ChainClient
from app.schemas.entry import EntryKind
from chain_support import RELAYER, RELAYER_KEY, RPC_URL, chain_now, sign_as_app

DEPLOYMENT = load_deployment(DEFAULT_PATH)
LEDGER_ABI = load_abi(DEPLOYMENT.contracts[LEDGER], DEFAULT_PATH)
ERRORS = {item["name"]: item for item in LEDGER_ABI if item["type"] == "error"}
DECODER = RevertDecoder(LEDGER_ABI)

# ABI 타입별 예시 인자. enum 인자(uint8)는 1 이라 Status 는 CONFIRMED, Kind 는 EXPENSE 로 보인다
SAMPLE = {"uint256": 7, "int256": -5, "uint8": 1, "bytes32": b"\x11" * 32, "address": RELAYER, "string": "x"}


def revert_data(name: str, *args) -> bytes:
    inputs = ERRORS[name]["inputs"]
    types = [i["type"] for i in inputs]
    values = list(args) or [SAMPLE[t] for t in types]
    return keccak(text=f"{name}({','.join(types)})")[:4] + encode(types, values)


@pytest.fixture(autouse=True)
def isolated(clean_chain_env):
    # 셸의 DEPLOYMENTS_FILE 등이 연결 대상과 서명 도메인을 바꾸지 않게 한다
    yield


# ---------------------------------------------------------------- 원장 에러


@pytest.mark.parametrize("reason", [r for r in RevertReason if r is not RevertReason.UNKNOWN], ids=lambda r: r.value)
def test_every_reason_decodes_from_the_ledger_abi(reason):
    revert = DECODER.decode(revert_data(reason.value))
    assert revert.reason is reason
    for item in ERRORS[reason.value]["inputs"]:
        assert f"{item['name']}=" in revert.detail


def test_no_reason_is_missing_from_the_deployed_abi():
    assert DECODER.missing_reasons() == []


def test_hex_string_and_bytes_are_the_same():
    data = revert_data("EntryAlreadyExists", 5)
    assert DECODER.decode("0x" + data.hex()).detail == DECODER.decode(data).detail == "id=5"


def test_enums_are_shown_by_name():
    assert DECODER.decode(revert_data("InvalidStatus", 5, 3, 0)).detail == "id=5, current=BLOCKED, expected=PENDING"
    assert DECODER.decode(revert_data("CorrectionKindMismatch", 2, 0, 1)).detail == "id=2, expected=INCOME, actual=EXPENSE"


def test_enum_value_outside_the_order_is_shown_as_a_number():
    assert DECODER.decode(revert_data("InvalidStatus", 5, 9, 0)).detail == "id=5, current=9, expected=PENDING"


def test_addresses_and_hashes_are_shown_in_their_usual_form():
    assert DECODER.decode(revert_data("NotRegistrant", RELAYER.lower())).detail == f"signer={RELAYER}"
    detail = DECODER.decode(revert_data("EntryCommitMismatch", 1, b"\xaa" * 32, b"\xbb" * 32)).detail
    assert detail == f"id=1, expected=0x{'aa' * 32}, actual=0x{'bb' * 32}"


def test_error_without_arguments_has_an_empty_detail():
    revert = DECODER.decode(revert_data("InvalidSignature"))
    assert (revert.reason, revert.detail, str(revert)) == (RevertReason.INVALID_SIGNATURE, "", "InvalidSignature")


def test_broken_arguments_keep_the_reason():
    # selector 가 맞으면 원인은 정해진다. 인자 때문에 UNKNOWN 으로 바뀌지 않는다
    data = revert_data("EntryAlreadyExists", 5)[:14]
    revert = DECODER.decode(data)
    assert revert.reason is RevertReason.ENTRY_ALREADY_EXISTS and revert.detail == "인자 해석 실패"


def test_only_the_ledger_enums_get_names():
    # 다른 컨트랙트에 같은 이름(Status)의 enum 이 있어도 원장 순서로 이름을 붙이지 않는다
    foreign = {
        "type": "error",
        "name": "OtherStatus",
        "inputs": [{"name": "status", "type": "uint8", "internalType": "enum Other.Status"}],
    }
    data = keccak(text="OtherStatus(uint8)")[:4] + encode(["uint8"], [3])
    assert RevertDecoder(LEDGER_ABI + [foreign]).decode(data).detail == "OtherStatus(status=3) — RevertReason 에 없는 원장 에러"


def test_budget_token_errors_declared_in_the_ledger_abi_are_known():
    # BudgetToken 이 confirmEntry 안에서 내지만 원장 ABI 에도 같은 시그니처로 있다 (IAccountingLedger)
    assert DECODER.decode(revert_data("InsufficientBudget", 1, 100, 500)).reason is RevertReason.INSUFFICIENT_BUDGET
    assert DECODER.decode(revert_data("BudgetExpired", 1, 1790694000)).reason is RevertReason.BUDGET_EXPIRED


# ---------------------------------------------------------------- 해석할 수 없는 revert


def unknown(data) -> str:
    revert = DECODER.decode(data)
    assert revert.reason is RevertReason.UNKNOWN
    return revert.detail


def test_ledger_error_outside_revert_reason_is_unknown_with_its_name():
    # 생성자에서만 나는 에러. 원장 ABI 에는 있지만 릴레이 중에는 나지 않는다
    assert unknown(revert_data("ZeroAddress")) == "ZeroAddress() — RevertReason 에 없는 원장 에러"


def test_selector_outside_the_ledger_abi_is_unknown():
    # BudgetToken 고유 에러 (원장 ABI 에 없다)
    refund = keccak(text="RefundExceedsSpent(uint256,uint256,uint256)")[:4]
    assert unknown(refund + encode(["uint256"] * 3, [1, 2, 3])) == f"알 수 없는 에러 selector 0x{refund.hex()}"


def test_panic_and_error_string_are_unknown_with_their_content():
    assert unknown(keccak(text="Panic(uint256)")[:4] + encode(["uint256"], [0x11])) == "Panic(0x11)"
    assert unknown(keccak(text="Error(string)")[:4] + encode(["string"], ["nope"])) == 'Error("nope")'


@pytest.mark.parametrize("data", [None, "", "0x", b"", "no data"])
def test_empty_revert_data_is_unknown(data):
    assert unknown(data) == "revert 데이터 없음"


@pytest.mark.parametrize("data", ["0x12", "0xzz", "deadbeef", 1234])
def test_malformed_revert_data_is_unknown(data):
    assert unknown(data) == "revert 데이터 형식 오류"


# ---------------------------------------------------------------- web3 예외


def test_custom_error_from_web3_is_decoded():
    data = "0x" + revert_data("SignatureExpired", 1).hex()
    revert = DECODER.from_web3_error(ContractCustomError(data, data=data))
    assert (revert.reason, revert.detail) == (RevertReason.SIGNATURE_EXPIRED, "deadline=1")


def test_reverted_prefix_is_stripped():
    # 일부 노드는 데이터 앞에 "Reverted " 를 붙인다. 해석할 수 있는 에러를 놓치지 않는다
    data = "Reverted 0x" + revert_data("SignatureExpired", 1).hex()
    assert DECODER.from_web3_error(ContractLogicError("execution reverted", data=data)).reason is RevertReason.SIGNATURE_EXPIRED


def test_geth_style_revert_without_data_keeps_the_node_message():
    # Geth·Bor 는 데이터 없는 revert 에 web3 표식 "no data" 를 남긴다. 형식 오류가 아니다
    revert = DECODER.from_web3_error(ContractLogicError("execution reverted", data="no data"))
    assert revert.reason is RevertReason.UNKNOWN and revert.detail == "revert 데이터 없음 — execution reverted"


def rpc_error(code: int, message: str, data=None) -> Web3RPCError:
    error = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    return Web3RPCError(str(error), rpc_response={"jsonrpc": "2.0", "id": 1, "error": error})


def test_revert_reported_on_send_is_decoded():
    # Hardhat automine 은 revert 하는 트랜잭션도 블록에 넣고 eth_sendRawTransaction 에 JSON-RPC 에러로 알린다.
    # 결과가 확정됐으니 "들어갔는지 모름" 이 아니라 revert 다
    error = rpc_error(3, "VM Exception while processing transaction: reverted with custom error", "0x" + revert_data("SignatureExpired", 1).hex())
    revert = DECODER.from_web3_error(error)
    assert (revert.reason, revert.detail) == (RevertReason.SIGNATURE_EXPIRED, "deadline=1")


def test_revert_on_send_without_data_is_unknown():
    revert = DECODER.from_web3_error(rpc_error(-32603, "Transaction reverted without a reason"))
    assert revert.reason is RevertReason.UNKNOWN and revert.detail.startswith("revert 데이터 없음 — Transaction reverted")


def test_rejection_that_is_not_a_revert_is_left_to_the_sender():
    # 잔액 부족·nonce 는 노드가 전송 자체를 거절한 것이다. revert 가 아니니 전송 경로가 따로 다룬다
    assert DECODER.from_web3_error(rpc_error(-32000, "Sender doesn't have enough funds to send tx")) is None
    assert DECODER.from_web3_error(rpc_error(-32000, "nonce too low")) is None


def test_rpc_error_that_is_only_a_string_is_handled():
    # JSON-RPC 규격은 error 를 객체로 주지만 문자열만 주는 노드·프록시도 있다. 해석하다 터지면 500 이 된다
    as_string = Web3RPCError("x", rpc_response={"jsonrpc": "2.0", "id": 1, "error": "execution reverted"})
    assert DECODER.from_web3_error(as_string).reason is RevertReason.UNKNOWN
    assert DECODER.from_web3_error(Web3RPCError("nonce too low", rpc_response=None)) is None


def test_revert_without_data_keeps_the_node_message():
    revert = DECODER.from_web3_error(ContractLogicError("Transaction reverted", data="0x"))
    assert revert.reason is RevertReason.UNKNOWN and revert.detail == "revert 데이터 없음 — Transaction reverted"


@pytest.mark.parametrize("error", [ProviderConnectionError("down"), TimeoutError(), OSError("refused"), ValueError("x")])
def test_errors_that_are_not_reverts_are_left_to_the_caller(error):
    # 연결 실패는 트랜잭션이 들어갔는지 모르는 상태다. revert 로 바꾸면 안 된다 (CHAIN_CLIENT §4)
    assert DECODER.from_web3_error(error) is None


# ---------------------------------------------------------------- 로컬 노드 (eth_call, 상태 변경 없음)


UNUSED_ID = 987_654_321  # 아직 기록된 적 없는 id


def request(deadline: int, **override) -> RecordRequest:
    fields = dict(
        id=UNUSED_ID,
        hash="0x" + keccak(text="revert-test").hex(),
        amount=1000,
        kind=EntryKind.INCOME,
        term=20262,
        occurred_at=1790694000,
        budget_id=0,
        corrects_id=0,
        deadline=deadline,
    )
    return RecordRequest(**{**fields, **override})


def simulate(build):
    """eth_call 로 원장 함수를 시뮬레이션하고, revert 를 해석해 돌려준다.

    build(ledger 함수들, 체인 시각) 이 호출을 만든다. deadline 은 chain_now 기준으로 정한다 (tests/chain_support.py).
    """

    async def run():
        client = await Web3ChainClient.connect(RPC_URL, RELAYER_KEY, DEFAULT_PATH)
        try:
            await build(client._ledger.functions, await chain_now(client._w3)).call({"from": client.relayer_address})
        except Exception as e:
            return client._reverts.from_web3_error(e)
        finally:
            await client.close()
        return None

    return asyncio.run(run())


def record_struct(req: RecordRequest, kind: Optional[int] = None) -> dict:
    """서명 대상과 같은 typed data message 로 만든다. kind 를 주면 그 값으로 바꾼다 (enum 밖 값을 보내 보는 테스트용)."""
    message = typed_data_for(req, DEPLOYMENT.eip712[LEDGER])["message"]
    return message if kind is None else {**message, "kind": kind}


def sign(req: RecordRequest, key: str) -> bytes:
    return bytes.fromhex(sign_as_app(req, DEPLOYMENT.eip712[LEDGER], key)[2:])


@pytest.mark.chain
def test_expired_signature_on_chain(node):
    # 시한 검사가 맨 먼저라 서명이 무엇이든 SignatureExpired (IAccountingLedger 검사 순서 1)
    revert = simulate(lambda f, now: f.recordPending(record_struct(request(deadline=1)), b"\x01" * 65))
    assert (revert.reason, revert.detail) == (RevertReason.SIGNATURE_EXPIRED, "deadline=1")


@pytest.mark.chain
def test_signature_from_a_non_treasurer_on_chain(node):
    # 형식이 맞는 서명이면 실패하지 않고 서명자를 복구한다. 릴레이어는 롤이 없으니 NotRegistrant
    def build(f, now):
        req = request(deadline=now + 600)
        return f.recordPending(record_struct(req), sign(req, RELAYER_KEY))

    revert = simulate(build)
    assert (revert.reason, revert.detail) == (RevertReason.NOT_REGISTRANT, f"signer={RELAYER}")


@pytest.mark.chain
def test_unknown_entry_on_chain(node):
    revert = simulate(lambda f, now: f.statusOf(UNUSED_ID))
    assert (revert.reason, revert.detail) == (RevertReason.ENTRY_NOT_FOUND, f"id={UNUSED_ID}")


@pytest.mark.chain
def test_kind_outside_the_enum_reverts_without_data(node):
    # 컨트랙트의 ABI 디코딩에서 막혀 에러 데이터가 없다. 백엔드는 모델 enum 으로 미리 막는다 (CONTRACTS.md)
    def build(f, now):
        req = request(deadline=now + 600)
        return f.recordPending(record_struct(req, kind=2), sign(req, RELAYER_KEY))

    revert = simulate(build)
    assert revert.reason is RevertReason.UNKNOWN and revert.detail.startswith("revert 데이터 없음")


@pytest.mark.chain
def test_revert_on_send_is_decoded_on_chain(node):
    # 실제로 보내 본다. Hardhat 은 revert 하는 트랜잭션도 블록에 넣으니 스냅샷 안에서 보내고 되돌린다 (상태 변경 없음)
    async def run():
        client = await Web3ChainClient.connect(RPC_URL, RELAYER_KEY, DEFAULT_PATH)
        w3 = client._w3
        snapshot = (await w3.provider.make_request("evm_snapshot", []))["result"]
        try:
            account = Account.from_key(RELAYER_KEY)
            tx = await client._ledger.functions.recordPending(record_struct(request(deadline=1)), b"\x01" * 65).build_transaction(
                {"from": account.address, "gas": 300_000, "nonce": await w3.eth.get_transaction_count(account.address)}
            )
            try:
                await w3.eth.send_raw_transaction(account.sign_transaction(tx).raw_transaction)
            except Exception as e:
                return client._reverts.from_web3_error(e)
            return None
        finally:
            await w3.provider.make_request("evm_revert", [snapshot])
            await client.close()

    revert = asyncio.run(run())
    assert (revert.reason, revert.detail) == (RevertReason.SIGNATURE_EXPIRED, "deadline=1")
