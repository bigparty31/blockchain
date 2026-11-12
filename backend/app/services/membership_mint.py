"""회원권 일괄 발행 (A3) — 준비·제출·결과 확인 (PRD v0.16 §4.2, §7.2, §9.2, docs/API.md 「회원권 2」).

흐름은 예산 최초 편성과 같다. 준비에서 서명할 값(학기 코드·nonce·수령자 순서)을 정해 저장하고, 제출에서 그 값으로
MintBatchRequest 를 다시 만들어 서명자를 확인한 뒤 릴레이한다. 서버는 서명하지 않는다 — 회장 또는 감사의 기기 서명이 없으면
발행되지 않는다 (서버 혼자 발행할 수 있으면 납부하지 않은 학생에게도 자격을 줄 수 있다, §4.2).

- 수령자는 학번이 아니라 서버가 wallet_index 로 파생한 학생 주소다. 승인자는 학번을 보고 주소에 서명한다 (§13 한계)
- 이미 보유한 학생은 준비에서 뺀다 (체인 hasValidMembership 기준). 그사이 발행돼도 컨트랙트가 건너뛴다 (SKIPPED).
  뺀 학생에게 DB 기록이 없으면 이때 체인 tokenOf 로 채운다 (결과를 모른 채 끝난 발행을 조회 없이 다시 준비한 경우, _backfill)
- DB 에 유효한 회원권 기록이 있는데 체인에 없으면 빼고 운영자 확인을 요구한다 (DB_MISMATCH) — 체인만 재배포한 환경이면
  tokenId 가 1부터 다시 시작해 DB 기록과 겹칠 수 있다
- nonce 는 서명자별이고 발행·소각이 공유한다. 제출 때 체인의 nonce 가 준비 때와 다르면 보내지 않는다 (다시 준비)
- 보내기 직전에 tx_hash 를 조건부 UPDATE 로 선점한다(SUBMITTING). 응답을 잃으면(NO_RESPONSE) 같은 서명을 다시 보내지 않는다 —
  들어갔으면 nonce 가 올라 재전송은 InvalidNonce 로 보이고 결과를 잃는다. 저장한 hash 로 결과를 확인한다 (refresh)
- 결과를 반영할 때 학생마다 DB 회원권 기록을 만든다. 만들지 못하면(token_id·활성 기록 충돌) 그 학생만 membership_id 가 없고
  나머지는 그대로 반영한다. INSERT ... ON CONFLICT DO NOTHING 으로 한다 — 세이브포인트 롤백은 세션 after_rollback 을 일으킨다
"""
import asyncio
import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable, Dict, List, Optional, Tuple, TypeVar

from sqlalchemy import update
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.chain.client import ChainClient
from app.chain.models import ChainError, ChainRevert, ChainSetupError, ChainUnavailable, MintBatchRequest, MintBatchResult
from app.auth import User
from app.models import Membership, MembershipMintBatch, MembershipMintTarget, Term
from app.models import User as DBUser
from app.schemas.auth import Role
from app.services.student_wallet import WalletDerivationError, student_address

logger = logging.getLogger(__name__)

T = TypeVar("T")

SUBMITTABLE = ("PREPARED", "REJECTED")
IN_FLIGHT = ("SUBMITTING", "NO_RESPONSE")


# ---------------------------------------------------------------- 오류 (라우터가 HTTP 코드로 바꾼다)


class MintError(Exception):
    """부른 쪽이 HTTP 오류로 바꾸는 실패. code 는 HTTP 상태 코드다."""

    code = 400

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message


class MintBadRequest(MintError):
    code = 400


class MintForbidden(MintError):
    code = 403


class MintNotFound(MintError):
    code = 404


class MintConflict(MintError):
    code = 409


class MintUnavailable(MintError):
    code = 503


class NothingToMint(MintBadRequest):
    """준비했더니 발행할 학생이 0명이다. excluded 로 학생별 사유를 보여 준다."""

    def __init__(self, excluded: List["Excluded"]):
        super().__init__("발행할 학생이 없습니다. 명단의 학생이 모두 제외되었습니다.")
        self.excluded = excluded


