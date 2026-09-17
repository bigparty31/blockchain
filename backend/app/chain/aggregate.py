"""체인 이벤트로 장부 잔액을 집계한다 (docs/CONTRACTS.md 이벤트).

    장부 잔액 = Σ EntryConfirmed.amount (INCOME) − Σ EntryConfirmed.amount (EXPENSE)

amount 는 수입·지출 모두 양수로 오므로 kind 로 나눠 뺀다. 정정 항목은 음수로 오므로 그대로 더한다.
예산 잔량은 여기서 계산하지 않는다 — BudgetToken.remaining() 이 정본이다.

매번 처음부터 읽지 않도록 마지막으로 읽은 블록까지의 합계를 TotalsStore 에 저장하고 그 뒤만 읽는다.
확인 블록 수만큼 쌓인 블록(safe_block)까지만 읽어서, 뒤집힐 수 있는 블록이 합계에 섞이지 않게 한다.
"""
from typing import Optional, Protocol

from pydantic import BaseModel, ConfigDict

from app.chain.client import LedgerEvents
from app.schemas.entry import EntryKind


class LedgerTotals(BaseModel):
    model_config = ConfigDict(frozen=True)

    income: int = 0
    expense: int = 0
    last_block: int = -1  # 이 블록까지 반영했다

    @property
    def balance(self) -> int:
        return self.income - self.expense


class TotalsStore(Protocol):
    async def load(self) -> Optional[LedgerTotals]:
        ...

    async def save(self, totals: LedgerTotals) -> None:
        ...


class InMemoryTotalsStore:
    def __init__(self):
        self.totals: Optional[LedgerTotals] = None

    async def load(self) -> Optional[LedgerTotals]:
        return self.totals

    async def save(self, totals: LedgerTotals) -> None:
        self.totals = totals


class LedgerAggregator:
    def __init__(self, events: LedgerEvents, store: TotalsStore, *, start_block: int = 0):
        self._events = events
        self._store = store
        self._start_block = start_block

    async def refresh(self) -> LedgerTotals:
        """새로 확정된 블록까지 합계를 갱신하고 돌려준다. 주기적으로 부른다.

        Raises:
            ChainUnavailable: 체인을 읽지 못했다. 저장된 합계는 그대로다.
        """
        current = await self._store.load() or LedgerTotals(last_block=self._start_block - 1)
        safe = await self._events.safe_block()
        if safe <= current.last_block:
            return current
        income, expense = current.income, current.expense
        for entry in await self._events.confirmed_entries(current.last_block + 1, safe):
            if entry.kind == EntryKind.INCOME:
                income += entry.amount
            else:
                expense += entry.amount
        updated = LedgerTotals(income=income, expense=expense, last_block=safe)
        await self._store.save(updated)
        return updated
