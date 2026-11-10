"""체인 조회 — 트랜잭션 기록(entry_tx_detail), 예산 잔량(ChainBudget.remaining), 읽기 전용 클라이언트.

Fake 와 실제 구현이 같은 시나리오에서 같은 값을 내는지 본다. Web3 쪽은 로컬 노드가 필요하고 없으면 건너뛴다.
"""
import asyncio
import time

import pytest
from eth_utils import keccak

from app.chain import (
    ChainSetupError,
    ChainUnavailable,
    ConfirmApproval,
    FakeChainClient,
    IssueRequest,
    RecordRequest,
    RejectDecision,
    entry_commit_of,
    fake_signature,
)
from app.chain import provider
from app.chain.deployment import DEFAULT_PATH, load_deployment
from app.chain.models import BlockReason
from app.chain.web3_client import BUDGET_TOKEN, LEDGER, Web3ChainClient
from app.schemas.entry import EntryKind, EntryStatus
from chain_support import (
    AUDITOR,
    AUDITOR_KEY,
    KST_MIDNIGHT,
    PRESIDENT,
    PRESIDENT_KEY,
    RPC_URL,
    TEST_ID_BASE,
    TREASURER,
    TREASURER_KEY,
    UNREACHABLE,
    approval_for_id,
    budget_remaining,
    on_chain,
    sign_as_app,
)

B = TEST_ID_BASE
TERM = 20262
WARNING_HASH = "0x" + keccak(text="경고 사유").hex()
REJECT_HASH = "0x" + keccak(text="반려 사유").hex()
UNKNOWN_HASH = "0x" + "ab" * 32
DOMAINS = load_deployment(DEFAULT_PATH).eip712


@pytest.fixture(autouse=True)
def isolated(clean_chain_env):
    provider.reset_chain_client()
    yield
    provider.reset_chain_client()


def record(entry_id: int, deadline: int, kind: EntryKind = EntryKind.INCOME, amount: int = 500_000, **override) -> RecordRequest:
    fields = dict(
        id=entry_id,
        hash="0x" + keccak(text=f"reads-{entry_id}").hex(),
        amount=amount,
        kind=kind,
        term=TERM,
        occurred_at=KST_MIDNIGHT,
        budget_id=0,
        corrects_id=0,
        deadline=deadline,
    )
    return RecordRequest(**{**fields, **override})


def fake_sign(payload) -> str:
    if isinstance(payload, RecordRequest):
        return fake_signature(TREASURER)
    if isinstance(payload, IssueRequest):
        return fake_signature(PRESIDENT)
    return fake_signature(AUDITOR)


def web3_sign(payload) -> str:
    if isinstance(payload, RecordRequest):
        return sign_as_app(payload, DOMAINS[LEDGER], TREASURER_KEY)
    if isinstance(payload, IssueRequest):
        return sign_as_app(payload, DOMAINS[BUDGET_TOKEN], PRESIDENT_KEY)
    return sign_as_app(payload, DOMAINS[LEDGER], AUDITOR_KEY)


async def tx_details(client, sign, now: int) -> list:
    """등록·경고 확정·반려·차단의 트랜잭션 기록. 블록 번호는 구현마다 달라 따로 본다."""
    deadline = now + 600
    registered = record(B + 1, deadline)
    first = await client.record_pending(registered, sign(registered))
    approval: ConfirmApproval = approval_for_id(
        await client.get_entry(B + 1), B + 1, deadline, had_warning=True, warning_reason_hash=WARNING_HASH
    )
    confirmed = await client.confirm_entry(approval, sign(approval))

    second_request = record(B + 2, deadline)
    await client.record_pending(second_request, sign(second_request))
    decision = RejectDecision(
        id=B + 2, entry_commit=entry_commit_of(await client.get_entry(B + 2)), reason_hash=REJECT_HASH, deadline=deadline
    )
    rejected = await client.reject_entry(decision, sign(decision))

    blocked_request = record(B + 3, deadline, kind=EntryKind.EXPENSE, amount=35_000)
    blocked = await client.record_pending(blocked_request, sign(blocked_request))

    details = [
        await client.entry_tx_detail(first.tx_hash, B + 1),
        await client.entry_tx_detail(confirmed.tx_hash, B + 1),
        await client.entry_tx_detail(rejected.tx_hash, B + 2),
        await client.entry_tx_detail(blocked.tx_hash, B + 3),
    ]
    assert [d.tx_hash for d in details] == [first.tx_hash, confirmed.tx_hash, rejected.tx_hash, blocked.tx_hash]
    numbers = [d.block_number for d in details]
    assert numbers == sorted(numbers) and len(set(numbers)) == len(numbers) and numbers[0] > 0
    return [(d.status, d.block_reason, d.reason_hash, d.had_warning) for d in details]


