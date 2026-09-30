"""FakeChainClient 가 컨트랙트 규칙을 그대로 흉내 내는지 확인한다.

여기서 확인하는 것은 등록 API 가 기대야 하는 동작이다 — 어떤 입력이 어떤 revert 로 오는지,
revert 뒤에 상태가 남지 않는지, 연결 실패를 어떻게 구분하는지.
정본은 contracts/interfaces/IAccountingLedger.sol 과 docs/CHAIN_CLIENT.md 다.
"""
import asyncio

import pytest

from app.chain import (
    MAX_AMOUNT,
    BlockReason,
    ChainRevert,
    ChainUnavailable,
    ConfirmApproval,
    FakeChainClient,
    RecordRequest,
    RejectDecision,
    RevertReason,
    entry_commit_of,
    fake_signature,
)
from app.schemas.entry import EntryKind, EntryStatus

NOW = 1_790_000_000
DAY = NOW // 86400 * 86400 + 54000  # KST 자정 (docs/HASHING.md §1.3)
TERM = 20262  # 학기 코드 YYYYS
OTHER_TERM = 20261
HASH = "0x" + "ab" * 32
OTHER_HASH = "0x" + "cd" * 32
REASON = "0x" + "12" * 32
ZERO32 = "0x" + "0" * 64
TREASURER = "0x1111111111111111111111111111111111111111"
AUDITOR = "0x2222222222222222222222222222222222222222"
ZERO_ADDRESS = "0x" + "0" * 40


def run(coro):
    return asyncio.run(coro)


def record(entry_id, **fields):
    values = dict(
        id=entry_id, hash=HASH, amount=1000, kind=EntryKind.EXPENSE, term=TERM, occurred_at=DAY, budget_id=2, deadline=NOW + 60
    )
    return RecordRequest(**{**values, **fields})


def _commit(chain, entry_id):
    """승인자가 화면에서 본 값 = 체인에 등록된 값. 없는 항목이면 0."""
    entry = run(chain.get_entry(entry_id))
    return entry_commit_of(entry) if entry else ZERO32


def confirm(chain, entry_id, **fields):
    values = dict(id=entry_id, hash=HASH, entry_commit=_commit(chain, entry_id), deadline=NOW + 60)
    return ConfirmApproval(**{**values, **fields})


def reject(chain, entry_id, **fields):
    values = dict(id=entry_id, entry_commit=_commit(chain, entry_id), reason_hash=REASON, deadline=NOW + 60)
    return RejectDecision(**{**values, **fields})


def confirmed(chain, entry_id, **fields):
    """등록하고 확정까지 끝낸 항목 (정정의 원본)."""
    run(chain.record_pending(record(entry_id, **fields), fake_signature(TREASURER)))
    run(chain.confirm_entry(confirm(chain, entry_id, hash=fields.get("hash", HASH)), fake_signature(AUDITOR)))


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
    assert (entry.id, entry.hash, entry.amount, entry.status, entry.term) == (1, HASH, 1000, EntryStatus.PENDING, TERM)
    assert entry.registrant.lower() == TREASURER
    assert entry.approver == ZERO_ADDRESS  # 아직 아무도 처리하지 않았다

    done = run(chain.confirm_entry(confirm(chain, 1), fake_signature(AUDITOR)))
    assert done.status == EntryStatus.CONFIRMED
    assert done.tx_hash != result.tx_hash

    entry = run(chain.get_entry(1))
    assert entry.status == EntryStatus.CONFIRMED
    assert entry.approver.lower() == AUDITOR


def test_record_then_reject(chain):
    run(chain.record_pending(record(1), fake_signature(TREASURER)))
    assert run(chain.reject_entry(reject(chain, 1), fake_signature(AUDITOR))).status == EntryStatus.REJECTED
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


def test_negative_correction_skips_budget_judgement(chain):
    """환불(음수 정정)은 마감·잔량과 무관하게 등록된다. 걸어둔 block_next 는 다음 양수 지출에 남는다."""
    confirmed(chain, 1)
    chain.block_next(BlockReason.BUDGET_EXPIRED)

    assert run(chain.record_pending(record(2, amount=-300, corrects_id=1), fake_signature(TREASURER))).status == EntryStatus.PENDING
    assert run(chain.record_pending(record(3), fake_signature(TREASURER))).block_reason == BlockReason.BUDGET_EXPIRED


