"""Web3ChainClient 의 confirm_entry (확정).

전부 로컬 노드에 실제로 보내고 evm_snapshot 으로 되돌린다. 지출 확정(예산 소모)과 예산 부족은 스냅샷 안에서
예산을 발행해 확인한다 — 공용 노드에는 예산이 남지 않는다 (chain_support.issue_budget).
승인자의 entryCommit 은 앱처럼 체인에 등록된 값(get_entry)으로 계산해 서명한다 (CHAIN_CLIENT §5).
항목·예산 id 는 공용 노드의 실제 기록과 겹치지 않는 TEST_ID_BASE 구간이다.
결과 이벤트를 못 찾았을 때의 대체 경로(등록·확정 공용)도 여기서 본다.
"""
import asyncio

import pytest
from eth_utils import keccak

from app.chain import ChainRevert, ChainUnavailable, ConfirmApproval, RecordRequest, RevertReason, TxResult
from app.chain.deployment import DEFAULT_PATH, load_deployment
from app.chain.web3_client import LEDGER, Web3ChainClient
from app.schemas.entry import EntryKind, EntryStatus
from chain_support import (
    AUDITOR,
    AUDITOR_KEY,
    PRESIDENT,
    PRESIDENT_KEY,
    RELAYER_KEY,
    RPC_URL,
    TEST_ID_BASE,
    TREASURER_KEY,
    approval_for_id,
    budget_remaining,
    chain_now,
    in_snapshot,
    issue_budget,
    sign_as_app,
)

DOMAIN = load_deployment(DEFAULT_PATH).eip712[LEDGER]
KST_MIDNIGHT = 1790694000
REASON = "0x" + keccak(text="경고 승인 사유").hex()
E = TEST_ID_BASE + 2000  # 항목 id
BUDGET = TEST_ID_BASE + 900  # 예산 id


@pytest.fixture(autouse=True)
def isolated(clean_chain_env):
    yield


def on_chain(body):
    """연결 → 스냅샷 안에서 body(client, now) → 되돌림 → 닫기."""

    async def run():
        client = await Web3ChainClient.connect(RPC_URL, RELAYER_KEY, DEFAULT_PATH)
        try:
            now = await chain_now(client._w3)
            return await in_snapshot(client._w3, lambda: body(client, now))
        finally:
            await client.close()

    return asyncio.run(run())


async def record(client, now: int, entry_id: int, **override) -> TxResult:
    """총무가 서명한 등록을 보낸다 (기본은 수입)."""
    fields = dict(
        id=entry_id,
        hash="0x" + keccak(text=f"confirm-{entry_id}").hex(),
        amount=500_000,
        kind=EntryKind.INCOME,
        term=20262,
        occurred_at=KST_MIDNIGHT,
        budget_id=0,
        corrects_id=0,
        deadline=now + 600,
    )
    request = RecordRequest(**{**fields, **override})
    return await client.record_pending(request, sign_as_app(request, DOMAIN, TREASURER_KEY))


async def approval_for(client, now: int, entry_id: int, **override) -> ConfirmApproval:
    """앱이 만드는 확정 요청. 체인에 등록된 값으로 entryCommit 을 계산한다."""
    return approval_for_id(await client.get_entry(entry_id), entry_id, **{"deadline": now + 600, **override})


async def confirm(client, approval: ConfirmApproval, key: str = AUDITOR_KEY, before_broadcast=None):
    return await client.confirm_entry(approval, sign_as_app(approval, DOMAIN, key), before_broadcast)


async def nonce(client) -> int:
    return await client._w3.eth.get_transaction_count(client.relayer_address, "latest")


# ---------------------------------------------------------------- 정상 경로


@pytest.mark.chain
def test_income_is_confirmed_by_the_auditor(node):
    seen = []

    async def body(client, now):
        await record(client, now, E + 1)

        async def claim(tx_hash):
            seen.append(tx_hash)  # 등록 API 라면 여기서 tx_confirm 을 선점한다

        result = await confirm(client, await approval_for(client, now, E + 1), before_broadcast=claim)
        return result, await client.get_entry(E + 1)

    result, entry = on_chain(body)
    assert result.status is EntryStatus.CONFIRMED and seen == [result.tx_hash]
    assert (entry.status, entry.approver) == (EntryStatus.CONFIRMED, AUDITOR)


@pytest.mark.chain
def test_expense_confirmation_spends_the_budget(node):
    # 확정 순간 BudgetToken.spend 가 불려 잔량이 준다 (PRD §4.3 "확정 — 예산 토큰 소모")
    async def body(client, now):
        await issue_budget(client._w3, BUDGET + 1, 100_000)
        await record(client, now, E + 2, kind=EntryKind.EXPENSE, amount=35_000, budget_id=BUDGET + 1)
        pending = await client.get_entry(E + 2)
        result = await confirm(client, await approval_for(client, now, E + 2))
        return pending.status, result.status, await budget_remaining(client._w3, BUDGET + 1)

    assert on_chain(body) == (EntryStatus.PENDING, EntryStatus.CONFIRMED, 65_000)


