"""Web3ChainClient 를 가짜 JSON-RPC 노드(tests/fake_node.py)에 붙여 확인한다. web3.py 의 요청 형식·응답 해석·예외를 실제로 거친다."""
import asyncio

import pytest
from eth_abi import encode
from eth_utils import to_checksum_address
from web3 import AsyncWeb3

from app.chain import ChainRevert, ChainUnavailable, ConfirmApproval, RecordRequest, RejectDecision, RevertReason
from app.chain.eip712 import domain_separator
from app.chain.models import BlockReason, ChainConfigError, ChainNotSent
from app.chain.revert import decode_revert
from app.chain.settings import ChainSettings
from app.chain.web3_client import Web3ChainClient
from app.schemas.entry import EntryKind, EntryStatus
from fake_node import BUDGET_ABI, CHAIN_ID, LEDGER, LEDGER_ABI, RELAYER, FakeNode, error_data, event_log, run, settings

TREASURER = to_checksum_address("0x" + "44" * 20)
AUDITOR = to_checksum_address("0x" + "55" * 20)
HASH = "0x" + "ab" * 32
SIG = "0x" + "cd" * 65
DAY = 1_790_000_000 // 86400 * 86400 + 54000


def request(entry_id=1):
    return RecordRequest(id=entry_id, hash=HASH, amount=35000, kind=EntryKind.EXPENSE, occurred_at=DAY, budget_id=2, deadline=1_790_000_300)


def pending_log(entry_id, block=0, tx_hash="0x" + "00" * 32):
    return event_log("EntryPending", block, tx_hash, id=entry_id, hash=bytes.fromhex(HASH[2:]), amount=35000, kind=1,
                     budgetId=2, correctsId=0, actor=TREASURER)


@pytest.fixture
def node():
    return FakeNode()


def client(node, **overrides):
    return Web3ChainClient(settings(**overrides), AsyncWeb3(node))


def entry_tuple(status=0, approver="0x" + "00" * 20):
    return "0x" + encode(
        ["(bytes32,int256,uint8,uint8,uint256,uint256,uint256,address,address)"],
        [(bytes.fromhex(HASH[2:]), -500, 1, status, DAY, 2, 9, TREASURER.lower(), approver)],
    ).hex()


def bool_result(value):
    return "0x" + encode(["bool"], [value]).hex()


# ---------------------------------------------------------------- 시작 점검


def test_check_passes_and_warns_on_low_balance(node):
    node.calls["DOMAIN_SEPARATOR"] = domain_separator(settings().domain)
    assert run(client(node).check()) == []

    node.balance = 10
    [warning] = run(client(node).check())
    assert RELAYER.address in warning


@pytest.mark.parametrize("broken", ["chain_id", "code", "domain"])
def test_check_rejects_mismatched_config(node, broken):
    node.calls["DOMAIN_SEPARATOR"] = domain_separator(settings().domain)
    if broken == "chain_id":
        node.chain_id = 80002
    elif broken == "code":
        node.code = "0x"
    else:
        node.calls["DOMAIN_SEPARATOR"] = domain_separator(settings(chain_id=80002).domain)
    with pytest.raises(ChainConfigError):
        run(client(node).check())


# ---------------------------------------------------------------- 보내기


def test_record_pending_sends_relayer_signed_tx(node):
    node.outcome["logs"] = lambda tx_hash, block: [pending_log(1, block, tx_hash)]
    result = run(client(node).record_pending(request(), SIG.upper().replace("0X", "0x")))

    [sent] = node.sent
    assert sent["from"] == RELAYER.address
    assert (sent["nonce"], sent["chainId"], to_checksum_address(sent["to"])) == (7, CHAIN_ID, LEDGER)
    assert sent["gas"] == 108_000  # 90_000 * 1.2
    fn, args = node.decode_input(sent)
    assert fn.fn_name == "recordPending"
    assert args["request"] == {
        "id": 1, "hash": bytes.fromhex(HASH[2:]), "amount": 35000, "kind": 1, "occurredAt": DAY,
        "budgetId": 2, "correctsId": 0, "deadline": 1_790_000_300,
    }
    assert args["signature"] == bytes.fromhex(SIG[2:])

    assert result.status == EntryStatus.PENDING
    assert result.tx_hash == sent["hash"]


def test_record_pending_reads_blocked_event(node):
    def logs(tx_hash, block):
        blocked = event_log("EntryBlocked", block, tx_hash, id=1, budgetId=2, attempted=35000, reason=1)
        return [blocked]

    node.outcome["logs"] = logs
    result = run(client(node).record_pending(request(), SIG))
    assert (result.status, result.block_reason) == (EntryStatus.BLOCKED, BlockReason.BUDGET_EXPIRED)


