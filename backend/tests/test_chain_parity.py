"""FakeChainClient 가 실제 체인(Web3ChainClient)과 같게 동작하는지 같은 시나리오로 확인한다.

등록 API 는 Fake 로 테스트하고 실제 구현으로 갈아끼운다 (CHAIN_CLIENT §6). 두 구현의 결과가 다르면 Fake 로 통과한 코드가
실제 체인에서 다르게 동작한다. 시나리오마다 두 구현이 같은 기대값을 내야 한다 — 결과(status·사유·revert 이유)와
get_entry 값까지 본다. Web3 쪽은 로컬 노드가 필요하고(없으면 건너뜀) evm_snapshot 안에서 실행해 되돌린다.
"""
import asyncio
import time

import pytest
from eth_account import Account
from eth_utils import keccak

from app.chain import ChainRevert, FakeChainClient, RecordRequest, RevertReason, fake_signature
from app.chain.deployment import DEFAULT_PATH, load_deployment
from app.chain.models import MAX_AMOUNT, UINT64_MAX, BlockReason
from app.chain.web3_client import LEDGER, Web3ChainClient
from app.schemas.entry import EntryKind, EntryStatus
from chain_support import RELAYER_KEY, RPC_URL, TREASURER_KEY, chain_now, in_snapshot, sign_as_app

DOMAIN = load_deployment(DEFAULT_PATH).eip712[LEDGER]
TREASURER = Account.from_key(TREASURER_KEY).address
PENDING, BLOCKED = EntryStatus.PENDING, EntryStatus.BLOCKED


@pytest.fixture(autouse=True)
def isolated(clean_chain_env):
    yield


def req(entry_id: int, **override) -> dict:
    """요청 필드. deadline 은 실행할 때 정한다 (기본은 지금 + 10분)."""
    fields = dict(
        id=entry_id,
        hash="0x" + keccak(text=f"parity-{entry_id}").hex(),
        amount=500_000,
        kind=EntryKind.INCOME,
        term=20262,
        occurred_at=1790694000,
        budget_id=0,
        corrects_id=0,
    )
    return {**fields, **override}


def expense(entry_id: int, **override) -> dict:
    return req(entry_id, **{"kind": EntryKind.EXPENSE, "amount": 35_000, **override})


# 개발 노드에는 등록 API 가 DB id(1부터)로 기록한 실제 항목이 있다. 스냅샷은 테스트 안의 쓰기만 되돌리니 그 id 를 피한다
B = 900_000_000_000

# (이름, 차례로 보낼 요청들, 차례로 기대하는 결과). 결과는 (status, block_reason) 또는 RevertReason
SCENARIOS = [
    ("income", [req(B + 1)], [(PENDING, None)]),
    ("expense_without_budget", [expense(B + 1)], [(BLOCKED, BlockReason.BUDGET_NOT_FOUND)]),
    ("same_id_twice", [req(B + 1), req(B + 1)], [(PENDING, None), RevertReason.ENTRY_ALREADY_EXISTS]),
    ("expired", [req(B + 1, deadline=1)], [RevertReason.SIGNATURE_EXPIRED]),
    ("income_with_budget", [req(B + 1, budget_id=3)], [RevertReason.BUDGET_ID_NOT_ALLOWED_FOR_INCOME]),
    ("negative_without_correction", [req(B + 1, amount=-5)], [RevertReason.NEGATIVE_AMOUNT_WITHOUT_CORRECTION]),
    ("zero_amount", [req(B + 1, amount=0)], [RevertReason.ZERO_AMOUNT]),
    ("zero_hash", [req(B + 1, hash="0x" + "00" * 32)], [RevertReason.HASH_REQUIRED]),
    ("amount_over_max", [req(B + 1, amount=MAX_AMOUNT + 1)], [RevertReason.AMOUNT_OUT_OF_RANGE]),
    ("id_over_uint64", [req(UINT64_MAX + 1)], [RevertReason.FIELD_OUT_OF_RANGE]),
    ("budget_over_uint64", [expense(B + 1, budget_id=UINT64_MAX + 1)], [RevertReason.FIELD_OUT_OF_RANGE]),
    ("correction_target_missing", [req(B + 1, corrects_id=B + 999, amount=100)], [RevertReason.CORRECTION_TARGET_NOT_FOUND]),
    (
        "correction_target_not_confirmed",
        [req(B + 1), req(B + 2, corrects_id=B + 1, amount=100)],
        [(PENDING, None), RevertReason.CORRECTION_TARGET_NOT_CONFIRMED],
    ),
]


async def play(client, sign, now: int, requests: list) -> list:
    """요청을 차례로 보내고 (결과, get_entry 값) 목록을 돌려준다."""
    outcomes = []
    for fields in requests:
        request = RecordRequest(**{"deadline": now + 600, **fields})
        try:
            result = await client.record_pending(request, sign(request))
        except ChainRevert as e:
            outcomes.append((e.reason, None))
            continue
        entry = await client.get_entry(request.id)
        outcomes.append(((result.status, result.block_reason), entry.model_dump()))
    return outcomes


def run_fake(requests: list) -> list:
    return asyncio.run(play(FakeChainClient(), lambda r: fake_signature(TREASURER), int(time.time()), requests))


def run_web3(requests: list) -> list:
    def sign(request):
        return sign_as_app(request, DOMAIN, TREASURER_KEY)

    async def run():
        client = await Web3ChainClient.connect(RPC_URL, RELAYER_KEY, DEFAULT_PATH)
        try:
            now = await chain_now(client._w3)
            return await in_snapshot(client._w3, lambda: play(client, sign, now, requests))
        finally:
            await client.close()

    return asyncio.run(run())


@pytest.mark.parametrize("name, requests, expected", SCENARIOS, ids=[s[0] for s in SCENARIOS])
def test_fake_gives_the_expected_results(name, requests, expected):
    assert [outcome for outcome, _ in run_fake(requests)] == expected


@pytest.mark.chain
@pytest.mark.parametrize("name, requests, expected", SCENARIOS, ids=[s[0] for s in SCENARIOS])
def test_chain_gives_the_same_results_as_the_fake(node, name, requests, expected):
    # 결과뿐 아니라 get_entry 로 읽은 값(등록자 주소 포함)까지 같아야 한다
    on_chain = run_web3(requests)
    assert [outcome for outcome, _ in on_chain] == expected
    assert on_chain == run_fake(requests)
