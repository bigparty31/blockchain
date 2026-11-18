"""계좌 대조 API — PRD v0.15 §4.6.

총무가 은행 거래내역 CSV 를 올리면 파싱해 원장과 1:1 로 맞추고, 짝이 없는 거래를 지목한다.
- 원장에 자동 반영하지 않는다. 파일은 검사 용도로만 쓴다 (자동 반영하면 대조 대상이 사라진다)
- 해시는 원본 바이트 그대로 SHA-256 (HASHING.md §4). 온체인 기록은 컨트랙트가 아직 없어 tx_hash 는 비워 둔다

한 학기에 여러 번 올릴 수 있다. 원장 항목 하나는 은행 거래 하나에만 짝이 될 수 있어서
(uq_bank_tran_matched_entry), 새로 올리면 같은 학기 이전 스냅샷의 짝을 풀고 최신 파일로 다시 맞춘다.
이전 스냅샷은 파일 해시·거래 줄을 근거로 남기고 superseded 로 표시한다.
"""
import base64
import binascii
import hashlib
import logging
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session

from app.auth.deps import require_roles
from app.auth.users import User
from app.bank import BankCsvError, BankRow, Candidate, match, parse_bank_csv
from app.database import get_db
from app.models import BankTransaction as DBBankTx
from app.models import Entry as DBEntry
from app.models import Snapshot as DBSnapshot
from app.models import Term as DBTerm
from app.schemas.auth import Role
from app.schemas.bank import (
    BankRowResult,
    BankUploadRequest,
    ReconcileSummary,
    ReconciliationReport,
    RowStatus,
    SnapshotItem,
    UnbackedEntry,
)
from app.services.notifications import notify_students_balance_mismatch

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/bank", tags=["Bank Reconciliation"])

treasurer_only = require_roles(Role.TREASURER)
council_only = require_roles(Role.TREASURER, Role.AUDITOR, Role.PRESIDENT)

MAX_FILE_BYTES = 2 * 1024 * 1024  # 한 학기 거래내역 CSV 는 수십 KB 수준
DB_ERROR = "데이터베이스 처리 중 오류가 발생했습니다."
KST = timezone(timedelta(hours=9))
_KIND_TO_DIRECTION = {"INCOME": "IN", "EXPENSE": "OUT"}


def _db_error(e: Exception, db: Session, what: str) -> HTTPException:
    db.rollback()
    logger.exception("%s 중 데이터베이스 오류 발생: %s", what, e)
    return HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=DB_ERROR)


def _kst_date(unix_seconds: int) -> str:
    # occurred_at 은 KST 자정 Unix 초 (models.Entry)
    return datetime.fromtimestamp(unix_seconds, KST).strftime("%Y-%m-%d")


# ---------------------------------------------------------------- 원장 후보


class _Ledger:
    """학기 원장에서 대조 후보를 만든다.

    - 후보는 정정이 아닌 원본 항목 중 PENDING·CONFIRMED 만. 초안·REJECTED·BLOCKED 는 제외 —
      특히 BLOCKED(예산 초과로 확정 못 한 지출)에 대응하는 출금은 '미등록'으로 잡혀야 한다 (BANK_CSV.md 부록)
    - 금액은 원본 + 확정된 정정의 합(순금액). 입력오류로 50,000 → 30,000 정정했다면 계좌엔 30,000 이 찍힌다
    - 순금액이 0 이하(전액 환불 등)면 후보에서 뺀다
    """

    def __init__(self, db: Session, term_id: int):
        entries = (
            db.query(DBEntry)
            .filter(DBEntry.term_id == term_id, DBEntry.status.in_(("PENDING", "CONFIRMED")))
            .all()
        )
        by_id = {e.id: e for e in entries}
        net: Dict[int, int] = {e.id: e.amount for e in entries if e.corrects_entry_id is None}
        for e in entries:
            if e.corrects_entry_id is None or e.status != "CONFIRMED":
                continue
            # 재분류 양수 정정을 다시 정정할 수 있어 원본까지 거슬러 올라간다
            root = e
            seen = set()
            while root.corrects_entry_id is not None and root.corrects_entry_id in by_id and root.id not in seen:
                seen.add(root.id)
                root = by_id[root.corrects_entry_id]
            if root.corrects_entry_id is None and root.id in net:
                net[root.id] += e.amount

        self.entries = {i: by_id[i] for i, amt in net.items() if amt > 0}
        self.net = {i: net[i] for i in self.entries}

    def still_matches(self, entry_id: int, t: DBBankTx) -> bool:
        """짝을 정할 때의 조건(방향·순금액·날짜, matcher.match)이 지금 원장에서도 맞는가."""
        e = self.entries[entry_id]
        return (
            _KIND_TO_DIRECTION.get(e.kind) == t.direction
            and self.net[entry_id] == t.amount
            and _kst_date(e.occurred_at) == t.tran_date
        )

    def candidates(self) -> List[Candidate]:
        return [
            Candidate(
                entry_id=e.id,
                direction=_KIND_TO_DIRECTION[e.kind],
                amount=self.net[e.id],
                date=_kst_date(e.occurred_at),
                confirmed=e.status == "CONFIRMED",
            )
            for e in self.entries.values()
            if e.kind in _KIND_TO_DIRECTION
        ]


