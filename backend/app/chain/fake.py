"""FakeChainClient — 체인 없이 API 를 만들고 테스트하기 위한 가짜 체인.

ChainClient·LedgerEvents·RoleReader·ObjectionClient·MembershipReader·BudgetReader 를 한 객체로 흉내 낸다.

입력만으로 판정할 수 있는 컨트랙트 규칙은 그대로 흉내 낸다 (중복 id, 금액, 정정 대상, 상태, 해시, 시한,
지출의 예산 id 0, 이의 중복·대상·답변 여부). 예산 잔량·학기 회원 여부처럼 실제 체인 상태가 필요한 결과는
fail_next / block_next 로, 연결 실패는 unavailable_next·not_sent_next 로 지정한다. 롤은 grant_role 로 주고,
enforce_roles=True 일 때만 서명자 롤을 검사한다 (기본은 검사하지 않는다).

서명자 주소는 서명의 앞 20바이트다. 테스트에서는 fake_signature(address) 로 서명을 만든다.
같은 주소로 만든 서명은 문자열이 매번 달라도 같은 사람이라, 그 서명들로 등록과 확정을 하면 SELF_APPROVAL 이 난다.
서버가 체인에 보내기 전에 서명자를 확인하는 곳(eip712.recover_signer)에는 fake_recover_signer 를 대신 넣는다.
주소는 web3.py 처럼 EIP-55 체크섬 형식으로 돌려준다. 트랜잭션 하나가 블록 하나다.
"""
import hashlib
import secrets
import time
from typing import Callable, Optional, TypeVar

from eth_utils import to_checksum_address

from app.chain.models import (
    APPROVER_ROLES,
    RESPONDER_ROLES,
    ZERO_ADDRESS,
    ZERO_BYTES32,
    AnswerRequest,
    BlockReason,
    ChainBudget,
    ChainEntry,
    ChainMembership,
    ChainNotSent,
    ChainObjection,
    ChainRevert,
    ChainUnavailable,
    ConfirmApproval,
    ConfirmedEntry,
    DecisionRecord,
    ObjectionStatus,
    ObjectionTx,
    RecordRequest,
    RejectDecision,
    RevertReason,
    Role,
    TxResult,
    check_address,
    check_bytes32,
    check_signature,
)
from app.schemas.entry import EntryKind, EntryStatus

R = TypeVar("R")

WRITE_METHODS = ("record_pending", "confirm_entry", "reject_entry", "raise_objection", "answer_objection")
READ_METHODS = (
    "get_entry",
    "get_record_result",
    "get_decision_result",
    "safe_block",
    "confirmed_entries",
    "has_role",
    "get_objection",
    "has_valid_membership",
    "token_of",
    "get_membership",
    "get_budget",
    "remaining",
)


def fake_signature(address: str) -> str:
    """address 가 서명한 것으로 취급되는 가짜 서명. 부를 때마다 다른 문자열이 나온다."""
    return "0x" + check_address(address)[2:].lower() + secrets.token_hex(45)


def fake_recover_signer(struct: object, signature: str) -> str:
    """eip712.recover_signer 의 가짜. fake_signature 를 만든 주소를 돌려준다. struct 는 보지 않는다."""
    return _signer(check_signature(signature))


def _signer(signature: str) -> str:
    return to_checksum_address("0x" + signature[2:42])


def _check_method(method: str, allowed: tuple[str, ...] = WRITE_METHODS) -> None:
    if method not in allowed:
        raise ValueError(f"method 는 {', '.join(allowed)} 중 하나다: {method!r}")


