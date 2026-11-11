"""등록·확정·반려를 체인에 보내는 동안의 DB 상태 — tx_pending 3상태 (CHAIN_CLIENT §3). 라우터가 부른다.

    ① 초안       status NULL · tx_pending NULL   제출할 수 있다
    ② 처리 중    status NULL · tx_pending 있음    보냈는데 결과를 모른다. 다시 보내지 않는다
    ③ 체인 기록  status 있음                      끝났다 (PENDING·BLOCKED)

확정은 같은 규칙을 tx_confirm 으로 한다 — PENDING 이고 tx_confirm NULL → tx_confirm 있음(approved_by·경고 사유도 함께)
→ CONFIRMED. 반려도 같은 칸을 쓴다 — tx_confirm 있음(rejected_by·사유도 함께) → REJECTED. 칸이 하나라 한 항목에 확정과 반려가
같이 나가지 않는다. 상대 단계의 선점(자기 첫 extra 칸이 비어 있다)은 읽지도 비우지도 않는다.
T4 수정 요청(revision_requested_at)이 있으면 확정을 선점하지 않는다. 라우터 검사만으로는 수정 요청과 확정이 동시에 오면 둘 다 통과한다.
반려는 막지 않는다 — 수정 요청은 반려를 거쳐 재등록된다 (PRD §4.3).

- 선점: ChainClient 의 before_broadcast 콜백에서 조건부 UPDATE 를 하고 바로 commit 한다. 보내기 전에 ② 가 DB 에 남는다.
  선점하지 못하면(다른 요청이 먼저 잡음) EntryConflict 를 던지고, 그러면 ChainClient 는 보내지 않는다.
- 콜백이 불린 뒤 ChainRevert·ChainSetupError 면 체인에 남은 것이 없으니 내 선점만 비운다 (칸에 내 hash 가 있을 때).
- 콜백이 불린 뒤 ChainUnavailable 이면 ② 를 둔 채 저장한 hash 로 결과를 한 번 확인한다 (tx_result). 모르면 그대로 올린다.
- 이미 ② 인 항목에 요청이 다시 오면 다시 보내지 않고 결과부터 확인한다. 실패로 끝났으면 ① 로 돌리고 이 요청의 서명으로
  보낸다. 결과가 있으면 ③ 으로 맞추되, 그 선점이 이 요청과 같은 내용(확정·반려면 같은 사람·사유)일 때만 성공으로 돌려준다.
- 콜백 전에 ENTRY_ALREADY_EXISTS(등록)·INVALID_STATUS(확정·반려)로 걸리면 다른 요청이 먼저 보냈을 수 있다.
  DB 를 다시 읽어 그렇다면 409(EntryConflict)로 바꾼다.

DB 는 단계(읽기·선점·반영·해제)마다 짧은 세션을 따로 열어 스레드에서 돌린다.
- 라우터가 넘긴 세션은 엔진을 얻는 데만 쓴다 — commit·rollback 하지 않고 그 객체도 다시 읽지 않는다.
  라우터는 부르기 전에 자기 변경을 commit 하고, 부른 뒤 항목 값이 필요하면 다시 읽는다(db.refresh)
- 동기 DB 대기가 이벤트 루프를 막지 않는다. 선점은 릴레이어 lock 을 쥔 채 일어나므로 특히 중요하다
- 체인을 기다리는 동안 열린 DB 트랜잭션이 없다
서명자 대조(signer_of)·권한·입력 검증은 라우터가 먼저 한다. 여기는 상태 전이만 한다.

알림 (docs/NOTIFICATION_API.md) — 상태 반영(③)과 같은 세션·같은 commit 으로 기록한다 (PRD §4.8). 반영 UPDATE 가 1행일 때만
기록하므로 재제출로 같은 결과를 다시 받아도 한 번만 남는다. 등록은 PENDING 이면 ENTRY_REGISTERED, BLOCKED 면 ENTRY_BLOCKED 만,
확정·반려는 그 항목의 재알림 대상을 먼저 닫고 결과를 알린다. 확정이 InsufficientBudget·BudgetExpired 로 거부되면 상태 전이가
없으니 자체 세션으로 ENTRY_CONFIRM_FAILED 만 기록한다 (총무가 반려 후 재등록이나 증액으로 조치할 수 있는 실패만).
② 가 오래 남는 경우(노드가 트랜잭션을 잃음)의 정리는 이번 범위가 아니다 — receipt 가 없다고 안 들어간다고 단정할 수 없다.

라우터에서의 예외 → HTTP:
    EntryConflict(EntryInFlight·EntryAlreadyRecorded) → 409
    LookupError → 404, ValueError → 400 (상태가 맞지 않음, 사유와 서명된 해시 불일치, 기록할 수 없는 승인자, 값 형식)
    ChainRevert → 400 (사유는 e.reason), ChainSetupError → 503 (main.py 전역 처리기), ChainUnavailable → 503 (② 유지)
    SQLAlchemyError → 503 (② 면 다시 요청해 결과를 맞춘다)
"""
import asyncio
import hashlib
import logging
from dataclasses import dataclass
from typing import Awaitable, Callable, Optional, TypeVar

