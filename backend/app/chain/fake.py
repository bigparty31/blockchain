"""FakeChainClient — 체인 없이 등록 API 를 만들고 테스트하기 위한 가짜 구현.

입력만으로 판정할 수 있는 컨트랙트 규칙은 그대로 흉내 낸다 (중복 id, 금액, 정정 대상, 상태, 해시, 시한,
지출의 예산 id 0). 서명자 검증·권한·예산 잔량처럼 실제 체인 상태가 필요한 결과는 fail_next / block_next 로,
연결 실패는 unavailable_next 로 지정한다.

서명자 주소는 서명의 앞 20바이트다. 테스트에서는 fake_signature(address) 로 서명을 만든다.
같은 주소로 만든 서명은 문자열이 매번 달라도 같은 사람이라, 그 서명들로 등록과 확정을 하면 SELF_APPROVAL 이 난다.
주소는 web3.py 처럼 EIP-55 체크섬 형식으로 돌려준다.
"""
import hashlib
import re
import secrets
import time
from typing import Callable, Optional

from eth_utils import to_checksum_address

from app.chain.models import (
    ZERO_ADDRESS,
    BlockReason,
    ChainEntry,
    ChainRevert,
    ChainUnavailable,
    ConfirmApproval,
    RecordRequest,
    RejectDecision,
    RevertReason,
    TxResult,
    check_signature,
)
from app.schemas.entry import EntryKind, EntryStatus

WRITE_METHODS = ("record_pending", "confirm_entry", "reject_entry")

_ADDRESS = re.compile(r"0x[0-9a-fA-F]{40}")


def fake_signature(address: str) -> str:
    """address 가 서명한 것으로 취급되는 가짜 서명. 부를 때마다 다른 문자열이 나온다."""
    if not _ADDRESS.fullmatch(address):
        raise ValueError("주소는 0x + hex 40자여야 한다")
    return "0x" + address[2:].lower() + secrets.token_hex(45)


def _signer(signature: str) -> str:
    return to_checksum_address("0x" + signature[2:42])


def _check_method(method: str) -> None:
    if method not in WRITE_METHODS:
        raise ValueError(f"method 는 {', '.join(WRITE_METHODS)} 중 하나다: {method!r}")


class FakeChainClient:
    def __init__(self, clock: Callable[[], float] = time.time):
        self._clock = clock
        self._entries: dict[int, ChainEntry] = {}
        self._tx_count = 0
        self._fail: dict[str, RevertReason] = {}
        self._unavailable: dict[str, bool] = {}
        self._block: Optional[BlockReason] = None

    # ------------------------------------------------------------ 시나리오 지정

    def fail_next(self, method: str, reason: RevertReason) -> None:
        """다음 한 번의 method 호출을 reason 으로 revert 시킨다. 상태는 바뀌지 않는다."""
        _check_method(method)
        self._fail[method] = reason

    def unavailable_next(self, method: str, landed: bool = False) -> None:
        """다음 한 번의 method 호출을 ChainUnavailable 로 끝낸다.

        landed=False 면 트랜잭션이 체인에 닿지 않아 상태가 그대로다.
        landed=True 면 체인은 평소대로 처리했고(revert 될 입력이면 revert) 응답만 받지 못한 것이다.
        """
        _check_method(method)
        self._unavailable[method] = landed

    def block_next(self, reason: BlockReason = BlockReason.BUDGET_EXCEEDED) -> None:
        """다음 지출(EXPENSE) record_pending 을 BLOCKED 로 저장한다. 수입과 예산 id 0 인 지출에는 적용되지 않는다."""
        self._block = reason

    # ------------------------------------------------------------ ChainClient

    async def record_pending(self, request: RecordRequest, signature: str) -> TxResult:
        signature = check_signature(signature)
        return self._send("record_pending", lambda: self._record(request, signature))

    async def confirm_entry(self, approval: ConfirmApproval, signature: str) -> TxResult:
        signature = check_signature(signature)
        return self._send("confirm_entry", lambda: self._confirm(approval, signature))

    async def reject_entry(self, decision: RejectDecision, signature: str) -> TxResult:
        signature = check_signature(signature)
        return self._send("reject_entry", lambda: self._reject(decision, signature))

    async def get_entry(self, entry_id: int) -> Optional[ChainEntry]:
        return self._entries.get(entry_id)

    # ------------------------------------------------------------ 컨트랙트 흉내

    def _record(self, request: RecordRequest, signature: str) -> TxResult:
        self._precheck("record_pending", request.deadline)
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
        if request.kind == EntryKind.EXPENSE:
            if request.budget_id == 0:
                # 0 은 "없음"으로 예약돼 있어 (docs/HASHING.md §2.1) 체인에서는 존재하지 않는 예산이다
                status, block_reason = EntryStatus.BLOCKED, BlockReason.BUDGET_NOT_FOUND
            elif self._block is not None:
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

    def _confirm(self, approval: ConfirmApproval, signature: str) -> TxResult:
        self._precheck("confirm_entry", approval.deadline)
        entry = self._pending_entry(approval.id)
        if entry.hash != approval.hash:
            raise ChainRevert(RevertReason.HASH_MISMATCH, f"id={approval.id}")
        return self._decide(entry, signature, EntryStatus.CONFIRMED)

    def _reject(self, decision: RejectDecision, signature: str) -> TxResult:
        self._precheck("reject_entry", decision.deadline)
        entry = self._pending_entry(decision.id)
        return self._decide(entry, signature, EntryStatus.REJECTED)

    # ------------------------------------------------------------ 내부

    def _send(self, method: str, apply: Callable[[], TxResult]) -> TxResult:
        """unavailable_next 로 지정된 호출이면 연결 실패를 흉내 낸다."""
        landed = self._unavailable.pop(method, None)
        if landed is None:
            return apply()
        if landed:
            try:
                apply()
            except ChainRevert:
                pass  # 체인에서 revert 됐어도 응답을 못 받았으니 호출한 쪽은 모른다
        raise ChainUnavailable(f"unavailable_next 로 지정 (landed={landed})")

    def _precheck(self, method: str, deadline: int) -> None:
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
