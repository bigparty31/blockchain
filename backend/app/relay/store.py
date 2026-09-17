"""초안·결정 저장소. 실제 구현은 DB 이고, 지켜야 할 조건은 각 메서드 설명과 docs/RELAY.md 에 있다."""
import asyncio
from collections.abc import Collection
from typing import Any, Optional, Protocol

from app.chain.models import BlockReason
from app.relay.models import OPEN_STATUSES, Decision, DecisionStatus, Draft, DraftStatus
from app.schemas.entry import EntryStatus


class DraftStore(Protocol):
    async def reserve_id(self) -> int:
        """Entry id 시퀀스에서 번호 하나를 받는다 (Postgres nextval). 초안을 버려도 돌려놓지 않는다."""
        ...

    async def add(self, draft: Draft) -> None:
        ...

    async def get(self, draft_id: int) -> Optional[Draft]:
        ...

    async def transition(
        self,
        draft_id: int,
        from_statuses: Collection[DraftStatus],
        changes: dict[str, Any],
        *,
        expected_signature: Optional[str] = None,
    ) -> Optional[Draft]:
        """status 가 from_statuses 중 하나일 때만 changes 를 적용하고 바뀐 초안을 돌려준다. 아니면 None.

        expected_signature 를 주면 서명까지 같을 때만 바꾼다 — 대조가 읽어 둔 제출이 그사이 실패·재제출됐으면
        새 제출을 건드리지 않게 한다.
        확인과 변경이 한 문장이어야 한다 (UPDATE ... WHERE id = :id AND status IN (...) [AND signature = :sig] RETURNING *).
        같은 초안으로 동시에 들어온 제출 중 하나만 체인에 보내는 장치가 이것이다.
        """
        ...

    async def record(
        self, draft_id: int, entry_status: EntryStatus, block_reason: Optional[BlockReason], tx_hash: str
    ) -> Optional[Draft]:
        """SUBMITTING 초안을 RECORDED 로 바꾸고, 같은 DB 트랜잭션에서 초안 값으로 Entry 행을 만든다.

        초안이 SUBMITTING 이 아니면 아무것도 하지 않고 None. Entry.id 는 초안 id, status 는 entry_status,
        tx_pending 은 tx_hash 다.
        """
        ...

    async def list_open(self, created_by: int) -> list[Draft]:
        """그 총무의 DRAFT·SUBMITTING·FAILED 초안."""
        ...

    async def list_submitting(self) -> list[Draft]:
        ...


class InMemoryDraftStore:
    """테스트용 DraftStore. entries 에 만들어진 Entry 행(초안 사본)이 쌓인다."""

    def __init__(self, start_id: int = 1):
        self._next_id = start_id
        self._drafts: dict[int, Draft] = {}
        self.entries: dict[int, Draft] = {}

    async def reserve_id(self) -> int:
        draft_id, self._next_id = self._next_id, self._next_id + 1
        return draft_id

    async def add(self, draft: Draft) -> None:
        self._drafts[draft.id] = draft

    async def get(self, draft_id: int) -> Optional[Draft]:
        await asyncio.sleep(0)  # 실제 DB 처럼 읽고 쓰는 사이에 다른 요청이 끼어들 수 있게 한다
        return self._drafts.get(draft_id)

    async def transition(
        self,
        draft_id: int,
        from_statuses: Collection[DraftStatus],
        changes: dict[str, Any],
        *,
        expected_signature: Optional[str] = None,
    ) -> Optional[Draft]:
        draft = self._drafts.get(draft_id)
        if draft is None or draft.status not in from_statuses:
            return None
        if expected_signature is not None and draft.signature != expected_signature:
            return None
        self._drafts[draft_id] = draft = draft.model_copy(update=changes)
        return draft

    async def record(
        self, draft_id: int, entry_status: EntryStatus, block_reason: Optional[BlockReason], tx_hash: str
    ) -> Optional[Draft]:
        changes = {
            "status": DraftStatus.RECORDED,
            "entry_status": entry_status,
            "block_reason": block_reason,
            "tx_hash": tx_hash,
        }
        draft = await self.transition(draft_id, (DraftStatus.SUBMITTING,), changes)
        if draft is not None:
            if draft_id in self.entries:
                raise AssertionError(f"Entry {draft_id} 가 두 번 만들어졌다")
            self.entries[draft_id] = draft
        return draft

    async def list_open(self, created_by: int) -> list[Draft]:
        return [d for d in self._drafts.values() if d.created_by == created_by and d.status in OPEN_STATUSES]

    async def list_submitting(self) -> list[Draft]:
        return [d for d in self._drafts.values() if d.status == DraftStatus.SUBMITTING]