def test_blocked_wins_when_both_events_are_emitted(node):
    """구현이 BLOCKED 에도 EntryPending 을 함께 낼 수 있다. 순서와 상관없이 BLOCKED 로 읽는다."""
    def logs(tx_hash, block):
        blocked = event_log("EntryBlocked", block, tx_hash, id=1, budgetId=2, attempted=35000, reason=0)
        return [pending_log(1, block, tx_hash), blocked]

    node.outcome["logs"] = logs
    result = run(client(node).record_pending(request(), SIG))
    assert (result.status, result.block_reason) == (EntryStatus.BLOCKED, BlockReason.BUDGET_EXCEEDED)


def test_receipt_without_expected_event_is_config_error(node):
    with pytest.raises(ChainConfigError):
        run(client(node).record_pending(request(), SIG))


@pytest.mark.parametrize(
    "data, reason",
    [
        (error_data(LEDGER_ABI, "EntryAlreadyExists", 1), RevertReason.ENTRY_ALREADY_EXISTS),
        (error_data(LEDGER_ABI, "NotRegistrant", TREASURER), RevertReason.NOT_REGISTRANT),
        (error_data(LEDGER_ABI, "ZeroAmount", 1), RevertReason.ZERO_AMOUNT),
        (error_data(BUDGET_ABI, "ZeroAmount"), RevertReason.ZERO_AMOUNT),
        (error_data(BUDGET_ABI, "InsufficientBudget", 2, 100, 35000), RevertReason.INSUFFICIENT_BUDGET),
        (error_data(BUDGET_ABI, "BudgetExpired", 2, DAY), RevertReason.BUDGET_EXPIRED),
    ],
)
def test_estimate_revert_is_mapped_and_nothing_is_sent(node, data, reason):
    node.estimate = {"revert": data}
    with pytest.raises(ChainRevert) as e:
        run(client(node).record_pending(request(), SIG))
    assert e.value.reason == reason
    assert e.value.data == data
    assert node.sent == []


@pytest.mark.parametrize(
    "data, detail",
    [
        (error_data(BUDGET_ABI, "BudgetNotExpired", 2, DAY), "BudgetNotExpired"),
        ("0x08c379a0" + encode(["string"], ["nope"]).hex(), "Error('nope')"),
        ("0x4e487b71" + encode(["uint256"], [17]).hex(), "Panic(17)"),
        ("0xdeadbeef", "0xdeadbeef"),
    ],
)
def test_unknown_revert_keeps_name_and_data(data, detail):
    revert = decode_revert(data)
    assert revert.reason == RevertReason.UNKNOWN
    assert detail in revert.detail
    assert revert.data == data


def test_failed_receipt_is_replayed_for_reason(node):
    node.outcome["status"] = 0
    node.calls["confirmEntry"] = {"revert": error_data(BUDGET_ABI, "InsufficientBudget", 2, 100, 35000)}
    approval = ConfirmApproval(id=1, hash=HASH, deadline=1_790_000_300)
    with pytest.raises(ChainRevert) as e:
        run(client(node).confirm_entry(approval, SIG))
    assert e.value.reason == RevertReason.INSUFFICIENT_BUDGET
    assert len(node.sent) == 1


def test_confirm_and_reject_read_their_events(node):
    node.outcome["logs"] = lambda tx_hash, block: [
        event_log("EntryConfirmed", block, tx_hash, id=1, hash=bytes.fromhex(HASH[2:]), amount=35000, kind=1, budgetId=2,
                  hadWarning=False, warningReasonHash=b"\0" * 32, actor=AUDITOR)
    ]
    assert run(client(node).confirm_entry(ConfirmApproval(id=1, hash=HASH, deadline=1_790_000_300), SIG)).status == EntryStatus.CONFIRMED

    node.outcome["logs"] = lambda tx_hash, block: [
        event_log("EntryRejected", block, tx_hash, id=2, reasonHash=b"\1" * 32, actor=AUDITOR)
    ]
    decision = RejectDecision(id=2, reason_hash="0x" + "01" * 32, deadline=1_790_000_300)
    assert run(client(node).reject_entry(decision, SIG)).status == EntryStatus.REJECTED


def test_bad_signature_format_is_rejected_before_rpc(node):
    with pytest.raises(ValueError):
        run(client(node).record_pending(request(), "0x1234"))
    assert node.requests == []


