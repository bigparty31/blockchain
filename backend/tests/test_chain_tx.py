"""tx_pending 3상태 (app/services/chain_tx.py).

DB 는 파일 sqlite(요청마다 다른 연결), 체인은 FakeChainClient 에 실제 구현에서만 나는 경로를 덧씌운 Chain 이다.
    ① 초안 status NULL · tx_pending NULL  ② 처리 중 tx_pending 만  ③ 체인 기록 status 있음
"""
import asyncio
import hashlib
import secrets
import threading
from datetime import datetime, timezone

import pytest
from eth_utils import keccak
from sqlalchemy import create_engine
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from app.chain import (
    ChainRevert,
    ChainSetupError,
    ChainUnavailable,
    FakeChainClient,
    RecordRequest,
    RejectDecision,
    RevertReason,
    entry_commit_of,
    fake_signature,
)
from app.chain.deployment import DEFAULT_PATH, load_deployment
from app.chain.models import ZERO_BYTES32, BlockReason
from app.chain.web3_client import LEDGER
from app.models import Base, Entry, Term, User
from app.schemas.entry import EntryKind, EntryStatus
from app.services import chain_tx
from app.services.chain_tx import EntryAlreadyRecorded, EntryConflict, EntryInFlight, relay_confirm, relay_record
from chain_support import (
    AUDITOR,
    AUDITOR_KEY,
    KST_MIDNIGHT,
    PRESIDENT,
    TEST_ID_BASE,
    TREASURER,
    TREASURER_KEY,
    approval_for_id,
    on_chain,
    sign_as_app,
)
from scripts.local_chain import approval_from_entry

FAR = 4_102_444_800  # deadline. 시계를 고정하지 않는 Fake 에서도 만료되지 않는다
TREASURER_ID, AUDITOR_ID, PRESIDENT_ID = 1, 2, 3
# HASHING §3 의 텍스트 해시 벡터 — 경고 승인 사유
REASON = "OCR 금액 불일치, 영수증 원본 확인함"
REASON_HASH = "0x41357b2c4497cfd0b66c43ad57242c82c8850c666e229aea0ca7ded5052e54fb"


class Chain(FakeChainClient):
    """FakeChainClient 에 시험용 손잡이를 단다.

    before_send — 보내기 직전(서비스가 항목을 읽은 뒤) 불린다. 그 사이 다른 요청이 DB 를 바꾼 경우를 만든다
    after_broadcast — 콜백까지 부른 뒤 이 예외로 끝난다 (전송 응답이 revert·노드가 전송을 거절. 가짜는 이 경로가 없다)
    on_broadcast — 서비스의 콜백(선점)이 끝난 직후 hash 로 불린다
    upper_hash — 콜백에 대문자 hash 를 넘긴다
    tx_result_errors — tx_result 가 차례로 던질 예외 (노드가 아직 응답하지 않음, 블록에서 실패로 끝남)
    """

    def __init__(self):
        super().__init__()
        self.sends = 0
        self.tx_result_calls = 0
        self.before_send = None
        self.after_broadcast = None
        self.on_broadcast = None
        self.upper_hash = False
        self.tx_result_errors: list = []

    async def record_pending(self, request, signature, before_broadcast=None):
        return await self._write(super().record_pending, request, signature, before_broadcast)

    async def confirm_entry(self, approval, signature, before_broadcast=None):
        return await self._write(super().confirm_entry, approval, signature, before_broadcast)

    async def tx_result(self, tx_hash, entry_id):
        self.tx_result_calls += 1
        if self.tx_result_errors:
            raise self.tx_result_errors.pop(0)
        return await super().tx_result(tx_hash, entry_id)

    async def _write(self, send, payload, signature, before_broadcast):
        self.sends += 1
        if self.before_send is not None:
            self.before_send()

        async def spied(tx_hash):
            await before_broadcast("0x" + tx_hash[2:].upper() if self.upper_hash else tx_hash)
            if self.on_broadcast is not None:
                self.on_broadcast(tx_hash)

        if self.after_broadcast is not None:
            error, self.after_broadcast = self.after_broadcast, None
            await spied("0x" + secrets.token_hex(32))
            raise error
        return await send(payload, signature, spied)


# ---------------------------------------------------------------- DB


