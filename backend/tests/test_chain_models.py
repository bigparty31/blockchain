"""서명 대상 모델이 컨트랙트가 상태와 무관하게 거부하는 값을 만들 때 막는지 (PR #20 2차 리뷰).

체인까지 가도 시뮬레이션에서 걸리지만, 등록 API 가 모델을 만들다 ValueError → 400 으로 일찍 돌려줄 수 있다.
같은 값을 FakeChainClient·컨트랙트가 직접 거부하는지는 test_fake_chain·test_chain_parity 가 본다.
"""
import pytest

from app.chain import ConfirmApproval, RecordRequest, RejectDecision
from app.chain.models import MAX_AMOUNT, UINT64_MAX, UINT256_MAX, ZERO_BYTES32
from app.schemas.entry import EntryKind

HASH = "0x" + "ab" * 32
DAY = 1790694000  # 2026-09-30 00:00 KST


def record(**override) -> RecordRequest:
    fields = dict(id=1, hash=HASH, amount=35000, kind=EntryKind.EXPENSE, term=20262, occurred_at=DAY, budget_id=2, deadline=1)
    return RecordRequest(**{**fields, **override})


@pytest.mark.parametrize(
    "override, contract_error",
    [
        ({"hash": ZERO_BYTES32}, "HashRequired"),
        ({"amount": 0}, "ZeroAmount"),
        ({"amount": MAX_AMOUNT + 1}, "AmountOutOfRange"),
        ({"amount": -(MAX_AMOUNT + 1), "corrects_id": 1}, "AmountOutOfRange"),
        ({"amount": -500}, "NegativeAmountWithoutCorrection"),
        ({"kind": EntryKind.INCOME, "budget_id": 2}, "BudgetIdNotAllowedForIncome"),
        ({"id": UINT64_MAX + 1}, "less than or equal"),
        ({"budget_id": UINT64_MAX + 1}, "less than or equal"),
        ({"corrects_id": UINT64_MAX + 1}, "less than or equal"),
        ({"occurred_at": (UINT64_MAX + 1) // 86400 * 86400 + 54000 + 86400}, "less than or equal"),
        ({"deadline": UINT256_MAX + 1}, "less than or equal"),
    ],
)
def test_record_rejects_what_the_contract_rejects(override, contract_error):
    with pytest.raises(ValueError, match=contract_error):
        record(**override)


@pytest.mark.parametrize(
    "override",
    [
        {"amount": MAX_AMOUNT},
        {"amount": -MAX_AMOUNT, "corrects_id": 1},
        {"id": UINT64_MAX, "budget_id": UINT64_MAX, "corrects_id": UINT64_MAX},
        {"kind": EntryKind.INCOME, "budget_id": 0},
        {"deadline": UINT256_MAX},
    ],
)
def test_record_accepts_the_boundaries(override):
    # 막는 범위가 컨트랙트보다 넓으면 정상 등록이 400 이 된다
    record(**override)


def test_confirm_and_reject_ids_fit_uint64():
    with pytest.raises(ValueError):
        ConfirmApproval(id=UINT64_MAX + 1, hash=HASH, entry_commit=HASH, deadline=1)
    with pytest.raises(ValueError):
        RejectDecision(id=UINT64_MAX + 1, entry_commit=HASH, reason_hash=HASH, deadline=1)
    ConfirmApproval(id=UINT64_MAX, hash=HASH, entry_commit=HASH, deadline=UINT256_MAX)
