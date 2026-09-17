"""확정·반려 릴레이 — 감사·회장 서명을 확인해 체인에 올리고, 결과를 모르는 제출을 마무리한다.

등록 릴레이와 같은 틀이다 (docs/RELAY.md §9). 다른 점은 항목이 이미 체인에 있다는 것 — 그래서 체인의 항목을 읽어
PENDING 인지·등록자가 아닌지를 보내기 전에 확인하고, 대조는 None 여부가 아니라 status 로 판단한다.
"""
import time
from typing import Callable, Optional

from app.chain.client import ChainClient, RoleReader
from app.chain.models import (
    APPROVER_ROLES,
    ZERO_BYTES32,
    ChainEntry,
    ChainNotSent,
    ChainRevert,
    ChainUnavailable,
    RevertReason,
    check_address,
)
from app.relay.checks import RecoverSigner, check_deadline, check_role, check_signer
from app.relay.models import (
    DECIDED_ELSEWHERE,
    NOT_RECORDED_BY_DEADLINE,
    NOT_SENT,
    Decision,
    DecisionKind,
    DecisionStatus,
    RelayError,
    RelayErrorCode,
)
from app.relay.store import DecisionStore
from app.schemas.entry import EntryStatus


class DecisionRelay:
    def __init__(
        self,
        chain: ChainClient,
        store: DecisionStore,
        recover_signer: RecoverSigner,
        *,
        clock: Callable[[], float] = time.time,
        max_deadline_seconds: int = 600,
        deadline_margin_seconds: int = 120,
        roles: Optional[RoleReader] = None,
    ):
        self._chain = chain
        self._store = store
        self._recover_signer = recover_signer
        self._roles = roles  # 붙이면 감사·회장 롤이 없는 서명을 체인에 보내기 전에 ROLE_MISSING 으로 막는다
        self._clock = clock
        self._max_deadline = max_deadline_seconds
        self._deadline_margin = deadline_margin_seconds

    async def confirm(
        self,
        entry_id: int,
        *,
        decided_by: int,
        approver: str,
        meta_hash: str,
        had_warning: bool,
        warning_reason_hash: str,
        deadline: int,
        signature: str,
    ) -> Decision:
        """확정. 경고가 있는 항목이면 had_warning=True 와 사유 해시가 함께 와야 한다.

        항목에 경고가 있는지(OCR 불일치·카테고리 경고)는 DB 값이라 호출하는 쪽이 보고 had_warning 을 정한다.
        돌려받은 결정이 FAILED(InsufficientBudget) 이면 반려 흐름으로 넘긴다 (docs/CONTRACTS.md).

        Raises:
            RelayError: 체인에 보내기 전에 막혔다.
            ChainUnavailable: 보내기 전 확인을 위해 체인을 읽지 못했다. 아무것도 저장하지 않았다.
        """
        if had_warning != (warning_reason_hash != ZERO_BYTES32):
            raise RelayError(RelayErrorCode.INVALID_REASON, "경고 승인에는 사유가, 경고가 없으면 bytes32(0)이 와야 한다")
        decision = self._new(
            DecisionKind.CONFIRM, entry_id, decided_by, approver, deadline, signature,
            hash=meta_hash, had_warning=had_warning, warning_reason_hash=warning_reason_hash,
        )
        return await self._submit(decision)

    async def reject(
        self, entry_id: int, *, decided_by: int, approver: str, reason_hash: str, deadline: int, signature: str
    ) -> Decision:
        """반려. 사유 해시는 필수다 (HASHING §3). 나머지는 confirm 과 같다."""
        if reason_hash == ZERO_BYTES32:
            raise RelayError(RelayErrorCode.INVALID_REASON, "반려 사유가 없다")
        decision = self._new(DecisionKind.REJECT, entry_id, decided_by, approver, deadline, signature, reason_hash=reason_hash)
        return await self._submit(decision)

    async def reconcile(self) -> list[Decision]:
        """결과를 모르는 SUBMITTING 결정을 체인과 대조해 마무리한다. 상태가 바뀐 결정을 돌려준다.

        체인 항목이 이 결정대로(같은 status·같은 승인자) 끝났으면 RECORDED, 다르게 끝났으면 FAILED(DecidedElsewhere),
        아직 PENDING 인데 서명 시한 + 여유가 지났으면 FAILED(NotRecordedByDeadline).
        """
        now = self._clock()
        changed = []
        for decision in await self._store.list_submitting():
            try:
                settled = await self._settle(decision)
            except ChainUnavailable:
                continue
            if settled is None and now > decision.deadline + self._deadline_margin:
                settled = await self._fail(decision.id, NOT_RECORDED_BY_DEADLINE)
            if settled is not None and settled.status != DecisionStatus.SUBMITTING:
                changed.append(settled)
        return changed

    # ------------------------------------------------------------ 내부

    def _new(self, kind, entry_id, decided_by, approver, deadline, signature, **fields) -> Decision:
        try:
            check_address(approver)
            decision = Decision(
                id=0, entry_id=entry_id, kind=kind, decided_by=decided_by, approver=approver,
                deadline=deadline, signature=signature.lower(), **fields,
            )
            decision.struct()  # 해시 형식 확인
        except ValueError as e:
            raise RelayError(RelayErrorCode.INVALID_DECISION, str(e)) from e
        return decision

    async def _submit(self, decision: Decision) -> Decision:
        active = await self._store.get_active(decision.entry_id)
        if active is not None:
            # 이미 진행 중이거나 끝난 결정이 있어도 요청 자체(시한·서명자·롤)는 먼저 확인한다.
            # 확인 없이 돌려주면 다른 승인자나 깨진 서명에도 남의 결정을 성공으로 내준다
            await self._check_request(decision)
            return _same_or_raise(active, decision)

        entry = await self._chain.get_entry(decision.entry_id)
        _check_entry(decision, entry)
        await self._check_request(decision)

        stored, created = await self._store.begin(decision)
        if not created:
            return _same_or_raise(stored, decision)  # 확인하는 사이 다른 요청이 먼저 넣었다

        try:
            if stored.kind == DecisionKind.CONFIRM:
                result = await self._chain.confirm_entry(stored.struct(), stored.signature)
            else:
                result = await self._chain.reject_entry(stored.struct(), stored.signature)
        except ChainNotSent:
            return await self._fail(stored.id, NOT_SENT)  # 체인에 없는 것이 확정. 바로 다시 낼 수 있다
        except ChainUnavailable:
            return stored  # SUBMITTING 으로 두고 reconcile 이 마무리한다
        except ChainRevert as e:
            if e.reason != RevertReason.INVALID_STATUS:
                return await self._fail(stored.id, e.reason.value)
            try:  # 확인한 뒤 보내기 전에 체인에서 결정이 났다. 누가 어떻게 냈는지 본다
                return await self._settle(stored) or await self._fail(stored.id, e.reason.value)
            except ChainUnavailable:
                return stored
        return await self._record(stored.id, result.tx_hash)

    async def _check_request(self, decision: Decision) -> None:
        check_deadline(self._clock(), decision.deadline, self._max_deadline)
        check_signer(self._recover_signer, decision.struct(), decision.signature, decision.approver)
        await check_role(self._roles, decision.approver, APPROVER_ROLES)

    async def _settle(self, decision: Decision) -> Optional[Decision]:
        """체인에서 항목이 결정됐으면 마무리한다. 아직 PENDING 이면 None."""
        entry = await self._chain.get_entry(decision.entry_id)
        if entry is None or entry.status in (EntryStatus.PENDING, EntryStatus.BLOCKED):
            return None
        if entry.status != decision.target_status or entry.approver.lower() != decision.approver.lower():
            return await self._fail(decision.id, DECIDED_ELSEWHERE)
        result = await self._chain.get_decision_result(decision.entry_id)
        if result is None:
            return decision  # 항목은 바뀌었는데 이벤트가 아직 안 읽힌다. 다음 번에 다시 본다
        return await self._record(decision.id, result.tx_hash)

    async def _record(self, decision_id: int, tx_hash: str) -> Decision:
        recorded = await self._store.record(decision_id, tx_hash)
        return recorded or await self._current(decision_id)

    async def _fail(self, decision_id: int, reason: str) -> Decision:
        failed = await self._store.transition(
            decision_id, (DecisionStatus.SUBMITTING,), {"status": DecisionStatus.FAILED, "fail_reason": reason}
        )
        return failed or await self._current(decision_id)

    async def _current(self, decision_id: int) -> Decision:
        decision = await self._store.get(decision_id)
        assert decision is not None, f"결정 {decision_id} 가 저장소에 없다"
        return decision


