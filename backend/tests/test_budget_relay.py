"""예산 발행·증액: 서명 대상, revert 해석, FakeChainClient·실제 체인의 같은 결과, 서비스의 항목별 결과."""
import asyncio
import json
import re
import time
from pathlib import Path

import pytest
from eth_abi import encode
from eth_account import Account
from eth_utils import keccak
from pydantic import ValidationError

from app.chain import (
    BudgetRevertReason,
    ChainRevert,
    ChainSetupError,
    ChainUnavailable,
    FakeChainClient,
    IncreaseRequest,
    IssueRequest,
    RevertReason,
    fake_signature,
)
from app.chain.deployment import DEFAULT_PATH, Eip712Domain, load_abi, load_deployment
from app.chain import web3_client
from app.chain.eip712 import (
    APPROVED_CATEGORIES,
    INCREASE_REQUEST_FIELDS,
    ISSUE_REQUEST_FIELDS,
    category_hash,
    digest,
    recover_signer,
    typed_data_for,
)
from app.chain.models import MAX_AMOUNT, ZERO_BYTES32
from app.chain.revert import RevertDecoder, budget_revert_decoder
from app.chain.web3_client import BUDGET_TOKEN, Web3ChainClient
from app.services.budget_relay import MALFORMED_SIGNATURE, REASON_HASH_MISMATCH, BudgetRelayStatus, relay_increase, relay_issue
from app.utils.hashing import text_hash
from chain_support import AUDITOR, AUDITOR_KEY, PRESIDENT, PRESIDENT_KEY, RELAYER_KEY, RPC_URL, TEST_ID_BASE, TREASURER_KEY, chain_now, in_snapshot, sign_as_app

FIXTURE = json.loads((Path(__file__).parent / "fixtures" / "eip712_vectors.json").read_text(encoding="utf-8"))
VECTOR_DOMAIN = Eip712Domain.model_validate(FIXTURE["budgetDomain"])
VECTORS = {v["name"]: v for v in FIXTURE["budgetVectors"]}
DEPLOYMENT = load_deployment(DEFAULT_PATH)
DOMAIN = DEPLOYMENT.eip712[BUDGET_TOKEN]
BUDGET_ABI = load_abi(DEPLOYMENT.contracts[BUDGET_TOKEN], DEFAULT_PATH)
BUDGET_ERRORS = {item["name"]: item for item in BUDGET_ABI if item["type"] == "error"}
LEDGER_ABI = load_abi(DEPLOYMENT.contracts["AccountingLedger"], DEFAULT_PATH)

B = TEST_ID_BASE + 50_000
TERM = 20262
REASON_TEXT = "참가 인원 증가"
REASON = text_hash(REASON_TEXT)
ISSUED, ALREADY, INCREASED, REJECTED, NO_RESPONSE, NOT_SENT = (
    BudgetRelayStatus.ISSUED,
    BudgetRelayStatus.ALREADY_ISSUED,
    BudgetRelayStatus.INCREASED,
    BudgetRelayStatus.REJECTED,
    BudgetRelayStatus.NO_RESPONSE,
    BudgetRelayStatus.NOT_SENT,
)


@pytest.fixture(autouse=True)
def isolated(clean_chain_env):
    yield


def category(budget_id: int) -> str:
    return "0x" + keccak(text=f"테스트 예산 {budget_id}").hex()


def issue_request(now: int, budget_id: int = B, **override) -> IssueRequest:
    fields = dict(budget_id=budget_id, term=TERM, category=category(budget_id), amount=1_000, expires_at=now + 86400, deadline=now + 600)
    return IssueRequest(**{**fields, **override})


def increase_request(now: int, budget_id: int = B, **override) -> IncreaseRequest:
    fields = dict(budget_id=budget_id, amount=500, reason_hash=REASON, version=1, deadline=now + 600)
    return IncreaseRequest(**{**fields, **override})


def vector_payload(vector: dict):
    m = vector["message"]
    if vector["primaryType"] == "IssueRequest":
        return IssueRequest(
            budget_id=m["budgetId"], term=m["term"], category=m["category"], amount=m["amount"], expires_at=m["expiresAt"], deadline=m["deadline"]
        )
    return IncreaseRequest(budget_id=m["budgetId"], amount=m["amount"], reason_hash=m["reasonHash"], version=m["version"], deadline=m["deadline"])


# ---------------------------------------------------------------- 서명 대상


@pytest.mark.parametrize("name", VECTORS)
def test_digest_and_signer_match_ethers(name):
    vector = VECTORS[name]
    typed = typed_data_for(vector_payload(vector), VECTOR_DOMAIN)
    assert digest(typed) == vector["digest"]
    assert recover_signer(typed, vector["signature"]) == vector["signer"]


def test_budget_vectors_match_the_repo_deployment():
    assert VECTOR_DOMAIN == DOMAIN