# ---------------------------------------------------------------- 보고서


def _latest_snapshot_id(db: Session, term_id: int) -> Optional[int]:
    row = db.query(DBSnapshot.id).filter(DBSnapshot.term_id == term_id).order_by(DBSnapshot.id.desc()).first()
    return row[0] if row else None


def _report(db: Session, snap: DBSnapshot) -> ReconciliationReport:
    txs = db.query(DBBankTx).filter(DBBankTx.snapshot_id == snap.id).order_by(DBBankTx.id.asc()).all()
    superseded = _latest_snapshot_id(db, snap.term_id) != snap.id
    dates = [t.tran_date for t in txs]
    period_start, period_end = min(dates), max(dates)

    base = dict(
        snapshot_id=snap.id,
        term_id=snap.term_id,
        file_hash=snap.file_hash,
        bank_balance=snap.bank_balance,
        snapshot_at=snap.snapshot_at,
        period_start=period_start,
        period_end=period_end,
        superseded=superseded,
    )
    if superseded:
        # 짝이 최신 스냅샷으로 옮겨 갔으므로 여기서 미등록으로 보이면 오해를 산다. 거래 줄만 보여 준다
        rows = [_row(t, None, None) for t in txs]
        return ReconciliationReport(**base, summary=None, transactions=rows, unbacked_entries=[])

    ledger = _Ledger(db, snap.term_id)
    rows: List[BankRowResult] = []
    used = set()
    for t in txs:
        entry = ledger.entries.get(t.matched_entry_id) if t.matched_entry_id else None
        # 업로드 뒤에 짝 항목이 반려됐거나, 정정으로 순금액이 달라졌다면 지금은 짝이 아니다 (#100).
        # 저장된 짝은 재대조 때 다시 정한다 — 그 전에도 보고서는 재대조한 것과 같은 판정을 보여 준다
        if entry is not None and not ledger.still_matches(entry.id, t):
            entry = None
        if entry is None:
            rows.append(_row(t, RowStatus.UNREGISTERED, None))
            continue
        used.add(entry.id)
        st = RowStatus.MATCHED if entry.status == "CONFIRMED" else RowStatus.MATCHED_PENDING
        rows.append(_row(t, st, entry.id))

    unbacked = [
        UnbackedEntry(
            entry_id=e.id,
            kind=e.kind,
            amount=ledger.net[e.id],
            date=_kst_date(e.occurred_at),
            counterparty=e.counterparty,
            purpose=e.purpose,
        )
        for e in sorted(ledger.entries.values(), key=lambda e: (e.occurred_at, e.id))
        if e.status == "CONFIRMED"
        and e.id not in used
        # 거래내역 기간 밖 항목은 이 파일로 판단할 수 없다
        and period_start <= _kst_date(e.occurred_at) <= period_end
    ]

    unreg = [r for r in rows if r.status == RowStatus.UNREGISTERED]
    summary = ReconcileSummary(
        total=len(rows),
        matched=sum(r.status == RowStatus.MATCHED for r in rows),
        matched_pending=sum(r.status == RowStatus.MATCHED_PENDING for r in rows),
        unregistered=len(unreg),
        unregistered_out_amount=sum(r.amount for r in unreg if r.direction == "OUT"),
        unregistered_in_amount=sum(r.amount for r in unreg if r.direction == "IN"),
        unbacked=len(unbacked),
    )
    return ReconciliationReport(**base, summary=summary, transactions=rows, unbacked_entries=unbacked)


def _row(t: DBBankTx, st: Optional[RowStatus], entry_id: Optional[int]) -> BankRowResult:
    return BankRowResult(
        id=t.id,
        tran_date=t.tran_date,
        tran_time=t.tran_time,
        description=t.description,
        direction=t.direction,
        amount=t.amount,
        balance_after=t.balance_after,
        status=st,
        entry_id=entry_id,
    )


# ---------------------------------------------------------------- 매칭 저장


def _when(r: BankRow):
    return (r.tran_date, r.tran_time or "")


