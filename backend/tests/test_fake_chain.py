"""FakeChainClient 가 컨트랙트 규칙을 그대로 흉내 내는지 확인한다.

여기서 확인하는 것은 등록 API 가 기대야 하는 동작이다 — 어떤 입력이 어떤 revert 로 오는지,
revert 뒤에 상태가 남지 않는지, 연결 실패를 어떻게 구분하는지.
정본은 contracts/interfaces/IAccountingLedger.sol 과 docs/CHAIN_CLIENT.md 다.
"""
import asyncio

import pytest

from app.chain import (
    BlockReason,
    ChainRevert,
    ChainUnavailable,
    ConfirmApproval,
    FakeChainClient,
    RecordRequest,
    RejectDecision,
    RevertReason,
    fake_signature,
)
from app.schemas.entry import EntryKind, EntryStatus

NOW = 1_790_000_000
DAY = NOW // 86400 * 86400 + 54000  # KST 자정 (docs/HASHING.md §1.3)
HASH = "0x" + "ab" * 32
OTHER_HASH = "0x" + "cd" * 32
REASON = "0x" + "12" * 32
TREASURER = "0x1111111111111111111111111111111111111111"
AUDITOR = "0x2222222222222222222222222222222222222222"
ZERO_ADDRESS = "0x" + "0" * 40


def run(coro):
    return asyncio.run(coro)


def record(entry_id, **fields):
    values = dict(id=entry_id, hash=HASH, amount=1000, kind=EntryKind.EXPENSE, occurred_at=DAY, budget_id=2, deadline=NOW + 60)
    return RecordRequest(**{**values, **fields})


def confirm(entry_id, **fields):
    return ConfirmApproval(**{**dict(id=entry_id, hash=HASH, deadline=NOW + 60), **fields})


def reject(entry_id, **fields):
    return RejectDecision(**{**dict(id=entry_id, reason_hash=REASON, deadline=NOW + 60), **fields})


def expect_revert(coro, reason):
    with pytest.raises(ChainRevert) as e:
        run(coro)
    assert e.value.reason == reason


@pytest.fixture
def chain():
    return FakeChainClient(clock=lambda: NOW)


# ---------------------------------------------------------------- 기본 흐름


def test_record_then_confirm(chain):
    result = run(chain.record_pending(record(1), fake_signature(TREASURER)))
    assert (result.status, result.block_reason) == (EntryStatus.PENDING, None)

    entry = run(chain.get_entry(1))
    assert (entry.id, entry.hash, entry.amount, entry.status) == (1, HASH, 1000, EntryStatus.PENDING)
    assert entry.registrant.lower() == TREASURER
    assert entry.approver == ZERO_ADDRESS  # 아직 아무도 처리하지 않았다

    done = run(chain.confirm_entry(confirm(1), fake_signature(AUDITOR)))
    assert done.status == EntryStatus.CONFIRMED
    assert done.tx_hash != result.tx_hash

    entry = run(chain.get_entry(1))
    assert entry.status == EntryStatus.CONFIRMED
    assert entry.approver.lower() == AUDITOR


def test_record_then_reject(chain):
    run(chain.record_pending(record(1), fake_signature(TREASURER)))
    assert run(chain.reject_entry(reject(1), fake_signature(AUDITOR))).status == EntryStatus.REJECTED
    assert run(chain.get_entry(1)).approver.lower() == AUDITOR


def test_unknown_entry_is_none(chain):
    assert run(chain.get_entry(999)) is None


def test_income_needs_no_budget(chain):
    result = run(chain.record_pending(record(1, kind=EntryKind.INCOME, budget_id=0), fake_signature(TREASURER)))
    assert result.status == EntryStatus.PENDING


# ---------------------------------------------------------------- BLOCKED


def test_expense_without_budget_is_blocked_and_keeps_block_next(chain):
    """예산 id 0 은 "없음"으로 예약된 값이라 체인에 그런 예산이 없다. block_next 를 쓰지 않고 막힌다."""
    chain.block_next(BlockReason.BUDGET_EXCEEDED)

    result = run(chain.record_pending(record(1, budget_id=0), fake_signature(TREASURER)))
    assert (result.status, result.block_reason) == (EntryStatus.BLOCKED, BlockReason.BUDGET_NOT_FOUND)

    result = run(chain.record_pending(record(2), fake_signature(TREASURER)))
    assert (result.status, result.block_reason) == (EntryStatus.BLOCKED, BlockReason.BUDGET_EXCEEDED)