# ---------------------------------------------------------------- 결과를 모르는 경우


@pytest.mark.parametrize("failing", ["eth_estimateGas", "eth_getTransactionCount", "eth_maxPriorityFeePerGas"])
def test_rpc_failure_before_sending_is_not_sent(node, failing):
    node.fail.add(failing)
    with pytest.raises(ChainNotSent):
        run(client(node).record_pending(request(), SIG))
    assert node.sent == []


def test_node_rejection_is_not_sent_and_rereads_nonce(node):
    node.outcome["logs"] = lambda tx_hash, block: [pending_log(1, block, tx_hash)]
    chain = client(node)

    async def scenario():
        node.reject_send = "insufficient funds for gas * price + value"
        with pytest.raises(ChainNotSent) as e:
            await chain.record_pending(request(), SIG)
        assert e.value.tx_hash is not None
        await chain.record_pending(request(), SIG)

    run(scenario())
    assert node.requests.count("eth_getTransactionCount") == 2
    assert [tx["nonce"] for tx in node.sent] == [7]


def test_already_known_is_treated_as_sent(node):
    node.outcome["logs"] = lambda tx_hash, block: [pending_log(1, block, tx_hash)]
    node.reject_send = "already known"
    node.mine = False
    chain = client(node, receipt_timeout_seconds=0.05, max_replacements=0)
    with pytest.raises(ChainUnavailable) as e:  # 멤풀에 있다고 했으니 결과를 모르는 것이다
        run(chain.record_pending(request(), SIG))
    assert e.value.tx_hash is not None


def test_receipt_timeout_is_unavailable_with_tx_hash(node):
    node.mine = False
    with pytest.raises(ChainUnavailable) as e:
        run(client(node).record_pending(request(), SIG))
    assert e.value.tx_hash == node.sent[0]["hash"]


def test_send_failure_rereads_nonce(node):
    node.outcome["logs"] = lambda tx_hash, block: [pending_log(1, block, tx_hash)]
    chain = client(node)

    async def scenario():
        node.fail.add("eth_sendRawTransaction")
        with pytest.raises(ChainUnavailable) as e:
            await chain.record_pending(request(), SIG)
        assert e.value.tx_hash is not None
        node.nonce = 8  # 노드가 그 트랜잭션을 받았던 경우
        await chain.record_pending(request(), SIG)
        await chain.record_pending(request(), SIG)

    run(scenario())
    assert node.requests.count("eth_getTransactionCount") == 2
    assert [tx["nonce"] for tx in node.sent] == [8, 9]


def test_concurrent_sends_get_distinct_nonces(node):
    node.outcome["logs"] = lambda tx_hash, block: [pending_log(1, block, tx_hash)]
    chain = client(node)

    async def scenario():
        await asyncio.gather(*(chain.record_pending(request(i), SIG) for i in (1, 2, 3)))

    run(scenario())
    assert sorted(tx["nonce"] for tx in node.sent) == [7, 8, 9]
    assert node.requests.count("eth_getTransactionCount") == 1


def test_confirmation_wait_survives_a_transient_rpc_error(node):
    node.outcome["logs"] = lambda tx_hash, block: [pending_log(1, block, tx_hash)]
    node.advance_on_block_number = True
    armed = []

    def rule(tx):
        if not armed:
            armed.append(True)
            node.fail.add("eth_blockNumber")  # 확인 블록을 기다리는 첫 조회가 끊긴다
        return True

    node.mine = rule
    result = run(client(node, confirmations=3).record_pending(request(), SIG))
    assert result.status == EntryStatus.PENDING


def test_waits_for_confirmations(node):
    node.outcome["logs"] = lambda tx_hash, block: [pending_log(1, block, tx_hash)]
    node.advance_on_block_number = True
    run(client(node, confirmations=3).record_pending(request(), SIG))
    assert node.requests.count("eth_blockNumber") >= 2

    node.advance_on_block_number = False
    with pytest.raises(ChainUnavailable):
        run(client(node, confirmations=3).record_pending(request(), SIG))


# ---------------------------------------------------------------- 조회


def test_get_entry_checks_exists_first(node):
    node.calls["exists"] = bool_result(False)
    assert run(client(node).get_entry(1)) is None
    assert node.requests.count("eth_call") == 1

    node.calls["exists"] = bool_result(True)
    node.calls["getEntry"] = entry_tuple(status=1, approver=AUDITOR.lower())
    entry = run(client(node).get_entry(1))
    assert (entry.hash, entry.amount, entry.kind, entry.status) == (HASH, -500, EntryKind.EXPENSE, EntryStatus.CONFIRMED)
    assert (entry.budget_id, entry.corrects_id, entry.occurred_at) == (2, 9, DAY)
    assert (entry.registrant, entry.approver) == (TREASURER, AUDITOR)