def test_president_and_auditor_sign_the_same_digest():
    assert VECTORS["increase_president"]["digest"] == VECTORS["increase_auditor"]["digest"]
    assert VECTORS["increase_president"]["signer"] != VECTORS["increase_auditor"]["signer"]


@pytest.mark.parametrize(
    "fields, function, struct",
    [(ISSUE_REQUEST_FIELDS, "issue", "IssueRequest"), (INCREASE_REQUEST_FIELDS, "increase", "IncreaseRequest")],
)
def test_field_order_matches_the_budget_token_abi(fields, function, struct):
    (item,) = [f for f in BUDGET_ABI if f.get("type") == "function" and f["name"] == function]
    arg = item["inputs"][0]
    assert arg["internalType"] == f"struct IBudgetToken.{struct}"
    assert [(c["name"], c["type"]) for c in arg["components"]] == list(fields)


def test_budget_signature_does_not_recover_under_the_ledger_domain():
    # 도메인이 다르면 같은 값·같은 서명이 다른 사람으로 복구된다. signer_of 가 도메인을 잘못 고르면 여기서 드러난다
    vector = VECTORS["issue_budget"]
    ledger = Eip712Domain.model_validate(FIXTURE["domain"])
    assert recover_signer(typed_data_for(vector_payload(vector), ledger), vector["signature"]) != vector["signer"]


def test_category_hash_matches_contracts_doc():
    assert category_hash("학생회비") == "0x30196e0702394f886c610dd63afe744491e2280bc4cb254069b0f6bb4e673015"
    assert category_hash("행사비") == VECTORS["issue_budget"]["message"]["category"]


@pytest.mark.parametrize(
    "name",
    ["", "행사 비", " 행사비", "\u1112\u1162\u11bc\u1109\u1161\u1107\u1175", "행사비\u200b", "행사비\ufeff", "행사\u00ad비", "테스트"],
    ids=["empty", "space", "leading_space", "nfd", "zero_width", "bom", "soft_hyphen", "not_in_table"],
)
def test_category_hash_only_takes_names_in_the_approved_table(name):
    with pytest.raises(ValueError):
        category_hash(name)


def test_approved_categories_match_contracts_doc():
    doc = (Path(__file__).parents[2] / "docs" / "CONTRACTS.md").read_text(encoding="utf-8")
    rows = re.findall(r"^\| (?:INCOME|EXPENSE) \| `([^`]+)` \| `(0x[0-9a-f]{64})` \|$", doc, re.MULTILINE)
    assert {name for name, _ in rows} == APPROVED_CATEGORIES
    for name, expected in rows:
        assert category_hash(name) == expected


@pytest.mark.parametrize(
    "override",
    [
        {"budget_id": 0},
        {"budget_id": 2**64},
        {"term": 1},
        {"category": ZERO_BYTES32},
        {"category": "0x" + "AB" * 32},
        {"amount": 0},
        {"amount": MAX_AMOUNT + 1},
        {"expires_at": 2**64},
    ],
)
def test_issue_model_refuses_what_the_contract_always_refuses(override):
    with pytest.raises(ValidationError):
        issue_request(1000, **override)


@pytest.mark.parametrize("override", [{"amount": 0}, {"reason_hash": ZERO_BYTES32}, {"version": 0}, {"budget_id": 0}])
def test_increase_model_refuses_what_the_contract_always_refuses(override):
    with pytest.raises(ValidationError):
        increase_request(1000, **override)


# ---------------------------------------------------------------- revert 해석


@pytest.mark.parametrize("reason", list(BudgetRevertReason), ids=lambda r: r.value)
def test_every_budget_reason_decodes_from_the_budget_token_abi(reason):
    inputs = BUDGET_ERRORS[reason.value]["inputs"]
    types = [i["type"] for i in inputs]
    sample = {"uint256": 7, "address": PRESIDENT, "bytes32": b"\x11" * 32}
    data = keccak(text=f"{reason.value}({','.join(types)})")[:4] + encode(types, [sample[t] for t in types])
    assert budget_revert_decoder(BUDGET_ABI).decode(data).reason is reason


def test_no_budget_reason_is_missing_from_the_deployed_abi():
    assert budget_revert_decoder(BUDGET_ABI).missing_reasons() == []


def test_ledger_decoder_keeps_budget_only_errors_unknown():
    # 원장 호출에서 날 수 없는 에러를 원장 사유로 붙이지 않는다. 두 해석기는 섞이지 않는다
    data = keccak(text="NotPresident(address)")[:4] + encode(["address"], [PRESIDENT])
    assert RevertDecoder(LEDGER_ABI, BUDGET_ABI).decode(data).reason is RevertReason.UNKNOWN
    assert budget_revert_decoder(BUDGET_ABI).decode(data).reason is BudgetRevertReason.NOT_PRESIDENT


# ---------------------------------------------------------------- Fake 와 실제 체인이 같은가

E = BudgetRevertReason