def _balance_continues(rows: List[BankRow]) -> bool:
    """이 순서가 시간순이라면 각 줄의 거래후잔액 = 앞 줄 잔액 + 입금 − 출금 이어야 한다."""
    return all(
        cur.balance_after == prev.balance_after + (cur.amount if cur.direction == "IN" else -cur.amount)
        for prev, cur in zip(rows, rows[1:])
    )


def _chronological(rows: List[BankRow]) -> List[BankRow]:
    """파일을 시간순(오래된 것 → 최신)으로 맞춘다. 마지막 줄의 잔액이 계좌 잔액이 된다.

    은행 파일은 최신순·시간순이 섞여 있고, 하루치이거나 시각이 없으면 날짜로는 방향을 알 수 없다 (#107).
    그래서 **잔액이 이어지는 방향**을 고른다. 두 방향 다 이어지면(+100 뒤 −100 처럼) 그때만 날짜·시각으로 정하고,
    그래도 모르면 잘못된 잔액을 저장하는 대신 파일을 다시 받아 달라고 한다.
    """
    forward, backward = list(rows), list(reversed(rows))
    fits = [o for o in (forward, backward) if _balance_continues(o)]
    if not fits:
        raise BankCsvError("거래후잔액이 거래 순서대로 이어지지 않습니다. 한 계좌의 거래내역을 은행에서 받은 그대로 올려 주세요.")
    if len(fits) == 2 and len(rows) > 1:
        first, last = _when(rows[0]), _when(rows[-1])
        if first == last:
            raise BankCsvError("거래 순서를 정할 수 없습니다 (같은 시각, 잔액으로도 구분되지 않음). 거래 시각이 들어간 거래내역을 받아 주세요.")
        fits = [forward if first < last else backward]
    ordered = fits[0]
    if any(_when(b) < _when(a) for a, b in zip(ordered, ordered[1:])):
        raise BankCsvError("거래 날짜·시각이 잔액 순서와 맞지 않습니다. 은행에서 받은 원본을 고치지 말고 올려 주세요.")
    return ordered


def _apply_matching(db: Session, snap: DBSnapshot) -> None:
    """이 스냅샷 거래들의 짝을 새로 정한다. 같은 학기 다른 스냅샷의 짝은 먼저 푼다."""
    other_ids = [i for (i,) in db.query(DBSnapshot.id).filter(DBSnapshot.term_id == snap.term_id).all()]
    (
        db.query(DBBankTx)
        .filter(DBBankTx.snapshot_id.in_(other_ids), DBBankTx.matched_entry_id.isnot(None))
        .update({DBBankTx.matched_entry_id: None}, synchronize_session=False)
    )
    db.flush()  # 짝을 푼 것이 먼저 반영돼야 아래에서 같은 항목을 다시 짝지을 때 유일 제약에 안 걸린다

    txs = db.query(DBBankTx).filter(DBBankTx.snapshot_id == snap.id).order_by(DBBankTx.id.asc()).all()
    rows = [
        BankRow(i + 1, t.tran_date, t.tran_time, t.description, t.direction, t.amount, t.balance_after)
        for i, t in enumerate(txs)
    ]
    for t, c in zip(txs, match(rows, _Ledger(db, snap.term_id).candidates())):
        t.matched_entry_id = c.entry_id if c else None


# ---------------------------------------------------------------- 잔액 차이 알림


def _ledger_balance(db: Session, term_id: int) -> int:
    """학기 장부 잔액 = Σ확정수입 − Σ확정지출 (PRD §7.4, /balance 와 같은 식). 확정 정정은 음수 금액으로 들어 있어 그대로 더한다."""
    rows = (
        db.query(DBEntry.kind, func.coalesce(func.sum(DBEntry.amount), 0))
        .filter(DBEntry.term_id == term_id, DBEntry.status == "CONFIRMED")
        .group_by(DBEntry.kind)
        .all()
    )
    totals = {str(k): int(v) for k, v in rows}
    return totals.get("INCOME", 0) - totals.get("EXPENSE", 0)


def _notify_if_mismatch(db: Session, snap: DBSnapshot) -> None:
    # 학생 홈 카드와 같은 비교다. 알림은 commit 과 함께 큐에 들어가 commit 뒤에 나간다
    if _ledger_balance(db, snap.term_id) != snap.bank_balance:
        notify_students_balance_mismatch(db, snap.term_id)


# ---------------------------------------------------------------- API