def test_block_next_applies_once(chain):
    chain.block_next()
    assert run(chain.record_pending(record(1), fake_signature(TREASURER))).status == EntryStatus.BLOCKED
    assert run(chain.record_pending(record(2), fake_signature(TREASURER))).status == EntryStatus.PENDING


def test_block_next_does_not_touch_income(chain):
    chain.block_next()
    result = run(chain.record_pending(record(1, kind=EntryKind.INCOME, budget_id=0), fake_signature(TREASURER)))
    assert result.status == EntryStatus.PENDING


def test_blocked_entry_cannot_be_decided(chain):
    run(chain.record_pending(record(1, budget_id=0), fake_signature(TREASURER)))
    expect_revert(chain.confirm_entry(confirm(1), fake_signature(AUDITOR)), RevertReason.INVALID_STATUS)
    expect_revert(chain.reject_entry(reject(1), fake_signature(AUDITOR)), RevertReason.INVALID_STATUS)


# ---------------------------------------------------------------- 등록 규칙


def test_duplicate_id(chain):
    run(chain.record_pending(record(1), fake_signature(TREASURER)))
    expect_revert(chain.record_pending(record(1, amount=2000), fake_signature(TREASURER)), RevertReason.ENTRY_ALREADY_EXISTS)
    assert run(chain.get_entry(1)).amount == 1000  # 먼저 들어간 값이 그대로다


def test_zero_amount(chain):
    expect_revert(chain.record_pending(record(1, amount=0), fake_signature(TREASURER)), RevertReason.ZERO_AMOUNT)
    assert run(chain.get_entry(1)) is None  # revert 뒤에는 아무것도 남지 않는다


def test_negative_amount_needs_correction_target(chain):
    expect_revert(
        chain.record_pending(record(1, amount=-500), fake_signature(TREASURER)),
        RevertReason.NEGATIVE_AMOUNT_WITHOUT_CORRECTION,
    )


def test_correction_target_must_exist(chain):
    expect_revert(
        chain.record_pending(record(1, corrects_id=7), fake_signature(TREASURER)),
        RevertReason.CORRECTION_TARGET_NOT_FOUND,
    )


def test_correction_target_must_be_confirmed(chain):
    run(chain.record_pending(record(1), fake_signature(TREASURER)))  # PENDING 인 채로 둔다
    expect_revert(
        chain.record_pending(record(2, corrects_id=1), fake_signature(TREASURER)),
        RevertReason.CORRECTION_TARGET_NOT_CONFIRMED,
    )


def test_negative_correction_of_confirmed_entry(chain):
    run(chain.record_pending(record(1), fake_signature(TREASURER)))
    run(chain.confirm_entry(confirm(1), fake_signature(AUDITOR)))

    result = run(chain.record_pending(record(2, amount=-300, corrects_id=1), fake_signature(TREASURER)))
    assert result.status == EntryStatus.PENDING
    assert run(chain.get_entry(2)).corrects_id == 1


# ---------------------------------------------------------------- 확정·반려 규칙


def test_confirm_hash_must_match(chain):
    run(chain.record_pending(record(1), fake_signature(TREASURER)))
    expect_revert(chain.confirm_entry(confirm(1, hash=OTHER_HASH), fake_signature(AUDITOR)), RevertReason.HASH_MISMATCH)
    assert run(chain.get_entry(1)).status == EntryStatus.PENDING


def test_reject_does_not_check_hash(chain):
    """반려는 내용을 승인하는 게 아니라 사유만 남기므로 meta_hash 를 보지 않는다."""
    run(chain.record_pending(record(1), fake_signature(TREASURER)))
    assert run(chain.reject_entry(reject(1), fake_signature(AUDITOR))).status == EntryStatus.REJECTED


@pytest.mark.parametrize("decide", ["confirm", "reject"])
def test_decide_unknown_entry(chain, decide):
    coro = chain.confirm_entry(confirm(9), fake_signature(AUDITOR)) if decide == "confirm" else chain.reject_entry(reject(9), fake_signature(AUDITOR))
    expect_revert(coro, RevertReason.ENTRY_NOT_FOUND)