EXPECTED_DETAILS = [
    (EntryStatus.PENDING, None, None, False),  # 이 트랜잭션의 결과다. 항목은 그 뒤 확정됐다
    (EntryStatus.CONFIRMED, None, WARNING_HASH, True),
    (EntryStatus.REJECTED, None, REJECT_HASH, False),
    (EntryStatus.BLOCKED, BlockReason.BUDGET_NOT_FOUND, None, False),
]


def test_fake_gives_each_transaction_its_own_record():
    assert asyncio.run(tx_details(FakeChainClient(), fake_sign, int(time.time()))) == EXPECTED_DETAILS


@pytest.mark.chain
def test_chain_gives_the_same_transaction_records_as_the_fake(node):
    assert on_chain(lambda client, now: tx_details(client, web3_sign, now)) == EXPECTED_DETAILS


async def lookups(client, sign, now: int):
    request = record(B + 1, now + 600)
    sent = await client.record_pending(request, sign(request))
    assert await client.entry_tx_detail(UNKNOWN_HASH, B + 1) is None  # 아직 블록에 없다
    with pytest.raises(ChainUnavailable):
        await client.entry_tx_detail(sent.tx_hash, B + 2)  # 다른 항목의 트랜잭션이다
    with pytest.raises(ValueError):
        await client.entry_tx_detail("0x1234", B + 1)


def test_fake_tx_detail_of_an_unknown_or_another_entrys_hash():
    asyncio.run(lookups(FakeChainClient(), fake_sign, int(time.time())))


@pytest.mark.chain
def test_chain_tx_detail_of_an_unknown_or_another_entrys_hash(node):
    on_chain(lambda client, now: lookups(client, web3_sign, now))


async def spend_and_refund(client, sign, now: int) -> list:
    """발행 → 지출 확정 → 음수 정정 확정. 단계마다 잔량을 읽는다."""
    deadline = now + 600
    budget = B + 10
    issue = IssueRequest(
        budget_id=budget,
        term=TERM,
        category="0x" + keccak(text=f"조회 시험 {budget}").hex(),
        amount=1_000,
        expires_at=now + 86400,
        deadline=deadline,
    )
    await client.issue_budget(issue, sign(issue))
    seen = [(await client.get_budget(budget)).remaining]

    async def confirmed(request: RecordRequest) -> None:
        await client.record_pending(request, sign(request))
        approval = approval_for_id(await client.get_entry(request.id), request.id, deadline)
        await client.confirm_entry(approval, sign(approval))
        seen.append((await client.get_budget(budget)).remaining)

    await confirmed(record(B + 1, deadline, kind=EntryKind.EXPENSE, amount=300, budget_id=budget))
    await confirmed(record(B + 2, deadline, kind=EntryKind.EXPENSE, amount=-100, budget_id=budget, corrects_id=B + 1))
    return seen


def test_fake_remaining_follows_confirmed_spending():
    assert asyncio.run(spend_and_refund(FakeChainClient(), fake_sign, int(time.time()))) == [1_000, 700, 800]