@router.post(
    "/snapshots",
    response_model=ReconciliationReport,
    status_code=status.HTTP_201_CREATED,
    summary="은행 거래내역 CSV 업로드 및 원장 대조",
)
async def upload_snapshot(body: BankUploadRequest, user: User = Depends(treasurer_only), db: Session = Depends(get_db)):
    try:
        raw = base64.b64decode(body.file_base64, validate=True)
    except (binascii.Error, ValueError):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="file_base64 가 올바른 base64 가 아닙니다.")
    if not raw:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="빈 파일입니다.")
    if len(raw) > MAX_FILE_BYTES:
        raise HTTPException(status_code=413, detail="파일이 2MB를 넘습니다.")

    file_hash = "0x" + hashlib.sha256(raw).hexdigest()
    if body.file_hash is not None and body.file_hash != file_hash:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="file_hash 가 업로드한 파일의 해시와 다릅니다.")

    try:
        ordered = _chronological(parse_bank_csv(raw))
    except BankCsvError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))

    try:
        if db.get(DBTerm, body.term_id) is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"ID {body.term_id}에 해당하는 학기를 찾을 수 없습니다.")
        dup = (
            db.query(DBSnapshot.id)
            .filter(DBSnapshot.term_id == body.term_id, DBSnapshot.file_hash == file_hash)
            .first()
        )
        if dup:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"같은 파일이 이미 업로드되어 있습니다 (스냅샷 {dup[0]}). 원장을 고친 뒤 다시 맞추려면 재대조를 쓰세요.",
            )

        snap = DBSnapshot(
            term_id=body.term_id,
            bank_balance=ordered[-1].balance_after,
            file_hash=file_hash,
            uploaded_by=user.id,
        )
        db.add(snap)
        db.flush()
        for r in ordered:
            db.add(DBBankTx(
                snapshot_id=snap.id,
                tran_date=r.tran_date,
                tran_time=r.tran_time,
                description=r.description,
                direction=r.direction,
                amount=r.amount,
                balance_after=r.balance_after,
            ))
        db.flush()
        _apply_matching(db, snap)
        _notify_if_mismatch(db, snap)
        db.commit()
    except IntegrityError:
        db.rollback()
        # 같은 학기 업로드·재대조가 동시에 돌아 한 원장 항목을 둘이 짝지으려 한 경우
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="같은 학기 대조가 동시에 진행되었습니다. 다시 시도해 주세요.")
    except SQLAlchemyError as e:
        raise _db_error(e, db, "거래내역 업로드")

    try:
        return _report(db, snap)
    except SQLAlchemyError as e:
        raise _db_error(e, db, "대조 결과 조회")


@router.post(
    "/snapshots/{snapshot_id}/rematch",
    response_model=ReconciliationReport,
    summary="최신 스냅샷을 현재 원장으로 다시 대조",
)
async def rematch_snapshot(snapshot_id: int, user: User = Depends(treasurer_only), db: Session = Depends(get_db)):
    """미등록 건을 등록·승인한 뒤 같은 파일로 다시 맞춘다. 같은 파일은 다시 올릴 수 없어서(409) 이 경로를 쓴다."""
    try:
        snap = db.get(DBSnapshot, snapshot_id)
        if snap is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"ID {snapshot_id}에 해당하는 스냅샷을 찾을 수 없습니다.")
        if _latest_snapshot_id(db, snap.term_id) != snap.id:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="더 최근 업로드가 있습니다. 최신 스냅샷에서 재대조하세요.")
        _apply_matching(db, snap)
        _notify_if_mismatch(db, snap)
        db.commit()
        return _report(db, snap)
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="같은 학기 대조가 동시에 진행되었습니다. 다시 시도해 주세요.")
    except SQLAlchemyError as e:
        raise _db_error(e, db, "재대조")


@router.get("/snapshots", response_model=List[SnapshotItem], summary="거래내역 업로드 목록")
async def list_snapshots(
    term_id: int = Query(..., gt=0, description="학기 ID"),
    user: User = Depends(council_only),
    db: Session = Depends(get_db),
):
    try:
        snaps = db.query(DBSnapshot).filter(DBSnapshot.term_id == term_id).order_by(DBSnapshot.id.desc()).all()
    except SQLAlchemyError as e:
        raise _db_error(e, db, "스냅샷 목록 조회")
    latest = snaps[0].id if snaps else None
    return [
        SnapshotItem(
            id=s.id, term_id=s.term_id, file_hash=s.file_hash, bank_balance=s.bank_balance,
            snapshot_at=s.snapshot_at, uploaded_by=s.uploaded_by, superseded=s.id != latest,
        )
        for s in snaps
    ]


@router.get("/snapshots/{snapshot_id}", response_model=ReconciliationReport, summary="대조 결과 조회")
async def get_report(snapshot_id: int, user: User = Depends(council_only), db: Session = Depends(get_db)):
    try:
        snap = db.get(DBSnapshot, snapshot_id)
        if snap is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"ID {snapshot_id}에 해당하는 스냅샷을 찾을 수 없습니다.")
        return _report(db, snap)
    except SQLAlchemyError as e:
        raise _db_error(e, db, "대조 결과 조회")