@dataclass(frozen=True)
class Excluded:
    student_no: str
    status: str  # ALREADY_MEMBER | NOT_FOUND | NOT_STUDENT | DUPLICATE | DB_MISMATCH
    user_id: Optional[int] = None
    name: Optional[str] = None


@dataclass
class Prepared:
    batch: MembershipMintBatch
    excluded: List[Excluded] = field(default_factory=list)


# ---------------------------------------------------------------- 준비


async def prepare(db: Session, chain: ChainClient, user: User, term_id: int, student_nos: List[str]) -> Prepared:
    """명단으로 발행 요청을 만든다. 발행할 학생이 0명이면 NothingToMint 이고 저장하지 않는다."""
    if not user.wallet_address:
        raise MintBadRequest("로그인한 임원의 지갑 주소가 등록되어 있지 않아 서명할 수 없습니다.")
    term = db.get(Term, term_id)
    if term is None:
        raise MintNotFound(f"ID {term_id}에 해당하는 학기를 찾을 수 없습니다.")

    # (명단에서의 자리, 사유). 화면이 명단 순서대로 보여 줄 수 있게 마지막에 자리 순으로 정렬한다
    excluded: List[Tuple[int, Excluded]] = []
    ordered: List[str] = []
    position: Dict[str, int] = {}
    for i, raw in enumerate(student_nos):
        student_no = raw.strip()
        if student_no in position:
            excluded.append((i, Excluded(student_no, "DUPLICATE")))
        else:
            position[student_no] = i
            ordered.append(student_no)
    users = {u.student_no: u for u in db.query(DBUser).filter(DBUser.student_no.in_(ordered))} if ordered else {}
    active = {
        m.user_id
        for m in db.query(Membership.user_id).filter(
            Membership.term_id == term.id,
            Membership.burned_at.is_(None),
            Membership.user_id.in_([u.id for u in users.values()]),
        )
    }

    candidates: List[Tuple[str, DBUser, str]] = []
    for student_no in ordered:
        u = users.get(student_no)
        if u is None:
            excluded.append((position[student_no], Excluded(student_no, "NOT_FOUND")))
        elif u.role != Role.STUDENT.value or u.wallet_index is None:
            excluded.append((position[student_no], Excluded(student_no, "NOT_STUDENT", u.id, u.name)))
        else:
            try:
                candidates.append((student_no, u, student_address(u.wallet_index)))
            except WalletDerivationError as e:
                raise MintUnavailable(f"학생 지갑 주소를 만들 수 없습니다: {e}") from e

    try:
        held = await asyncio.gather(*(chain.has_valid_membership(address, term.term_code) for _, _, address in candidates))
        nonce = await chain.membership_nonce(user.wallet_address)
    except ChainError as e:
        raise MintUnavailable(f"체인에서 회원권 보유 여부를 확인하지 못했습니다: {e}") from e

    targets: List[Tuple[DBUser, str]] = []
    unrecorded: List[Tuple[int, str]] = []  # 체인에는 있는데 DB 기록이 없는 학생 (user_id, 주소)
    for (student_no, u, address), has in zip(candidates, held):
        if has:
            excluded.append((position[student_no], Excluded(student_no, "ALREADY_MEMBER", u.id, u.name)))
            if u.id not in active:
                unrecorded.append((u.id, address))
        elif u.id in active:
            # DB 에는 유효한 기록이 있는데 체인에는 없다. 발행하면 DB 기록과 겹치므로 운영자가 먼저 확인한다
            excluded.append((position[student_no], Excluded(student_no, "DB_MISMATCH", u.id, u.name)))
        else:
            targets.append((u, address))
    reasons = [x for _, x in sorted(excluded, key=lambda pair: pair[0])]
    if unrecorded:
        await _backfill(db, chain, term, unrecorded)
    if not targets:
        raise NothingToMint(reasons)

    batch = MembershipMintBatch(
        term_id=term.id,
        requested_by=user.id,
        signer_address=user.wallet_address.lower(),
        nonce=nonce,
        status="PREPARED",
    )
    batch.targets = [
        MembershipMintTarget(position=i, user_id=u.id, address=address, status="PENDING") for i, (u, address) in enumerate(targets)
    ]
    db.add(batch)
    db.commit()
    db.refresh(batch)
    return Prepared(batch, reasons)