def _steps(now: int) -> dict:
    """시나리오 이름 → (단계 목록, 기대 결과). 단계는 ("issue", 요청) 또는 ("increase", 요청)."""
    issue, increase = (lambda **o: ("issue", issue_request(now, **o))), (lambda **o: ("increase", increase_request(now, **o)))
    return {
        "issue": ([issue()], [1]),
        "issue_same_id": ([issue(), issue()], [1, E.BUDGET_ALREADY_EXISTS]),
        "issue_same_term_category": (
            [issue(), issue(budget_id=B + 1, category=category(B))],
            [1, E.BUDGET_ALREADY_ISSUED],
        ),
        "issue_other_term": ([issue(), issue(budget_id=B + 1, category=category(B), term=20271)], [1, 1]),
        "issue_signature_expired": ([issue(deadline=1)], [E.SIGNATURE_EXPIRED]),
        "issue_budget_expired": ([issue(expires_at=1)], [E.BUDGET_EXPIRED]),
        "increase": ([issue(), increase()], [1, 2]),
        "increase_twice": ([issue(), increase(), increase(version=2)], [1, 2, 3]),
        "increase_reused_signature": ([issue(), increase(), increase()], [1, 2, E.VERSION_MISMATCH]),
        "increase_unknown_budget": ([increase()], [E.BUDGET_NOT_FOUND]),
        "increase_signature_expired": ([issue(), increase(deadline=1)], [1, E.SIGNATURE_EXPIRED]),
        "increase_over_the_cap": ([issue(), increase(amount=MAX_AMOUNT)], [1, E.AMOUNT_OUT_OF_RANGE]),
    }


SCENARIOS = list(_steps(0))


async def _play(client, steps: list, sign_issue, sign_increase) -> list:
    outcomes = []
    for kind, request in steps:
        try:
            if kind == "issue":
                result = await client.issue_budget(request, sign_issue(request))
            else:
                result = await client.increase_budget(request, *sign_increase(request))
        except ChainRevert as e:
            outcomes.append((e.reason, None))
            continue
        assert await client.budget_tx_result(result.tx_hash, request.budget_id) == result
        outcomes.append((result.version, (await client.get_budget(request.budget_id)).model_dump()))
    return outcomes


def run_fake(name: str) -> list:
    now = int(time.time())
    return asyncio.run(
        _play(
            FakeChainClient(),
            _steps(now)[name][0],
            lambda _: fake_signature(PRESIDENT),
            lambda _: (fake_signature(PRESIDENT), fake_signature(AUDITOR)),
        )
    )


def run_web3(name: str) -> list:
    async def run():
        client = await Web3ChainClient.connect(RPC_URL, RELAYER_KEY, DEFAULT_PATH)
        try:
            now = await chain_now(client._w3)
            steps = _steps(now)[name][0]

            def sign_increase(request):
                return sign_as_app(request, DOMAIN, PRESIDENT_KEY), sign_as_app(request, DOMAIN, AUDITOR_KEY)

            return await in_snapshot(client._w3, lambda: _play(client, steps, lambda r: sign_as_app(r, DOMAIN, PRESIDENT_KEY), sign_increase))
        finally:
            await client.close()

    return asyncio.run(run())


@pytest.mark.parametrize("name", SCENARIOS)
def test_fake_gives_the_expected_results(name):
    assert [o for o, _ in run_fake(name)] == _steps(0)[name][1]


@pytest.mark.chain
@pytest.mark.parametrize("name", SCENARIOS)
def test_chain_gives_the_same_results_as_the_fake(node, name):
    def comparable(outcomes):
        # 시각은 실행마다 다르다. 나머지 값은 같아야 한다
        return [(o, {k: v for k, v in b.items() if k != "expires_at"} if b else None) for o, b in outcomes]

    assert comparable(run_web3(name)) == comparable(run_fake(name))


@pytest.mark.chain
def test_signer_of_uses_the_budget_token_domain_on_chain(node):
    async def run():
        client = await Web3ChainClient.connect(RPC_URL, RELAYER_KEY, DEFAULT_PATH)
        try:
            request = issue_request(await chain_now(client._w3))
            return client.signer_of(request, sign_as_app(request, DOMAIN, PRESIDENT_KEY))
        finally:
            await client.close()

    assert asyncio.run(run()) == PRESIDENT


@pytest.mark.chain
@pytest.mark.parametrize(
    "keys, reason",
    [
        ((TREASURER_KEY, AUDITOR_KEY), E.NOT_PRESIDENT),
        ((PRESIDENT_KEY, PRESIDENT_KEY), E.NOT_AUDITOR),
        ((PRESIDENT_KEY, TREASURER_KEY), E.NOT_AUDITOR),
    ],
    ids=["requester_not_president", "same_signer_twice", "approver_not_auditor"],
)
def test_increase_needs_president_and_auditor_on_chain(node, keys, reason):
    async def run():
        client = await Web3ChainClient.connect(RPC_URL, RELAYER_KEY, DEFAULT_PATH)
        try:
            now = await chain_now(client._w3)

            async def body():
                issue = issue_request(now)
                await client.issue_budget(issue, sign_as_app(issue, DOMAIN, PRESIDENT_KEY))
                request = increase_request(now)
                await client.increase_budget(request, sign_as_app(request, DOMAIN, keys[0]), sign_as_app(request, DOMAIN, keys[1]))

            await in_snapshot(client._w3, body)
        finally:
            await client.close()

    with pytest.raises(ChainRevert) as e:
        asyncio.run(run())
    assert e.value.reason is reason