def test_get_record_result_scans_back_in_chunks(node):
    node.head = 35
    node.logs = [pending_log(1, block=5, tx_hash="0x" + "aa" * 32), pending_log(2, block=34, tx_hash="0x" + "bb" * 32)]
    chain = client(node, log_chunk_blocks=10, deploy_block=0)

    result = run(chain.get_record_result(1))
    assert (result.status, result.tx_hash) == (EntryStatus.PENDING, "0x" + "aa" * 32)
    assert node.log_ranges == [(26, 35), (16, 25), (6, 15), (0, 5)]

    node.requests.clear()
    assert run(chain.get_record_result(3)) is None
    assert node.requests.count("eth_getLogs") == 4


def test_get_record_result_stops_at_deploy_block(node):
    node.head = 35
    node.logs = [pending_log(1, block=5)]
    assert run(client(node, log_chunk_blocks=10, deploy_block=10).get_record_result(1)) is None


def test_get_decision_result(node):
    node.logs = [event_log("EntryRejected", 50, "0x" + "cc" * 32, id=4, reasonHash=b"\1" * 32, actor=AUDITOR)]
    result = run(client(node).get_decision_result(4))
    assert (result.status, result.tx_hash) == (EntryStatus.REJECTED, "0x" + "cc" * 32)
    assert (result.reason_hash, result.approver, result.block_number) == ("0x" + "01" * 32, AUDITOR, 50)


def test_confirm_returns_warning_details_for_verification(node):
    node.outcome["logs"] = lambda tx_hash, block: [
        event_log("EntryConfirmed", block, tx_hash, id=1, hash=bytes.fromhex(HASH[2:]), amount=35000, kind=1, budgetId=2,
                  hadWarning=True, warningReasonHash=b"\x07" * 32, actor=AUDITOR)
    ]
    approval = ConfirmApproval(id=1, hash=HASH, had_warning=True, warning_reason_hash="0x" + "07" * 32, deadline=1_790_000_300)
    result = run(client(node).confirm_entry(approval, SIG))
    assert (result.had_warning, result.warning_reason_hash, result.approver) == (True, "0x" + "07" * 32, AUDITOR)


def test_read_connection_failure_is_unavailable(node):
    node.fail.add("eth_call")
    with pytest.raises(ChainUnavailable):
        run(client(node).get_entry(1))


# ---------------------------------------------------------------- 설정


def test_settings_from_env():
    env = {
        "CHAIN_RPC_URL": "http://localhost:8545", "CHAIN_ID": "31337", "CHAIN_LEDGER_ADDRESS": LEDGER,
        "CHAIN_RELAYER_KEY": "0x" + "11" * 32, "CHAIN_CONFIRMATIONS": "3",
    }
    s = ChainSettings.from_env(env)
    assert (s.chain_id, s.confirmations, s.deploy_block) == (31337, 3, 0)
    assert "11" * 32 not in repr(s)
    with pytest.raises(ValueError):
        ChainSettings.from_env({k: v for k, v in env.items() if k != "CHAIN_ID"})


# ---------------------------------------------------------------- 멈춘 트랜잭션 재전송


def test_stuck_transaction_is_resent_with_higher_fee(node):
    import math

    node.outcome["logs"] = lambda tx_hash, block: [pending_log(1, block, tx_hash)]
    first_fee = node.base_fee * 2 + node.priority_fee
    node.mine = lambda tx: tx["maxFeePerGas"] > first_fee  # 처음 수수료로는 들어가지 않는다

    result = run(client(node, replace_after_seconds=0.03).record_pending(request(), SIG))

    first, second = node.sent
    assert first["nonce"] == second["nonce"]
    assert second["maxPriorityFeePerGas"] == math.ceil(node.priority_fee * 1.25)
    assert second["maxFeePerGas"] == math.ceil(first_fee * 1.25)
    assert result.tx_hash == second["hash"]


def test_original_mined_after_replacement_is_used(node):
    node.outcome["logs"] = lambda tx_hash, block: [pending_log(1, block, tx_hash)]
    node.mine = lambda tx: len(node.sent) >= 2 and tx["hash"] == node.sent[0]["hash"]  # 재전송한 뒤에 원래 것이 들어간다

    result = run(client(node, replace_after_seconds=0.03).record_pending(request(), SIG))
    assert len(node.sent) == 2
    assert result.tx_hash == node.sent[0]["hash"]