async def _backfill(db: Session, chain: ChainClient, term: Term, unrecorded: List[Tuple[int, str]]) -> None:
    """체인에는 있는데 DB 기록이 없는 학생의 기록을 채운다. 결과를 모른 채 끝난 발행(NO_RESPONSE)을 조회 없이 다시 준비하면
    이 학생은 ALREADY_MEMBER 로 빠져 기록이 영영 생기지 않는다 — 그러면 GET /memberships/me 의 id 가 없어 앱이 미보유로 그린다.

    별도 세션으로 바로 커밋한다. 발행할 학생이 0명이라 준비가 400 으로 끝나도 채운 기록은 남는다.
    tokenOf 가 0(그사이 소각)이거나 읽지 못하면 채우지 않는다. 충돌(같은 token_id 등)이면 그 학생만 채우지 않는다.
    채우지 못해도 준비 결과는 같다 — 실패는 로그로만 남긴다. minted_at 은 실제 발행 시각을 몰라 지금 시각이다.
    """
    tokens = await asyncio.gather(*(chain.membership_token_of(address, term.term_code) for _, address in unrecorded), return_exceptions=True)
    found: List[Tuple[int, int]] = []
    for (user_id, address), token in zip(unrecorded, tokens):
        if isinstance(token, BaseException):
            if not isinstance(token, ChainError):
                raise token
            logger.warning("회원권 기록을 채우지 못함 — tokenId 를 읽지 못함 (user=%s address=%s): %s", user_id, address, token)
        elif token == 0:
            logger.warning("회원권 기록을 채우지 않음 — 그사이 소각됨 (user=%s address=%s)", user_id, address)
        else:
            found.append((user_id, token))
    if not found:
        return
    db.commit()  # 준비 세션의 읽기 트랜잭션을 닫는다. 채운 기록이 아래 조회에도 보이게 한다

    def fill(s: Session) -> None:
        now = _now()
        for user_id, token in found:
            _existing_or_new_membership(s, user_id, term.id, token, now)

    try:
        await _short(db, fill)
    except SQLAlchemyError as e:
        logger.warning("회원권 기록을 채우지 못함 — DB 오류 (term=%s): %s", term.id, e)


# ---------------------------------------------------------------- 제출


def mint_request(batch: MembershipMintBatch, term_code: int, deadline: int) -> MintBatchRequest:
    """저장된 값으로 서명 대상을 다시 만든다. 앱이 준비 응답의 값으로 만든 것과 같아야 한다."""
    return MintBatchRequest(
        recipients=tuple(t.address for t in sorted(batch.targets, key=lambda t: t.position)),
        term=term_code,
        nonce=batch.nonce,
        deadline=deadline,
    )