def test_already_decided_entry(chain):
    run(chain.record_pending(record(1), fake_signature(TREASURER)))
    run(chain.confirm_entry(confirm(1), fake_signature(AUDITOR)))
    expect_revert(chain.confirm_entry(confirm(1), fake_signature(AUDITOR)), RevertReason.INVALID_STATUS)
    expect_revert(chain.reject_entry(reject(1), fake_signature(AUDITOR)), RevertReason.INVALID_STATUS)


def test_signatures_from_same_address_are_same_person(chain):
    """서명 문자열은 매번 달라도 주소가 같으면 같은 사람이다 — 자기가 올린 걸 자기가 확정할 수 없다."""
    first, second = fake_signature(TREASURER), fake_signature(TREASURER)
    assert first != second

    run(chain.record_pending(record(1), first))
    expect_revert(chain.confirm_entry(confirm(1), second), RevertReason.SELF_APPROVAL)
    expect_revert(chain.reject_entry(reject(1), second), RevertReason.SELF_APPROVAL)
    assert run(chain.get_entry(1)).status == EntryStatus.PENDING

    assert run(chain.confirm_entry(confirm(1), fake_signature(AUDITOR))).status == EntryStatus.CONFIRMED


def test_addresses_are_checksummed(chain):
    """web3.py 가 EIP-55 체크섬 주소를 돌려주므로 DB 와 비교할 땐 양쪽을 소문자로 맞춰야 한다."""
    mixed = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
    run(chain.record_pending(record(1), fake_signature(mixed)))

    registrant = run(chain.get_entry(1)).registrant
    assert registrant.lower() == mixed
    assert registrant != mixed  # 소문자 그대로가 아니라 체크섬이 섞인 형태다


# ---------------------------------------------------------------- 서명·입력 형식


def test_signature_is_case_insensitive(chain):
    signature = fake_signature(TREASURER)
    run(chain.record_pending(record(1), signature.upper().replace("0X", "0x")))
    assert run(chain.get_entry(1)).registrant.lower() == TREASURER


@pytest.mark.parametrize("bad", ["", "0x", "1" * 130, "0x" + "1" * 129, "0x" + "1" * 131, "0x" + "zz" * 65])
def test_signature_format_is_checked_before_the_chain(chain, bad):
    """형식 오류는 ChainError 가 아니라 ValueError 다 — 체인에 보내기 전에 막힌다."""
    with pytest.raises(ValueError):
        run(chain.record_pending(record(1), bad))
    assert run(chain.get_entry(1)) is None


@pytest.mark.parametrize("bad", ["0x111", TREASURER + "11", "1" * 40])
def test_fake_signature_checks_address(bad):
    with pytest.raises(ValueError):
        fake_signature(bad)


@pytest.mark.parametrize("bad", [-86400, 0, NOW, DAY + 1])
def test_occurred_at_must_be_kst_midnight(bad):
    with pytest.raises(ValueError):
        record(1, occurred_at=bad)


@pytest.mark.parametrize("field, bad", [("hash", "0x" + "AB" * 32), ("hash", "0xabcd"), ("hash", "ab" * 32)])
def test_hash_must_be_lowercase_bytes32(field, bad):
    with pytest.raises(ValueError):
        record(1, **{field: bad})


def test_warning_reason_hash_is_checked_too():
    with pytest.raises(ValueError):
        confirm(1, had_warning=True, warning_reason_hash="0x" + "AB" * 32)


@pytest.mark.parametrize("bad_id", [0, -1])
def test_entry_id_starts_at_one(bad_id):
    with pytest.raises(ValueError):
        record(bad_id)


# ---------------------------------------------------------------- 시한


def test_expired_signature_is_rejected(chain):
    expect_revert(chain.record_pending(record(1, deadline=NOW - 1), fake_signature(TREASURER)), RevertReason.SIGNATURE_EXPIRED)
    assert run(chain.get_entry(1)) is None


def test_deadline_exactly_now_still_passes(chain):
    """컨트랙트는 deadline 이 지난 뒤에만 거부한다 (block.timestamp > deadline)."""
    assert run(chain.record_pending(record(1, deadline=NOW), fake_signature(TREASURER))).status == EntryStatus.PENDING


