import asyncio
from types import SimpleNamespace

import pytest

from app.chain import ChainUnavailable, ConfirmApproval, FakeChainClient, RecordRequest, RevertReason, fake_recover_signer, fake_signature
from app.chain.models import ZERO_BYTES32
from app.relay import (
    DECIDED_ELSEWHERE,
    NOT_RECORDED_BY_DEADLINE,
    NOT_SENT,
    DecisionKind,
    DecisionRelay,
    DecisionStatus,
    InMemoryDecisionStore,
    RelayError,
    RelayErrorCode,
)
from app.schemas.entry import EntryKind, EntryStatus

NOW = 1_790_000_000
DAY = NOW // 86400 * 86400 + 54000
HASH = "0x" + "ab" * 32
REASON = "0x" + "cd" * 32
TREASURER = "0x1111111111111111111111111111111111111111"
AUDITOR = "0x2222222222222222222222222222222222222222"
PRESIDENT = "0x3333333333333333333333333333333333333333"
AUDITOR_ID, PRESIDENT_ID = 3, 4


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
    store = InMemoryDecisionStore()
    relay = DecisionRelay(chain, store, fake_recover_signer, clock=clock)
    request = RecordRequest(id=1, hash=HASH, amount=1000, kind=EntryKind.EXPENSE, occurred_at=DAY, budget_id=2, deadline=NOW + 60)
    run(chain.record_pending(request, fake_signature(TREASURER)))

    sent = []
    for name in ("confirm_entry", "reject_entry"):
        original = getattr(chain, name)

        async def counting(struct, signature, _original=original, _name=name):
            sent.append((_name, struct.id))
            return await _original(struct, signature)

        setattr(chain, name, counting)
    return SimpleNamespace(clock=clock, chain=chain, store=store, relay=relay, sent=sent)


def confirm(env, signer=AUDITOR, entry_id=1, **overrides):
    values = dict(
        decided_by=AUDITOR_ID, approver=AUDITOR, meta_hash=HASH, had_warning=False, warning_reason_hash=ZERO_BYTES32,
        deadline=int(env.clock.now) + 300, signature=fake_signature(signer),
    )
    return env.relay.confirm(entry_id, **{**values, **overrides})


def reject(env, signer=AUDITOR, entry_id=1, **overrides):
    values = dict(decided_by=AUDITOR_ID, approver=AUDITOR, reason_hash=REASON, deadline=int(env.clock.now) + 300,
                  signature=fake_signature(signer))
    return env.relay.reject(entry_id, **{**values, **overrides})


def expect_error(code, coro):
    with pytest.raises(RelayError) as e:
        run(coro)
    assert e.value.code == code


# ---------------------------------------------------------------- 정상 흐름


def test_confirm_records_decision(env):
    done = run(confirm(env))
    assert (done.kind, done.status) == (DecisionKind.CONFIRM, DecisionStatus.RECORDED)
    assert done.tx_hash == run(env.chain.get_decision_result(1)).tx_hash
    assert env.store.entry_updates[1] == done
    assert run(env.chain.get_entry(1)).status == EntryStatus.CONFIRMED


def test_confirm_with_warning_reason(env):
    done = run(confirm(env, had_warning=True, warning_reason_hash=REASON))
    assert done.status == DecisionStatus.RECORDED


def test_reject_records_decision(env):
    done = run(reject(env, approver=PRESIDENT, decided_by=PRESIDENT_ID, signer=PRESIDENT))
    assert (done.kind, done.status) == (DecisionKind.REJECT, DecisionStatus.RECORDED)
    assert run(env.chain.get_entry(1)).status == EntryStatus.REJECTED


# ---------------------------------------------------------------- 보내기 전에 막는 것