def _check_entry(decision: Decision, entry: Optional[ChainEntry]) -> None:
    if entry is None:
        raise RelayError(RelayErrorCode.ENTRY_NOT_FOUND, f"id={decision.entry_id}")
    if entry.status != EntryStatus.PENDING:
        raise RelayError(RelayErrorCode.ENTRY_NOT_PENDING, f"id={decision.entry_id} status={entry.status.value}")
    if decision.approver.lower() == entry.registrant.lower():
        raise RelayError(RelayErrorCode.SELF_APPROVAL, f"id={decision.entry_id}")
    if decision.kind == DecisionKind.CONFIRM and decision.hash != entry.hash:
        raise RelayError(RelayErrorCode.HASH_MISMATCH, f"chain={entry.hash} app={decision.hash}")


def _same_or_raise(active: Decision, wanted: Decision) -> Decision:
    """같은 승인자가 같은 내용으로 다시 낸 요청이면 이미 있는 결정을 돌려주고 다시 보내지 않는다.

    다른 승인자이거나 내용이 다르면 (반대 결정 포함) 막는다 — 남의 결정을 자기 결정처럼 돌려주지 않는다.
    """
    same = (
        active.kind == wanted.kind
        and active.approver.lower() == wanted.approver.lower()
        and (active.hash, active.had_warning, active.warning_reason_hash, active.reason_hash)
        == (wanted.hash, wanted.had_warning, wanted.warning_reason_hash, wanted.reason_hash)
    )
    if same:
        return active
    code = RelayErrorCode.ALREADY_DECIDED if active.status == DecisionStatus.RECORDED else RelayErrorCode.DECISION_IN_PROGRESS
    raise RelayError(code, f"id={wanted.entry_id} {active.kind.value} {active.status.value}")