@pytest.mark.chain
def test_issue_by_a_non_president_is_refused_on_chain(node):
    async def run():
        client = await Web3ChainClient.connect(RPC_URL, RELAYER_KEY, DEFAULT_PATH)
        try:
            request = issue_request(await chain_now(client._w3))
            return await relay_issue(client, request, sign_as_app(request, DOMAIN, TREASURER_KEY))
        finally:
            await client.close()

    outcome = asyncio.run(run())
    assert (outcome.status, outcome.reason) == (REJECTED, "NotPresident")


def test_fake_same_signer_twice_is_not_auditor():
    now = int(time.time())

    async def run():
        fake = FakeChainClient()
        await fake.issue_budget(issue_request(now), fake_signature(PRESIDENT))
        await fake.increase_budget(increase_request(now), fake_signature(PRESIDENT), fake_signature(PRESIDENT))

    with pytest.raises(ChainRevert) as e:
        asyncio.run(run())
    assert e.value.reason is E.NOT_AUDITOR


def test_entry_tx_result_does_not_read_a_budget_transaction():
    now = int(time.time())

    async def run():
        fake = FakeChainClient()
        result = await fake.issue_budget(issue_request(now), fake_signature(PRESIDENT))
        await fake.tx_result(result.tx_hash, B)

    with pytest.raises(Exception, match="결과 이벤트를 찾지 못했다"):
        asyncio.run(run())


# ---------------------------------------------------------------- 항목별 결과 (app/services/budget_relay.py)

SENT_HASH = "0x" + "ab" * 32


class Clock:
    def __init__(self):
        self.now = int(time.time())

    def __call__(self):
        return self.now


def now_s() -> int:
    return int(time.time())


def issue_once(fake, request, **kw):
    return asyncio.run(relay_issue(fake, request, fake_signature(PRESIDENT), **kw))


def increase_once(fake, request, previous_tx_hash=None, reason=REASON_TEXT, **kw):
    return asyncio.run(
        relay_increase(fake, request, reason, fake_signature(PRESIDENT), fake_signature(AUDITOR), previous_tx_hash=previous_tx_hash, **kw)
    )


def raises(error):
    """호출되면 error 를 던지는 비동기 함수. 가짜가 만들지 못하는 체인 응답을 흉내 낸다."""

    async def call(*_):
        raise error

    return call


def sends_then_raises(error, tx_hash=SENT_HASH):
    """before_broadcast 까지 간 뒤 error 를 던지는 쓰기. 블록에 들어가 실패했거나(revert) 전송이 거절된 경우다."""

    async def call(*args):
        await args[-1](tx_hash)
        raise error

    return call


def counting(fake, method):
    calls = []
    original = getattr(fake, method)

    async def call(*args):
        calls.append(args)
        return await original(*args)

    setattr(fake, method, call)
    return calls


# 발행


def test_issue_is_issued_with_its_hash_and_version():
    outcome = issue_once(FakeChainClient(), issue_request(now_s()))
    assert (outcome.status, outcome.version) == (ISSUED, 1)
    assert outcome.tx_hash


def test_retry_after_a_landed_lost_response_is_already_issued():
    # 앱 주석의 경우: 응답이 없던 시도가 사실은 성공했다
    fake, request = FakeChainClient(), issue_request(now_s())
    fake.unavailable_next("issue_budget", landed=True)
    assert issue_once(fake, request).status is ISSUED  # 저장한 hash 로 바로 확인된다
    again = issue_once(fake, request)
    assert again.status is ALREADY
    assert (again.existing.id, again.existing.issued) == (B, request.amount)


def test_retry_after_the_deadline_of_a_landed_issue_is_already_issued():
    # 컨트랙트는 시한을 먼저 봐서 SignatureExpired 가 난다. 체인에 예산이 있는데 "거부" 라고 하면 안 된다
    clock = Clock()
    fake, request = FakeChainClient(clock=clock), issue_request(clock.now)
    issue_once(fake, request)
    clock.now = request.deadline + 1
    outcome = issue_once(fake, request)
    assert (outcome.status, outcome.reason) == (ALREADY, "SignatureExpired")


def test_expired_issue_that_never_landed_is_rejected():
    clock = Clock()
    fake, request = FakeChainClient(clock=clock), issue_request(clock.now)
    clock.now = request.deadline + 1
    outcome = issue_once(fake, request)
    assert (outcome.status, outcome.reason) == (REJECTED, "SignatureExpired")


