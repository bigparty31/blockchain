import asyncio
from functools import partial
from types import SimpleNamespace

import pytest
from eth_account import Account
from eth_account.messages import encode_typed_data

from app.chain import (
    BlockReason,
    Eip712Domain,
    FakeChainClient,
    RecordRequest,
    RevertReason,
    fake_recover_signer,
    fake_signature,
    recover_signer,
    typed_data,
)
from app.relay import (
    ENTRY_ID_TAKEN,
    NOT_RECORDED_BY_DEADLINE,
    NOT_SENT,
    DraftStatus,
    InMemoryDraftStore,
    RegistrationRelay,
    RelayError,
    RelayErrorCode,
)
from app.schemas.entry import EntryKind, EntryStatus

NOW = 1_790_000_000
DAY = NOW // 86400 * 86400 + 54000  # KST 자정
HASH = "0x" + "ab" * 32
TREASURER_ID = 2
TREASURER = "0x1111111111111111111111111111111111111111"
OTHER = "0x9999999999999999999999999999999999999999"


class Clock:
    def __init__(self, now):
        self.now = now

    def __call__(self):
        return self.now


def run(coro):
    return asyncio.run(coro)


@pytest.fixture
def env():
    clock = Clock(NOW)
    chain = FakeChainClient(clock=clock)
    store = InMemoryDraftStore()
    relay = RegistrationRelay(chain, store, fake_recover_signer, clock=clock)

    sent = []
    record_pending = chain.record_pending

    async def counting(request, signature):
        sent.append(request.id)
        return await record_pending(request, signature)

    chain.record_pending = counting
    return SimpleNamespace(clock=clock, chain=chain, store=store, relay=relay, sent=sent)


def open_draft(env, **fields):
    values = dict(
        created_by=TREASURER_ID, registrant=TREASURER, meta_hash=HASH,
        amount=1000, kind=EntryKind.EXPENSE, occurred_at=DAY, budget_id=2,
    )
    return run(env.relay.open_draft(**{**values, **fields}))


def submit(env, draft, signer=TREASURER, **overrides):
    values = dict(meta_hash=draft.hash, deadline=int(env.clock.now) + 300, signature=fake_signature(signer))
    return run(env.relay.submit(draft.id, **{**values, **overrides}))


def expect_error(code, coro):
    with pytest.raises(RelayError) as e:
        run(coro)
    assert e.value.code == code


# ---------------------------------------------------------------- 정상 흐름


def test_submit_records_entry(env):
    draft = open_draft(env)
    assert (draft.id, draft.status) == (1, DraftStatus.DRAFT)

    done = submit(env, draft)
    assert (done.status, done.entry_status) == (DraftStatus.RECORDED, EntryStatus.PENDING)
    assert done.tx_hash == run(env.chain.get_record_result(1)).tx_hash
    assert env.store.entries[1].tx_hash == done.tx_hash
    assert run(env.chain.get_entry(1)).registrant.lower() == TREASURER


def test_blocked_expense_is_recorded_as_blocked(env):
    env.chain.block_next(BlockReason.BUDGET_EXCEEDED)
    done = submit(env, open_draft(env))
    assert (done.status, done.entry_status, done.block_reason) == (
        DraftStatus.RECORDED, EntryStatus.BLOCKED, BlockReason.BUDGET_EXCEEDED,
    )
    assert 1 in env.store.entries


def test_income_draft_takes_no_budget(env):
    done = submit(env, open_draft(env, kind=EntryKind.INCOME, budget_id=None))
    assert done.entry_status == EntryStatus.PENDING
    assert run(env.chain.get_entry(1)).budget_id == 0


def test_real_eip712_signature(env):
    domain = Eip712Domain(chain_id=31337, verifying_contract="0x" + "33" * 20)
    account = Account.create()
    relay = RegistrationRelay(env.chain, env.store, partial(recover_signer, domain), clock=env.clock)
    draft = run(relay.open_draft(
        created_by=TREASURER_ID, registrant=account.address, meta_hash=HASH,
        amount=1000, kind=EntryKind.EXPENSE, occurred_at=DAY, budget_id=2,
    ))
    deadline = NOW + 300

    def sign(request: RecordRequest) -> str:
        message = encode_typed_data(full_message=typed_data(domain, request))
        return Account.sign_message(message, account.key).signature.to_0x_hex()

    wrong = sign(draft.record_request(deadline).model_copy(update={"budget_id": 7}))
    expect_error(RelayErrorCode.SIGNER_MISMATCH, relay.submit(draft.id, meta_hash=HASH, deadline=deadline, signature=wrong))
    assert env.sent == []

    right = sign(draft.record_request(deadline))
    done = run(relay.submit(draft.id, meta_hash=HASH, deadline=deadline, signature=right))
    assert done.status == DraftStatus.RECORDED


# ---------------------------------------------------------------- 체인에 보내기 전에 막는 것