async def submit(
    db: Session, chain: ChainClient, user: User, batch_id: int, deadline: int, signature: str
) -> MembershipMintBatch:
    """서명을 확인하고 릴레이한다. 결과(MINTED·REJECTED·NO_RESPONSE)를 반영한 요청을 돌려준다."""
    batch = db.get(MembershipMintBatch, batch_id)
    if batch is None:
        raise MintNotFound(f"ID {batch_id}에 해당하는 발행 요청을 찾을 수 없습니다.")
    if batch.requested_by != user.id:
        raise MintForbidden("발행 요청을 준비한 임원만 제출할 수 있습니다.")
    if batch.status == "MINTED":
        raise MintConflict("이미 발행된 요청입니다.")
    if batch.status in IN_FLIGHT:
        raise MintConflict("이 요청은 체인에 보내는 중이거나 결과를 확인하는 중입니다. 조회로 결과를 확인해 주세요.")

    term_code = batch.term.term_code
    request = mint_request(batch, term_code, deadline)
    try:
        signer = chain.signer_of(request, signature)
    except ValueError as e:
        raise MintBadRequest(f"유효하지 않은 서명 형식입니다: {e}") from e
    except ChainSetupError as e:
        raise MintUnavailable(str(e)) from e
    if signer.lower() != batch.signer_address.lower():
        raise MintBadRequest("서명자가 발행을 준비한 임원의 지갑 주소와 일치하지 않습니다.")

    try:
        current = await chain.membership_nonce(batch.signer_address)
    except ChainError as e:
        raise MintUnavailable(f"체인의 nonce 를 확인하지 못했습니다: {e}") from e
    if current != batch.nonce:
        raise MintConflict("준비한 뒤 같은 임원의 다른 발행·회수가 먼저 처리되었습니다. 다시 준비해 주세요.")

    db.commit()  # 릴레이 전에 열린 트랜잭션을 닫는다 (CHAIN_CLIENT §3)
    claimed: List[str] = []

    async def before_broadcast(tx_hash: str) -> None:
        def claim(s: Session) -> int:
            return s.execute(
                update(MembershipMintBatch)
                .where(MembershipMintBatch.id == batch_id, MembershipMintBatch.status.in_(SUBMITTABLE))
                .values(status="SUBMITTING", tx_hash=tx_hash, signature=signature, deadline=deadline, reason=None, updated_at=_now())
                .execution_options(synchronize_session=False)
            ).rowcount

        if await _short(db, claim) != 1:
            raise MintConflict("다른 제출이 먼저 이 요청을 보내고 있습니다.")
        claimed.append(tx_hash)

    try:
        result = await chain.mint_memberships(request, signature, before_broadcast)
    except MintConflict:
        raise
    except ChainRevert as e:
        reason, tx_hash = e.reason.value, (claimed[0] if claimed else None)
        await _short(db, lambda s: _reject(s, batch_id, tx_hash, reason, signature, deadline))
    except ChainUnavailable as e:
        if not claimed:
            raise MintUnavailable(f"체인에 보내지 못했습니다: {e}") from e
        logger.warning("회원권 발행 결과를 모름 (batch=%s, tx=%s): %s", batch_id, claimed[0], e)
        await _short(db, lambda s: _set_in_flight(s, batch_id, claimed[0], "NO_RESPONSE"))
    except ChainSetupError as e:
        if claimed:
            await _short(db, lambda s: _release(s, batch_id, claimed[0]))
        raise MintUnavailable(str(e)) from e
    else:
        await apply_result(db, chain, batch_id, result)
    db.expire_all()
    return db.get(MembershipMintBatch, batch_id)


# ---------------------------------------------------------------- 결과 확인 (GET)


async def refresh(db: Session, chain: ChainClient, batch_id: int) -> MembershipMintBatch:
    """요청을 돌려준다. 결과를 모르는 상태(SUBMITTING·NO_RESPONSE)면 저장된 hash 로 결과를 확인해 반영한 뒤 돌려준다.

    확인하지 못하면 상태를 그대로 둔다 — 모르는 것을 실패로 단정하지 않는다.
    """
    batch = db.get(MembershipMintBatch, batch_id)
    if batch is None:
        raise MintNotFound(f"ID {batch_id}에 해당하는 발행 요청을 찾을 수 없습니다.")
    if batch.status not in IN_FLIGHT or batch.tx_hash is None:
        return batch
    tx_hash = batch.tx_hash
    try:
        result = await chain.mint_tx_result(tx_hash)
    except ChainRevert as e:
        reason = e.reason.value
        await _short(db, lambda s: _reject_in_flight(s, batch_id, tx_hash, reason))
    except ChainError as e:
        logger.warning("회원권 발행 결과 확인 실패 (batch=%s, tx=%s): %s", batch_id, tx_hash, e)
    else:
        if result is not None:
            await apply_result(db, chain, batch_id, result)
    db.expire_all()
    return db.get(MembershipMintBatch, batch_id)