from sqlalchemy import and_, or_, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from app.chain.client import BeforeBroadcast, ChainClient
from app.chain.models import (
    ZERO_BYTES32,
    ChainRevert,
    ChainSetupError,
    ChainUnavailable,
    ConfirmApproval,
    RecordRequest,
    RejectDecision,
    RevertReason,
    TxResult,
    check_tx_hash,
)
from app.models import Entry
from app.schemas.entry import EntryStatus
from app.services.notifications import NotificationKind, create_notification, resolve_notifications

logger = logging.getLogger(__name__)

# DB 의 status 칸 값 (문자열)
PENDING = EntryStatus.PENDING.value
CONFIRMED = EntryStatus.CONFIRMED.value
REJECTED = EntryStatus.REJECTED.value
BLOCKED = EntryStatus.BLOCKED.value

T = TypeVar("T")

# 확정이 이 사유로 거부되면 총무에게 알린다. 항목은 PENDING 으로 남고 총무가 반려 후 재등록·증액 요청으로 조치할 수 있다 (§4.1)
_CONFIRM_FAILURE_NOTICES = frozenset({RevertReason.INSUFFICIENT_BUDGET, RevertReason.BUDGET_EXPIRED})


class EntryConflict(Exception):
    """409. 이 항목은 지금 보낼 수 없다."""

    def __init__(self, entry_id: int, message: str):
        self.entry_id = entry_id
        super().__init__(message)


class EntryInFlight(EntryConflict):
    """② — 다른 요청이 보낸 트랜잭션의 결과를 아직 모른다. 잠시 뒤 다시 요청하면 결과를 확인한다."""


class EntryAlreadyRecorded(EntryConflict):
    """③ — 이미 체인에 기록됐다 (다른 요청이 먼저 했거나, 다른 내용으로)."""


@dataclass(frozen=True)
class _Step:
    """선점하는 칸과 그 칸을 쓰는 상태. 등록은 tx_pending(status NULL 에서), 확정·반려는 tx_confirm(status PENDING 에서)."""

    name: str
    column: str
    ready: Optional[str]  # 이 단계를 보낼 수 있는 status
    done: frozenset  # 이 단계가 이미 끝난 status
    results: frozenset  # 이 단계의 트랜잭션이 낼 수 있는 결과 status
    competitor: RevertReason  # 콜백 전에 이 revert 면 다른 요청이 먼저 보냈을 수 있다
    extra: tuple = ()  # 선점할 때 함께 적고 비울 때 함께 비우는 칸. 첫 칸은 이 단계의 선점이면 반드시 채워진다
    rival: str = ""  # 같은 칸을 쓰는 상대 단계의 이름
    must_be_empty: tuple = ()  # 선점할 때 비어 있어야 하는 칸. 값이 있으면 보내지 않고 409 다


_RECORD = _Step(
    "등록",
    "tx_pending",
    None,
    frozenset({PENDING, CONFIRMED, REJECTED, BLOCKED}),
    frozenset({PENDING, BLOCKED}),
    RevertReason.ENTRY_ALREADY_EXISTS,
)
_CONFIRM = _Step(
    "확정",
    "tx_confirm",
    PENDING,
    frozenset({CONFIRMED, REJECTED}),
    frozenset({CONFIRMED}),
    RevertReason.INVALID_STATUS,
    ("approved_by", "warning_ack_reason"),
    "반려",
    ("revision_requested_at",),
)
_REJECT = _Step(
    "반려",
    "tx_confirm",
    PENDING,
    frozenset({CONFIRMED, REJECTED}),
    frozenset({REJECTED}),
    RevertReason.INVALID_STATUS,
    ("rejected_by", "reject_reason"),
    "확정",
)


