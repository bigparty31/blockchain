import asyncio

import pytest

from app.chain import (
    AnswerRequest,
    BlockReason,
    ChainRevert,
    ChainUnavailable,
    ConfirmApproval,
    FakeChainClient,
    ObjectionStatus,
    RecordRequest,
    RejectDecision,
    RevertReason,
    Role,
    fake_signature,
)
from app.schemas.entry import EntryKind, EntryStatus

NOW = 1_790_000_000
DAY = NOW // 86400 * 86400 + 54000  # KST 자정
HASH = "0x" + "ab" * 32
TREASURER = "0x1111111111111111111111111111111111111111"
AUDITOR = "0x2222222222222222222222222222222222222222"
STUDENT = "0x9999999999999999999999999999999999999999"


def run(coro):
    return asyncio.run(coro)


def record(entry_id, **fields):
    values = dict(id=entry_id, hash=HASH, amount=1000, kind=EntryKind.EXPENSE, occurred_at=DAY, budget_id=2, deadline=NOW + 60)
    return RecordRequest(**{**values, **fields})


def confirm(entry_id):
    return ConfirmApproval(id=entry_id, hash=HASH, deadline=NOW + 60)


def expect_revert(coro, reason):
    with pytest.raises(ChainRevert) as e:
        run(coro)
    assert e.value.reason == reason


@pytest.fixture
def chain():
    return FakeChainClient(clock=lambda: NOW)


def test_expense_without_budget_is_blocked_and_keeps_block_next(chain):
    chain.block_next(BlockReason.BUDGET_EXCEEDED)

    r = run(chain.record_pending(record(1, budget_id=0), fake_signature(TREASURER)))
    assert (r.status, r.block_reason) == (EntryStatus.BLOCKED, BlockReason.BUDGET_NOT_FOUND)

    r = run(chain.record_pending(record(2), fake_signature(TREASURER)))
    assert (r.status, r.block_reason) == (EntryStatus.BLOCKED, BlockReason.BUDGET_EXCEEDED)

    r = run(chain.record_pending(record(3, kind=EntryKind.INCOME, budget_id=0), fake_signature(TREASURER)))
    assert r.status == EntryStatus.PENDING


def test_signatures_from_same_address_are_same_person(chain):
    first, second = fake_signature(TREASURER), fake_signature(TREASURER)
    assert first != second

    run(chain.record_pending(record(1), first))
    expect_revert(chain.confirm_entry(confirm(1), second), RevertReason.SELF_APPROVAL)
    assert run(chain.confirm_entry(confirm(1), fake_signature(AUDITOR))).status == EntryStatus.CONFIRMED


def test_addresses_are_checksummed(chain):
    mixed = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
    run(chain.record_pending(record(1), fake_signature(mixed)))

    entry = run(chain.get_entry(1))
    assert entry.registrant.lower() == mixed
    assert entry.registrant != mixed
    assert entry.approver == "0x" + "0" * 40


@pytest.mark.parametrize("method", ["confirmEntry", "record"])
def test_scenarios_reject_unknown_method(chain, method):
    with pytest.raises(ValueError):
        chain.fail_next(method, RevertReason.INSUFFICIENT_BUDGET)
    with pytest.raises(ValueError):
        chain.unavailable_next(method)


def test_fail_next_is_for_write_methods_only(chain):
    with pytest.raises(ValueError):
        chain.fail_next("get_entry", RevertReason.INSUFFICIENT_BUDGET)


@pytest.mark.parametrize("method", ["get_entry", "get_record_result", "get_decision_result"])
def test_unavailable_read_applies_once(chain, method):
    run(chain.record_pending(record(1), fake_signature(TREASURER)))
    chain.unavailable_next(method)
    with pytest.raises(ChainUnavailable):
        run(getattr(chain, method)(1))
    run(getattr(chain, method)(1))


def test_decision_result(chain):
    run(chain.record_pending(record(1), fake_signature(TREASURER)))
    assert run(chain.get_decision_result(1)) is None
    done = run(chain.confirm_entry(confirm(1), fake_signature(AUDITOR)))
    assert run(chain.get_decision_result(1)) == done


def test_unavailable_not_landed_leaves_state(chain):
    chain.unavailable_next("record_pending")
    with pytest.raises(ChainUnavailable):
        run(chain.record_pending(record(1), fake_signature(TREASURER)))
    assert run(chain.get_entry(1)) is None

    assert run(chain.record_pending(record(1), fake_signature(TREASURER))).status == EntryStatus.PENDING