@pytest.mark.parametrize(
    "call, code",
    [
        (lambda env: confirm(env, entry_id=99), RelayErrorCode.ENTRY_NOT_FOUND),
        (lambda env: confirm(env, approver=TREASURER, signer=TREASURER), RelayErrorCode.SELF_APPROVAL),
        (lambda env: confirm(env, meta_hash="0x" + "99" * 32), RelayErrorCode.HASH_MISMATCH),
        (lambda env: confirm(env, had_warning=True), RelayErrorCode.INVALID_REASON),
        (lambda env: confirm(env, warning_reason_hash=REASON), RelayErrorCode.INVALID_REASON),
        (lambda env: reject(env, reason_hash=ZERO_BYTES32), RelayErrorCode.INVALID_REASON),
        (lambda env: confirm(env, deadline=NOW - 1), RelayErrorCode.INVALID_DEADLINE),
        (lambda env: confirm(env, signer=PRESIDENT), RelayErrorCode.SIGNER_MISMATCH),
        (lambda env: confirm(env, signature="0x1234"), RelayErrorCode.INVALID_SIGNATURE),
        (lambda env: confirm(env, approver="0x1234"), RelayErrorCode.INVALID_DECISION),
        (lambda env: reject(env, reason_hash="0xABCD"), RelayErrorCode.INVALID_DECISION),
    ],
)
def test_rejected_before_chain(env, call, code):
    expect_error(code, call(env))
    assert env.sent == []
    assert run(env.store.get_active(1)) is None


def test_entry_not_pending_on_chain(env):
    approval = ConfirmApproval(id=1, hash=HASH, deadline=NOW + 60)
    run(env.chain.confirm_entry(approval, fake_signature(PRESIDENT)))
    env.sent.clear()
    expect_error(RelayErrorCode.ENTRY_NOT_PENDING, reject(env))
    assert env.sent == []


def test_chain_read_failure_before_sending_stores_nothing(env):
    env.chain.unavailable_next("get_entry")
    with pytest.raises(ChainUnavailable):
        run(confirm(env))
    assert run(env.store.get_active(1)) is None


# ---------------------------------------------------------------- 한 항목에 결정 하나


def test_same_decision_again_is_not_resent(env):
    first = run(confirm(env))
    again = run(confirm(env))
    assert again == first
    assert env.sent == [("confirm_entry", 1)]


def test_opposite_decision_after_recorded(env):
    run(confirm(env))
    expect_error(RelayErrorCode.ALREADY_DECIDED, reject(env))


def test_concurrent_confirm_and_reject_send_once(env):
    async def both():
        return await asyncio.gather(confirm(env), reject(env), return_exceptions=True)

    results = run(both())
    assert len(env.sent) == 1
    [error] = [r for r in results if isinstance(r, RelayError)]
    # 먼저 들어간 쪽이 이미 끝났으면 ALREADY_DECIDED, 아직 보내는 중이면 DECISION_IN_PROGRESS
    assert error.code in (RelayErrorCode.ALREADY_DECIDED, RelayErrorCode.DECISION_IN_PROGRESS)


# ---------------------------------------------------------------- 실패와 대조


def test_insufficient_budget_fails_then_reject_goes_through(env):
    env.chain.fail_next("confirm_entry", RevertReason.INSUFFICIENT_BUDGET)
    failed = run(confirm(env))
    assert (failed.status, failed.fail_reason) == (DecisionStatus.FAILED, "InsufficientBudget")
    assert run(env.store.get_active(1)) is None

    done = run(reject(env))
    assert (done.kind, done.status) == (DecisionKind.REJECT, DecisionStatus.RECORDED)


def test_unsent_decision_blocks_opposite_until_deadline(env):
    env.chain.unavailable_next("confirm_entry", landed=False)
    pending = run(confirm(env))
    assert pending.status == DecisionStatus.SUBMITTING
    expect_error(RelayErrorCode.DECISION_IN_PROGRESS, reject(env))

    env.clock.now = pending.deadline + 120
    assert run(env.relay.reconcile()) == []
    env.clock.now = pending.deadline + 121
    [failed] = run(env.relay.reconcile())
    assert failed.fail_reason == NOT_RECORDED_BY_DEADLINE

    assert run(reject(env)).status == DecisionStatus.RECORDED


def test_landed_decision_is_recorded_by_reconcile(env):
    env.chain.unavailable_next("reject_entry", landed=True)
    assert run(reject(env)).status == DecisionStatus.SUBMITTING

    env.chain.unavailable_next("get_entry")
    assert run(env.relay.reconcile()) == []

    [done] = run(env.relay.reconcile())
    assert (done.status, done.tx_hash) == (DecisionStatus.RECORDED, run(env.chain.get_decision_result(1)).tx_hash)
    assert 1 in env.store.entry_updates