async def apply_result(db: Session, chain: ChainClient, batch_id: int, result: MintBatchResult) -> None:
    """들어간 발행을 반영한다. 같은 hash 를 두 번 반영하지 않는다 (요청 상태를 조건부 UPDATE 로 먼저 바꾼 쪽만 반영)."""
    batch = db.get(MembershipMintBatch, batch_id)
    term_code = batch.term.term_code
    # MembershipSkipped 에는 tokenId 가 없다. 읽지 못하면 null 로 두고 DB 기록도 만들지 않는다
    skipped_tokens: Dict[str, Optional[int]] = {}
    for address in result.skipped:
        try:
            token = await chain.membership_token_of(address, term_code)
        except ChainError as e:
            logger.warning("건너뛴 회원권의 tokenId 를 읽지 못함 (batch=%s, address=%s): %s", batch_id, address, e)
            token = None
        skipped_tokens[address.lower()] = token or None  # 0 은 그사이 소각됐다는 뜻이다
    minted = {m.address.lower(): m.token_id for m in result.minted}
    db.commit()
    await _short(db, lambda s: _apply(s, batch_id, result.tx_hash, minted, skipped_tokens))


def _apply(s: Session, batch_id: int, tx_hash: str, minted: Dict[str, int], skipped: Dict[str, Optional[int]]) -> None:
    rows = s.execute(
        update(MembershipMintBatch)
        .where(
            MembershipMintBatch.id == batch_id,
            MembershipMintBatch.tx_hash == tx_hash,
            MembershipMintBatch.status.in_(IN_FLIGHT),
        )
        .values(status="MINTED", reason=None, updated_at=_now())
        .execution_options(synchronize_session=False)
    ).rowcount
    if rows != 1:
        return  # 다른 요청(조회·제출)이 먼저 반영했다
    batch = s.get(MembershipMintBatch, batch_id)
    now = _now()
    for target in batch.targets:
        key = target.address.lower()
        if key in minted:
            target.status, target.token_id = "MINTED", minted[key]
            # 준비가 먼저 채웠을 수 있다 (_backfill). 같은 tokenId 의 기록이 있으면 그것을 잇는다
            target.membership_id = _existing_or_new_membership(s, target.user_id, batch.term_id, minted[key], now)
        elif key in skipped:
            target.status, target.token_id = "SKIPPED", skipped[key]
            target.membership_id = _existing_or_new_membership(s, target.user_id, batch.term_id, skipped[key], now)
        else:
            # 서명한 수령자인데 결과 이벤트가 없다 — 컨트랙트가 모든 수령자에 이벤트를 남기므로 일어나면 안 된다
            logger.error("발행 결과에 없는 수령자 (batch=%s, address=%s, tx=%s)", batch_id, target.address, tx_hash)


def _existing_or_new_membership(s: Session, user_id: int, term_id: int, token_id: Optional[int], now: datetime) -> Optional[int]:
    row = (
        s.query(Membership)
        .filter(Membership.user_id == user_id, Membership.term_id == term_id, Membership.burned_at.is_(None))
        .first()
    )
    if row is not None:
        if token_id is not None and row.token_id == token_id:
            return row.id
        logger.warning(
            "DB 회원권 기록과 체인 tokenId 가 다름 (user=%s term=%s db=%s chain=%s)", user_id, term_id, row.token_id, token_id
        )
        return None
    if token_id is None:
        return None
    return _record_membership(s, user_id, term_id, token_id, now)