@pytest.mark.chain
def test_the_president_can_confirm_too(node):
    # 회장도 감사와 같은 승인 권한을 가진다 (PRD §3, 원장 _requireApprover)
    async def body(client, now):
        await record(client, now, E + 6)
        result = await confirm(client, await approval_for(client, now, E + 6), PRESIDENT_KEY)
        entry = await client.get_entry(E + 6)
        return result.status, entry.status, entry.approver

    assert on_chain(body) == (EntryStatus.CONFIRMED, EntryStatus.CONFIRMED, PRESIDENT)


@pytest.mark.chain
def test_confirmation_with_a_warning_and_its_reason(node):
    async def body(client, now):
        await record(client, now, E + 3)
        approval = await approval_for(client, now, E + 3, had_warning=True, warning_reason_hash=REASON)
        return (await confirm(client, approval)).status

    assert on_chain(body) is EntryStatus.CONFIRMED


@pytest.mark.chain
def test_insufficient_budget_keeps_the_entry_pending(node):
    # 등록 때는 잔량만 보고 대기 건을 예약하지 않는다. 대기 두 건이 예산을 나눠 쓰면 두 번째 확정이 revert 하고
    # 항목은 PENDING 그대로다 — 반려 흐름으로 넘긴다 (CHAIN_CLIENT §4)
    async def body(client, now):
        await issue_budget(client._w3, BUDGET + 2, 50_000)
        await record(client, now, E + 4, kind=EntryKind.EXPENSE, amount=35_000, budget_id=BUDGET + 2)
        await record(client, now, E + 5, kind=EntryKind.EXPENSE, amount=35_000, budget_id=BUDGET + 2)
        await confirm(client, await approval_for(client, now, E + 4))
        with pytest.raises(ChainRevert) as error:
            await confirm(client, await approval_for(client, now, E + 5))
        return error.value, await client.get_entry(E + 5), await budget_remaining(client._w3, BUDGET + 2)

    revert, entry, remaining = on_chain(body)
    assert revert.reason is RevertReason.INSUFFICIENT_BUDGET
    assert entry.status is EntryStatus.PENDING and remaining == 15_000


# ---------------------------------------------------------------- 시뮬레이션에서 걸리는 것 (가스 0, 콜백 없음)


def rejected(prepare, key: str = AUDITOR_KEY):
    """prepare(client, now) 로 준비한 확정 요청이 시뮬레이션에서 걸려 보내지지 않는지. revert 를 돌려준다."""
    called = []

    async def body(client, now):
        approval = await prepare(client, now)
        before = await nonce(client)

        async def claim(tx_hash):
            called.append(tx_hash)

        with pytest.raises(ChainRevert) as error:
            await confirm(client, approval, key, claim)
        return error.value, before, await nonce(client)

    revert, before, after = on_chain(body)
    assert called == [] and after == before
    return revert


async def recorded_income(client, now, entry_id=E + 10, **override):
    await record(client, now, entry_id)
    return await approval_for(client, now, entry_id, **override)


@pytest.mark.chain
@pytest.mark.parametrize(
    "override, reason",
    [
        ({"entry_commit": "0x" + "33" * 32}, RevertReason.ENTRY_COMMIT_MISMATCH),  # 승인자가 본 값 ≠ 등록 값
        ({"hash": "0x" + "44" * 32}, RevertReason.HASH_MISMATCH),
        ({"had_warning": True}, RevertReason.REASON_REQUIRED),  # 경고 승인인데 사유 없음
        ({"warning_reason_hash": REASON}, RevertReason.REASON_NOT_ALLOWED),  # 경고가 아닌데 사유 있음
        ({"deadline": 1}, RevertReason.SIGNATURE_EXPIRED),
    ],
)
def test_invalid_approvals_are_caught_before_sending(node, override, reason):
    assert rejected(lambda client, now: recorded_income(client, now, **override)).reason is reason


@pytest.mark.chain
def test_blocked_entry_cannot_be_confirmed(node):
    async def prepare(client, now):
        await record(client, now, E + 11, kind=EntryKind.EXPENSE, amount=35_000)  # 예산 0 → BLOCKED
        return await approval_for(client, now, E + 11)

    assert rejected(prepare).reason is RevertReason.INVALID_STATUS


@pytest.mark.chain
def test_confirming_twice_is_invalid_status(node):
    async def prepare(client, now):
        approval = await recorded_income(client, now, E + 12)
        await confirm(client, approval)
        return approval

    assert rejected(prepare).reason is RevertReason.INVALID_STATUS


@pytest.mark.chain
def test_unknown_entry_is_not_found(node):
    assert rejected(lambda client, now: approval_for(client, now, E + 999)).reason is RevertReason.ENTRY_NOT_FOUND