def test_failed_replacement_keeps_waiting_for_original(node):
    node.outcome["logs"] = lambda tx_hash, block: [pending_log(1, block, tx_hash)]
    armed = []

    def rule(tx):
        if not armed:
            armed.append(True)
            node.fail.add("eth_sendRawTransaction")  # 다음 전송(재전송)은 연결 실패
            return False
        return node.requests.count("eth_maxPriorityFeePerGas") >= 2  # 재전송을 시도한 뒤에 원래 것이 들어간다

    node.mine = rule
    result = run(client(node, replace_after_seconds=0.03).record_pending(request(), SIG))
    assert [tx["hash"] for tx in node.sent] == [result.tx_hash]


def test_gives_up_after_max_replacements_and_frees_the_nonce(node):
    node.mine = lambda tx: to_checksum_address(tx["to"]) == RELAYER.address  # 덮어쓰기 전송만 들어간다
    chain = client(node, replace_after_seconds=0.02, max_replacements=2, receipt_timeout_seconds=0.3)
    with pytest.raises(ChainUnavailable) as e:
        run(chain.record_pending(request(), SIG))

    *attempts, cancel = node.sent
    assert len(attempts) == 3
    assert e.value.tx_hash == attempts[-1]["hash"]
    assert (cancel["nonce"], to_checksum_address(cancel["to"]), cancel["gas"], cancel["value"]) == (7, RELAYER.address, 21_000, 0)
    assert cancel["maxFeePerGas"] > attempts[-1]["maxFeePerGas"]

    node.mine = True
    node.outcome["logs"] = lambda tx_hash, block: [pending_log(2, block, tx_hash)]
    run(chain.record_pending(request(2), SIG))
    assert node.sent[-1]["nonce"] == 8  # 비운 nonce 뒤에서 바로 이어 간다


def test_failed_abandon_rereads_nonce(node):
    armed = []

    def rule(tx):
        if not armed:
            armed.append(True)
            node.fail.add("eth_sendRawTransaction")  # 덮어쓰기 전송이 연결 실패 — 노드가 nonce 를 잃어버린 경우
            node.mempool.clear()
        return False

    node.mine = rule
    chain = client(node, max_replacements=0, receipt_timeout_seconds=0.05)
    with pytest.raises(ChainUnavailable):
        run(chain.record_pending(request(), SIG))

    node.mine = True
    node.outcome["logs"] = lambda tx_hash, block: [pending_log(2, block, tx_hash)]
    run(chain.record_pending(request(2), SIG))
    assert node.requests.count("eth_getTransactionCount") == 2
    assert node.sent[-1]["nonce"] == 7  # 잃어버린 번호를 다시 쓴다


# ---------------------------------------------------------------- 장부 잔액 이벤트


def confirmed_log(entry_id, amount, kind, block):
    return event_log("EntryConfirmed", block, "0x" + f"{entry_id:064x}", id=entry_id, hash=bytes.fromhex(HASH[2:]),
                     amount=amount, kind=kind, budgetId=0 if kind == 0 else 2, hadWarning=False,
                     warningReasonHash=b"\0" * 32, actor=AUDITOR)


def test_confirmed_entries_read_forward_in_chunks(node):
    node.head = 25
    node.logs = [confirmed_log(1, 5_000_000, 0, block=3), confirmed_log(2, 35_000, 1, block=12), confirmed_log(3, -5_000, 1, block=22)]
    entries = run(client(node, log_chunk_blocks=10).confirmed_entries(0, 25))

    assert [(e.id, e.amount, e.kind, e.block_number) for e in entries] == [
        (1, 5_000_000, EntryKind.INCOME, 3), (2, 35_000, EntryKind.EXPENSE, 12), (3, -5_000, EntryKind.EXPENSE, 22),
    ]
    assert node.log_ranges == [(0, 9), (10, 19), (20, 25)]  # 공개 RPC 는 범위를 엄격히 제한한다. 한 칸도 넘지 않는다


def test_safe_block_uses_finalized_tag_or_finality_depth(node):
    node.head = 200
    node.finalized = 150
    assert run(client(node, confirmations=1).safe_block()) == 150  # 보낼 때 확인 블록 수와 상관없다

    node.finalized = None  # 태그를 모르는 노드
    assert run(client(node, finality_blocks=64).safe_block()) == 136
    node.head = 10
    assert run(client(node, finality_blocks=64).safe_block()) == -1
