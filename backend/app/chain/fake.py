"""FakeChainClient — 체인 없이 등록 API 를 만들고 테스트하기 위한 가짜 구현.

입력과 이미 기록된 항목만으로 판정할 수 있는 원장 규칙은 IAccountingLedger 의 검사 순서대로 흉내 낸다
(중복 id, 해시, 금액·필드 범위, 수입의 예산 id, 정정 대상·종류·학기·예산·누적 한도, 상태, 해시·entryCommit, 사유, 시한,
지출의 예산 id 0). 서명자 검증·권한·예산(잔량·마감·학기)처럼 실제 체인 상태가 필요한 결과는 fail_next / block_next 로,
연결 실패는 unavailable_next 로 지정한다.

예산 발행·증액도 IBudgetToken 의 검사 순서대로 흉내 낸다. 발행한 예산은 등록·확정의 예산 판정과 이어져 있지 않다 —
원장 쪽은 여전히 block_next·fail_next 로 지정한다. 회장 서명 여부는 fail_next(NOT_PRESIDENT)로만 나고, 증액에서 두 서명자가
같으면 NOT_AUDITOR 다 (한 주소 한 롤이라 회장은 감사가 아니다).

서명자 주소는 서명의 앞 20바이트다. 테스트에서는 fake_signature(address) 로 서명을 만든다.
같은 주소로 만든 서명은 문자열이 매번 달라도 같은 사람이라, 그 서명들로 등록과 확정을 하면 SELF_APPROVAL 이 난다.
실제 체인은 승인 권한(감사·회장)을 먼저 보므로, 지금 총무인 사람이 자기 건을 승인하면 NOT_APPROVER 가 먼저 난다.
롤을 모르는 가짜는 이 둘을 구분하지 못한다 — NOT_APPROVER 는 fail_next 로 지정한다.
주소는 web3.py 처럼 EIP-55 체크섬 형식으로 돌려준다.
"""
import asyncio
import hashlib
import secrets
import time
from typing import Callable, Optional, Tuple, Union

from eth_utils import to_checksum_address

from app.chain.abi import check_address
from app.chain.client import BeforeBroadcast
from app.chain.commit import entry_commit_of
from app.chain.models import (
    MAX_AMOUNT,
    UINT64_MAX,
    ZERO_ADDRESS,
    ZERO_BYTES32,
    BURN_REASON_ORDER,
    MAX_MINT_BATCH,
    BlockReason,
    BudgetRevertReason,
    BudgetTxResult,
    BurnRequest,
    BurnResult,
    MembershipRevertReason,
    MintBatchRequest,
    MintBatchResult,
    MintedMembership,
    ChainBudget,
    ChainEntry,
    EntryTxDetail,
    ChainRevert,
    ChainUnavailable,
    ConfirmApproval,
    IncreaseRequest,
    IssueRequest,
    RecordRequest,
    RejectDecision,
    RevertReason,
    TxResult,
    check_signature,
    check_tx_hash,
)
from app.schemas.entry import EntryKind, EntryStatus

WRITE_METHODS = (
    "record_pending",
    "confirm_entry",
    "reject_entry",
    "issue_budget",
    "increase_budget",
    "mint_memberships",
    "burn_membership_relayed",
)

_BUDGET_METHODS = ("issue_budget", "increase_budget")
_MEMBERSHIP_METHODS = ("mint_memberships", "burn_membership_relayed")
_ZERO_TERM = 0
UINT32_MAX = 2**32 - 1  # Budget.term 의 저장 폭

# 검사를 통과한 쓰기의 (항목 id, 결과, 상태 변경). 상태는 before_broadcast 가 끝난 뒤에 바꾼다. 회원권은 id 자리가 0 이다
Result = Union[TxResult, BudgetTxResult, MintBatchResult, BurnResult]
Prepared = Tuple[int, Result, Callable[[], None]]


def fake_signature(address: str) -> str:
    """address 가 서명한 것으로 취급되는 가짜 서명. 부를 때마다 다른 문자열이 나온다."""
    return "0x" + check_address(address)[2:].lower() + secrets.token_hex(45)


def _signer(signature: str) -> str:
    return to_checksum_address("0x" + signature[2:42])


def _check_method(method: str) -> None:
    if method not in WRITE_METHODS:
        raise ValueError(f"method 는 {', '.join(WRITE_METHODS)} 중 하나다: {method!r}")


