"""FakeChainClient — 체인 없이 등록 API 를 만들고 테스트하기 위한 가짜 구현.

입력만으로 판정할 수 있는 컨트랙트 규칙은 그대로 흉내 낸다 (중복 id, 금액, 정정 대상, 상태, 해시, 시한).
서명자 검증·권한·예산 잔량처럼 실제 체인 상태가 필요한 결과는 fail_next / block_next 로 지정한다.

서명자 주소는 서명 문자열에서 결정적으로 만든다. 같은 서명 문자열로 등록과 확정을 하면
SELF_APPROVAL 이 나고, 다른 문자열이면 서로 다른 사람으로 취급한다.
"""
import hashlib
import time
from typing import Callable, Optional

from app.chain.models import (
    ZERO_ADDRESS,
    BlockReason,
    ChainEntry,
    ChainRevert,
    ConfirmApproval,
    RecordRequest,
    RejectDecision,
    RevertReason,
    TxResult,
    check_signature,
)
from app.schemas.entry import EntryKind, EntryStatus


def _signer(signature: str) -> str:
    return "0x" + hashlib.sha256(signature.encode()).hexdigest()[:40]


class FakeChainClient:
    def __init__(self, clock: Callable[[], float] = time.time):
        self._clock = clock
        self._entries: dict[int, ChainEntry] = {}
        self._tx_count = 0
        self._fail: dict[str, RevertReason] = {}
        self._block: Optional[BlockReason] = None

    # ------------------------------------------------------------ 시나리오 지정

    def fail_next(self, method: str, reason: RevertReason) -> None:
        """다음 한 번의 method 호출을 reason 으로 revert 시킨다. 상태는 바뀌지 않는다."""
        self._fail[method] = reason

    def block_next(self, reason: BlockReason = BlockReason.BUDGET_EXCEEDED) -> None:
        """다음 지출(EXPENSE) record_pending 을 BLOCKED 로 저장한다. 수입에는 적용되지 않는다."""
        self._block = reason

    # ------------------------------------------------------------ ChainClient

    async def record_pending(self, request: RecordRequest, signature: str) -> TxResult:
        self._precheck("record_pending", signature, request.deadline)
        if request.id in self._entries:
            raise ChainRevert(RevertReason.ENTRY_ALREADY_EXISTS, f"id={request.id}")
        if request.amount == 0:
            raise ChainRevert(RevertReason.ZERO_AMOUNT)
        if request.amount < 0 and request.corrects_id == 0:
            raise ChainRevert(RevertReason.NEGATIVE_AMOUNT_WITHOUT_CORRECTION)
        if request.corrects_id:
            target = self._entries.get(request.corrects_id)
            if target is None:
                raise ChainRevert(RevertReason.CORRECTION_TARGET_NOT_FOUND, f"corrects_id={request.corrects_id}")
            if target.status != EntryStatus.CONFIRMED:
                raise ChainRevert(RevertReason.CORRECTION_TARGET_NOT_CONFIRMED, f"corrects_id={request.corrects_id}")

        status, block_reason = EntryStatus.PENDING, None
        if self._block is not None and request.kind == EntryKind.EXPENSE:
            status, block_reason, self._block = EntryStatus.BLOCKED, self._block, None

        self._entries[request.id] = ChainEntry(
            id=request.id,
            hash=request.hash,
            amount=request.amount,
            kind=request.kind,
            status=status,
            occurred_at=request.occurred_at,
            budget_id=request.budget_id,
            corrects_id=request.corrects_id,
            registrant=_signer(signature),
            approver=ZERO_ADDRESS,
        )
        return TxResult(tx_hash=self._next_tx(), status=status, block_reason=block_reason)

    async def confirm_entry(self, approval: ConfirmApproval, signature: str) -> TxResult:
        self._precheck("confirm_entry", signature, approval.deadline)
        entry = self._pending_entry(approval.id)
        if entry.hash != approval.hash:
            raise ChainRevert(RevertReason.HASH_MISMATCH, f"id={approval.id}")
        return self._decide(entry, signature, EntryStatus.CONFIRMED)

    async def reject_entry(self, decision: RejectDecision, signature: str) -> TxResult:
        self._precheck("reject_entry", signature, decision.deadline)
        entry = self._pending_entry(decision.id)
        return self._decide(entry, signature, EntryStatus.REJECTED)

    async def get_entry(self, entry_id: int) -> Optional[ChainEntry]:
        return self._entries.get(entry_id)

    # ------------------------------------------------------------ 내부

    def _precheck(self, method: str, signature: str, deadline: int) -> None:
        check_signature(signature)
        forced = self._fail.pop(method, None)
        if forced is not None:
            raise ChainRevert(forced, "fail_next 로 지정")
        if deadline < self._clock():
            raise ChainRevert(RevertReason.SIGNATURE_EXPIRED, f"deadline={deadline}")

    def _pending_entry(self, entry_id: int) -> ChainEntry:
        entry = self._entries.get(entry_id)
        if entry is None:
            raise ChainRevert(RevertReason.ENTRY_NOT_FOUND, f"id={entry_id}")
        if entry.status != EntryStatus.PENDING:
            raise ChainRevert(RevertReason.INVALID_STATUS, f"id={entry_id} status={entry.status.value}")
        return entry

    def _decide(self, entry: ChainEntry, signature: str, status: EntryStatus) -> TxResult:
        signer = _signer(signature)
        if signer == entry.registrant:
            raise ChainRevert(RevertReason.SELF_APPROVAL, f"id={entry.id}")
        self._entries[entry.id] = entry.model_copy(update={"status": status, "approver": signer})
        return TxResult(tx_hash=self._next_tx(), status=status)

    def _next_tx(self) -> str:
        self._tx_count += 1
        return "0x" + hashlib.sha256(f"fake-tx-{self._tx_count}".encode()).hexdigest()