@pytest.fixture
def engine(tmp_path):
    # 파일 DB — 요청(세션)마다 다른 연결이라 commit 한 값만 서로 보인다
    engine = create_engine(f"sqlite:///{tmp_path / 'chain_tx.db'}", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    with Session(engine) as db:
        db.add(Term(id=1, term_code=20262, name="2026-2학기", started_at=_at(2026, 9, 1), ended_at=_at(2027, 2, 28)))
        for user_id, role, address in ((TREASURER_ID, "TREASURER", TREASURER), (AUDITOR_ID, "AUDITOR", AUDITOR), (PRESIDENT_ID, "PRESIDENT", PRESIDENT)):
            db.add(User(id=user_id, student_no=f"S{user_id}", password_hash="x", name=role, role=role, wallet_address=address.lower()))
        db.commit()
    yield engine
    engine.dispose()


@pytest.fixture
def db(engine):
    """라우터가 받는 요청 세션."""
    with Session(engine) as session:
        yield session


def _at(year, month, day):
    return datetime(year, month, day, tzinfo=timezone.utc)


def draft(engine, kind: str = "INCOME", amount: int = 500_000, **columns) -> int:
    with Session(engine) as db:
        entry = Entry(
            term_id=1,
            kind=kind,
            amount=amount,
            counterparty="거래처",
            purpose="목적",
            occurred_at=KST_MIDNIGHT,
            created_by=TREASURER_ID,
            **columns,
        )
        db.add(entry)
        db.commit()
        return entry.id


def write(engine, entry_id: int, **values) -> None:
    """다른 요청(세션)이 DB 를 바꾼 것처럼."""
    with Session(engine) as other:
        entry = other.get(Entry, entry_id)
        for name, value in values.items():
            setattr(entry, name, value)
        other.commit()


def row(engine, entry_id: int) -> dict:
    """다른 연결로 읽은 DB 값 — 서비스가 commit 한 것만 보인다."""
    with Session(engine) as db:
        e = db.get(Entry, entry_id)
        names = ("status", "block_reason", "tx_pending", "tx_confirm", "approved_by", "warning_ack_reason", "rejected_by")
        return {name: getattr(e, name) for name in names}


def request_for(entry_id: int, kind: EntryKind = EntryKind.INCOME, amount: int = 500_000, deadline: int = FAR) -> RecordRequest:
    return RecordRequest(
        id=entry_id,
        hash="0x" + keccak(text=f"entry-{entry_id}").hex(),
        amount=amount,
        kind=kind,
        term=20262,
        occurred_at=KST_MIDNIGHT,
        budget_id=0,
        corrects_id=0,
        deadline=deadline,
    )


def submit(db, chain, entry_id: int, **request):
    return asyncio.run(relay_record(db, chain, request_for(entry_id, **request), fake_signature(TREASURER)))


async def approve(db, chain, entry_id: int, approver_id: int = AUDITOR_ID, signer: str = AUDITOR, reason=None, **override):
    approval = approval_for_id(await chain.get_entry(entry_id), entry_id, FAR, **override)
    return await relay_confirm(db, chain, approval, fake_signature(signer), approver_id, reason)


def warned(**kwargs) -> dict:
    """경고 승인: 서명된 해시와 저장할 원문(HASHING §3 벡터)."""
    return {"reason": REASON, "had_warning": True, "warning_reason_hash": REASON_HASH, **kwargs}


# ---------------------------------------------------------------- 등록: 정상


def test_draft_is_recorded_and_its_hash_kept(engine, db):
    chain = Chain()
    entry_id = draft(engine)
    seen = []
    chain.on_broadcast = lambda tx_hash: seen.append(row(engine, entry_id))  # 보내기 직전의 DB
    result = submit(db, chain, entry_id)
    assert result.status is EntryStatus.PENDING
    # 보내기 전에 ② 가 commit 돼 있었다 — 응답을 잃어도 어느 트랜잭션인지 안다
    assert seen[0]["tx_pending"] == result.tx_hash and seen[0]["status"] is None
    assert row(engine, entry_id) == {**seen[0], "status": "PENDING"}


def test_blocked_is_recorded_with_its_reason(engine, db):
    entry_id = draft(engine, kind="EXPENSE", amount=35_000)
    result = submit(db, Chain(), entry_id, kind=EntryKind.EXPENSE, amount=35_000)
    assert (result.status, result.block_reason) == (EntryStatus.BLOCKED, BlockReason.BUDGET_NOT_FOUND)
    assert (row(engine, entry_id)["status"], row(engine, entry_id)["block_reason"]) == ("BLOCKED", "BUDGET_NOT_FOUND")


def test_recorded_entry_is_a_conflict_and_not_sent_again(engine, db):
    chain = Chain()
    entry_id = draft(engine)
    submit(db, chain, entry_id)
    with pytest.raises(EntryAlreadyRecorded):
        submit(db, chain, entry_id)
    assert chain.sends == 1


def test_unknown_entry_is_a_lookup_error(db):
    with pytest.raises(LookupError):
        submit(db, Chain(), 999)


def test_claimed_hash_is_stored_in_lowercase(engine, db):
    chain = Chain()
    chain.upper_hash = True
    entry_id = draft(engine)
    result = submit(db, chain, entry_id)
    assert row(engine, entry_id)["tx_pending"] == result.tx_hash == result.tx_hash.lower()


# ---------------------------------------------------------------- 호출자 세션과 이벤트 루프


def test_callers_session_is_left_alone(engine, db):
    # 라우터 세션의 반영 전 변경을 덮어쓰지도(populate_existing), 중간에 commit 하지도, 버리지도 않는다
    entry_id = draft(engine)
    entry = db.get(Entry, entry_id)
    entry.purpose = "라우터가 바꾼 목적"
    db.add(User(id=9, student_no="S9", password_hash="x", name="새 사용자", role="STUDENT", wallet_index=9))
    submit(db, Chain(), entry_id)
    assert entry.purpose == "라우터가 바꾼 목적"
    with Session(engine) as other:
        assert other.get(Entry, entry_id).purpose == "목적" and other.get(User, 9) is None  # 아직 commit 되지 않았다
    db.commit()
    with Session(engine) as other:
        assert other.get(Entry, entry_id).purpose == "라우터가 바꾼 목적" and other.get(User, 9) is not None


@pytest.mark.parametrize("pool", [StaticPool, None], ids=["static_pool", "default_pool"])
def test_in_memory_sqlite_needs_a_static_pool(pool):
    # DB 작업은 다른 스레드에서 돈다. 메모리 sqlite 의 기본 풀은 스레드마다 다른 DB 라 "no such table" 이 아니라 시작할 때 알린다
    options = {"poolclass": pool} if pool else {}
    engine = create_engine("sqlite://", connect_args={"check_same_thread": False}, **options)
    Base.metadata.create_all(engine)
    with Session(engine) as db:
        db.add(Term(id=1, term_code=20262, name="2026-2학기", started_at=_at(2026, 9, 1), ended_at=_at(2027, 2, 28)))
        db.add(User(id=TREASURER_ID, student_no="S1", password_hash="x", name="총무", role="TREASURER", wallet_address=TREASURER.lower()))
        db.commit()
    entry_id = draft(engine)
    with Session(engine) as db:
        if pool:
            assert submit(db, Chain(), entry_id).status is EntryStatus.PENDING
        else:
            with pytest.raises(RuntimeError, match="StaticPool"):
                submit(db, Chain(), entry_id)


def test_database_work_runs_off_the_event_loop(engine, db, monkeypatch):
    # 선점은 릴레이어 lock 을 쥔 채 일어난다. 동기 DB 대기가 이벤트 루프(다른 요청 전체)를 막지 않게 스레드에서 돈다
    on_loop = []
    original = chain_tx._Store._in_session

    def spy(self, work):
        on_loop.append(threading.current_thread() is threading.main_thread())
        return original(self, work)

    monkeypatch.setattr(chain_tx._Store, "_in_session", spy)
    submit(db, Chain(), draft(engine))
    assert len(on_loop) == 3 and not any(on_loop)  # 읽기·선점·반영


# ---------------------------------------------------------------- 등록: 실패와 응답 유실


@pytest.mark.parametrize("error", [ChainRevert(RevertReason.UNKNOWN, "전송 응답이 revert"), ChainSetupError("릴레이어 잔액 부족")])
def test_failure_after_broadcast_releases_the_claim(engine, db, error):
    # 체인에 남은 것이 없다 → ① 로 돌린다. 예외는 그대로 올라간다 (ChainSetupError 는 503)
    chain = Chain()
    chain.after_broadcast = error
    entry_id = draft(engine)
    with pytest.raises(type(error)):
        submit(db, chain, entry_id)
    assert row(engine, entry_id)["tx_pending"] is None and row(engine, entry_id)["status"] is None


def test_failure_before_broadcast_leaves_the_row_alone(engine, db):
    # 콜백 전 실패(시뮬레이션 revert·보내기 전 끊김)에는 선점이 없다. tx_pending 을 건드리지 않는다
    chain = Chain()
    entry_id = draft(engine)
    chain.unavailable_next("record_pending", sent=False)
    with pytest.raises(ChainUnavailable):
        submit(db, chain, entry_id)
    with pytest.raises(ChainRevert) as error:
        submit(db, chain, entry_id, deadline=1)
    assert error.value.reason is RevertReason.SIGNATURE_EXPIRED
    assert row(engine, entry_id)["tx_pending"] is None


def test_lost_response_that_landed_is_recovered_with_its_reason(engine, db):
    # 응답을 잃어도 저장한 hash 로 결과를 바로 확인한다. BLOCKED 사유는 이벤트에만 있어 추측하지 않고 읽어 온다
    chain = Chain()
    chain.unavailable_next("record_pending", landed=True)
    entry_id = draft(engine, kind="EXPENSE", amount=35_000)
    result = submit(db, chain, entry_id, kind=EntryKind.EXPENSE, amount=35_000)
    assert (result.status, result.block_reason) == (EntryStatus.BLOCKED, BlockReason.BUDGET_NOT_FOUND)
    assert row(engine, entry_id)["block_reason"] == "BUDGET_NOT_FOUND" and chain.sends == 1


def test_lost_response_that_did_not_land_stays_in_flight_and_is_not_resent(engine, db):
    chain = Chain()
    chain.unavailable_next("record_pending", landed=False)
    entry_id = draft(engine)
    with pytest.raises(ChainUnavailable):
        submit(db, chain, entry_id)
    in_flight = row(engine, entry_id)
    assert in_flight["tx_pending"] is not None and in_flight["status"] is None  # ②
    with pytest.raises(EntryInFlight):
        submit(db, chain, entry_id)  # 총무가 다시 눌러도 보내지 않는다
    assert chain.sends == 1 and row(engine, entry_id) == in_flight


def test_client_replaced_while_checking_a_sent_transaction_is_unavailable(engine, db):
    # 보낸 뒤 결과를 확인하는 사이 교체로 클라이언트가 닫혔다(tx_result 가 ChainSetupError). 보낸 것이니 "보내지 않음"(503
    # ChainSetupError)이 아니라 ChainUnavailable 이고 ② 를 둔다 — 다시 요청하면 결과를 확인한다
    chain = Chain()
    chain.unavailable_next("record_pending", landed=True)
    chain.tx_result_errors = [ChainSetupError("체인 클라이언트가 교체됐다")]
    entry_id = draft(engine)
    with pytest.raises(ChainUnavailable):
        submit(db, chain, entry_id)
    assert row(engine, entry_id)["tx_pending"] is not None and row(engine, entry_id)["status"] is None
    assert submit(db, chain, entry_id).status is EntryStatus.PENDING and chain.sends == 1


def lost_but_landed(engine, db, chain, entry_id):
    """응답을 잃었고(② 유지) 처음 확인 때 노드도 아직 응답하지 않는다. 트랜잭션은 실제로 들어갔다."""
    chain.unavailable_next("record_pending", landed=True)
    chain.tx_result_errors = [ChainUnavailable("노드가 아직 응답하지 않음")]
    with pytest.raises(ChainUnavailable):
        submit(db, chain, entry_id)
    return row(engine, entry_id)["tx_pending"]


def test_resubmit_recovers_once_the_node_answers(engine, db):
    # 다시 제출하면 보내지 않고 그 트랜잭션의 결과로 ③ 을 맞춘다
    chain = Chain()
    entry_id = draft(engine)
    first = lost_but_landed(engine, db, chain, entry_id)
    result = submit(db, chain, entry_id)
    assert result.status is EntryStatus.PENDING and result.tx_hash == first
    assert row(engine, entry_id)["status"] == "PENDING" and chain.sends == 1


def test_stored_hash_in_another_case_is_still_settled(engine, db):
    # 반영·해제의 조건은 DB 에 저장된 값 그대로다. tx_result 가 소문자로 바꾼 hash 로 찾으면 0행이 돼 ② 에 남는다
    chain = Chain()
    entry_id = draft(engine)
    first = lost_but_landed(engine, db, chain, entry_id)
    write(engine, entry_id, tx_pending="0x" + first[2:].upper())
    submit(db, chain, entry_id)
    assert row(engine, entry_id)["status"] == "PENDING"


def test_resubmit_after_a_failed_transaction_sends_again(engine, db):
    # 그 트랜잭션이 블록에서 실패로 끝났으면 체인에 남은 것이 없다 → ① 로 돌리고 이 요청의 서명으로 보낸다
    chain = Chain()
    chain.unavailable_next("record_pending", landed=False)
    entry_id = draft(engine)
    with pytest.raises(ChainUnavailable):
        submit(db, chain, entry_id)
    failed = row(engine, entry_id)["tx_pending"]
    chain.tx_result_errors = [ChainRevert(RevertReason.UNKNOWN, "블록에서 실패")]
    result = submit(db, chain, entry_id)
    assert result.status is EntryStatus.PENDING and result.tx_hash != failed
    assert row(engine, entry_id)["tx_pending"] == result.tx_hash and chain.sends == 2


def test_a_transaction_of_another_step_is_not_settled(engine, db):
    # ② 의 hash 가 이 단계의 트랜잭션이 아니면(등록 칸에 확정 트랜잭션) 그 결과를 쓰지 않는다 — 초안이 CONFIRMED 가 된다
    chain = Chain()
    entry_id = draft(engine)

    async def confirm_on_chain_only():
        await FakeChainClient.record_pending(chain, request_for(entry_id), fake_signature(TREASURER))
        approval = approval_from_entry(await chain.get_entry(entry_id), FAR)
        return await FakeChainClient.confirm_entry(chain, approval, fake_signature(AUDITOR))

    confirmed = asyncio.run(confirm_on_chain_only())
    write(engine, entry_id, tx_pending=confirmed.tx_hash)
    with pytest.raises(EntryInFlight):
        submit(db, chain, entry_id)
    assert row(engine, entry_id)["status"] is None and chain.sends == 0


def test_release_never_clears_someone_elses_claim(engine, db):
    # 비우는 UPDATE 는 칸에 내 hash 가 있을 때만이다. 그 사이 다른 값이 들어갔으면 그대로 둔다
    chain = Chain()
    chain.after_broadcast = ChainRevert(RevertReason.UNKNOWN)
    entry_id = draft(engine)
    other = "0x" + "ee" * 32
    chain.on_broadcast = lambda tx_hash: write(engine, entry_id, tx_pending=other)
    with pytest.raises(ChainRevert):
        submit(db, chain, entry_id)
    assert row(engine, entry_id)["tx_pending"] == other


def test_settle_does_not_report_success_when_the_db_disagrees(engine, db):
    # 체인은 끝났는데 DB 의 선점이 바뀌어 반영이 0행이면, 성공으로 돌려주지 않는다 (DB 는 ② 로 남는다)
    chain = Chain()
    entry_id = draft(engine)
    chain.on_broadcast = lambda tx_hash: write(engine, entry_id, tx_pending="0x" + "ee" * 32)
    with pytest.raises(RuntimeError, match="DB 가 체인 결과와 다르다"):
        submit(db, chain, entry_id)


def test_claim_after_the_entry_changed_reports_the_current_state(engine, db):
    # 읽은 뒤 선점 전에 다른 요청이 기록을 끝냈다 — "처리 중" 이 아니라 "이미 기록됨" 이고, 보내지 않는다
    chain = Chain()
    entry_id = draft(engine)
    chain.before_send = lambda: write(engine, entry_id, status="PENDING", tx_pending="0x" + "ee" * 32)
    with pytest.raises(EntryAlreadyRecorded):
        submit(db, chain, entry_id)
    assert asyncio.run(chain.get_entry(entry_id)) is None


# ---------------------------------------------------------------- 등록: 동시 요청


def run_together(engine, chain, entry_id):
    """같은 초안에 두 요청이 동시에 온다. 요청마다 세션이 다르다. 결과는 먼저 끝난 순서와 상관없이 (성공, 실패) 로."""

    async def both():
        with Session(engine) as a, Session(engine) as b:
            return await asyncio.gather(
                relay_record(a, chain, request_for(entry_id), fake_signature(TREASURER)),
                relay_record(b, chain, request_for(entry_id), fake_signature(TREASURER)),
                return_exceptions=True,
            )

    return asyncio.run(both())


def test_concurrent_submits_record_once(engine):
    # 둘째 요청은 선점에 실패하거나 시뮬레이션에서 ENTRY_ALREADY_EXISTS 로 걸린다. 어느 쪽이든 400 "revert" 가 아니라 409
    chain = Chain()
    entry_id = draft(engine)
    outcomes = run_together(engine, chain, entry_id)
    results = [o for o in outcomes if not isinstance(o, BaseException)]
    conflicts = [o for o in outcomes if isinstance(o, EntryConflict)]
    assert len(results) == 1 and len(conflicts) == 1, outcomes
    assert row(engine, entry_id)["tx_pending"] == results[0].tx_hash


def test_concurrent_submit_while_the_first_is_unknown_is_not_sent(engine):
    # 첫 요청이 응답을 잃어 ② 인 동안, 같은 초안을 먼저 읽어 둔 둘째 요청은 선점에 실패해 보내지 않는다
    chain = Chain()
    chain.unavailable_next("record_pending", landed=False)
    entry_id = draft(engine)
    outcomes = run_together(engine, chain, entry_id)
    assert sorted(type(o).__name__ for o in outcomes) == ["ChainUnavailable", "EntryInFlight"], outcomes
    assert asyncio.run(chain.get_entry(entry_id)) is None  # 둘째는 체인에 닿지 않았다
    assert row(engine, entry_id)["status"] is None and row(engine, entry_id)["tx_pending"] is not None


# ---------------------------------------------------------------- 확정


def recorded(engine, db, chain, kind: str = "INCOME", amount: int = 500_000) -> int:
    entry_id = draft(engine, kind=kind, amount=amount)
    submit(db, chain, entry_id, kind=EntryKind(kind), amount=amount)
    return entry_id


def test_confirmation_records_the_approver_and_reason(engine, db):
    chain = Chain()
    entry_id = recorded(engine, db, chain)
    result = asyncio.run(approve(db, chain, entry_id, **warned()))
    assert result.status is EntryStatus.CONFIRMED
    saved = row(engine, entry_id)
    assert (saved["status"], saved["tx_confirm"], saved["approved_by"], saved["warning_ack_reason"]) == (
        "CONFIRMED",
        result.tx_hash,
        AUDITOR_ID,
        REASON,
    )


@pytest.mark.parametrize(
    "case",
    [
        warned(reason="다른 사유"),  # 서명된 해시와 다른 원문
        warned(reason="OCR 금액 불일치, 영수증 원본 확인함 "),  # 정본이 아닌 원문 (끝 공백)
        warned(reason=""),  # 빈 문자열은 해시하지 않는다
        warned(reason=None),
        warned(warning_reason_hash=ZERO_BYTES32),
        {"reason": REASON},  # 경고 승인이 아닌데 사유
    ],
)
def test_warning_reason_must_match_the_signed_hash(engine, db, case):
    # 다르면 체인에는 서명된 해시, DB 에는 다른 원문이 남아 학생 검증에서 위조로 보인다 (HASHING §2.1·§3)
    chain = Chain()
    entry_id = recorded(engine, db, chain)
    with pytest.raises(ValueError):
        asyncio.run(approve(db, chain, entry_id, **case))
    assert chain.sends == 1 and row(engine, entry_id)["tx_confirm"] is None  # 확정은 보내지 않았다


def test_failed_confirmation_releases_the_approver_too(engine, db):
    # 예산 부족 등으로 전송이 revert 하면 PENDING 그대로, 선점한 tx_confirm·approved_by·사유를 함께 비운다 (반려 흐름으로)
    chain = Chain()
    entry_id = recorded(engine, db, chain)
    chain.after_broadcast = ChainRevert(RevertReason.INSUFFICIENT_BUDGET)
    with pytest.raises(ChainRevert):
        asyncio.run(approve(db, chain, entry_id, **warned()))
    saved = row(engine, entry_id)
    assert saved["status"] == "PENDING" and saved["tx_confirm"] is None
    assert saved["approved_by"] is None and saved["warning_ack_reason"] is None


def test_lost_confirmation_is_recovered(engine, db):
    chain = Chain()
    entry_id = recorded(engine, db, chain)
    chain.unavailable_next("confirm_entry", landed=True)
    result = asyncio.run(approve(db, chain, entry_id))
    assert result.status is EntryStatus.CONFIRMED and row(engine, entry_id)["status"] == "CONFIRMED"


def lost_confirmation(engine, db, chain, entry_id, **approval):
    chain.unavailable_next("confirm_entry", landed=True)
    chain.tx_result_errors = [ChainUnavailable("노드가 아직 응답하지 않음")]
    with pytest.raises(ChainUnavailable):
        asyncio.run(approve(db, chain, entry_id, **approval))


def test_the_same_approver_retrying_gets_their_result(engine, db):
    chain = Chain()
    entry_id = recorded(engine, db, chain)
    lost_confirmation(engine, db, chain, entry_id, **warned())
    result = asyncio.run(approve(db, chain, entry_id, **warned()))
    assert result.status is EntryStatus.CONFIRMED and chain.sends == 2  # 등록 1 + 확정 1. 다시 보내지 않았다


@pytest.mark.parametrize(
    "second",
    [
        {"approver_id": PRESIDENT_ID, "signer": PRESIDENT, **warned()},  # 다른 승인자
        warned(reason="다른 사유", warning_reason_hash="0x" + hashlib.sha256("다른 사유".encode()).hexdigest()),  # 같은 승인자, 다른 사유
    ],
)
def test_someone_elses_confirmation_is_not_reported_as_theirs(engine, db, second):
    # 감사 A 의 확정이 응답을 잃은 뒤 들어왔다. 다른 요청에 A 의 결과를 성공(200)으로 돌려주지 않는다 — 그 서명은 보내지 않았다
    chain = Chain()
    entry_id = recorded(engine, db, chain)
    lost_confirmation(engine, db, chain, entry_id, **warned())
    with pytest.raises(EntryAlreadyRecorded):
        asyncio.run(approve(db, chain, entry_id, **second))
    saved = row(engine, entry_id)
    assert (saved["status"], saved["approved_by"], saved["warning_ack_reason"]) == ("CONFIRMED", AUDITOR_ID, REASON)
    assert chain.sends == 2


def test_concurrent_confirmations_confirm_once(engine, db):
    chain = Chain()
    entry_id = recorded(engine, db, chain)

    async def both():
        with Session(engine) as a, Session(engine) as b:
            return await asyncio.gather(approve(a, chain, entry_id), approve(b, chain, entry_id), return_exceptions=True)

    outcomes = asyncio.run(both())
    assert sorted(type(o).__name__ for o in outcomes)[0] in ("EntryAlreadyRecorded", "EntryInFlight"), outcomes
    assert sum(not isinstance(o, BaseException) for o in outcomes) == 1


@pytest.mark.parametrize("state", ["draft", "blocked"])
def test_only_pending_entries_can_be_confirmed(engine, db, state):
    chain = Chain()
    entry_id = draft(engine) if state == "draft" else recorded(engine, db, chain, kind="EXPENSE", amount=35_000)
    with pytest.raises(ValueError, match="확정할 수 있는 상태가 아니다"):
        asyncio.run(approve(db, chain, entry_id))  # 초안은 체인에 없어 approval_for_id 가 임시 값을 채운다
    assert chain.sends == (0 if state == "draft" else 1)  # 확정은 보내지 않았다


@pytest.mark.parametrize("approver_id", [TREASURER_ID, 999], ids=["self_approval", "unknown_user"])
def test_unrecordable_approver_is_refused_before_sending(engine, db, approver_id):
    # 등록자 = 승인자(ck_entries_maker_checker)·없는 사용자(FK) 는 선점에서 막혀 500 이 아니라 400(ValueError), 보내지 않는다
    chain = Chain()
    entry_id = recorded(engine, db, chain)
    with pytest.raises(ValueError, match="선점을 기록할 수 없다"):
        asyncio.run(approve(db, chain, entry_id, approver_id=approver_id))
    assert asyncio.run(chain.get_entry(entry_id)).status is EntryStatus.PENDING
    assert row(engine, entry_id)["tx_confirm"] is None


def rejection_in_flight(engine, db, chain, entry_id, tx_hash):
    """반려 흐름이 tx_confirm 을 선점했다 (rejected_by·사유와 함께, approved_by 는 비어 있다)."""
    write(engine, entry_id, tx_confirm=tx_hash, rejected_by=AUDITOR_ID, reject_reason="반려 사유")


def test_confirmation_leaves_a_landed_rejection_to_the_rejection_flow(engine, db):
    # tx_confirm 은 반려와 같이 쓰는 칸이다. 반려의 선점이면 확정 흐름은 결과를 읽지도 쓰지도 않고 409 로 끝낸다
    chain = Chain()
    entry_id = recorded(engine, db, chain)
    entry = asyncio.run(chain.get_entry(entry_id))
    decision = RejectDecision(id=entry_id, entry_commit=entry_commit_of(entry), reason_hash="0x" + "77" * 32, deadline=FAR)
    rejected = asyncio.run(chain.reject_entry(decision, fake_signature(AUDITOR)))
    rejection_in_flight(engine, db, chain, entry_id, rejected.tx_hash)
    before = row(engine, entry_id)
    with pytest.raises(EntryInFlight, match="반려"):
        asyncio.run(approve(db, chain, entry_id))
    assert row(engine, entry_id) == before and chain.tx_result_calls == 0 and chain.sends == 1


def test_confirmation_does_not_release_a_failed_rejection(engine, db):
    # 반려 트랜잭션이 블록에서 실패해도, 확정 흐름이 그 선점을 비우고 확정을 보내면 rejected_by·사유가 남은 CONFIRMED 가 된다
    chain = Chain()
    entry_id = recorded(engine, db, chain)
    rejection_in_flight(engine, db, chain, entry_id, "0x" + "dd" * 32)
    chain.tx_result_errors = [ChainRevert(RevertReason.UNKNOWN, "반려가 블록에서 실패")]
    before = row(engine, entry_id)
    with pytest.raises(EntryInFlight):
        asyncio.run(approve(db, chain, entry_id))
    assert row(engine, entry_id) == before and chain.sends == 1


def test_confirming_a_confirmed_entry_is_a_conflict(engine, db):
    chain = Chain()
    entry_id = recorded(engine, db, chain)
    asyncio.run(approve(db, chain, entry_id))
    with pytest.raises(EntryConflict):
        asyncio.run(approve(db, chain, entry_id))
    assert chain.sends == 2  # 등록 1 + 확정 1


# ---------------------------------------------------------------- FakeChainClient.tx_result


def test_fake_tx_result_reads_landed_transactions_only():
    async def run():
        chain = FakeChainClient()
        landed = await chain.record_pending(request_for(1), fake_signature(TREASURER))
        chain.unavailable_next("record_pending", landed=False)
        lost = []
        with pytest.raises(ChainUnavailable):
            await chain.record_pending(request_for(2), fake_signature(TREASURER), lambda h: _append(lost, h))
        return chain, landed, lost[0]

    chain, landed, lost = asyncio.run(run())
    assert asyncio.run(chain.tx_result(landed.tx_hash, 1)) == landed
    assert asyncio.run(chain.tx_result("0x" + landed.tx_hash[2:].upper(), 1)) == landed  # 대소문자는 같은 hash
    assert asyncio.run(chain.tx_result(lost, 2)) is None  # 닿지 않았다
    assert asyncio.run(chain.tx_result("0x" + "ab" * 32, 1)) is None
    with pytest.raises(ChainUnavailable, match="결과 이벤트를 찾지 못했다"):
        asyncio.run(chain.tx_result(landed.tx_hash, 2))  # 다른 id 의 트랜잭션
    with pytest.raises(ValueError, match="hex 64자"):
        asyncio.run(chain.tx_result("0x1234", 1))


def test_fake_tx_hashes_differ_between_instances():
    # 서버를 다시 켜 새 가짜가 생겨도 DB 에 남은 옛 hash 와 겹치지 않는다 (겹치면 tx_result 가 남의 결과를 읽는다)
    async def first_hash():
        return (await FakeChainClient().record_pending(request_for(1), fake_signature(TREASURER))).tx_hash

    assert asyncio.run(first_hash()) != asyncio.run(first_hash())


async def _append(seen: list, value) -> None:
    seen.append(value)


# ---------------------------------------------------------------- 실제 체인 (스냅샷 안)

DOMAIN = load_deployment(DEFAULT_PATH).eip712[LEDGER]


@pytest.mark.chain
def test_record_and_confirm_on_the_real_chain(node, engine, db, clean_chain_env):
    # 실제 릴레이어로 ① → ③ → CONFIRMED. DB 의 hash 가 체인의 receipt 와 같다
    entry_id = draft(engine, id=TEST_ID_BASE + 7001)

    async def body(client, now):
        request = request_for(entry_id, deadline=now + 600)
        recorded = await relay_record(db, client, request, sign_as_app(request, DOMAIN, TREASURER_KEY))
        approval = approval_from_entry(await client.get_entry(entry_id), now + 600)
        confirmed = await relay_confirm(db, client, approval, sign_as_app(approval, DOMAIN, AUDITOR_KEY), AUDITOR_ID)
        receipts = [await client._w3.eth.get_transaction_receipt(r.tx_hash) for r in (recorded, confirmed)]
        return recorded, confirmed, [r["status"] for r in receipts]

    recorded, confirmed, statuses = on_chain(body)
    assert statuses == [1, 1]
    saved = row(engine, entry_id)
    assert (saved["status"], saved["tx_pending"], saved["tx_confirm"]) == ("CONFIRMED", recorded.tx_hash, confirmed.tx_hash)


@pytest.mark.chain
def test_lost_response_is_recovered_on_the_real_chain(node, engine, db, clean_chain_env):
    # 트랜잭션은 블록에 들어갔는데 응답을 잃었다 — 저장한 hash 로 receipt 를 읽어 ③ 을 맞춘다 (사유까지)
    entry_id = draft(engine, kind="EXPENSE", amount=35_000, id=TEST_ID_BASE + 7002)

    async def body(client, now):
        relay = client._relay

        async def lost(call, before_broadcast):
            await relay(call, before_broadcast)
            raise ChainUnavailable("receipt 를 받지 못했다 (흉내)")

        client._relay = lost
        request = request_for(entry_id, kind=EntryKind.EXPENSE, amount=35_000, deadline=now + 600)
        return await relay_record(db, client, request, sign_as_app(request, DOMAIN, TREASURER_KEY))

    result = on_chain(body)
    assert (result.status, result.block_reason) == (EntryStatus.BLOCKED, BlockReason.BUDGET_NOT_FOUND)
    saved = row(engine, entry_id)
    assert (saved["status"], saved["block_reason"], saved["tx_pending"]) == ("BLOCKED", "BUDGET_NOT_FOUND", result.tx_hash)