def test_blocked_entry_cannot_be_decided(chain):
    run(chain.record_pending(record(1, budget_id=0), fake_signature(TREASURER)))
    expect_revert(chain.confirm_entry(confirm(chain, 1), fake_signature(AUDITOR)), RevertReason.INVALID_STATUS)
    expect_revert(chain.reject_entry(reject(chain, 1), fake_signature(AUDITOR)), RevertReason.INVALID_STATUS)


# ---------------------------------------------------------------- 등록 규칙


def test_duplicate_id(chain):
    run(chain.record_pending(record(1), fake_signature(TREASURER)))
    expect_revert(chain.record_pending(record(1, amount=2000), fake_signature(TREASURER)), RevertReason.ENTRY_ALREADY_EXISTS)
    assert run(chain.get_entry(1)).amount == 1000  # 먼저 들어간 값이 그대로다


def test_zero_hash_is_rejected(chain):
    """학생 앱은 0 해시를 "아직 기록 안 됨"으로 읽어서, 체인이 0 해시를 받지 않는다."""
    expect_revert(chain.record_pending(record(1, hash=ZERO32), fake_signature(TREASURER)), RevertReason.HASH_REQUIRED)
    assert run(chain.get_entry(1)) is None


def test_zero_amount(chain):
    expect_revert(chain.record_pending(record(1, amount=0), fake_signature(TREASURER)), RevertReason.ZERO_AMOUNT)
    assert run(chain.get_entry(1)) is None  # revert 뒤에는 아무것도 남지 않는다


def test_amount_limit(chain):
    assert run(chain.record_pending(record(1, amount=MAX_AMOUNT), fake_signature(TREASURER))).status == EntryStatus.PENDING
    expect_revert(chain.record_pending(record(2, amount=MAX_AMOUNT + 1), fake_signature(TREASURER)), RevertReason.AMOUNT_OUT_OF_RANGE)
    expect_revert(
        chain.record_pending(record(3, amount=-(MAX_AMOUNT + 1), corrects_id=1), fake_signature(TREASURER)),
        RevertReason.AMOUNT_OUT_OF_RANGE,
    )


@pytest.mark.parametrize("field", ["id", "budget_id", "corrects_id"])
def test_fields_must_fit_storage(chain, field):
    """원장은 id·budgetId·correctsId 를 uint64 로 저장한다."""
    expect_revert(chain.record_pending(record(1, **{field: 2**64}), fake_signature(TREASURER)), RevertReason.FIELD_OUT_OF_RANGE)


def test_negative_amount_needs_correction_target(chain):
    expect_revert(
        chain.record_pending(record(1, amount=-500), fake_signature(TREASURER)),
        RevertReason.NEGATIVE_AMOUNT_WITHOUT_CORRECTION,
    )


def test_income_must_not_have_budget(chain):
    expect_revert(
        chain.record_pending(record(1, kind=EntryKind.INCOME, budget_id=2), fake_signature(TREASURER)),
        RevertReason.BUDGET_ID_NOT_ALLOWED_FOR_INCOME,
    )


# ---------------------------------------------------------------- 정정 규칙


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
    confirmed(chain, 1)
    result = run(chain.record_pending(record(2, amount=-300, corrects_id=1), fake_signature(TREASURER)))
    assert result.status == EntryStatus.PENDING
    assert run(chain.get_entry(2)).corrects_id == 1


def test_correction_kind_must_match(chain):
    confirmed(chain, 1)
    expect_revert(
        chain.record_pending(record(2, kind=EntryKind.INCOME, budget_id=0, amount=-300, corrects_id=1), fake_signature(TREASURER)),
        RevertReason.CORRECTION_KIND_MISMATCH,
    )


def test_correction_term_must_match_original(chain):
    """정정으로 학기를 옮길 수 없다 — 다른 학기 예산으로의 재분류와 수입 정정도 막힌다."""
    confirmed(chain, 1)
    expect_revert(
        chain.record_pending(record(2, amount=500, budget_id=3, term=OTHER_TERM, corrects_id=1), fake_signature(TREASURER)),
        RevertReason.TERM_MISMATCH,
    )
    confirmed(chain, 3, kind=EntryKind.INCOME, budget_id=0)
    expect_revert(
        chain.record_pending(record(4, kind=EntryKind.INCOME, budget_id=0, amount=-100, term=OTHER_TERM, corrects_id=3), fake_signature(TREASURER)),
        RevertReason.TERM_MISMATCH,
    )


def test_negative_correction_must_use_original_budget(chain):
    confirmed(chain, 1)
    expect_revert(
        chain.record_pending(record(2, amount=-300, budget_id=3, corrects_id=1), fake_signature(TREASURER)),
        RevertReason.CORRECTION_BUDGET_MISMATCH,
    )