@dataclass(frozen=True)
class _Row:
    """한 단계가 보는 항목 값. 세션이 닫힌 뒤에도 쓰도록 값만 담는다."""

    status: Optional[str]
    claim: Optional[str]  # 단계의 선점 칸 (tx_pending·tx_confirm)
    extra: tuple  # 단계의 extra 칸 값
    barred: bool = False  # must_be_empty 칸에 값이 있다

    def claimed_by(self, step: _Step) -> bool:
        """선점이 이 단계의 것인가. 확정은 approved_by, 반려는 rejected_by 를 채운다 — 비어 있으면 같은 칸을 쓰는 상대의 것이다."""
        return not step.extra or self.extra[0] is not None


async def relay_record(db: Session, chain: ChainClient, request: RecordRequest, signature: str) -> TxResult:
    """초안(①)을 체인에 등록한다. 결과(PENDING·BLOCKED)를 DB 에 남기고 돌려준다. 예외는 모듈 설명의 표대로.

    db 는 엔진을 얻는 데만 쓴다 (모듈 설명). 부르기 전에 라우터의 변경을 commit 한다.
    """
    return await _relay(_Store(db), chain, _RECORD, request.id, {}, lambda claim: chain.record_pending(request, signature, claim))


async def relay_confirm(
    db: Session,
    chain: ChainClient,
    approval: ConfirmApproval,
    signature: str,
    approver_id: int,
    warning_reason: Optional[str] = None,
) -> TxResult:
    """PENDING 항목을 확정한다. approved_by·경고 사유(warning_ack_reason)는 선점할 때 함께 적고, 실패하면 함께 비운다.

    warning_reason 은 앱이 해시해 서명한 사유 원문(HASHING §3 정본)이다. 그 SHA256 이 approval.warning_reason_hash 와
    같아야 한다 — 다르면 체인에는 서명된 해시가, DB 에는 다른 원문이 남아 학생 검증에서 위조로 보인다 (HASHING §2.1).
    경고 승인이 아니면 None 이고 해시는 bytes32(0) 이다.
    """
    _check_warning_reason(approval, warning_reason)
    extra = {"approved_by": approver_id, "warning_ack_reason": warning_reason}
    store = _Store(db)
    try:
        return await _relay(store, chain, _CONFIRM, approval.id, extra, lambda claim: chain.confirm_entry(approval, signature, claim))
    except ChainRevert as e:
        if e.reason in _CONFIRM_FAILURE_NOTICES:
            await store.notify_confirm_failed(approval.id)
        raise


async def relay_reject(
    db: Session,
    chain: ChainClient,
    decision: RejectDecision,
    signature: str,
    rejecter_id: int,
    reason: str,
) -> TxResult:
    """PENDING 항목을 반려한다. rejected_by·사유(reject_reason)는 선점할 때 함께 적고, 실패하면 함께 비운다.

    reason 은 앱이 해시해 서명한 사유 원문(HASHING §3 정본)이다. 그 SHA256 이 decision.reason_hash 와 같아야 한다 —
    다르면 체인에는 서명된 해시, DB 에는 다른 원문이 남아 학생 검증에서 위조로 보인다.
    """
    if not reason or _text_hash(reason) != decision.reason_hash:
        raise ValueError("반려 사유 원문의 SHA256 이 서명된 reason_hash 와 다르다 (HASHING §3)")
    extra = {"rejected_by": rejecter_id, "reject_reason": reason}
    return await _relay(_Store(db), chain, _REJECT, decision.id, extra, lambda claim: chain.reject_entry(decision, signature, claim))


def _check_warning_reason(approval: ConfirmApproval, reason: Optional[str]) -> None:
    if not approval.had_warning:
        if reason is not None:
            raise ValueError("경고 승인이 아니면 사유를 저장하지 않는다 (warning_reason 은 None)")
        return  # 해시가 0 이 아니면 체인이 REASON_NOT_ALLOWED 로 거부한다
    if not reason:
        raise ValueError("경고 승인에는 사유가 필요하다 (빈 문자열은 해시하지 않는다, HASHING §3)")
    if approval.warning_reason_hash == ZERO_BYTES32 or _text_hash(reason) != approval.warning_reason_hash:
        raise ValueError("사유 원문의 SHA256 이 서명된 warning_reason_hash 와 다르다 (HASHING §3)")


