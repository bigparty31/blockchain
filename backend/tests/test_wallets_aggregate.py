import asyncio

import pytest

from app.chain import (
    ChainUnavailable,
    ConfirmApproval,
    FakeChainClient,
    InMemoryTotalsStore,
    LedgerAggregator,
    LedgerTotals,
    RecordRequest,
    RejectDecision,
    fake_signature,
    student_address,
)
from app.chain.wallets import StudentWallets, mnemonic_from_env
from app.schemas.entry import EntryKind

# Hardhat 기본 니모닉. 공개된 테스트용이라 실제 자산이 없다. 주소는 Hardhat 이 출력하는 값과 같다
HARDHAT_MNEMONIC = "test test test test test test test test test test test junk"

NOW = 1_790_000_000
DAY = NOW // 86400 * 86400 + 54000
TREASURER = "0x1111111111111111111111111111111111111111"
AUDITOR = "0x2222222222222222222222222222222222222222"


def run(coro):
    return asyncio.run(coro)


# ---------------------------------------------------------------- 학생 지갑


def test_student_address_follows_bip44_path():
    assert student_address(HARDHAT_MNEMONIC, 0) == "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    assert student_address(HARDHAT_MNEMONIC, 1) == "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"


@pytest.mark.parametrize("mnemonic, index", [(HARDHAT_MNEMONIC, -1), (HARDHAT_MNEMONIC, 2**31), ("not a valid mnemonic", 0)])
def test_student_address_rejects_bad_input(mnemonic, index):
    with pytest.raises(ValueError):
        student_address(mnemonic, index)


def test_student_wallets_match_eth_account_and_cache():
    from eth_account import Account

    Account.enable_unaudited_hdwallet_features()
    wallets = StudentWallets(HARDHAT_MNEMONIC, cache_size=2)
    for index in (0, 1, 7, 1000, 2**31 - 1):
        expected = Account.from_mnemonic(HARDHAT_MNEMONIC, account_path=f"m/44'/60'/0'/0/{index}").address
        assert wallets.address(index) == expected
    assert list(wallets._cache) == [1000, 2**31 - 1]  # 오래 안 쓴 것부터 버린다
    assert not hasattr(wallets, "_mnemonic")  # 니모닉을 들고 있지 않는다


def test_mnemonic_from_env():
    assert mnemonic_from_env({"STUDENT_WALLET_MNEMONIC": HARDHAT_MNEMONIC}) == HARDHAT_MNEMONIC
    with pytest.raises(ValueError):
        mnemonic_from_env({})


# ---------------------------------------------------------------- 장부 잔액


class Ledger:
    """FakeChainClient 에 항목을 올리고 확정·반려한다."""

    def __init__(self):
        self.chain = FakeChainClient(clock=lambda: NOW)
        self._next = 1

    def record(self, amount, kind, corrects_id=0) -> int:
        entry_id, self._next = self._next, self._next + 1
        request = RecordRequest(
            id=entry_id, hash="0x" + f"{entry_id:064x}", amount=amount, kind=kind, occurred_at=DAY,
            budget_id=0 if kind == EntryKind.INCOME else 2, corrects_id=corrects_id, deadline=NOW + 60,
        )
        run(self.chain.record_pending(request, fake_signature(TREASURER)))
        return entry_id

    def confirm(self, entry_id):
        approval = ConfirmApproval(id=entry_id, hash="0x" + f"{entry_id:064x}", deadline=NOW + 60)
        run(self.chain.confirm_entry(approval, fake_signature(AUDITOR)))

    def reject(self, entry_id):
        decision = RejectDecision(id=entry_id, reason_hash="0x" + "01" * 32, deadline=NOW + 60)
        run(self.chain.reject_entry(decision, fake_signature(AUDITOR)))


def test_balance_counts_only_confirmed_and_splits_by_kind():
    ledger = Ledger()
    ledger.confirm(ledger.record(5_000_000, EntryKind.INCOME))
    spent = ledger.record(35_000, EntryKind.EXPENSE)
    ledger.confirm(spent)
    ledger.confirm(ledger.record(-5_000, EntryKind.EXPENSE, corrects_id=spent))  # 감액 정정은 음수로 그대로 더한다
    ledger.reject(ledger.record(99_000, EntryKind.EXPENSE))
    ledger.record(77_000, EntryKind.EXPENSE)  # PENDING

    totals = run(LedgerAggregator(ledger.chain, InMemoryTotalsStore()).refresh())
    assert (totals.income, totals.expense, totals.balance) == (5_000_000, 30_000, 4_970_000)


def test_refresh_reads_only_new_blocks():
    ledger = Ledger()
    ranges = []
    original = ledger.chain.confirmed_entries

    async def recording(from_block, to_block):
        ranges.append((from_block, to_block))
        return await original(from_block, to_block)

    ledger.chain.confirmed_entries = recording
    store = InMemoryTotalsStore()
    aggregator = LedgerAggregator(ledger.chain, store)

    ledger.confirm(ledger.record(1_000, EntryKind.INCOME))  # 블록 1, 2
    assert run(aggregator.refresh()).balance == 1_000
    assert run(aggregator.refresh()).balance == 1_000  # 새 블록이 없으면 읽지 않는다
    ledger.confirm(ledger.record(300, EntryKind.EXPENSE))  # 블록 3, 4
    assert run(aggregator.refresh()).balance == 700

    assert ranges == [(0, 2), (3, 4)]
    assert store.totals.last_block == 4


def test_refresh_failure_keeps_stored_totals():
    ledger = Ledger()
    store = InMemoryTotalsStore()
    store.totals = LedgerTotals(income=10, expense=3, last_block=0)
    ledger.confirm(ledger.record(1_000, EntryKind.INCOME))

    ledger.chain.unavailable_next("confirmed_entries")
    with pytest.raises(ChainUnavailable):
        run(LedgerAggregator(ledger.chain, store).refresh())
    assert store.totals == LedgerTotals(income=10, expense=3, last_block=0)


def test_start_block_skips_earlier_history():
    ledger = Ledger()
    ledger.confirm(ledger.record(1_000, EntryKind.INCOME))  # 블록 1, 2
    ledger.confirm(ledger.record(500, EntryKind.INCOME))  # 블록 3, 4
    totals = run(LedgerAggregator(ledger.chain, InMemoryTotalsStore(), start_block=3).refresh())
    assert totals.income == 500
