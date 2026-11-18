"""학생 홈 계좌 대조 카드 (S11) — GET /snapshots/latest (docs/backend_requests.md §1-5).

임원용 /bank/snapshots/{id} 대조 결과에서 학생에게 보여도 되는 것만 추린다.
조회 전용이라 학생 서버(STUDENT_QUERY_ROUTERS)에도 붙는다 — 이 파일에서 DB 에 쓰면 안 된다.
"""
import logging
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.auth.deps import get_current_user
from app.auth.users import User
from app.database import get_db
from app.models import Snapshot as DBSnapshot
from app.routers.bank import KST, _db_error, _latest_snapshot_id, _report
from app.schemas.bank import BankRowResult, RowStatus, StudentSnapshot, UnrecordedTransaction
from app.services.membership import current_term

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/snapshots", tags=["Bank Reconciliation"])
query_router = router


def _unix(dt: datetime) -> int:
    # SQLite 는 시간대를 버리고 돌려준다. 서버 기본값 now() 는 UTC 라 시간대 없는 값은 UTC 로 본다
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


def _occurred_at(r: BankRowResult, fallback: int) -> int:
    # 은행 거래내역의 날짜·시각은 한국 시간이다. 시각이 없는 은행 양식이면 그날 자정.
    # 업로드 검증(#117 리뷰) 전에 저장된 값이 달력에 없으면(2026-02-31·24:00:00) 카드 전체를 500 으로
    # 깨뜨리지 않는다 — 시각만 틀리면 그날 자정, 날짜도 틀리면 [fallback](업로드 시각)
    for text, fmt in ((f"{r.tran_date} {r.tran_time or '00:00:00'}", "%Y-%m-%d %H:%M:%S"), (r.tran_date, "%Y-%m-%d")):
        try:
            return int(datetime.strptime(text, fmt).replace(tzinfo=KST).timestamp())
        except ValueError:
            continue
    logger.warning("거래 일시를 읽지 못해 업로드 시각으로 대신함: %r %r", r.tran_date, r.tran_time)
    return fallback


@router.get("/latest", response_model=StudentSnapshot, summary="현재 학기 최신 계좌 대조 (학생 화면)")
async def latest_snapshot(
    term_id: Optional[int] = Query(None, ge=1, description="학기 ID (미지정 시 현재 학기)"),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """가장 최근 업로드된 거래내역 기준으로, 계좌에서 나갔는데 장부에 없는 출금만 돌려준다.

    로그인한 누구나 볼 수 있다. 업로드가 아직 없으면 404 — 앱은 카드에 '불러오지 못했습니다'를 띄운다.
    """
    try:
        if term_id is None:
            term = current_term(db)
            if term is None:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="진행 중인 학기가 없습니다.")
            term_id = term.id
        snap_id = _latest_snapshot_id(db, term_id)
        if snap_id is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="아직 업로드된 계좌 거래내역이 없습니다.")
        snap = db.get(DBSnapshot, snap_id)
        report = _report(db, snap)
    except SQLAlchemyError as e:
        raise _db_error(e, db, "최신 계좌 대조 조회")

    uploaded_at = _unix(snap.snapshot_at)
    return StudentSnapshot(
        id=snap.id,
        term_id=snap.term_id,
        bank_balance=snap.bank_balance,
        snapshot_at=uploaded_at,
        tx_hash=snap.tx_hash,
        unrecorded=[
            UnrecordedTransaction(amount=r.amount, counterparty=r.description, occurred_at=_occurred_at(r, uploaded_at))
            for r in report.transactions
            if r.status == RowStatus.UNREGISTERED and r.direction == "OUT"
        ],
    )