@pytest.mark.chain
def test_chain_remaining_matches_the_contract_and_the_fake(node):
    async def body(client, now):
        seen = await spend_and_refund(client, web3_sign, now)
        assert seen[-1] == await budget_remaining(client._w3, B + 10)  # BudgetToken.remaining 과 같은 식이다
        assert await client.get_budget(B + 11) is None  # remaining() 은 0 을 주지만 없는 예산은 None 이다
        return seen

    assert on_chain(body) == [1_000, 700, 800]


def test_fake_does_not_spend_on_a_rejected_expense():
    async def body():
        client, now = FakeChainClient(), int(time.time())
        issue = IssueRequest(
            budget_id=B + 10,
            term=TERM,
            category="0x" + keccak(text="반려 시험").hex(),
            amount=1_000,
            expires_at=now + 86400,
            deadline=now + 600,
        )
        await client.issue_budget(issue, fake_sign(issue))
        request = record(B + 1, now + 600, kind=EntryKind.EXPENSE, amount=300, budget_id=B + 10)
        await client.record_pending(request, fake_sign(request))
        decision = RejectDecision(
            id=B + 1, entry_commit=entry_commit_of(await client.get_entry(B + 1)), reason_hash=REJECT_HASH, deadline=now + 600
        )
        await client.reject_entry(decision, fake_sign(decision))
        return (await client.get_budget(B + 10)).remaining

    assert asyncio.run(body()) == 1_000


# ---------------------------------------------------------------- 읽기 전용


@pytest.mark.parametrize("key", [None, "", "   "])
def test_server_without_a_relayer_key_tries_a_read_only_connection(monkeypatch, key):
    # 키가 없어도 형식 오류로 막지 않고 노드에 연결하러 간다. 여기서는 노드가 없으니 연결 실패다
    monkeypatch.setenv("CHAIN_RPC_URL", UNREACHABLE)
    if key is not None:
        monkeypatch.setenv("RELAYER_PRIVATE_KEY", key)
    with pytest.raises(ChainSetupError, match="노드에 연결할 수 없다"):
        asyncio.run(provider.get_chain_client())


def test_a_malformed_relayer_key_is_still_refused(monkeypatch):
    # 값을 넣었는데 틀렸으면 읽기 전용으로 넘어가지 않는다. 쓰기 서버의 설정 실수를 숨기면 안 된다
    monkeypatch.setenv("CHAIN_RPC_URL", UNREACHABLE)
    monkeypatch.setenv("RELAYER_PRIVATE_KEY", "0x1234")
    with pytest.raises(ChainSetupError, match="0x \\+ hex 64자"):
        asyncio.run(provider.get_chain_client())


@pytest.mark.chain
def test_read_only_client_reads_but_does_not_send(node):
    async def body():
        client = await Web3ChainClient.connect(RPC_URL, None, DEFAULT_PATH)
        try:
            assert client.relayer_address is None and "relayer=None" in repr(client)
            assert await client.get_entry(B + 999) is None
            assert await client.get_budget(B + 999) is None
            assert await client.entry_tx_detail(UNKNOWN_HASH, B + 999) is None
            assert await client.tx_result(UNKNOWN_HASH, B + 999) is None

            request = record(B + 999, 4_102_444_800)
            signature = web3_sign(request)
            assert client.signer_of(request, signature).lower() == TREASURER.lower()
            called = []

            async def before_broadcast(tx_hash):
                called.append(tx_hash)

            with pytest.raises(ChainSetupError, match="읽기 전용"):
                await client.record_pending(request, signature, before_broadcast)
            assert not called  # 선점도 하지 않는다
            assert await client.get_entry(B + 999) is None
        finally:
            await client.close()

    asyncio.run(body())


@pytest.mark.chain
def test_provider_gives_a_read_only_client_without_a_key(node, monkeypatch):
    monkeypatch.setenv("CHAIN_RPC_URL", RPC_URL)

    async def body():
        try:
            client = await provider.get_chain_client()
            assert isinstance(client, Web3ChainClient) and client.relayer_address is None
            assert await client.get_entry(B + 999) is None
        finally:
            await provider.close_chain_client()

    asyncio.run(body())