def test_lost_response_that_did_not_land_is_no_response_with_its_hash_and_cause():
    fake = FakeChainClient()
    fake.unavailable_next("issue_budget", landed=False)
    outcome = issue_once(fake, issue_request(now_s()))
    assert outcome.status is NO_RESPONSE
    assert outcome.tx_hash and outcome.failed_tx_hash is None
    assert "unavailable_next" in outcome.detail


def test_failure_before_sending_is_no_response_without_a_hash():
    fake = FakeChainClient()
    fake.unavailable_next("issue_budget", sent=False)
    outcome = issue_once(fake, issue_request(now_s()))
    assert (outcome.status, outcome.tx_hash) == (NO_RESPONSE, None)
    assert "보내기 전" in outcome.detail


def test_result_that_cannot_be_read_back_is_no_response_with_both_causes():
    fake = FakeChainClient()
    fake.unavailable_next("issue_budget", landed=True)
    fake.budget_tx_result = raises(ChainSetupError("교체됨"))
    outcome = issue_once(fake, issue_request(now_s()))
    assert outcome.status is NO_RESPONSE
    assert outcome.tx_hash
    assert "unavailable_next" in outcome.detail and "교체됨" in outcome.detail


def test_transaction_that_ended_in_failure_is_rejected_and_its_claim_can_be_released():
    fake = FakeChainClient()
    fake.unavailable_next("issue_budget", landed=False)
    fake.budget_tx_result = raises(ChainRevert(RevertReason.UNKNOWN, "실패로 끝났다"))
    outcome = issue_once(fake, issue_request(now_s()))
    assert (outcome.status, outcome.reason) == (REJECTED, "Unknown")
    assert outcome.failed_tx_hash and outcome.tx_hash is None


def test_failed_transaction_of_an_already_landed_budget_is_already_issued():
    fake, request = FakeChainClient(), issue_request(now_s())
    issue_once(fake, request)
    fake.issue_budget = sends_then_raises(ChainRevert(RevertReason.UNKNOWN))
    outcome = issue_once(fake, request)
    assert outcome.status is ALREADY
    assert outcome.failed_tx_hash == SENT_HASH  # 이번 시도는 체인에 남지 않았다. 저장할 hash 가 아니다
    assert outcome.tx_hash is None


def test_same_term_and_category_under_another_id_reports_the_real_budget():
    # DB 를 초기화해 id 가 어긋난 경우. "이미 발행됨" 만 돌려주면 이 id 를 쓰는 지출이 BUDGET_NOT_FOUND 로 막힌다
    fake, now = FakeChainClient(), now_s()
    issue_once(fake, issue_request(now))
    outcome = issue_once(fake, issue_request(now, budget_id=B + 1, category=category(B)))
    assert outcome.status is ALREADY
    assert outcome.existing.id == B


def test_same_id_with_another_budget_is_rejected_not_already_issued():
    # id 가 겹친 다른 항목을 "이미 발행됨" 이라 하면, 이 항목은 발행되지 않았는데 끝난 것처럼 보인다
    fake, now = FakeChainClient(), now_s()
    issue_once(fake, issue_request(now))
    outcome = issue_once(fake, issue_request(now, category=category(B + 1)))
    assert (outcome.status, outcome.reason) == (REJECTED, "BudgetAlreadyExists")


@pytest.mark.parametrize("reason", [E.BUDGET_ALREADY_EXISTS, E.BUDGET_ALREADY_ISSUED])
def test_already_there_but_not_readable_is_in_the_mempool_not_rejected(reason):
    # 시뮬레이션은 다음 블록, 조회는 최신 블록 기준이다. 거부라고 하면 잠시 뒤 실제로 발행된다
    fake = FakeChainClient()
    fake.issue_budget = raises(ChainRevert(reason))
    assert issue_once(fake, issue_request(now_s())).status is NO_RESPONSE


def test_chain_that_cannot_be_read_after_a_revert_is_no_response():
    fake, now = FakeChainClient(), now_s()
    issue_once(fake, issue_request(now))
    fake.budget_id_of = raises(ChainUnavailable("끊김"))
    outcome = issue_once(fake, issue_request(now))
    assert outcome.status is NO_RESPONSE
    assert "끊김" in outcome.detail


@pytest.mark.parametrize("reason", [E.NOT_PRESIDENT, E.BUDGET_EXPIRED])
def test_other_issue_reverts_are_rejected_with_the_error_name(reason):
    fake = FakeChainClient()
    fake.fail_next("issue_budget", reason)
    outcome = issue_once(fake, issue_request(now_s()))
    assert (outcome.status, outcome.reason) == (REJECTED, reason.value)
    assert outcome.failed_tx_hash is None  # 시뮬레이션에서 걸렸다. 비울 칸이 없다