def _text_hash(text: str) -> str:
    """HASHING §3 텍스트 해시. text 는 정본(canonical_text 를 거친 값)이어야 한다."""
    return "0x" + hashlib.sha256(text.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------- 전이


async def _relay(
    store: "_Store",
    chain: ChainClient,
    step: _Step,
    entry_id: int,
    extra: dict,
    send: Callable[[BeforeBroadcast], Awaitable[TxResult]],
) -> TxResult:
    row = await store.read(step, entry_id)
    if row.status in step.done:
        raise EntryAlreadyRecorded(entry_id, f"이미 체인에 기록된 항목이다 (id={entry_id}, status={row.status})")
    if row.status != step.ready:
        raise ValueError(f"{step.name}할 수 있는 상태가 아니다 (id={entry_id}, status={row.status})")
    if row.claim is not None:
        if not row.claimed_by(step):
            # 같은 칸을 상대 단계가 쓰는 중이다. 그 결과·해제는 그 흐름이 한다
            raise EntryInFlight(entry_id, f"다른 처리({step.rival})가 진행 중이다 (id={entry_id}, tx={row.claim})")
        # ② — 다시 보내지 않고 그 트랜잭션의 결과부터 본다
        try:
            result = await _check(store, chain, step, entry_id, row.claim)
        except ChainRevert:
            pass  # 실패로 끝나 ① 로 돌아왔다. 이 요청의 서명으로 보낸다
        else:
            if result is None:
                raise EntryInFlight(entry_id, f"{step.name} 트랜잭션의 결과를 아직 모른다 (id={entry_id}, tx={row.claim})")
            if row.extra != tuple(extra.get(name) for name in step.extra):
                # 앞선 요청(다른 승인자·사유)이 확정한 것이다. 이 요청의 서명은 보내지 않았으니 성공으로 돌려주지 않는다
                raise EntryAlreadyRecorded(entry_id, f"다른 요청으로 이미 {step.name}됐다 (id={entry_id})")
            return result

    claimed: list = []

    async def claim(tx_hash: str) -> None:
        # 보내기 직전. 조건부 UPDATE 로 ① → ② 를 잡고 commit 한다. 못 잡으면 예외 — ChainClient 가 보내지 않는다
        tx_hash = check_tx_hash(tx_hash)
        await store.claim(step, entry_id, tx_hash, extra)
        claimed.append(tx_hash)

    try:
        result = await send(claim)
    except (ChainRevert, ChainSetupError) as e:
        if claimed:
            await store.release(step, entry_id, claimed[0])  # 체인에 남은 것이 없다
        elif isinstance(e, ChainRevert) and e.reason is step.competitor:
            await store.raise_if_taken(step, entry_id)
        raise
    except ChainUnavailable as e:
        if not claimed:
            raise  # 보내기 전에 끊겼다. 선점도 없다
        unavailable = e
    else:
        await store.settle(step, entry_id, claimed[0], result)
        return result

    # 들어갔는지 모른다. 바로 다시 보내지 않고 저장한 hash 로 한 번 확인한다 (CHAIN_CLIENT §4)
    try:
        result = await _check(store, chain, step, entry_id, claimed[0])
    except (ChainUnavailable, ChainSetupError):
        # 확인도 못 했다(그 사이 교체로 클라이언트가 닫힌 경우 포함). ② 그대로. 보낸 뒤라 ChainSetupError("보내지 않음")로
        # 올리지 않는다 — CHAIN_CLIENT §4. 원래 원인도 지우지 않는다
        raise unavailable
    if result is None:
        raise unavailable
    return result


async def _check(store: "_Store", chain: ChainClient, step: _Step, entry_id: int, tx_hash: str) -> Optional[TxResult]:
    """② 의 트랜잭션 결과를 확인해 DB 에 반영한다. 결과가 나왔으면 ③ 으로 맞추고 돌려준다.

    tx_hash 는 DB 에 저장된 값이다 — 반영·해제의 조건으로 그대로 쓴다.
    실패로 끝났으면 ① 로 돌리고 그 ChainRevert 를 던진다. 아직 모르거나 이 단계의 결과가 아니면 None (② 그대로).
    """
    try:
        result = await chain.tx_result(tx_hash, entry_id)
    except ChainRevert:
        await store.release(step, entry_id, tx_hash)
        raise
    if result is None or result.status.value not in step.results:
        return None
    await store.settle(step, entry_id, tx_hash, result)
    return result


# ---------------------------------------------------------------- DB


class _Store:
    """DB 단계마다 짧은 세션을 따로 열어 스레드에서 돌린다. 호출자 세션의 트랜잭션은 건드리지 않는다."""

    def __init__(self, db: Session):
        self._bind = db.get_bind()
        url = self._bind.url
        if url.get_backend_name() == "sqlite" and url.database in (None, "", ":memory:") and not isinstance(self._bind.pool, StaticPool):
            # 메모리 sqlite 는 연결마다 다른 DB 다. 기본 풀은 스레드마다 연결을 따로 열어, 스레드의 세션에는 테이블이 없다
            raise RuntimeError("메모리 sqlite 엔진은 poolclass=StaticPool 로 만든다 (DB 작업이 다른 스레드에서 돈다). 또는 파일 DB 를 쓴다")

    async def read(self, step: _Step, entry_id: int) -> _Row:
        return await self._run(lambda db: _row(db, step, entry_id))

    async def claim(self, step: _Step, entry_id: int, tx_hash: str, extra: dict) -> None:
        def work(db: Session) -> None:
            if step is _CONFIRM:
                target_entry = db.get(Entry, entry_id)
                if (
                    target_entry is not None
                    and target_entry.corrects_entry_id is not None
                    and target_entry.amount < 0
                    and target_entry.correction_reason == "RECLASSIFY"
                ):
                    parent = (
                        db.query(Entry)
                        .filter(Entry.id == target_entry.corrects_entry_id)
                        .with_for_update()
                        .first()
                    )
                    if parent is not None:
                        pos_rows = (
                            db.query(Entry)
                            .filter(
                                Entry.corrects_entry_id == parent.id,
                                Entry.status == CONFIRMED,
                                Entry.amount > 0,
                                Entry.budget_id.isnot(None),
                                Entry.budget_id != parent.budget_id,
                            )
                            .all()
                        )
                        neg_rows = (
                            db.query(Entry)
                            .filter(
                                Entry.corrects_entry_id == parent.id,
                                Entry.id != entry_id,
                                Entry.amount < 0,
                                Entry.correction_reason == "RECLASSIFY",
                                or_(
                                    Entry.status == CONFIRMED,
                                    and_(
                                        Entry.status == PENDING,
                                        Entry.tx_confirm.isnot(None),
                                        Entry.rejected_by.is_(None),
                                    ),
                                ),
                            )
                            .all()
                        )
                        confirmed_pos_sum = sum(int(r.amount) for r in pos_rows)
                        reserved_neg_abs_sum = sum(abs(int(r.amount)) for r in neg_rows)
                        if confirmed_pos_sum - reserved_neg_abs_sum < abs(int(target_entry.amount)):
                            raise ValueError(
                                "항목 재분류(RECLASSIFY)는 새 예산에 대한 양수(증액) 정정이 먼저 확정(CONFIRMED)된 후에 원래 예산의 음수(감액) 정정을 진행할 수 있습니다."
                            )

            try:
                rows = db.execute(
                    update(Entry)
                    .where(
                        Entry.id == entry_id,
                        _column(step).is_(None),
                        _status_is(step.ready),
                        *(getattr(Entry, name).is_(None) for name in step.must_be_empty),
                    )
                    .values({step.column: tx_hash, **extra})
                    .execution_options(synchronize_session=False)
                ).rowcount
            except IntegrityError as e:
                # 등록자 = 승인·반려자(ck_entries_maker_checker·ck_entries_rejected_maker)·없는 사용자(FK). 보내지 않고 400 으로 끝낸다
                raise ValueError(f"{step.name} 선점을 기록할 수 없다 (id={entry_id}): {e.orig}") from e
            if rows != 1:
                # 읽은 뒤 다른 요청이 바꿨다. 지금 상태에 맞는 응답으로 (이미 기록됨·처리 중·상태가 맞지 않음)
                db.rollback()
                current = _row(db, step, entry_id)
                _raise_taken(current, step, entry_id)
                if current.status != step.ready:
                    raise ValueError(f"{step.name}할 수 있는 상태가 아니다 (id={entry_id}, status={current.status})")
                if current.barred:
                    raise EntryConflict(entry_id, f"수정 요청 중인 내역은 {step.name}할 수 없다 (id={entry_id})")
                raise EntryInFlight(entry_id, f"다른 요청이 먼저 보냈다 (id={entry_id})")

        await self._run(work)

    async def settle(self, step: _Step, entry_id: int, tx_hash: str, result: TxResult) -> None:
        """② → ③. 칸에 이 hash 가 있을 때만 쓴다. 다른 요청이 먼저 같은 결과로 반영했으면 그대로 둔다."""
        values = {"status": result.status.value}
        if result.block_reason is not None:
            values["block_reason"] = result.block_reason.value

        def work(db: Session) -> None:
            if _update(db, step, entry_id, tx_hash, values) == 1:
                _notify_settled(db, step, entry_id, result)
                return
            current = _row(db, step, entry_id)
            if (current.status, current.claim) != (result.status.value, tx_hash):
                # 체인은 끝났는데 DB 가 다르게 바뀌었다. 조용히 성공으로 돌려주지 않는다
                raise RuntimeError(f"DB 가 체인 결과와 다르다 (id={entry_id}, tx={tx_hash}, DB status={current.status})")

        await self._run(work)

    async def release(self, step: _Step, entry_id: int, tx_hash: str) -> None:
        """② → ①. 칸에 이 hash 가 있을 때만 비운다 — 남의 선점은 건드리지 않는다."""
        values = {step.column: None, **{name: None for name in step.extra}}
        await self._run(lambda db: _update(db, step, entry_id, tx_hash, values))

    async def notify_confirm_failed(self, entry_id: int) -> None:
        """확정 실패 알림을 자체 세션으로 기록한다. 기록에 실패해도 원래의 거부(ChainRevert)를 가리지 않게 로그만 남긴다."""

        def work(db: Session) -> None:
            create_notification(db, NotificationKind.ENTRY_CONFIRM_FAILED, entry_id=entry_id)

        try:
            await self._run(work)
        except Exception:
            logger.exception("확정 실패 알림을 기록하지 못했다 (entry_id=%s)", entry_id)

    async def raise_if_taken(self, step: _Step, entry_id: int) -> None:
        """콜백 전에 걸린 revert 가 다른 요청 때문이면 409 로 바꾼다. 아니면 그대로 둔다 (원래 revert 가 올라간다)."""
        await self._run(lambda db: _raise_taken(_row(db, step, entry_id), step, entry_id))

    async def _run(self, work: Callable[[Session], T]) -> T:
        return await asyncio.to_thread(self._in_session, work)

    def _in_session(self, work: Callable[[Session], T]) -> T:
        with Session(self._bind) as db:
            try:
                value = work(db)
                db.commit()
                return value
            except BaseException:
                db.rollback()
                raise


def _notify_settled(db: Session, step: _Step, entry_id: int, result: TxResult) -> None:
    """상태가 이 요청으로 바뀐 직후, 같은 세션에서 알림을 기록한다. 호출한 쪽(_run)이 함께 commit 한다."""
    if step is _RECORD:
        kind = NotificationKind.ENTRY_BLOCKED if result.status is EntryStatus.BLOCKED else NotificationKind.ENTRY_REGISTERED
    else:
        resolve_notifications(db, entry_id=entry_id)  # 승인 요청·수정 요청을 먼저 닫는다
        kind = NotificationKind.ENTRY_CONFIRMED if step is _CONFIRM else NotificationKind.ENTRY_REJECTED
    create_notification(db, kind, entry_id=entry_id)


def _row(db: Session, step: _Step, entry_id: int) -> _Row:
    entry = db.get(Entry, entry_id)
    if entry is None:
        raise LookupError(f"항목이 없다 (id={entry_id})")
    return _Row(
        entry.status,
        getattr(entry, step.column),
        tuple(getattr(entry, name) for name in step.extra),
        any(getattr(entry, name) is not None for name in step.must_be_empty),
    )


def _raise_taken(row: _Row, step: _Step, entry_id: int) -> None:
    if row.status in step.done:
        raise EntryAlreadyRecorded(entry_id, f"다른 요청이 먼저 처리했다 (id={entry_id}, status={row.status})")
    if row.claim is not None:
        raise EntryInFlight(entry_id, f"다른 요청이 처리 중이다 (id={entry_id})")


def _update(db: Session, step: _Step, entry_id: int, tx_hash: str, values: dict) -> int:
    return db.execute(
        update(Entry)
        .where(Entry.id == entry_id, _column(step) == tx_hash, _status_is(step.ready))
        .values(values)
        .execution_options(synchronize_session=False)
    ).rowcount


def _column(step: _Step):
    return getattr(Entry, step.column)


def _status_is(status: Optional[str]):
    return Entry.status.is_(None) if status is None else Entry.status == status