def test_corrections_cannot_be_correction_targets(chain):
    """같은 예산 양수 정정과 음수 정정은 대상이 될 수 없다 — 같은 금액이 두 번 환불되는 것을 막는다."""
    confirmed(chain, 1)
    confirmed(chain, 2, amount=500, corrects_id=1)  # 같은 예산 양수 정정
    confirmed(chain, 3, amount=-200, corrects_id=1)  # 음수 정정
    for target in (2, 3):
        expect_revert(
            chain.record_pending(record(10 + target, amount=-100, corrects_id=target), fake_signature(TREASURER)),
            RevertReason.INVALID_CORRECTION_TARGET,
        )


def test_reclassified_positive_correction_is_a_target(chain):
    """다른 예산으로 간 양수 정정(재분류)은 자기 순금액을 갖고, 그 범위 안에서만 되돌릴 수 있다."""
    confirmed(chain, 1)
    confirmed(chain, 2, amount=400, budget_id=3, corrects_id=1)
    assert run(chain.record_pending(record(3, amount=-400, budget_id=3, corrects_id=2), fake_signature(TREASURER))).status == EntryStatus.PENDING
    expect_revert(
        chain.record_pending(record(4, amount=-401, budget_id=3, corrects_id=2), fake_signature(TREASURER)),
        RevertReason.CORRECTION_EXCEEDS_ORIGINAL,
    )


def test_negative_corrections_are_capped_by_net_amount(chain):
    """원본 1000 → -600 확정 뒤 -500 은 초과. 같은 예산 +300 확정으로 순금액 700 이 되면 -700 까지 된다."""
    confirmed(chain, 1)
    confirmed(chain, 2, amount=-600, corrects_id=1)
    expect_revert(chain.record_pending(record(3, amount=-500, corrects_id=1), fake_signature(TREASURER)), RevertReason.CORRECTION_EXCEEDS_ORIGINAL)

    confirmed(chain, 4, amount=300, corrects_id=1)
    expect_revert(chain.record_pending(record(5, amount=-701, corrects_id=1), fake_signature(TREASURER)), RevertReason.CORRECTION_EXCEEDS_ORIGINAL)
    assert run(chain.record_pending(record(6, amount=-700, corrects_id=1), fake_signature(TREASURER))).status == EntryStatus.PENDING


def test_negative_correction_cap_is_checked_again_at_confirm(chain):
    """대기 중인 음수 정정은 한도를 예약하지 않아서, 나중 확정이 확정 시점 검사에서 막힌다."""
    confirmed(chain, 1)
    run(chain.record_pending(record(2, amount=-1000, corrects_id=1), fake_signature(TREASURER)))
    run(chain.record_pending(record(3, amount=-1000, corrects_id=1), fake_signature(TREASURER)))
    run(chain.confirm_entry(confirm(chain, 2), fake_signature(AUDITOR)))
    expect_revert(chain.confirm_entry(confirm(chain, 3), fake_signature(AUDITOR)), RevertReason.CORRECTION_EXCEEDS_ORIGINAL)
    assert run(chain.get_entry(3)).status == EntryStatus.PENDING


# ---------------------------------------------------------------- 확정·반려 규칙


def test_confirm_hash_must_match(chain):
    run(chain.record_pending(record(1), fake_signature(TREASURER)))
    expect_revert(chain.confirm_entry(confirm(chain, 1, hash=OTHER_HASH), fake_signature(AUDITOR)), RevertReason.HASH_MISMATCH)
    assert run(chain.get_entry(1)).status == EntryStatus.PENDING


@pytest.mark.parametrize("decide", ["confirm", "reject"])
def test_entry_commit_must_match_what_approver_saw(chain, decide):
    """승인·반려자가 본 예산이 등록된 예산과 다르면 막힌다 — meta_hash 만으로는 잡히지 않는 경우다."""
    run(chain.record_pending(record(1), fake_signature(TREASURER)))
    seen = entry_commit_of(run(chain.get_entry(1)).model_copy(update={"budget_id": 3}))
    coro = (
        chain.confirm_entry(confirm(chain, 1, entry_commit=seen), fake_signature(AUDITOR))
        if decide == "confirm"
        else chain.reject_entry(reject(chain, 1, entry_commit=seen), fake_signature(AUDITOR))
    )
    expect_revert(coro, RevertReason.ENTRY_COMMIT_MISMATCH)
    assert run(chain.get_entry(1)).status == EntryStatus.PENDING