def test_relayer_failure_keeps_earlier_lines_and_the_next_line_still_goes():
    # 앞줄이 발행된 뒤 릴레이어가 멈춰도 예외로 끝나지 않는다. 앞줄의 hash 를 잃으면 안 된다
    fake, now = FakeChainClient(), now_s()
    first = issue_once(fake, issue_request(now))
    working = fake.issue_budget
    fake.issue_budget = raises(ChainSetupError("릴레이어 잔액 부족"))
    second = issue_once(fake, issue_request(now, budget_id=B + 1))
    fake.issue_budget = working
    third = issue_once(fake, issue_request(now, budget_id=B + 2))
    assert [o.status for o in (first, second, third)] == [ISSUED, NOT_SENT, ISSUED]
    assert "잔액 부족" in second.detail


def test_send_refused_after_the_claim_reports_the_hash_to_release():
    fake = FakeChainClient()
    fake.issue_budget = sends_then_raises(ChainSetupError("nonce too low"))
    outcome = issue_once(fake, issue_request(now_s()))
    assert (outcome.status, outcome.failed_tx_hash, outcome.tx_hash) == (NOT_SENT, SENT_HASH, None)


def test_malformed_signature_is_a_result_and_nothing_is_sent():
    fake = FakeChainClient()
    calls = counting(fake, "issue_budget")
    outcome = asyncio.run(relay_issue(fake, issue_request(now_s()), "0x1234"))
    assert (outcome.status, outcome.reason) == (REJECTED, MALFORMED_SIGNATURE)
    assert calls == []


def test_refused_before_broadcast_callback_sends_nothing():
    fake = FakeChainClient()

    async def refuse(_):
        raise RuntimeError("선점 실패")

    with pytest.raises(RuntimeError):
        issue_once(fake, issue_request(now_s()), before_broadcast=refuse)
    assert asyncio.run(fake.get_budget(B)) is None


# 증액


def test_increase_is_increased_with_the_new_version():
    fake, now = FakeChainClient(), now_s()
    issue_once(fake, issue_request(now))
    outcome = increase_once(fake, increase_request(now))
    assert (outcome.status, outcome.version) == (INCREASED, 2)
    assert asyncio.run(fake.get_budget(B)).issued == 1_500


def test_previous_hash_is_a_required_argument():
    # 빠뜨리면 이중 증액이 되는 인자라 기본값을 두지 않는다
    with pytest.raises(TypeError):
        asyncio.run(relay_increase(FakeChainClient(), increase_request(1000), REASON_TEXT, "0x", "0x"))


def test_landed_increase_is_not_applied_twice_after_the_deadline():
    # 응답을 잃은 증액이 사실은 들어갔는데 시한이 지났다. 컨트랙트는 시한을 먼저 봐서 SignatureExpired 를 낸다
    clock = Clock()
    fake = FakeChainClient(clock=clock)
    issue_once(fake, issue_request(clock.now))
    request = increase_request(clock.now)
    fake.unavailable_next("increase_budget", landed=True)
    working = fake.budget_tx_result
    fake.budget_tx_result = raises(ChainUnavailable("끊김"))
    first = increase_once(fake, request)
    assert first.status is NO_RESPONSE and first.tx_hash
    fake.budget_tx_result = working
    clock.now = request.deadline + 1

    # hash 없이 다시 보내면 재서명으로 가는 응답이 나온다. 이 경로를 막으려고 인자가 필수다
    assert increase_once(fake, request).reason == "SignatureExpired"

    calls = counting(fake, "increase_budget")
    outcome = increase_once(fake, request, previous_tx_hash=first.tx_hash)
    assert (outcome.status, outcome.version, outcome.tx_hash) == (INCREASED, 2, first.tx_hash)
    assert calls == []
    budget = asyncio.run(fake.get_budget(B))
    assert (budget.issued, budget.version) == (1_500, 2)


def test_previous_not_in_a_block_yet_blocks_a_second_send():
    fake, now = FakeChainClient(), now_s()
    issue_once(fake, issue_request(now))
    fake.unavailable_next("increase_budget", landed=False)
    first = increase_once(fake, increase_request(now))
    calls = counting(fake, "increase_budget")
    outcome = increase_once(fake, increase_request(now), previous_tx_hash=first.tx_hash)
    assert (outcome.status, outcome.tx_hash) == (NO_RESPONSE, first.tx_hash)
    assert calls == []


@pytest.mark.parametrize("error", [ChainUnavailable("끊김"), ChainSetupError("교체됨")], ids=["unavailable", "setup"])
def test_previous_that_cannot_be_checked_blocks_a_second_send(error):
    fake, now = FakeChainClient(), now_s()
    issue_once(fake, issue_request(now))
    fake.budget_tx_result = raises(error)
    calls = counting(fake, "increase_budget")
    outcome = increase_once(fake, increase_request(now), previous_tx_hash=SENT_HASH)
    assert (outcome.status, outcome.tx_hash) == (NO_RESPONSE, SENT_HASH)
    assert calls == []