# ---------------------------------------------------------------- 시나리오 훅


def test_fail_next_applies_once_and_leaves_no_state(chain):
    chain.fail_next("record_pending", RevertReason.NOT_REGISTRANT)
    expect_revert(chain.record_pending(record(1), fake_signature(TREASURER)), RevertReason.NOT_REGISTRANT)
    assert run(chain.get_entry(1)) is None

    assert run(chain.record_pending(record(1), fake_signature(TREASURER))).status == EntryStatus.PENDING


def test_fail_next_is_per_method(chain):
    """확정에 걸어둔 실패가 등록에 새지 않는다 — 예산 부족은 확정에서만 난다."""
    run(chain.record_pending(record(1), fake_signature(TREASURER)))
    chain.fail_next("confirm_entry", RevertReason.INSUFFICIENT_BUDGET)

    assert run(chain.record_pending(record(2), fake_signature(TREASURER))).status == EntryStatus.PENDING
    expect_revert(chain.confirm_entry(confirm(1), fake_signature(AUDITOR)), RevertReason.INSUFFICIENT_BUDGET)
    assert run(chain.get_entry(1)).status == EntryStatus.PENDING  # 반려 흐름으로 넘길 수 있게 그대로 남는다


@pytest.mark.parametrize("method", ["confirmEntry", "record", "get_entry", ""])
def test_scenarios_reject_unknown_method(chain, method):
    with pytest.raises(ValueError):
        chain.fail_next(method, RevertReason.INSUFFICIENT_BUDGET)
    with pytest.raises(ValueError):
        chain.unavailable_next(method)


def test_unavailable_not_landed_leaves_state(chain):
    """트랜잭션이 체인에 닿지 않은 경우. 그대로 다시 보내면 된다."""
    chain.unavailable_next("record_pending")
    with pytest.raises(ChainUnavailable):
        run(chain.record_pending(record(1), fake_signature(TREASURER)))
    assert run(chain.get_entry(1)) is None

    assert run(chain.record_pending(record(1), fake_signature(TREASURER))).status == EntryStatus.PENDING


def test_unavailable_landed_applies_then_raises(chain):
    """체인은 처리했는데 응답만 못 받은 경우. 확인 없이 재시도하면 중복으로 revert 된다."""
    chain.unavailable_next("record_pending", landed=True)
    with pytest.raises(ChainUnavailable):
        run(chain.record_pending(record(1), fake_signature(TREASURER)))
    assert run(chain.get_entry(1)).status == EntryStatus.PENDING

    expect_revert(chain.record_pending(record(1), fake_signature(TREASURER)), RevertReason.ENTRY_ALREADY_EXISTS)

    chain.unavailable_next("confirm_entry", landed=True)
    with pytest.raises(ChainUnavailable):
        run(chain.confirm_entry(confirm(1), fake_signature(AUDITOR)))
    assert run(chain.get_entry(1)).status == EntryStatus.CONFIRMED  # 확정은 status 로 판단한다

    expect_revert(chain.confirm_entry(confirm(1), fake_signature(AUDITOR)), RevertReason.INVALID_STATUS)


def test_unavailable_landed_but_reverted_leaves_state(chain):
    """체인까지 갔지만 revert 된 경우. 부른 쪽은 revert 였는지 알 수 없고, 상태는 그대로다."""
    chain.unavailable_next("record_pending", landed=True)
    with pytest.raises(ChainUnavailable):
        run(chain.record_pending(record(1, amount=0), fake_signature(TREASURER)))
    assert run(chain.get_entry(1)) is None


def test_unavailable_applies_once(chain):
    chain.unavailable_next("record_pending")
    with pytest.raises(ChainUnavailable):
        run(chain.record_pending(record(1), fake_signature(TREASURER)))
    assert run(chain.record_pending(record(1), fake_signature(TREASURER))).status == EntryStatus.PENDING


def test_tx_hashes_differ(chain):
    first = run(chain.record_pending(record(1), fake_signature(TREASURER))).tx_hash
    second = run(chain.record_pending(record(2), fake_signature(TREASURER))).tx_hash
    assert first != second
    assert len(first) == 66 and first.startswith("0x")