def test_unavailable_landed_applies_then_raises(chain):
    chain.unavailable_next("record_pending", landed=True)
    with pytest.raises(ChainUnavailable):
        run(chain.record_pending(record(1), fake_signature(TREASURER)))
    assert run(chain.get_entry(1)).status == EntryStatus.PENDING
    assert run(chain.get_record_result(1)).status == EntryStatus.PENDING
    expect_revert(chain.record_pending(record(1), fake_signature(TREASURER)), RevertReason.ENTRY_ALREADY_EXISTS)

    chain.unavailable_next("confirm_entry", landed=True)
    with pytest.raises(ChainUnavailable):
        run(chain.confirm_entry(confirm(1), fake_signature(AUDITOR)))
    assert run(chain.get_entry(1)).status == EntryStatus.CONFIRMED
    expect_revert(chain.confirm_entry(confirm(1), fake_signature(AUDITOR)), RevertReason.INVALID_STATUS)


def test_unavailable_landed_but_reverted_leaves_state(chain):
    chain.unavailable_next("record_pending", landed=True)
    with pytest.raises(ChainUnavailable):
        run(chain.record_pending(record(1, amount=0), fake_signature(TREASURER)))
    assert run(chain.get_entry(1)) is None


def test_fail_next_applies_once(chain):
    chain.fail_next("record_pending", RevertReason.NOT_REGISTRANT)
    expect_revert(chain.record_pending(record(1), fake_signature(TREASURER)), RevertReason.NOT_REGISTRANT)
    assert run(chain.get_entry(1)) is None
    assert run(chain.record_pending(record(1), fake_signature(TREASURER))).status == EntryStatus.PENDING


def test_signature_case_and_format(chain):
    upper = "0x" + fake_signature(TREASURER)[2:].upper()
    run(chain.record_pending(record(1), upper))
    assert run(chain.get_entry(1)).registrant.lower() == TREASURER

    with pytest.raises(ValueError):
        run(chain.record_pending(record(2), "0x" + "g" * 130))


def test_negative_occurred_at_is_rejected():
    with pytest.raises(ValueError):
        record(1, occurred_at=-32400)  # -32400 % 86400 == 54000 이라 자정 검사만으로는 통과한다


def test_deadline_is_judged_by_clock():
    late = FakeChainClient(clock=lambda: NOW + 3600)
    expect_revert(late.record_pending(record(1), fake_signature(TREASURER)), RevertReason.SIGNATURE_EXPIRED)


# ---------------------------------------------------------------- 롤


def test_roles_are_not_checked_unless_enforced(chain):
    assert run(chain.record_pending(record(1), fake_signature(TREASURER))).status == EntryStatus.PENDING


def test_enforced_roles():
    chain = FakeChainClient(clock=lambda: NOW, enforce_roles=True)
    expect_revert(chain.record_pending(record(1), fake_signature(TREASURER)), RevertReason.NOT_REGISTRANT)

    chain.grant_role(Role.TREASURER, TREASURER)
    run(chain.record_pending(record(1), fake_signature(TREASURER)))
    expect_revert(chain.confirm_entry(confirm(1), fake_signature(AUDITOR)), RevertReason.NOT_APPROVER)

    chain.grant_role(Role.AUDITOR, AUDITOR)
    assert run(chain.has_role(Role.AUDITOR, AUDITOR.upper().replace("0X", "0x")))
    assert run(chain.confirm_entry(confirm(1), fake_signature(AUDITOR))).status == EntryStatus.CONFIRMED


# ---------------------------------------------------------------- 이의


def answer(objection_id=3):
    return AnswerRequest(objection_id=objection_id, answer_hash="0x" + "a1" * 32, deadline=NOW + 60)


def test_objection_rules(chain):
    content = "0x" + "c1" * 32
    expect_revert(chain.raise_objection(3, 1, content, STUDENT), RevertReason.ENTRY_NOT_FOUND)
    run(chain.record_pending(record(1), fake_signature(TREASURER)))

    assert run(chain.raise_objection(3, 1, content, STUDENT)).status == ObjectionStatus.OPEN
    expect_revert(chain.raise_objection(3, 1, content, STUDENT), RevertReason.OBJECTION_ALREADY_EXISTS)
    expect_revert(chain.answer_objection(answer(9), fake_signature(AUDITOR)), RevertReason.OBJECTION_NOT_FOUND)

    assert run(chain.answer_objection(answer(), fake_signature(AUDITOR))).status == ObjectionStatus.ANSWERED
    objection = run(chain.get_objection(3))
    assert (objection.status, objection.responder.lower(), objection.raiser.lower()) == (ObjectionStatus.ANSWERED, AUDITOR, STUDENT)
    expect_revert(chain.answer_objection(answer(), fake_signature(AUDITOR)), RevertReason.OBJECTION_ALREADY_ANSWERED)