def test_previous_that_failed_lets_this_request_go():
    fake, now = FakeChainClient(), now_s()
    issue_once(fake, issue_request(now))
    real_result = fake.budget_tx_result
    fake.budget_tx_result = raises(ChainRevert(RevertReason.UNKNOWN))
    outcome = increase_once(fake, increase_request(now), previous_tx_hash=SENT_HASH)
    assert (outcome.status, outcome.version) == (INCREASED, 2)
    assert outcome.tx_hash != SENT_HASH
    fake.budget_tx_result = real_result


@pytest.mark.parametrize(
    "fail, status",
    [("revert", REJECTED), ("setup", NOT_SENT), ("unavailable", NO_RESPONSE)],
)
def test_previous_that_failed_is_reported_for_release_when_this_try_sends_nothing(fail, status):
    fake, now = FakeChainClient(), now_s()
    issue_once(fake, issue_request(now))
    fake.budget_tx_result = raises(ChainRevert(RevertReason.UNKNOWN))
    if fail == "revert":
        fake.fail_next("increase_budget", E.VERSION_MISMATCH)
    elif fail == "setup":
        fake.increase_budget = raises(ChainSetupError("노드 없음"))
    else:
        fake.unavailable_next("increase_budget", sent=False)
    outcome = increase_once(fake, increase_request(now), previous_tx_hash=SENT_HASH)
    assert (outcome.status, outcome.failed_tx_hash, outcome.tx_hash) == (status, SENT_HASH, None)


def test_reverted_increase_after_the_claim_reports_the_hash_to_release():
    fake, now = FakeChainClient(), now_s()
    issue_once(fake, issue_request(now))
    fake.increase_budget = sends_then_raises(ChainRevert(E.VERSION_MISMATCH, "expected=2 actual=1"))
    outcome = increase_once(fake, increase_request(now))
    assert (outcome.status, outcome.reason, outcome.failed_tx_hash) == (REJECTED, "VersionMismatch", SENT_HASH)


def test_expired_increase_tells_the_caller_to_ask_for_a_new_signature():
    fake, now = FakeChainClient(), now_s()
    issue_once(fake, issue_request(now))
    outcome = increase_once(fake, increase_request(now, deadline=1))
    assert (outcome.status, outcome.reason) == (REJECTED, "SignatureExpired")
    assert asyncio.run(fake.get_budget(B)).version == 1


def test_stale_version_is_rejected_with_version_mismatch():
    fake, now = FakeChainClient(), now_s()
    issue_once(fake, issue_request(now))
    increase_once(fake, increase_request(now))
    outcome = increase_once(fake, increase_request(now))
    assert (outcome.status, outcome.reason) == (REJECTED, "VersionMismatch")


def test_increase_lost_response_that_landed_is_found_by_its_hash():
    fake, now = FakeChainClient(), now_s()
    issue_once(fake, issue_request(now))
    fake.unavailable_next("increase_budget", landed=True)
    outcome = increase_once(fake, increase_request(now))
    assert (outcome.status, outcome.version) == (INCREASED, 2)


def test_before_broadcast_gets_the_hash_that_is_returned():
    fake, now = FakeChainClient(), now_s()
    issue_once(fake, issue_request(now))
    claimed = []

    async def claim(tx_hash):
        claimed.append(tx_hash)

    outcome = increase_once(fake, increase_request(now), before_broadcast=claim)
    assert claimed == [outcome.tx_hash]


@pytest.mark.parametrize("reason", ["다른 사유", ""], ids=["other_text", "empty"])
def test_reason_that_does_not_match_the_signed_hash_is_refused_before_sending(reason):
    # 체인에는 서명된 해시, DB 에는 다른 원문이 영구히 남으면 학생 검증에서 위조로 보인다
    fake, now = FakeChainClient(), now_s()
    issue_once(fake, issue_request(now))
    calls = counting(fake, "increase_budget")
    outcome = increase_once(fake, increase_request(now), reason=reason)
    assert (outcome.status, outcome.reason) == (REJECTED, REASON_HASH_MISMATCH)
    assert calls == []


@pytest.mark.parametrize("bad", ["president", "auditor"])
def test_either_malformed_signature_is_refused_before_sending(bad):
    fake, now = FakeChainClient(), now_s()
    issue_once(fake, issue_request(now))
    calls = counting(fake, "increase_budget")
    president = "0x12" if bad == "president" else fake_signature(PRESIDENT)
    auditor = "0x12" if bad == "auditor" else fake_signature(AUDITOR)
    outcome = asyncio.run(relay_increase(fake, increase_request(now), REASON_TEXT, president, auditor, previous_tx_hash=None))
    assert (outcome.status, outcome.reason) == (REJECTED, MALFORMED_SIGNATURE)
    assert calls == []


# 실제 체인에서만 나는 응답. 가짜는 대기열도, 실패로 끝난 트랜잭션도 만들지 못한다