def test_decided_elsewhere_while_submitting(env):
    env.chain.unavailable_next("confirm_entry", landed=False)
    run(confirm(env))
    approval = ConfirmApproval(id=1, hash=HASH, deadline=NOW + 60)
    run(FakeChainClient.confirm_entry(env.chain, approval, fake_signature(PRESIDENT)))  # 다른 경로로 회장이 확정

    [failed] = run(env.relay.reconcile())
    assert failed.fail_reason == DECIDED_ELSEWHERE
    assert env.store.entry_updates == {}


@pytest.mark.parametrize("other_signer, expected", [(AUDITOR, DecisionStatus.RECORDED), (PRESIDENT, DecisionStatus.FAILED)])
def test_invalid_status_on_send_is_settled_from_chain(env, other_signer, expected):
    """보내기 직전 확인을 통과한 뒤 체인에서 먼저 결정이 난 경우."""
    original = FakeChainClient.confirm_entry

    async def racing(struct, signature):
        await original(env.chain, struct, fake_signature(other_signer))
        return await original(env.chain, struct, signature)

    env.chain.confirm_entry = racing
    done = run(confirm(env))
    assert done.status == expected
    if expected == DecisionStatus.FAILED:
        assert done.fail_reason == DECIDED_ELSEWHERE


# ---------------------------------------------------------------- 롤 조회를 붙였을 때


def test_approver_role_is_checked_before_chain(env):
    from app.chain import Role

    relay = DecisionRelay(env.chain, env.store, fake_recover_signer, clock=env.clock, roles=env.chain)
    env.chain.grant_role(Role.TREASURER, AUDITOR)  # 임원이지만 승인 롤은 아니다
    expect_error(RelayErrorCode.ROLE_MISSING, relay.confirm(
        1, decided_by=AUDITOR_ID, approver=AUDITOR, meta_hash=HASH, had_warning=False,
        warning_reason_hash=ZERO_BYTES32, deadline=NOW + 300, signature=fake_signature(AUDITOR),
    ))
    assert env.sent == []

    env.chain.grant_role(Role.PRESIDENT, PRESIDENT)  # 회장도 승인할 수 있다
    done = run(relay.reject(1, decided_by=PRESIDENT_ID, approver=PRESIDENT, reason_hash=REASON, deadline=NOW + 300,
                            signature=fake_signature(PRESIDENT)))
    assert done.status == DecisionStatus.RECORDED


# ---------------------------------------------------------------- 리뷰 반영


def test_not_sent_decision_fails_immediately_and_unblocks(env):
    env.chain.not_sent_next("confirm_entry")
    failed = run(confirm(env))
    assert (failed.status, failed.fail_reason) == (DecisionStatus.FAILED, NOT_SENT)
    assert run(reject(env)).status == DecisionStatus.RECORDED  # 반대 결정이 시한까지 막히지 않는다


def test_other_approver_does_not_get_someone_elses_decision(env):
    env.chain.unavailable_next("confirm_entry")
    auditor_decision = run(confirm(env))
    assert auditor_decision.status == DecisionStatus.SUBMITTING

    expect_error(RelayErrorCode.DECISION_IN_PROGRESS, confirm(env, approver=PRESIDENT, decided_by=PRESIDENT_ID, signer=PRESIDENT))
    expect_error(RelayErrorCode.INVALID_SIGNATURE, confirm(env, approver=PRESIDENT, decided_by=PRESIDENT_ID, signature="0x1234"))
    expect_error(RelayErrorCode.SIGNER_MISMATCH, confirm(env, signer=PRESIDENT))  # 감사 이름으로 회장이 서명
    expect_error(RelayErrorCode.DECISION_IN_PROGRESS, confirm(env, had_warning=True, warning_reason_hash=REASON))  # 같은 감사, 다른 내용

    again = run(confirm(env))  # 같은 감사가 같은 내용으로 다시 — 이미 있는 결정을 돌려준다
    assert again == auditor_decision
    assert env.sent == [("confirm_entry", 1)]


def test_recorded_decision_rejects_other_approver(env):
    run(confirm(env))
    expect_error(RelayErrorCode.ALREADY_DECIDED, confirm(env, approver=PRESIDENT, decided_by=PRESIDENT_ID, signer=PRESIDENT))