@pytest.mark.parametrize(
    "fields",
    [
        {"amount": 0},
        {"amount": -1000},
        {"budget_id": None},
        {"kind": EntryKind.INCOME, "budget_id": 2},
        {"meta_hash": "0x" + "AB" * 32},
        {"occurred_at": DAY + 3600},
        {"registrant": "0x1234"},
    ],
)
def test_invalid_draft_is_rejected_before_reserving_id(env, fields):
    expect_error(RelayErrorCode.INVALID_DRAFT, env.relay.open_draft(**{
        **dict(created_by=TREASURER_ID, registrant=TREASURER, meta_hash=HASH, amount=1000,
               kind=EntryKind.EXPENSE, occurred_at=DAY, budget_id=2),
        **fields,
    }))
    assert open_draft(env).id == 1


def test_negative_amount_is_allowed_for_correction(env):
    assert open_draft(env, amount=-1000, corrects_id=5).corrects_id == 5


@pytest.mark.parametrize(
    "overrides, code",
    [
        ({"meta_hash": "0x" + "cd" * 32}, RelayErrorCode.HASH_MISMATCH),
        ({"deadline": NOW}, RelayErrorCode.INVALID_DEADLINE),
        ({"deadline": NOW + 601}, RelayErrorCode.INVALID_DEADLINE),
        ({"signature": "0x1234"}, RelayErrorCode.INVALID_SIGNATURE),
        ({"signer": OTHER}, RelayErrorCode.SIGNER_MISMATCH),
    ],
)
def test_bad_submission_is_rejected_before_chain(env, overrides, code):
    draft = open_draft(env)
    with pytest.raises(RelayError) as e:
        submit(env, draft, **overrides)
    assert e.value.code == code
    assert run(env.store.get(draft.id)).status == DraftStatus.DRAFT
    assert env.sent == []


# ---------------------------------------------------------------- 다시 보내지 않는다


def test_resubmit_after_recorded_does_not_resend(env):
    draft = open_draft(env)
    first = submit(env, draft)
    again = submit(env, draft)
    assert again == first
    assert env.sent == [1]


def test_concurrent_submits_send_once(env):
    draft = open_draft(env)

    async def both():
        return await asyncio.gather(
            env.relay.submit(draft.id, meta_hash=HASH, deadline=NOW + 300, signature=fake_signature(TREASURER)),
            env.relay.submit(draft.id, meta_hash=HASH, deadline=NOW + 300, signature=fake_signature(TREASURER)),
        )

    run(both())
    assert env.sent == [1]
    assert run(env.store.get(1)).status == DraftStatus.RECORDED


# ---------------------------------------------------------------- 실패와 대조


def test_revert_fails_draft_and_it_can_be_signed_again(env):
    draft = open_draft(env)
    env.chain.fail_next("record_pending", RevertReason.NOT_REGISTRANT)

    failed = submit(env, draft)
    assert (failed.status, failed.fail_reason) == (DraftStatus.FAILED, "NotRegistrant")
    assert [d.id for d in run(env.relay.open_drafts(TREASURER_ID))] == [1]

    assert submit(env, draft).status == DraftStatus.RECORDED
    assert run(env.relay.open_drafts(TREASURER_ID)) == []


def test_unsent_submission_fails_only_after_deadline(env):
    draft = open_draft(env)
    env.chain.unavailable_next("record_pending", landed=False)

    pending = submit(env, draft)
    assert pending.status == DraftStatus.SUBMITTING
    assert submit(env, draft).status == DraftStatus.SUBMITTING
    assert env.sent == [1]

    env.clock.now = pending.deadline + 120  # 여유 시간 경계. 아직 판단하지 않는다
    assert run(env.relay.reconcile()) == []

    env.clock.now = pending.deadline + 121
    [failed] = run(env.relay.reconcile())
    assert (failed.status, failed.fail_reason) == (DraftStatus.FAILED, NOT_RECORDED_BY_DEADLINE)

    assert submit(env, draft).status == DraftStatus.RECORDED


def test_landed_submission_is_recorded_by_reconcile(env):
    draft = open_draft(env)
    env.chain.block_next(BlockReason.BUDGET_EXPIRED)
    env.chain.unavailable_next("record_pending", landed=True)
    assert submit(env, draft).status == DraftStatus.SUBMITTING

    [done] = run(env.relay.reconcile())
    assert (done.status, done.entry_status, done.block_reason) == (
        DraftStatus.RECORDED, EntryStatus.BLOCKED, BlockReason.BUDGET_EXPIRED,
    )
    assert done.tx_hash == run(env.chain.get_record_result(1)).tx_hash
    assert run(env.relay.reconcile()) == []


def test_reconcile_skips_when_chain_read_fails(env):
    draft = open_draft(env)
    env.chain.unavailable_next("record_pending", landed=True)
    submit(env, draft)

    env.chain.unavailable_next("get_entry")
    assert run(env.relay.reconcile()) == []
    assert run(env.store.get(1)).status == DraftStatus.SUBMITTING

    [done] = run(env.relay.reconcile())
    assert done.status == DraftStatus.RECORDED