async def _connected(body):
    client = await Web3ChainClient.connect(RPC_URL, RELAYER_KEY, DEFAULT_PATH)
    try:
        now = await chain_now(client._w3)
        return await in_snapshot(client._w3, lambda: body(client, now))
    finally:
        await client.close()


def _signed_issue(request):
    return sign_as_app(request, DOMAIN, PRESIDENT_KEY)


def _signed_increase(request):
    return sign_as_app(request, DOMAIN, PRESIDENT_KEY), sign_as_app(request, DOMAIN, AUDITOR_KEY)


@pytest.mark.chain
def test_retry_while_the_first_issue_is_in_the_mempool_on_chain(node, monkeypatch):
    # 코드 리뷰에서 재현한 경우: 첫 트랜잭션이 대기열에 있으면 재시도가 BudgetAlreadyExists 로 걸리지만 조회에는 없다
    monkeypatch.setattr(web3_client, "RECEIPT_TIMEOUT_SECONDS", 1)

    async def body(client, now):
        provider = client._w3.provider
        await provider.make_request("evm_setAutomine", [False])
        try:
            request = issue_request(now)
            first = await relay_issue(client, request, _signed_issue(request))
            retry = await relay_issue(client, request, _signed_issue(request))
            await provider.make_request("evm_mine", [])
            settled = await relay_issue(client, request, _signed_issue(request))
            landed = await client.budget_tx_result(first.tx_hash, B)
            return first, retry, settled, landed
        finally:
            await provider.make_request("evm_setAutomine", [True])

    first, retry, settled, landed = asyncio.run(_connected(body))
    assert first.status is NO_RESPONSE and first.tx_hash
    assert retry.status is NO_RESPONSE
    assert settled.status is ALREADY and settled.existing.id == B
    assert landed.version == 1


@pytest.mark.chain
def test_budget_tx_result_of_a_transaction_that_failed_on_chain(node):
    async def body(client, now):
        w3 = client._w3
        request = issue_request(now, deadline=1)
        call = client._budget_token.functions.issue(
            typed_data_for(request, DOMAIN)["message"], bytes.fromhex(_signed_issue(request)[2:])
        )
        relayer = Account.from_key(RELAYER_KEY)
        tx = await call.build_transaction(
            {"from": relayer.address, "gas": 300_000, "nonce": await w3.eth.get_transaction_count(relayer.address)}
        )
        signed = relayer.sign_transaction(tx)
        try:
            await w3.eth.send_raw_transaction(signed.raw_transaction)
        except Exception:
            pass  # Hardhat 은 revert 하는 트랜잭션도 블록에 넣고 에러를 돌려준다
        await client.budget_tx_result("0x" + bytes(signed.hash).hex(), B)

    with pytest.raises(ChainRevert) as e:
        asyncio.run(_connected(body))
    assert e.value.reason is RevertReason.UNKNOWN


@pytest.mark.chain
def test_budget_tx_result_of_an_unknown_hash_and_another_budget_on_chain(node):
    async def body(client, now):
        unknown = await client.budget_tx_result(SENT_HASH, B)
        request = issue_request(now)
        issued = await client.issue_budget(request, _signed_issue(request))
        try:
            await client.budget_tx_result(issued.tx_hash, B + 1)
        except ChainUnavailable:
            return unknown, True
        return unknown, False

    unknown, other_budget_refused = asyncio.run(_connected(body))
    assert unknown is None
    assert other_budget_refused


@pytest.mark.chain
def test_landed_increase_is_not_applied_twice_after_the_deadline_on_chain(node):
    async def body(client, now):
        issue = issue_request(now)
        await client.issue_budget(issue, _signed_issue(issue))
        request = increase_request(now)
        president, auditor = _signed_increase(request)
        first = await relay_increase(client, request, REASON_TEXT, president, auditor, previous_tx_hash=None)
        await client._w3.provider.make_request("evm_increaseTime", [601])
        await client._w3.provider.make_request("evm_mine", [])
        without_hash = await relay_increase(client, request, REASON_TEXT, president, auditor, previous_tx_hash=None)
        with_hash = await relay_increase(client, request, REASON_TEXT, president, auditor, previous_tx_hash=first.tx_hash)
        return first, without_hash, with_hash, await client.get_budget(B)

    first, without_hash, with_hash, budget = asyncio.run(_connected(body))
    assert first.status is INCREASED
    assert without_hash.reason == "SignatureExpired"
    assert (with_hash.status, with_hash.version, with_hash.tx_hash) == (INCREASED, 2, first.tx_hash)
    assert (budget.issued, budget.version) == (1_500, 2)


@pytest.mark.chain
def test_same_term_and_category_under_another_id_on_chain(node):
    async def body(client, now):
        first = issue_request(now)
        await client.issue_budget(first, _signed_issue(first))
        other = issue_request(now, budget_id=B + 1, category=category(B))
        return await relay_issue(client, other, _signed_issue(other))

    outcome = asyncio.run(_connected(body))
    assert outcome.status is ALREADY
    assert outcome.existing.id == B