# ---------------------------------------------------------------- 확정·반려


ACTIVE_DECISION = (DecisionStatus.SUBMITTING, DecisionStatus.RECORDED)


class DecisionStore(Protocol):
    async def begin(self, decision: Decision) -> tuple[Decision, bool]:
        """entry_id 에 SUBMITTING·RECORDED 결정이 없을 때만 decision 을 넣고 (id 가 매겨진 결정, True).
        이미 있으면 넣지 않고 (그 결정, False).

        확인과 삽입이 한 번에 일어나야 한다 — (entry_id) WHERE status IN ('SUBMITTING', 'RECORDED') 부분 유니크 인덱스.
        한 항목에 확정과 반려를 둘 다 보내지 않는 장치가 이것이다.
        """
        ...

    async def get(self, decision_id: int) -> Optional[Decision]:
        ...

    async def get_active(self, entry_id: int) -> Optional[Decision]:
        ...

    async def transition(
        self, decision_id: int, from_statuses: Collection[DecisionStatus], changes: dict[str, Any]
    ) -> Optional[Decision]:
        """DraftStore.transition 과 같다."""
        ...

    async def record(self, decision_id: int, tx_hash: str) -> Optional[Decision]:
        """SUBMITTING 결정을 RECORDED 로 바꾸고, 같은 DB 트랜잭션에서 Entry 를 갱신한다.

        Entry.status 는 결정의 target_status, tx_confirm 은 tx_hash. 확정이면 approved_by·warning_ack_reason,
        반려면 reject_reason (반려자 칼럼이 생기면 그것도). 결정이 SUBMITTING 이 아니면 아무것도 하지 않고 None.
        """
        ...

    async def list_submitting(self) -> list[Decision]:
        ...


class InMemoryDecisionStore:
    """테스트용 DecisionStore. entry_updates 에 Entry 갱신(결정 사본)이 쌓인다."""

    def __init__(self):
        self._next_id = 1
        self._decisions: dict[int, Decision] = {}
        self.entry_updates: dict[int, Decision] = {}

    async def begin(self, decision: Decision) -> tuple[Decision, bool]:
        await asyncio.sleep(0)  # 실제 DB 처럼 다른 요청이 끼어들 수 있게 한다
        active = self._active(decision.entry_id)
        if active is not None:
            return active, False
        decision = decision.model_copy(update={"id": self._next_id, "status": DecisionStatus.SUBMITTING})
        self._next_id += 1
        self._decisions[decision.id] = decision
        return decision, True

    async def get(self, decision_id: int) -> Optional[Decision]:
        return self._decisions.get(decision_id)

    async def get_active(self, entry_id: int) -> Optional[Decision]:
        await asyncio.sleep(0)
        return self._active(entry_id)

    async def transition(
        self, decision_id: int, from_statuses: Collection[DecisionStatus], changes: dict[str, Any]
    ) -> Optional[Decision]:
        decision = self._decisions.get(decision_id)
        if decision is None or decision.status not in from_statuses:
            return None
        self._decisions[decision_id] = decision = decision.model_copy(update=changes)
        return decision

    async def record(self, decision_id: int, tx_hash: str) -> Optional[Decision]:
        changes = {"status": DecisionStatus.RECORDED, "tx_hash": tx_hash}
        decision = await self.transition(decision_id, (DecisionStatus.SUBMITTING,), changes)
        if decision is not None:
            if decision.entry_id in self.entry_updates:
                raise AssertionError(f"Entry {decision.entry_id} 가 두 번 결정됐다")
            self.entry_updates[decision.entry_id] = decision
        return decision

    async def list_submitting(self) -> list[Decision]:
        return [d for d in self._decisions.values() if d.status == DecisionStatus.SUBMITTING]

    def _active(self, entry_id: int) -> Optional[Decision]:
        return next((d for d in self._decisions.values() if d.entry_id == entry_id and d.status in ACTIVE_DECISION), None)