def test_warning_reason_rules(chain):
    run(chain.record_pending(record(1), fake_signature(TREASURER)))
    expect_revert(chain.confirm_entry(confirm(chain, 1, had_warning=True), fake_signature(AUDITOR)), RevertReason.REASON_REQUIRED)
    expect_revert(chain.confirm_entry(confirm(chain, 1, warning_reason_hash=REASON), fake_signature(AUDITOR)), RevertReason.REASON_NOT_ALLOWED)
    done = run(chain.confirm_entry(confirm(chain, 1, had_warning=True, warning_reason_hash=REASON), fake_signature(AUDITOR)))
    assert done.status == EntryStatus.CONFIRMED


def test_reject_needs_reason(chain):
    run(chain.record_pending(record(1), fake_signature(TREASURER)))
    expect_revert(chain.reject_entry(reject(chain, 1, reason_hash=ZERO32), fake_signature(AUDITOR)), RevertReason.REASON_REQUIRED)


@pytest.mark.parametrize("decide", ["confirm", "reject"])
def test_decide_unknown_entry(chain, decide):
    coro = (
        chain.confirm_entry(confirm(chain, 9), fake_signature(AUDITOR))
        if decide == "confirm"
        else chain.reject_entry(reject(chain, 9), fake_signature(AUDITOR))
    )
    expect_revert(coro, RevertReason.ENTRY_NOT_FOUND)


def test_already_decided_entry(chain):
    run(chain.record_pending(record(1), fake_signature(TREASURER)))
    run(chain.confirm_entry(confirm(chain, 1), fake_signature(AUDITOR)))
    expect_revert(chain.confirm_entry(confirm(chain, 1), fake_signature(AUDITOR)), RevertReason.INVALID_STATUS)
    expect_revert(chain.reject_entry(reject(chain, 1), fake_signature(AUDITOR)), RevertReason.INVALID_STATUS)


def test_signatures_from_same_address_are_same_person(chain):
    """서명 문자열은 매번 달라도 주소가 같으면 같은 사람이다 — 자기가 올린 걸 자기가 확정할 수 없다."""
    first, second = fake_signature(TREASURER), fake_signature(TREASURER)
    assert first != second

    run(chain.record_pending(record(1), first))
    expect_revert(chain.confirm_entry(confirm(chain, 1), second), RevertReason.SELF_APPROVAL)
    expect_revert(chain.reject_entry(reject(chain, 1), second), RevertReason.SELF_APPROVAL)
    assert run(chain.get_entry(1)).status == EntryStatus.PENDING

    assert run(chain.confirm_entry(confirm(chain, 1), fake_signature(AUDITOR))).status == EntryStatus.CONFIRMED


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


@pytest.mark.parametrize("bad", [0, 1, 2026, 20260, 20265, 123456])
def test_term_must_be_semester_code(bad):
    """term 은 학기 코드 YYYYS 다. DB 의 Term.id(1, 2, ...)를 넘기면 체인에서 TermMismatch 가 난다."""
    with pytest.raises(ValueError):
        record(1, term=bad)


@pytest.mark.parametrize("good", [20261, 20262, 20263, 20264])
def test_term_accepts_all_semesters(good):
    assert record(1, term=good).term == good


@pytest.mark.parametrize("field, bad", [("hash", "0x" + "AB" * 32), ("hash", "0xabcd"), ("hash", "ab" * 32)])
def test_hash_must_be_lowercase_bytes32(field, bad):
    with pytest.raises(ValueError):
        record(1, **{field: bad})


@pytest.mark.parametrize("field", ["entry_commit", "warning_reason_hash"])
def test_confirm_hashes_are_checked_too(field):
    with pytest.raises(ValueError):
        ConfirmApproval(**{**dict(id=1, hash=HASH, entry_commit=HASH, deadline=NOW), field: "0x" + "AB" * 32})


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
    expect_revert(chain.confirm_entry(confirm(chain, 1), fake_signature(AUDITOR)), RevertReason.INSUFFICIENT_BUDGET)
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
        run(chain.confirm_entry(confirm(chain, 1), fake_signature(AUDITOR)))
    assert run(chain.get_entry(1)).status == EntryStatus.CONFIRMED  # 확정은 status 로 판단한다

    expect_revert(chain.confirm_entry(confirm(chain, 1), fake_signature(AUDITOR)), RevertReason.INVALID_STATUS)


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