class FakeChainClient:
    def __init__(self, clock: Callable[[], float] = time.time):
        self._clock = clock
        self._entries: dict[int, ChainEntry] = {}
        # 정정 가능 항목(원본·재분류 양수 정정)의 순금액. 원장의 netAmountOf 와 같은 규칙으로 갱신한다
        self._net: dict[int, int] = {}
        self._budgets: dict[int, ChainBudget] = {}
        self._memberships: dict[tuple[str, int], int] = {}  # (주소 소문자, 학기 코드) → 유효한 tokenId
        self._membership_count = 0
        self._sbt_nonces: dict[str, int] = {}  # 서명자 주소 소문자 → nonces(signer). 발행·소각이 공유한다
        self._tx_count = 0
        # tx hash 에 섞는 인스턴스별 값. 서버를 다시 켜 새 가짜가 생겨도 DB 에 남은 옛 hash 와 겹치지 않는다 (tx_result)
        self._tx_salt = secrets.token_hex(8)
        self._landed: dict[str, tuple[int, Result]] = {}  # 블록에 들어간 트랜잭션 hash → (id, 결과). tx_result 가 읽는다
        self._blocks: dict[str, int] = {}  # 트랜잭션 hash → 블록 번호. 들어간 순서대로 하나씩 오른다 (entry_tx_detail)
        self._reasons: dict[str, tuple[Optional[str], bool]] = {}  # 트랜잭션 hash → (사유 해시, 경고 승인 여부)
        self._fail: dict[str, Union[RevertReason, BudgetRevertReason, MembershipRevertReason]] = {}
        self._unavailable: dict[str, tuple[bool, bool]] = {}  # method → (sent, landed)
        self._send_lock: Optional[asyncio.Lock] = None
        self._lock_loop: Optional[asyncio.AbstractEventLoop] = None
        self._lock_owner: Optional[asyncio.Task] = None
        self._block: Optional[BlockReason] = None

    # ------------------------------------------------------------ 시나리오 지정

    def fail_next(self, method: str, reason: Union[RevertReason, BudgetRevertReason, MembershipRevertReason]) -> None:
        """다음 한 번의 method 호출을 reason 으로 revert 시킨다. 상태는 바뀌지 않는다."""
        _check_method(method)
        self._fail[method] = reason

    def unavailable_next(self, method: str, landed: bool = False, sent: bool = True) -> None:
        """다음 한 번의 method 호출을 ChainUnavailable 로 끝낸다. 실제 구현에서 연결이 끊기는 두 시점을 흉내 낸다.

        sent=False — 보내기 전(시뮬레이션·nonce 조회 중)에 끊겼다. before_broadcast 는 불리지 않고 상태도 그대로다.
                     tx_pending 을 선점하지 않은 채로 ChainUnavailable 이 오는 경로다.
        sent=True  — 보낸 뒤 응답을 못 받았다. before_broadcast 는 불린다. landed=True 면 체인에 기록됐고,
                     False 면 닿지 않았다. revert 할 입력은 실제처럼 시뮬레이션에서 ChainRevert 로 먼저 끝난다.
        지정은 그 단계에 실제로 도달한 호출이 쓴다 — 검사에서 걸리거나 콜백이 실패한 호출은 지정을 남긴다.
        """
        _check_method(method)
        if landed and not sent:
            raise ValueError("보내지 않은 트랜잭션은 체인에 기록될 수 없다 (sent=False 면 landed=False)")
        self._unavailable[method] = (sent, landed)

    def block_next(self, reason: BlockReason = BlockReason.BUDGET_EXCEEDED) -> None:
        """다음 양수 지출(EXPENSE) record_pending 을 BLOCKED 로 저장한다.

        수입, 예산 id 0 인 지출, 음수 정정(환불은 예산 판정을 건너뛴다)에는 적용되지 않는다.
        """
        self._block = reason

    # ------------------------------------------------------------ ChainClient

    def signer_of(
        self,
        payload: Union[
            RecordRequest, ConfirmApproval, RejectDecision, IssueRequest, IncreaseRequest, MintBatchRequest, BurnRequest
        ],
        signature: str,
    ) -> str:
        """fake_signature 가 담은 주소. payload 는 보지 않는다 — 가짜 서명은 값에 묶여 있지 않다."""
        return _signer(check_signature(signature))

    async def record_pending(
        self, request: RecordRequest, signature: str, before_broadcast: Optional[BeforeBroadcast] = None
    ) -> TxResult:
        signature = check_signature(signature)
        return await self._send("record_pending", lambda tx: self._record(request, signature, tx), before_broadcast)

    async def confirm_entry(
        self, approval: ConfirmApproval, signature: str, before_broadcast: Optional[BeforeBroadcast] = None
    ) -> TxResult:
        signature = check_signature(signature)
        return await self._send("confirm_entry", lambda tx: self._confirm(approval, signature, tx), before_broadcast)

    async def reject_entry(
        self, decision: RejectDecision, signature: str, before_broadcast: Optional[BeforeBroadcast] = None
    ) -> TxResult:
        signature = check_signature(signature)
        return await self._send("reject_entry", lambda tx: self._reject(decision, signature, tx), before_broadcast)

    async def entry_tx_detail(self, tx_hash: str, entry_id: int) -> Optional[EntryTxDetail]:
        result = await self.tx_result(tx_hash, entry_id)
        if result is None:
            return None
        reason_hash, had_warning = self._reasons.get(result.tx_hash, (None, False))
        return EntryTxDetail(
            tx_hash=result.tx_hash,
            status=result.status,
            block_number=self._blocks[result.tx_hash],
            block_reason=result.block_reason,
            reason_hash=reason_hash,
            had_warning=had_warning,
        )

    async def get_entry(self, entry_id: int) -> Optional[ChainEntry]:
        return self._entries.get(entry_id)

    async def tx_result(self, tx_hash: str, entry_id: int) -> Optional[TxResult]:
        """들어간 트랜잭션의 결과. 검사에서 걸렸거나(보내지 않음) unavailable_next(landed=False) 로 닿지 않은 hash 는 None.

        가짜의 revert 는 모두 보내기 전(검사)에 나서, 블록에 들어가 실패로 끝난 트랜잭션(ChainRevert)은 만들지 않는다.
        """
        landed = self._landed.get(check_tx_hash(tx_hash))
        if landed is None:
            return None
        landed_id, result = landed
        if landed_id != entry_id or not isinstance(result, TxResult):
            raise ChainUnavailable(f"결과 이벤트를 찾지 못했다 — 이 트랜잭션은 id={landed_id} 의 것이다 (tx={tx_hash})")
        return result

    async def issue_budget(
        self, request: IssueRequest, signature: str, before_broadcast: Optional[BeforeBroadcast] = None
    ) -> BudgetTxResult:
        check_signature(signature)
        return await self._send("issue_budget", lambda tx: self._issue(request, tx), before_broadcast)

    async def increase_budget(
        self,
        request: IncreaseRequest,
        requester_signature: str,
        approver_signature: str,
        before_broadcast: Optional[BeforeBroadcast] = None,
    ) -> BudgetTxResult:
        requester, approver = check_signature(requester_signature), check_signature(approver_signature)
        return await self._send("increase_budget", lambda tx: self._increase(request, requester, approver, tx), before_broadcast)

    async def budget_tx_result(self, tx_hash: str, budget_id: int) -> Optional[BudgetTxResult]:
        landed = self._landed.get(check_tx_hash(tx_hash))
        if landed is None:
            return None
        landed_id, result = landed
        if landed_id != budget_id or not isinstance(result, BudgetTxResult):
            raise ChainUnavailable(f"결과 이벤트를 찾지 못했다 — 이 트랜잭션은 id={landed_id} 의 것이다 (tx={tx_hash})")
        return result

    async def get_budget(self, budget_id: int) -> Optional[ChainBudget]:
        return self._budgets.get(budget_id)

    async def budget_id_of(self, term: int, category: str) -> int:
        for budget in self._budgets.values():
            if (budget.term, budget.category) == (term, category):
                return budget.id
        return 0

    # ------------------------------------------------------------ 회원권 (MembershipSBT)
    # 릴레이(mint_memberships·burn_membership_relayed)는 IMembershipSBT 를 흉내 낸다. 서명자가 회장·감사인지는 롤을 몰라
    # fail_next(NOT_APPROVER)로만 난다. 테스트는 grant_membership·burn_membership 으로 서명 없이 체인 상태를 만들 수도 있다
    # (nonce 는 오르지 않는다)

    def grant_membership(self, account: str, term: int) -> int:
        """(account, term) 에 회원권을 발행한 것으로 둔다. 이미 유효하면 그 tokenId 를 돌려준다 (컨트랙트의 건너뛰기와 같다)."""
        key = (check_address(account).lower(), term)
        if key not in self._memberships:
            self._membership_count += 1
            self._memberships[key] = self._membership_count
        return self._memberships[key]

    def burn_membership(self, account: str, term: int) -> None:
        """(account, term) 의 회원권을 소각한 것으로 둔다. 소각하면 tokenOf 가 0 이 된다."""
        self._memberships.pop((check_address(account).lower(), term), None)

    async def has_valid_membership(self, account: str, term: int) -> bool:
        return (check_address(account).lower(), term) in self._memberships

    async def membership_token_of(self, account: str, term: int) -> int:
        return self._memberships.get((check_address(account).lower(), term), 0)

    async def membership_nonce(self, signer: str) -> int:
        return self._sbt_nonces.get(check_address(signer).lower(), 0)

    async def mint_memberships(
        self, request: MintBatchRequest, signature: str, before_broadcast: Optional[BeforeBroadcast] = None
    ) -> MintBatchResult:
        signature = check_signature(signature)
        return await self._send("mint_memberships", lambda tx: self._mint(request, signature, tx), before_broadcast)

    async def mint_tx_result(self, tx_hash: str) -> Optional[MintBatchResult]:
        landed = self._landed.get(check_tx_hash(tx_hash))
        if landed is None:
            return None
        result = landed[1]
        if not isinstance(result, MintBatchResult):
            raise ChainUnavailable(f"결과 이벤트를 찾지 못했다 — 회원권 발행 트랜잭션이 아니다 (tx={tx_hash})")
        return result

    async def burn_membership_relayed(
        self, request: BurnRequest, signature: str, before_broadcast: Optional[BeforeBroadcast] = None
    ) -> BurnResult:
        signature = check_signature(signature)
        return await self._send("burn_membership_relayed", lambda tx: self._burn(request, signature, tx), before_broadcast)

    # ------------------------------------------------------------ 컨트랙트 흉내

    def _record(self, r: RecordRequest, signature: str, tx_hash: str) -> Prepared:
        # 1 시한 (fail_next 도 여기서 난다)
        self._precheck("record_pending", r.deadline)
        # 2~5 입력 자체. id 0·term 형식은 RecordRequest 가 먼저 막는다
        if r.id > UINT64_MAX:
            raise ChainRevert(RevertReason.FIELD_OUT_OF_RANGE, f"id={r.id}")
        if r.id in self._entries:
            raise ChainRevert(RevertReason.ENTRY_ALREADY_EXISTS, f"id={r.id}")
        if r.hash == ZERO_BYTES32:
            raise ChainRevert(RevertReason.HASH_REQUIRED, f"id={r.id}")
        if r.amount == 0:
            raise ChainRevert(RevertReason.ZERO_AMOUNT)
        if abs(r.amount) > MAX_AMOUNT:
            raise ChainRevert(RevertReason.AMOUNT_OUT_OF_RANGE, f"amount={r.amount}")
        if r.amount < 0 and r.corrects_id == 0:
            raise ChainRevert(RevertReason.NEGATIVE_AMOUNT_WITHOUT_CORRECTION)
        for name in ("occurred_at", "budget_id", "corrects_id"):
            if getattr(r, name) > UINT64_MAX:
                raise ChainRevert(RevertReason.FIELD_OUT_OF_RANGE, f"{name}={getattr(r, name)}")
        # 6 NotRegistrant 는 롤을 알아야 해서 fail_next 로만 난다
        # 7 수입에는 예산이 없다
        if r.kind == EntryKind.INCOME and r.budget_id != 0:
            raise ChainRevert(RevertReason.BUDGET_ID_NOT_ALLOWED_FOR_INCOME, f"budget_id={r.budget_id}")
        # 8 정정 대상
        if r.corrects_id:
            self._check_correction(r)
        # 9 예산 term 대조는 예산 상태가 필요해 fail_next 로만 난다
        # 10 양수 지출의 예산 판정. 음수 정정(환불)은 건너뛴다
        status, block_reason, uses_block_next = EntryStatus.PENDING, None, False
        if r.kind == EntryKind.EXPENSE and r.amount > 0:
            if r.budget_id == 0:
                # 0 은 "없음"으로 예약돼 있어 (docs/HASHING.md §2.1) 체인에서는 존재하지 않는 예산이다
                status, block_reason = EntryStatus.BLOCKED, BlockReason.BUDGET_NOT_FOUND
            elif self._block is not None:
                status, block_reason, uses_block_next = EntryStatus.BLOCKED, self._block, True

        entry = ChainEntry(
            id=r.id,
            hash=r.hash,
            amount=r.amount,
            kind=r.kind,
            status=status,
            term=r.term,
            occurred_at=r.occurred_at,
            budget_id=r.budget_id,
            corrects_id=r.corrects_id,
            registrant=_signer(signature),
            approver=ZERO_ADDRESS,
        )

        def commit() -> None:
            self._entries[r.id] = entry
            if uses_block_next:  # 보내지 않았으면(콜백 실패) 다음 지출에 그대로 남는다
                self._block = None

        return r.id, TxResult(tx_hash=tx_hash, status=status, block_reason=block_reason), commit

    def _check_correction(self, r: RecordRequest) -> None:
        target = self._entries.get(r.corrects_id)
        if target is None:
            raise ChainRevert(RevertReason.CORRECTION_TARGET_NOT_FOUND, f"corrects_id={r.corrects_id}")
        if target.status != EntryStatus.CONFIRMED:
            raise ChainRevert(RevertReason.CORRECTION_TARGET_NOT_CONFIRMED, f"corrects_id={r.corrects_id}")
        if target.kind != r.kind:
            raise ChainRevert(RevertReason.CORRECTION_KIND_MISMATCH, f"expected={target.kind.value}")
        if target.term != r.term:
            raise ChainRevert(RevertReason.TERM_MISMATCH, f"expected={target.term} actual={r.term}")
        if not self._is_correctable(target):
            raise ChainRevert(RevertReason.INVALID_CORRECTION_TARGET, f"corrects_id={r.corrects_id}")
        if r.amount < 0:
            if target.budget_id != r.budget_id:
                raise ChainRevert(RevertReason.CORRECTION_BUDGET_MISMATCH, f"expected={target.budget_id}")
            self._check_cap(r.corrects_id, r.amount)

    def _confirm(self, a: ConfirmApproval, signature: str, tx_hash: str) -> Prepared:
        self._precheck("confirm_entry", a.deadline)
        entry = self._pending_entry(a.id)
        if entry.hash != a.hash:
            raise ChainRevert(RevertReason.HASH_MISMATCH, f"id={a.id}")
        self._check_commit(entry, a.entry_commit)
        if a.had_warning and a.warning_reason_hash == ZERO_BYTES32:
            raise ChainRevert(RevertReason.REASON_REQUIRED, f"id={a.id} (경고 승인에 사유 없음)")
        if not a.had_warning and a.warning_reason_hash != ZERO_BYTES32:
            raise ChainRevert(RevertReason.REASON_NOT_ALLOWED, f"id={a.id}")
        approver = self._approver(entry, signature)
        # 음수 정정: 대기 중 다른 정정이 먼저 확정됐을 수 있어 확정 시점에 다시 검사한다
        if entry.corrects_id and entry.amount < 0:
            self._check_cap(entry.corrects_id, entry.amount)
        # 예산 소모(spend)·환불(refund) 실패는 예산 상태가 필요해 fail_next 로만 난다

        def commit() -> None:
            self._entries[entry.id] = entry.model_copy(update={"status": EntryStatus.CONFIRMED, "approver": approver})
            self._update_net(entry)
            self._spend(entry)
            if a.had_warning:
                self._reasons[tx_hash] = (a.warning_reason_hash, True)

        return entry.id, TxResult(tx_hash=tx_hash, status=EntryStatus.CONFIRMED), commit

    def _spend(self, entry: ChainEntry) -> None:
        """확정된 지출을 예산에 반영한다. 원장이 부르는 BudgetToken.spend·refund 와 같은 계산이다 (음수 정정은 되돌린다).

        발행하지 않은 예산은 건너뛴다 — 가짜의 원장 시나리오는 예산 발행 없이 budget_id 만 쓰기도 한다.
        """
        budget = self._budgets.get(entry.budget_id)
        if entry.kind is EntryKind.EXPENSE and budget is not None:
            self._budgets[budget.id] = budget.model_copy(update={"spent": budget.spent + entry.amount})

    def _reject(self, d: RejectDecision, signature: str, tx_hash: str) -> Prepared:
        self._precheck("reject_entry", d.deadline)
        entry = self._pending_entry(d.id)
        self._check_commit(entry, d.entry_commit)
        if d.reason_hash == ZERO_BYTES32:
            raise ChainRevert(RevertReason.REASON_REQUIRED, f"id={d.id} (반려 사유 없음)")
        approver = self._approver(entry, signature)

        def commit() -> None:
            self._entries[entry.id] = entry.model_copy(update={"status": EntryStatus.REJECTED, "approver": approver})
            self._reasons[tx_hash] = (d.reason_hash, False)

        return entry.id, TxResult(tx_hash=tx_hash, status=EntryStatus.REJECTED), commit

    def _issue(self, r: IssueRequest, tx_hash: str) -> Prepared:
        # BudgetToken.issue 의 검사 순서. NotPresident 는 롤을 알아야 해서 fail_next 로만 난다
        self._precheck("issue_budget", r.deadline)
        now = int(self._clock())
        if r.budget_id == 0:
            raise ChainRevert(BudgetRevertReason.RESERVED_ID, f"budgetId={r.budget_id}")
        if r.budget_id > UINT64_MAX:
            raise ChainRevert(BudgetRevertReason.FIELD_OUT_OF_RANGE, f"budgetId={r.budget_id}")
        if r.budget_id in self._budgets:
            raise ChainRevert(BudgetRevertReason.BUDGET_ALREADY_EXISTS, f"budgetId={r.budget_id}")
        if r.term == 0:
            raise ChainRevert(BudgetRevertReason.TERM_REQUIRED)
        if r.term > UINT32_MAX:
            raise ChainRevert(BudgetRevertReason.FIELD_OUT_OF_RANGE, f"term={r.term}")
        if r.category == ZERO_BYTES32:
            raise ChainRevert(BudgetRevertReason.CATEGORY_REQUIRED)
        if r.amount == 0:
            raise ChainRevert(BudgetRevertReason.ZERO_AMOUNT)
        if r.amount > MAX_AMOUNT:
            raise ChainRevert(BudgetRevertReason.AMOUNT_OUT_OF_RANGE, f"amount={r.amount}")
        if r.expires_at > UINT64_MAX:
            raise ChainRevert(BudgetRevertReason.FIELD_OUT_OF_RANGE, f"expiresAt={r.expires_at}")
        if r.expires_at <= now:
            raise ChainRevert(BudgetRevertReason.BUDGET_EXPIRED, f"budgetId={r.budget_id} expiresAt={r.expires_at}")
        for existing in self._budgets.values():
            if (existing.term, existing.category) == (r.term, r.category):
                raise ChainRevert(BudgetRevertReason.BUDGET_ALREADY_ISSUED, f"existingBudgetId={existing.id}")
        budget = ChainBudget(
            id=r.budget_id,
            term=r.term,
            category=r.category,
            issued=r.amount,
            spent=0,
            expires_at=r.expires_at,
            version=1,
            reclaim_count=0,
        )

        def commit() -> None:
            self._budgets[r.budget_id] = budget

        return r.budget_id, BudgetTxResult(tx_hash=tx_hash, budget_id=r.budget_id, version=1), commit

    def _increase(self, r: IncreaseRequest, requester: str, approver: str, tx_hash: str) -> Prepared:
        # BudgetToken.increase 의 검사 순서
        self._precheck("increase_budget", r.deadline)
        if _signer(requester) == _signer(approver):
            raise ChainRevert(BudgetRevertReason.NOT_AUDITOR, f"signer={_signer(approver)}")
        budget = self._budgets.get(r.budget_id)
        if budget is None:
            raise ChainRevert(BudgetRevertReason.BUDGET_NOT_FOUND, f"budgetId={r.budget_id}")
        if r.version != budget.version:
            raise ChainRevert(BudgetRevertReason.VERSION_MISMATCH, f"expected={budget.version} actual={r.version}")
        if int(self._clock()) > budget.expires_at:
            raise ChainRevert(BudgetRevertReason.BUDGET_EXPIRED, f"budgetId={r.budget_id} expiresAt={budget.expires_at}")
        if r.reason_hash == ZERO_BYTES32:
            raise ChainRevert(BudgetRevertReason.REASON_REQUIRED)
        if r.amount == 0:
            raise ChainRevert(BudgetRevertReason.ZERO_AMOUNT)
        issued = budget.issued + r.amount
        if r.amount > MAX_AMOUNT or issued > MAX_AMOUNT:
            raise ChainRevert(BudgetRevertReason.AMOUNT_OUT_OF_RANGE, f"amount={max(r.amount, issued)}")
        version = budget.version + 1

        def commit() -> None:
            self._budgets[r.budget_id] = budget.model_copy(update={"issued": issued, "version": version})

        return r.budget_id, BudgetTxResult(tx_hash=tx_hash, budget_id=r.budget_id, version=version), commit

    # ------------------------------------------------------------ 내부

    def _check_sbt_nonce(self, signer: str, nonce: int) -> None:
        expected = self._sbt_nonces.get(signer.lower(), 0)
        if nonce != expected:
            raise ChainRevert(MembershipRevertReason.INVALID_NONCE, f"expected={expected} actual={nonce}")

    def _mint(self, r: MintBatchRequest, signature: str, tx_hash: str) -> Prepared:
        # IMembershipSBT.mintBatchRelayed. 배치 전체 revert 값은 모델이 막지만 model_copy 로 건너뛴 시험을 위해 다시 본다
        self._precheck("mint_memberships", r.deadline)
        signer = _signer(signature)
        self._check_sbt_nonce(signer, r.nonce)
        if not r.recipients:
            raise ChainRevert(MembershipRevertReason.EMPTY_BATCH)
        if len(r.recipients) > MAX_MINT_BATCH:
            raise ChainRevert(MembershipRevertReason.BATCH_TOO_LARGE, f"size={len(r.recipients)}")
        if r.term == _ZERO_TERM:
            raise ChainRevert(MembershipRevertReason.TERM_REQUIRED)
        if any(a.lower() == ZERO_ADDRESS for a in r.recipients):
            raise ChainRevert(MembershipRevertReason.ZERO_ADDRESS)
        minted, skipped, seen = [], [], set()
        next_id = self._membership_count
        for address in r.recipients:
            key = (address.lower(), r.term)
            if key in self._memberships or key in seen:
                skipped.append(to_checksum_address(address))  # 같은 배치의 중복도 건너뛴다
                continue
            seen.add(key)
            next_id += 1
            minted.append(MintedMembership(address=to_checksum_address(address), token_id=next_id))
        result = MintBatchResult(tx_hash=tx_hash, signer=signer, minted=tuple(minted), skipped=tuple(skipped))

        def commit() -> None:
            for m in minted:
                self._memberships[(m.address.lower(), r.term)] = m.token_id
            self._membership_count = next_id
            self._sbt_nonces[signer.lower()] = r.nonce + 1  # 전부 건너뛰어도 nonce 는 쓴다

        return 0, result, commit

    def _burn(self, r: BurnRequest, signature: str, tx_hash: str) -> Prepared:
        # IMembershipSBT.burnRelayed
        self._precheck("burn_membership_relayed", r.deadline)
        signer = _signer(signature)
        self._check_sbt_nonce(signer, r.nonce)
        if r.term == _ZERO_TERM:
            raise ChainRevert(MembershipRevertReason.TERM_REQUIRED)
        if r.holder.lower() == ZERO_ADDRESS:
            raise ChainRevert(MembershipRevertReason.ZERO_ADDRESS)
        if r.reason not in BURN_REASON_ORDER:
            raise ChainRevert(MembershipRevertReason.INVALID_BURN_REASON, f"reason={r.reason}")
        key = (r.holder.lower(), r.term)
        token_id = self._memberships.get(key)
        if token_id is None:
            raise ChainRevert(MembershipRevertReason.NO_MEMBERSHIP, f"holder={r.holder} term={r.term}")
        result = BurnResult(tx_hash=tx_hash, holder=to_checksum_address(r.holder), token_id=token_id, reason=r.reason, signer=signer)

        def commit() -> None:
            del self._memberships[key]  # tokenOf 를 비워 같은 학기 재발행을 허용한다
            self._sbt_nonces[signer.lower()] = r.nonce + 1

        return 0, result, commit

    async def _send(
        self, method: str, prepare: Callable[[str], Prepared], before_broadcast: Optional[BeforeBroadcast]
    ) -> Result:
        """검사 → before_broadcast → 상태 변경. 실제 구현의 시뮬레이션 → 콜백 → 전송 순서와 같다.

        실제 구현은 릴레이어 lock 안에서 시뮬레이션부터 receipt 까지 하므로, 같은 id 를 동시에 보내면 두 번째는
        ENTRY_ALREADY_EXISTS 다. 가짜도 lock 안에서 한 줄로 처리해 콜백이 await 하는 동안 다른 호출이 끼어들지 못한다.
        검사에서 걸리면(revert) 콜백 없이 끝나고, 콜백이 예외를 던지면 상태와 지정(block_next·unavailable_next)이 그대로다.
        """
        # 콜백은 lock 을 쥔 채 불린다. 그 안에서 다시 쓰면 실제 구현처럼 바로 오류다 (기다리면 영원히 멈춘다)
        if self._lock_owner is asyncio.current_task():
            raise RuntimeError(
                "before_broadcast 안에서 같은 릴레이어로 보내거나 닫을 수 없다 — 릴레이어 lock 을 쥔 채 불려 영원히 기다린다"
            )
        async with self._lock():
            self._lock_owner = asyncio.current_task()
            try:
                return await self._send_locked(method, prepare, before_broadcast)
            finally:
                self._lock_owner = None

    async def _send_locked(
        self, method: str, prepare: Callable[[str], Prepared], before_broadcast: Optional[BeforeBroadcast]
    ) -> Result:
        scenario = self._unavailable.get(method)
        if scenario is not None and not scenario[0]:
            del self._unavailable[method]
            raise ChainUnavailable("unavailable_next 로 지정 (보내기 전)")
        tx_hash = self._next_tx()
        entry_id, result, commit = prepare(tx_hash)
        if before_broadcast is not None:
            await before_broadcast(tx_hash)
        if scenario is not None:
            del self._unavailable[method]
            landed = scenario[1]
            if landed:
                self._land(tx_hash, entry_id, result, commit)
            raise ChainUnavailable(f"unavailable_next 로 지정 (보낸 뒤, landed={landed})")
        self._land(tx_hash, entry_id, result, commit)
        return result

    def _land(self, tx_hash: str, entry_id: int, result: Result, commit: Callable[[], None]) -> None:
        """블록에 들어갔다 — 상태를 바꾸고 결과를 hash 로 남긴다 (tx_result)."""
        commit()
        self._landed[tx_hash] = (entry_id, result)
        self._blocks[tx_hash] = len(self._blocks) + 1

    def _lock(self) -> asyncio.Lock:
        # asyncio.Lock 은 처음 경합한 이벤트 루프에 묶인다. 테스트마다 루프가 바뀌니(asyncio.run) 루프별로 만든다
        loop = asyncio.get_running_loop()
        if self._send_lock is None or self._lock_loop is not loop:
            self._send_lock, self._lock_loop = asyncio.Lock(), loop
        return self._send_lock

    def _precheck(self, method: str, deadline: int) -> None:
        forced = self._fail.pop(method, None)
        if forced is not None:
            raise ChainRevert(forced, "fail_next 로 지정")
        # 컨트랙트는 초 단위 정수 block.timestamp > deadline 로 본다. 소수점 시각과 비교하면 같은 초가 만료로 잡힌다
        if deadline < int(self._clock()):
            expired = (
                BudgetRevertReason
                if method in _BUDGET_METHODS
                else MembershipRevertReason if method in _MEMBERSHIP_METHODS else RevertReason
            )
            raise ChainRevert(expired.SIGNATURE_EXPIRED, f"deadline={deadline}")

    def _pending_entry(self, entry_id: int) -> ChainEntry:
        entry = self._entries.get(entry_id)
        if entry is None:
            raise ChainRevert(RevertReason.ENTRY_NOT_FOUND, f"id={entry_id}")
        if entry.status != EntryStatus.PENDING:
            raise ChainRevert(RevertReason.INVALID_STATUS, f"id={entry_id} status={entry.status.value}")
        return entry

    def _check_commit(self, entry: ChainEntry, signed: str) -> None:
        expected = entry_commit_of(entry)
        if signed != expected:
            raise ChainRevert(RevertReason.ENTRY_COMMIT_MISMATCH, f"id={entry.id} expected={expected}")

    def _approver(self, entry: ChainEntry, signature: str) -> str:
        signer = _signer(signature)
        if signer == entry.registrant:
            raise ChainRevert(RevertReason.SELF_APPROVAL, f"id={entry.id}")
        return signer

    def _is_correctable(self, entry: ChainEntry) -> bool:
        """정정 대상이 될 수 있는가: 원본이거나, 원본과 다른 예산으로 간 양수 정정(재분류)."""
        if entry.corrects_id == 0:
            return True
        return entry.amount > 0 and entry.budget_id != self._entries[entry.corrects_id].budget_id

    def _check_cap(self, corrects_id: int, amount: int) -> None:
        net = self._net.get(corrects_id, 0)
        if abs(amount) > net:
            raise ChainRevert(RevertReason.CORRECTION_EXCEEDS_ORIGINAL, f"net={net} requested={abs(amount)}")

    def _update_net(self, entry: ChainEntry) -> None:
        """원장의 순금액 갱신과 같다. 같은 예산 정정만 대상 순금액에 반영하고, 재분류 양수 정정은 자기 순금액을 갖는다."""
        if entry.amount > 0 and self._is_correctable(entry):
            self._net[entry.id] = entry.amount
        if entry.corrects_id and self._entries[entry.corrects_id].budget_id == entry.budget_id:
            self._net[entry.corrects_id] = self._net.get(entry.corrects_id, 0) + entry.amount

    def _next_tx(self) -> str:
        self._tx_count += 1
        return "0x" + hashlib.sha256(f"fake-tx-{self._tx_salt}-{self._tx_count}".encode()).hexdigest()