def test_id_taken_by_other_content_on_submit(env):
    foreign = RecordRequest(id=1, hash="0x" + "99" * 32, amount=5, kind=EntryKind.INCOME, occurred_at=DAY, deadline=NOW + 60)
    run(env.chain.record_pending(foreign, fake_signature(OTHER)))

    failed = submit(env, open_draft(env))
    assert (failed.status, failed.fail_reason) == (DraftStatus.FAILED, ENTRY_ID_TAKEN)
    assert env.store.entries == {}


def test_id_taken_by_other_content_on_reconcile(env):
    draft = open_draft(env)
    env.chain.unavailable_next("record_pending", landed=False)
    submit(env, draft)

    foreign = RecordRequest(id=1, hash="0x" + "99" * 32, amount=5, kind=EntryKind.INCOME, occurred_at=DAY, deadline=NOW + 60)
    run(env.chain.record_pending(foreign, fake_signature(OTHER)))

    [failed] = run(env.relay.reconcile())
    assert failed.fail_reason == ENTRY_ID_TAKEN
    assert env.store.entries == {}


# ---------------------------------------------------------------- 버리기


def test_discard(env):
    draft = open_draft(env)
    expect_error(RelayErrorCode.NOT_OWNER, env.relay.discard(draft.id, by_user=TREASURER_ID + 1))

    assert run(env.relay.discard(draft.id, by_user=TREASURER_ID)).status == DraftStatus.DISCARDED
    expect_error(RelayErrorCode.DRAFT_DISCARDED, env.relay.submit(
        draft.id, meta_hash=HASH, deadline=NOW + 300, signature=fake_signature(TREASURER)
    ))
    assert run(env.relay.open_drafts(TREASURER_ID)) == []


def test_submitting_draft_cannot_be_discarded(env):
    draft = open_draft(env)
    env.chain.unavailable_next("record_pending")
    submit(env, draft)
    expect_error(RelayErrorCode.CANNOT_DISCARD, env.relay.discard(draft.id, by_user=TREASURER_ID))


def test_unknown_draft(env):
    expect_error(RelayErrorCode.DRAFT_NOT_FOUND, env.relay.submit(
        99, meta_hash=HASH, deadline=NOW + 300, signature=fake_signature(TREASURER)
    ))


# ---------------------------------------------------------------- 롤 조회를 붙였을 때


def test_role_missing_is_rejected_before_chain(env):
    from app.chain import Role

    relay = RegistrationRelay(env.chain, env.store, fake_recover_signer, clock=env.clock, roles=env.chain)
    draft = run(relay.open_draft(
        created_by=TREASURER_ID, registrant=TREASURER, meta_hash=HASH, amount=1000, kind=EntryKind.EXPENSE,
        occurred_at=DAY, budget_id=2,
    ))
    submit_args = dict(meta_hash=HASH, deadline=NOW + 300)

    expect_error(RelayErrorCode.ROLE_MISSING, relay.submit(draft.id, signature=fake_signature(TREASURER), **submit_args))
    assert env.sent == []
    assert run(env.store.get(draft.id)).status == DraftStatus.DRAFT

    env.chain.grant_role(Role.TREASURER, TREASURER)
    assert run(relay.submit(draft.id, signature=fake_signature(TREASURER), **submit_args)).status == DraftStatus.RECORDED


# ---------------------------------------------------------------- 리뷰 반영


def test_not_sent_fails_immediately_and_can_be_resubmitted(env):
    draft = open_draft(env)
    env.chain.not_sent_next("record_pending")
    failed = submit(env, draft)
    assert (failed.status, failed.fail_reason) == (DraftStatus.FAILED, NOT_SENT)  # 시한까지 SUBMITTING 으로 묶이지 않는다
    assert submit(env, draft).status == DraftStatus.RECORDED


def test_stale_reconcile_does_not_fail_a_resubmitted_draft(env):
    """대조 워커가 읽어 둔 옛 제출로 판단하는 사이 초안이 실패·재제출된 경우."""
    draft = open_draft(env)
    env.chain.unavailable_next("record_pending")
    first = submit(env, draft)
    stale = run(env.store.list_submitting())  # 워커 B 가 읽어 둔 목록

    env.clock.now = first.deadline + 121
    [failed] = run(env.relay.reconcile())  # 워커 A 가 먼저 실패 처리
    assert failed.fail_reason == NOT_RECORDED_BY_DEADLINE

    env.chain.unavailable_next("record_pending")
    second = submit(env, draft)  # 새 서명으로 다시 제출. 아직 결과 모름
    assert second.status == DraftStatus.SUBMITTING

    async def stale_list():
        return stale

    env.store.list_submitting = stale_list
    env.clock.now = first.deadline + 200  # 옛 시한은 지났지만 새 시한은 아직이다
    assert run(env.relay.reconcile()) == []
    assert run(env.store.get(draft.id)).status == DraftStatus.SUBMITTING