def _record_membership(s: Session, user_id: int, term_id: int, token_id: int, now: datetime) -> Optional[int]:
    """회원권 기록을 만든다. 같은 token_id 나 같은 학생·학기의 유효한 기록이 이미 있으면 만들지 않고 None (그 학생만)."""
    new_id = _insert_ignoring_conflict(
        s, Membership, {"user_id": user_id, "term_id": term_id, "token_id": token_id, "minted_at": now, "created_at": now}
    )
    if new_id is None:
        logger.warning(
            "회원권 기록을 만들지 못함 — 충돌 (user=%s term=%s token=%s). 체인 기록이 기준이며 운영자 확인이 필요하다",
            user_id,
            term_id,
            token_id,
        )
    return new_id


def _insert_ignoring_conflict(s: Session, model, values: dict) -> Optional[int]:
    """INSERT ... ON CONFLICT DO NOTHING RETURNING id. 넣었으면 새 id, 충돌이면 None.

    IntegrityError 를 세이브포인트로 잡지 않는다 — 세이브포인트 롤백도 세션의 after_rollback 을 일으켜 같은 세션의 다른 처리에 걸린다.
    """
    dialect = s.get_bind().dialect.name
    if dialect == "postgresql":
        from sqlalchemy.dialects.postgresql import insert
    elif dialect == "sqlite":
        from sqlalchemy.dialects.sqlite import insert
    else:
        raise RuntimeError(f"지원하지 않는 DB 다: {dialect}")
    return s.execute(insert(model).values(**values).on_conflict_do_nothing().returning(model.id)).scalar_one_or_none()


def _reject(s: Session, batch_id: int, tx_hash: Optional[str], reason: str, signature: str, deadline: int) -> None:
    """체인이 거부했다. 선점했으면 그 hash 의 요청만, 선점 전(시뮬레이션)이면 제출할 수 있는 상태의 요청만 바꾼다."""
    condition = (
        MembershipMintBatch.tx_hash == tx_hash if tx_hash is not None else MembershipMintBatch.status.in_(SUBMITTABLE)
    )
    s.execute(
        update(MembershipMintBatch)
        .where(MembershipMintBatch.id == batch_id, condition)
        .values(status="REJECTED", reason=reason, signature=signature, deadline=deadline, updated_at=_now())
        .execution_options(synchronize_session=False)
    )


def _reject_in_flight(s: Session, batch_id: int, tx_hash: str, reason: str) -> None:
    s.execute(
        update(MembershipMintBatch)
        .where(MembershipMintBatch.id == batch_id, MembershipMintBatch.tx_hash == tx_hash, MembershipMintBatch.status.in_(IN_FLIGHT))
        .values(status="REJECTED", reason=reason, updated_at=_now())
        .execution_options(synchronize_session=False)
    )


def _set_in_flight(s: Session, batch_id: int, tx_hash: str, status: str) -> None:
    s.execute(
        update(MembershipMintBatch)
        .where(MembershipMintBatch.id == batch_id, MembershipMintBatch.tx_hash == tx_hash, MembershipMintBatch.status.in_(IN_FLIGHT))
        .values(status=status, updated_at=_now())
        .execution_options(synchronize_session=False)
    )


def _release(s: Session, batch_id: int, tx_hash: str) -> None:
    """선점한 뒤 보내지 못했다 (ChainSetupError). 다시 제출할 수 있게 되돌린다."""
    s.execute(
        update(MembershipMintBatch)
        .where(MembershipMintBatch.id == batch_id, MembershipMintBatch.tx_hash == tx_hash, MembershipMintBatch.status == "SUBMITTING")
        .values(status="PREPARED", tx_hash=None, updated_at=_now())
        .execution_options(synchronize_session=False)
    )


async def _short(db: Session, fn: Callable[[Session], T]) -> T:
    """릴레이어 lock 안(before_broadcast)이나 체인 대기 직후의 DB 갱신을 별도 스레드·짧은 세션으로 한다 (예산 발행과 같다)."""
    bind = db.get_bind()

    def work() -> T:
        with Session(bind=bind, expire_on_commit=False) as s:
            try:
                out = fn(s)
                s.commit()
                return out
            except Exception:
                s.rollback()
                raise

    return await asyncio.to_thread(work)


def _now() -> datetime:
    return datetime.now(timezone.utc)