def test_objection_scenarios_and_enforced_responder():
    chain = FakeChainClient(clock=lambda: NOW, enforce_roles=True)
    chain.grant_role(Role.TREASURER, TREASURER)
    run(chain.record_pending(record(1), fake_signature(TREASURER)))

    chain.fail_next("raise_objection", RevertReason.NOT_MEMBER)
    expect_revert(chain.raise_objection(3, 1, "0x" + "c1" * 32, STUDENT), RevertReason.NOT_MEMBER)
    run(chain.raise_objection(3, 1, "0x" + "c1" * 32, STUDENT))

    expect_revert(chain.answer_objection(answer(), fake_signature(STUDENT)), RevertReason.NOT_RESPONDER)
    assert run(chain.answer_objection(answer(), fake_signature(TREASURER))).status == ObjectionStatus.ANSWERED  # 총무도 임원


# ---------------------------------------------------------------- SBT·이벤트


def test_memberships(chain):
    token = chain.grant_membership(STUDENT, 20262, "0x" + "07" * 32)
    assert run(chain.has_valid_membership(STUDENT, 20262))
    assert not run(chain.has_valid_membership(STUDENT, 20261))
    assert run(chain.token_of(STUDENT, 20262)) == token
    assert run(chain.token_of(STUDENT, 20261)) is None
    assert run(chain.get_membership(token)).commitment == "0x" + "07" * 32
    with pytest.raises(ValueError):
        chain.grant_membership(STUDENT, 20262)


def test_confirmed_entries_have_block_numbers(chain):
    run(chain.record_pending(record(1), fake_signature(TREASURER)))  # 블록 1
    run(chain.record_pending(record(2, kind=EntryKind.INCOME, budget_id=0), fake_signature(TREASURER)))  # 블록 2
    run(chain.confirm_entry(confirm(1), fake_signature(AUDITOR)))  # 블록 3
    run(chain.reject_entry(RejectDecision(id=2, reason_hash="0x" + "01" * 32, deadline=NOW + 60), fake_signature(AUDITOR)))  # 블록 4

    assert run(chain.safe_block()) == 4
    [confirmed] = run(chain.confirmed_entries(0, 4))
    assert (confirmed.id, confirmed.amount, confirmed.block_number) == (1, 1000, 3)
    assert run(chain.confirmed_entries(4, 4)) == []


# ---------------------------------------------------------------- 검증용 결정 내용·예산 조회


def test_decision_record_keeps_reason_hashes(chain):
    run(chain.record_pending(record(1), fake_signature(TREASURER)))
    run(chain.record_pending(record(2), fake_signature(TREASURER)))
    warning = "0x" + "a1" * 32
    approval = ConfirmApproval(id=1, hash=HASH, had_warning=True, warning_reason_hash=warning, deadline=NOW + 60)
    run(chain.confirm_entry(approval, fake_signature(AUDITOR)))
    run(chain.reject_entry(RejectDecision(id=2, reason_hash="0x" + "b2" * 32, deadline=NOW + 60), fake_signature(AUDITOR)))

    confirmed, rejected = run(chain.get_decision_result(1)), run(chain.get_decision_result(2))
    assert (confirmed.had_warning, confirmed.warning_reason_hash, confirmed.approver.lower()) == (True, warning, AUDITOR)
    assert (rejected.status, rejected.reason_hash) == (EntryStatus.REJECTED, "0x" + "b2" * 32)


def test_budget_reads(chain):
    from app.chain import ChainBudget

    assert run(chain.get_budget(2)) is None
    assert run(chain.remaining(2)) is None
    budget = ChainBudget(id=2, term=20262, category="0x" + "c3" * 32, issued=2_000_000, spent=500_000, expires_at=NOW + 86400, version=1)
    chain.set_budget(budget, remaining=1_500_000)
    assert run(chain.get_budget(2)) == budget
    assert run(chain.remaining(2)) == 1_500_000