class FakeChainClient:
    def __init__(self, clock: Callable[[], float] = time.time, enforce_roles: bool = False):
        self._clock = clock
        self._enforce_roles = enforce_roles
        self._entries: dict[int, ChainEntry] = {}
        self._record_results: dict[int, TxResult] = {}
        self._decision_results: dict[int, DecisionRecord] = {}
        self._budgets: dict[int, tuple[ChainBudget, int]] = {}  # budgetId → (내용, 잔량)
        self._confirmed: list[ConfirmedEntry] = []
        self._objections: dict[int, ChainObjection] = {}
        self._roles: set[tuple[Role, str]] = set()
        self._memberships: dict[int, tuple[str, ChainMembership]] = {}  # tokenId → (주소 소문자, 내용)
        self._tx_count = 0
        self._fail: dict[str, RevertReason] = {}
        self._unavailable: dict[str, bool] = {}
        self._not_sent: set[str] = set()
        self._block_reason: Optional[BlockReason] = None

    # ------------------------------------------------------------ 시나리오 지정

    def fail_next(self, method: str, reason: RevertReason) -> None:
        """다음 한 번의 method 호출을 reason 으로 revert 시킨다. 상태는 바뀌지 않는다."""
        _check_method(method)
        self._fail[method] = reason

    def unavailable_next(self, method: str, landed: bool = False) -> None:
        """다음 한 번의 method 호출을 ChainUnavailable 로 끝낸다.

        쓰기 메서드: landed=False 면 트랜잭션이 체인에 닿지 않아 상태가 그대로다.
        landed=True 면 체인은 평소대로 처리했고(revert 될 입력이면 revert) 응답만 받지 못한 것이다.
        조회 메서드(get_entry 등)에는 landed 가 의미 없다.
        """
        _check_method(method, WRITE_METHODS + READ_METHODS)
        self._unavailable[method] = landed

    def not_sent_next(self, method: str) -> None:
        """다음 한 번의 쓰기 호출을 ChainNotSent 로 끝낸다 — 보내지 못했고 체인에 없는 것이 확정인 경우 (잔고 부족 등)."""
        _check_method(method)
        self._not_sent.add(method)

    def block_next(self, reason: BlockReason = BlockReason.BUDGET_EXCEEDED) -> None:
        """다음 지출(EXPENSE) record_pending 을 BLOCKED 로 저장한다. 수입과 예산 id 0 인 지출에는 적용되지 않는다."""
        self._block_reason = reason

    def grant_role(self, role: Role, address: str) -> None:
        self._roles.add((role, check_address(address).lower()))

    def grant_membership(self, address: str, term: int, commitment: str = ZERO_BYTES32) -> int:
        """SBT 를 발급한 상태로 만든다. 발급 자체는 회장이 직접 하는 일이라 체인 호출로 흉내 내지 않는다."""
        owner = check_address(address).lower()
        if any(o == owner and m.term == term for o, m in self._memberships.values()):
            raise ValueError(f"{address} 는 {term} 학기 SBT 가 이미 있다")
        token_id = len(self._memberships) + 1
        self._memberships[token_id] = (owner, ChainMembership(token_id=token_id, term=term, commitment=check_bytes32(commitment)))
        return token_id

    def set_budget(self, budget: ChainBudget, remaining: int) -> None:
        """예산이 발행된 상태로 만든다. 확정과 잔량은 연결하지 않는다 — 잔량 부족은 fail_next 로 지정한다."""
        self._budgets[budget.id] = (budget, remaining)

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
        self._read("get_entry")
        return self._entries.get(entry_id)

    async def get_record_result(self, entry_id: int) -> Optional[TxResult]:
        self._read("get_record_result")
        return self._record_results.get(entry_id)

    async def get_decision_result(self, entry_id: int) -> Optional[DecisionRecord]:
        self._read("get_decision_result")
        return self._decision_results.get(entry_id)

    # ------------------------------------------------------------ LedgerEvents

    async def safe_block(self) -> int:
        self._read("safe_block")
        return self._tx_count

    async def confirmed_entries(self, from_block: int, to_block: int) -> list[ConfirmedEntry]:
        self._read("confirmed_entries")
        return [e for e in self._confirmed if from_block <= e.block_number <= to_block]

    # ------------------------------------------------------------ RoleReader

    async def has_role(self, role: Role, account: str) -> bool:
        self._read("has_role")
        return (role, check_address(account).lower()) in self._roles

    # ------------------------------------------------------------ ObjectionClient

    async def raise_objection(self, objection_id: int, entry_id: int, content_hash: str, raiser: str) -> ObjectionTx:
        check_bytes32(content_hash)
        check_address(raiser)
        return self._send("raise_objection", lambda: self._raise(objection_id, entry_id, content_hash, raiser))

    async def answer_objection(self, request: AnswerRequest, signature: str) -> ObjectionTx:
        signature = check_signature(signature)
        return self._send("answer_objection", lambda: self._answer(request, signature))

    async def get_objection(self, objection_id: int) -> Optional[ChainObjection]:
        self._read("get_objection")
        return self._objections.get(objection_id)

    # ------------------------------------------------------------ MembershipReader

    async def has_valid_membership(self, account: str, term: int) -> bool:
        self._read("has_valid_membership")
        return self._token(account, term) is not None

    async def token_of(self, account: str, term: int) -> Optional[int]:
        self._read("token_of")
        return self._token(account, term)

    async def get_membership(self, token_id: int) -> Optional[ChainMembership]:
        self._read("get_membership")
        found = self._memberships.get(token_id)
        return found[1] if found else None

    # ------------------------------------------------------------ BudgetReader

    async def get_budget(self, budget_id: int) -> Optional[ChainBudget]:
        self._read("get_budget")
        found = self._budgets.get(budget_id)
        return found[0] if found else None

    async def remaining(self, budget_id: int) -> Optional[int]:
        self._read("remaining")
        found = self._budgets.get(budget_id)
        return found[1] if found else None

    # ------------------------------------------------------------ 컨트랙트 흉내

    def _record(self, request: RecordRequest, signature: str) -> TxResult:
        self._precheck("record_pending", request.deadline)
        self._require_role(_signer(signature), (Role.TREASURER,), RevertReason.NOT_REGISTRANT)
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
            elif self._block_reason is not None:
                status, block_reason, self._block_reason = EntryStatus.BLOCKED, self._block_reason, None

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
        result = TxResult(tx_hash=self._next_tx(), status=status, block_reason=block_reason)
        self._record_results[request.id] = result
        return result

    def _confirm(self, approval: ConfirmApproval, signature: str) -> TxResult:
        self._precheck("confirm_entry", approval.deadline)
        entry = self._pending_entry(approval.id)
        if entry.hash != approval.hash:
            raise ChainRevert(RevertReason.HASH_MISMATCH, f"id={approval.id}")
        return self._decide(
            entry, signature, EntryStatus.CONFIRMED,
            had_warning=approval.had_warning, warning_reason_hash=approval.warning_reason_hash,
        )

    def _reject(self, decision: RejectDecision, signature: str) -> TxResult:
        self._precheck("reject_entry", decision.deadline)
        entry = self._pending_entry(decision.id)
        return self._decide(entry, signature, EntryStatus.REJECTED, reason_hash=decision.reason_hash)

    def _raise(self, objection_id: int, entry_id: int, content_hash: str, raiser: str) -> ObjectionTx:
        self._precheck("raise_objection")
        if objection_id in self._objections:
            raise ChainRevert(RevertReason.OBJECTION_ALREADY_EXISTS, f"id={objection_id}")
        if entry_id not in self._entries:
            raise ChainRevert(RevertReason.ENTRY_NOT_FOUND, f"entry_id={entry_id}")
        self._objections[objection_id] = ChainObjection(
            id=objection_id,
            entry_id=entry_id,
            content_hash=content_hash,
            answer_hash=ZERO_BYTES32,
            status=ObjectionStatus.OPEN,
            raiser=to_checksum_address(raiser),
            responder=ZERO_ADDRESS,
        )
        return ObjectionTx(tx_hash=self._next_tx(), status=ObjectionStatus.OPEN)

    def _answer(self, request: AnswerRequest, signature: str) -> ObjectionTx:
        self._precheck("answer_objection", request.deadline)
        signer = _signer(signature)
        self._require_role(signer, RESPONDER_ROLES, RevertReason.NOT_RESPONDER)
        objection = self._objections.get(request.objection_id)
        if objection is None:
            raise ChainRevert(RevertReason.OBJECTION_NOT_FOUND, f"id={request.objection_id}")
        if objection.status == ObjectionStatus.ANSWERED:
            raise ChainRevert(RevertReason.OBJECTION_ALREADY_ANSWERED, f"id={request.objection_id}")
        self._objections[request.objection_id] = objection.model_copy(
            update={"status": ObjectionStatus.ANSWERED, "answer_hash": request.answer_hash, "responder": signer}
        )
        return ObjectionTx(tx_hash=self._next_tx(), status=ObjectionStatus.ANSWERED)

    # ------------------------------------------------------------ 내부

    def _send(self, method: str, apply: Callable[[], R]) -> R:
        """not_sent_next·unavailable_next 로 지정된 호출이면 보내기 실패·연결 실패를 흉내 낸다."""
        if method in self._not_sent:
            self._not_sent.discard(method)
            raise ChainNotSent("not_sent_next 로 지정")
        landed = self._unavailable.pop(method, None)
        if landed is None:
            return apply()
        if landed:
            try:
                apply()
            except ChainRevert:
                pass  # 체인에서 revert 됐어도 응답을 못 받았으니 호출한 쪽은 모른다
        raise ChainUnavailable(f"unavailable_next 로 지정 (landed={landed})")

    def _read(self, method: str) -> None:
        if self._unavailable.pop(method, None) is not None:
            raise ChainUnavailable("unavailable_next 로 지정")

    def _precheck(self, method: str, deadline: Optional[int] = None) -> None:
        forced = self._fail.pop(method, None)
        if forced is not None:
            raise ChainRevert(forced, "fail_next 로 지정")
        if deadline is not None and deadline < self._clock():
            raise ChainRevert(RevertReason.SIGNATURE_EXPIRED, f"deadline={deadline}")

    def _require_role(self, signer: str, roles: tuple[Role, ...], reason: RevertReason) -> None:
        if self._enforce_roles and not any((role, signer.lower()) in self._roles for role in roles):
            raise ChainRevert(reason, f"signer={signer}")

    def _pending_entry(self, entry_id: int) -> ChainEntry:
        entry = self._entries.get(entry_id)
        if entry is None:
            raise ChainRevert(RevertReason.ENTRY_NOT_FOUND, f"id={entry_id}")
        if entry.status != EntryStatus.PENDING:
            raise ChainRevert(RevertReason.INVALID_STATUS, f"id={entry_id} status={entry.status.value}")
        return entry

    def _decide(self, entry: ChainEntry, signature: str, status: EntryStatus, **details) -> DecisionRecord:
        signer = _signer(signature)
        self._require_role(signer, APPROVER_ROLES, RevertReason.NOT_APPROVER)
        if signer == entry.registrant:
            raise ChainRevert(RevertReason.SELF_APPROVAL, f"id={entry.id}")
        self._entries[entry.id] = entry.model_copy(update={"status": status, "approver": signer})
        tx_hash = self._next_tx()
        result = DecisionRecord(tx_hash=tx_hash, status=status, approver=signer, block_number=self._tx_count, **details)
        self._decision_results[entry.id] = result
        if status == EntryStatus.CONFIRMED:
            self._confirmed.append(
                ConfirmedEntry(id=entry.id, amount=entry.amount, kind=entry.kind, block_number=self._tx_count, tx_hash=result.tx_hash)
            )
        return result

    def _token(self, account: str, term: int) -> Optional[int]:
        owner = check_address(account).lower()
        return next((t for t, (o, m) in self._memberships.items() if o == owner and m.term == term), None)

    def _next_tx(self) -> str:
        self._tx_count += 1
        return "0x" + hashlib.sha256(f"fake-tx-{self._tx_count}".encode()).hexdigest()