@pytest.mark.chain
@pytest.mark.parametrize("key", [TREASURER_KEY, RELAYER_KEY])
def test_only_auditors_and_the_president_can_confirm(node, key):
    # 지금 총무인 사람은 롤 검사에서 먼저 막혀 SELF_APPROVAL 이 아니라 NOT_APPROVER 다 (CHAIN_CLIENT §6)
    assert rejected(lambda client, now: recorded_income(client, now, E + 13), key=key).reason is RevertReason.NOT_APPROVER


# ---------------------------------------------------------------- 결과 이벤트를 못 찾았을 때 (등록·확정 공용 대체 경로)


def without_events(client, close_after_landing: bool = False) -> None:
    """receipt 에서 로그를 뺀다 — ABI 가 어긋나 결과 이벤트를 해석하지 못한 경우를 흉내 낸다.

    close_after_landing 이면 트랜잭션이 들어가고 lock 이 풀린 직후 provider 가 교체로 클라이언트를 닫은 것처럼 한다.
    """
    relay = client._relay

    async def patched(call, before_broadcast):
        tx_hash, receipt = await relay(call, before_broadcast)
        if close_after_landing:
            client._closed = True  # close() 와 같은 표시. 연결은 스냅샷을 되돌려야 하니 끊지 않는다
        return tx_hash, {**receipt, "logs": []}

    client._relay = patched


@pytest.mark.chain
def test_landed_transactions_without_an_event_are_read_from_the_chain(node):
    async def body(client, now):
        await record(client, now, E + 20)
        without_events(client)
        recorded = await record(client, now, E + 21)
        confirmed = await confirm(client, await approval_for(client, now, E + 20))
        return recorded, confirmed

    recorded, confirmed = on_chain(body)
    assert (recorded.status, recorded.block_reason) == (EntryStatus.PENDING, None)
    assert (confirmed.status, confirmed.block_reason) == (EntryStatus.CONFIRMED, None)


@pytest.mark.chain
def test_blocked_without_an_event_is_not_asserted(node):
    # 차단 사유는 이벤트에만 있다. 이벤트 없이 체인에서 BLOCKED 를 읽어도 사유를 지어내지 않고 "결과 모름" 으로 둔다
    async def body(client, now):
        without_events(client)
        with pytest.raises(ChainUnavailable, match="결과 이벤트를 찾지 못했다"):
            await record(client, now, E + 22, kind=EntryKind.EXPENSE, amount=35_000)
        return await client.get_entry(E + 22)

    entry = on_chain(body)
    assert entry.status is EntryStatus.BLOCKED  # 실제로는 들어갔다


@pytest.mark.chain
def test_client_replaced_after_landing_is_unavailable_not_a_setup_error(node):
    # 들어간 뒤의 ChainSetupError 는 서비스가 "보내지 않음" 으로 보고 tx_confirm 을 비운다 (CHAIN_CLIENT §3).
    # 그러면 재시도가 이미 CONFIRMED 인 항목에 INVALID_STATUS 를 받는다. 들어갔으니 ChainUnavailable 이어야 한다
    claimed = []

    async def body(client, now):
        await record(client, now, E + 23)
        without_events(client, close_after_landing=True)

        async def claim(tx_hash):
            claimed.append(tx_hash)

        with pytest.raises(ChainUnavailable, match="들어갔지만 결과를 확인하지 못했다") as error:
            await confirm(client, await approval_for(client, now, E + 23), before_broadcast=claim)
        client._closed = False  # 체인 상태를 직접 확인하려고 다시 연다
        return error.value, await client.get_entry(E + 23)

    error, entry = on_chain(body)
    assert len(claimed) == 1 and entry.status is EntryStatus.CONFIRMED
    assert "ChainSetupError" in str(error)


# ---------------------------------------------------------------- 테스트 도우미 (예산 발행)


@pytest.mark.chain
def test_test_budgets_never_share_a_budget_key(node):
    # 예산 키 (term, category) 는 budget_id 마다 테스트 전용 이름이다. 같은 학기에 여러 개를 발행해도
    # BudgetAlreadyIssued 가 나지 않고, 예산 화면이 쓰는 "행사비" 같은 실제 이름과도 겹치지 않는다
    async def body(client, now):
        await issue_budget(client._w3, BUDGET + 3, 1_000)
        await issue_budget(client._w3, BUDGET + 4, 2_000)
        return await budget_remaining(client._w3, BUDGET + 3), await budget_remaining(client._w3, BUDGET + 4)

    assert on_chain(body) == (1_000, 2_000)


@pytest.mark.chain
def test_a_failing_budget_issue_names_its_revert(node):
    # Hardhat 은 revert 하는 전송에 에러만 돌려준다. 시뮬레이션에서 사유 이름과 함께 멈춰야 원인을 안다
    async def body(client, now):
        await issue_budget(client._w3, BUDGET + 5, 1_000)
        with pytest.raises(AssertionError, match="예산 발행이 revert 한다: .*BudgetAlready"):
            await issue_budget(client._w3, BUDGET + 5, 1_000)

    on_chain(body)
