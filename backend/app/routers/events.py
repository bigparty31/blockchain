"""행사·입장 API — PRD v0.15 §4.2 SBT 회원권 → QR 입장.

흐름: 학생이 QR 제시 → 임원이 스캔 → 서버가 회원권 확인 → 입장 기록.
- QR 에는 학생 식별자만 들어 있다. 자격은 매번 서버가 조회한다 (캡처 전달로 대리 입장 방지)
- 한 행사에 한 학생은 한 번만 입장한다. 최종 방어선은 DB 유일 제약 uq_check_ins_event_user
- 판정 결과(입장·중복·미보유·판정 불가)는 오류가 아니라 200 + result 로 돌려준다.
  스캐너 화면이 결과별로 다른 안내를 띄우기 때문이다. 400/404 는 요청 자체가 잘못된 경우만
"""
import logging
import re
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session

from app.auth.deps import require_roles
from app.auth.users import User
from app.database import get_db
from app.membership_check import MembershipChecker, MembershipUnavailable, get_membership_checker
from app.models import CheckIn as DBCheckIn
from app.models import Event as DBEvent
from app.models import Term as DBTerm
from app.models import User as DBUser
from app.schemas.auth import Role
from app.schemas.event import (
    CheckInRequest,
    CheckInResponse,
    CheckInResult,
    EventCreate,
    EventResponse,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/events", tags=["Events"])

# 행사 등록·조회·스캔은 학생회 임원만 한다
council_only = require_roles(Role.TREASURER, Role.AUDITOR, Role.PRESIDENT)

DB_ERROR = "데이터베이스 처리 중 오류가 발생했습니다."

# 앱 QR 형식 (docs/backend_requests.md §1-4): "SCA:<학기>:U<학생 ID 0채움>" 예) SCA:2026-2:U000003
# 학생 ID 는 12자리까지만 받는다 — 그보다 길면 BIGINT 범위를 넘을 수 있다
_QR_PATTERN = re.compile(r"SCA:[^:\s]+:U(\d{1,12})")


def parse_qr(payload: str) -> Optional[int]:
    """QR 문자열에서 학생 ID 를 꺼낸다. 형식이 아니면 None.

    가운데 학기 부분은 판정에 쓰지 않는다. 자격은 QR 의 학기가 아니라 '행사의 학기' 회원권으로
    본다 — 지난 학기 QR 캡처를 보여 줘도 이번 학기 회원권이 없으면 NOT_MEMBER 가 된다.
    """
    m = _QR_PATTERN.fullmatch(payload.strip())
    return int(m.group(1)) if m else None


def _db_error(e: Exception, db: Session, what: str) -> HTTPException:
    db.rollback()
    logger.exception("%s 중 데이터베이스 오류 발생: %s", what, e)
    return HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=DB_ERROR)


def _find_check_in(db: Session, event_id: int, user_id: int) -> Optional[DBCheckIn]:
    return db.query(DBCheckIn).filter(DBCheckIn.event_id == event_id, DBCheckIn.user_id == user_id).first()


@router.post("", response_model=EventResponse, status_code=status.HTTP_201_CREATED, summary="행사 등록")
async def create_event(body: EventCreate, user: User = Depends(council_only), db: Session = Depends(get_db)):
    try:
        if db.get(DBTerm, body.term_id) is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail=f"ID {body.term_id}에 해당하는 학기를 찾을 수 없습니다."
            )
        name = body.name.strip()
        if not name:
            raise HTTPException(status_code=422, detail="행사명이 비어 있습니다.")
        event = DBEvent(term_id=body.term_id, name=name, held_at=body.held_at, created_by=user.id)
        db.add(event)
        db.commit()
        db.refresh(event)
        return event
    except SQLAlchemyError as e:
        raise _db_error(e, db, "행사 등록")


@router.get("", response_model=List[EventResponse], summary="행사 목록 조회")
async def list_events(
    term_id: Optional[int] = Query(None, description="학기 ID로 거르기"),
    user: User = Depends(council_only),
    db: Session = Depends(get_db),
):
    try:
        q = db.query(DBEvent)
        if term_id is not None:
            q = q.filter(DBEvent.term_id == term_id)
        return q.order_by(DBEvent.held_at.desc(), DBEvent.id.desc()).all()
    except SQLAlchemyError as e:
        raise _db_error(e, db, "행사 목록 조회")


@router.post("/{event_id}/check-in", response_model=CheckInResponse, summary="QR 스캔 입장 처리")
async def check_in(
    event_id: int,
    body: CheckInRequest,
    user: User = Depends(council_only),
    db: Session = Depends(get_db),
    has_membership: MembershipChecker = Depends(get_membership_checker),
):
    student_id = parse_qr(body.qr_payload)
    if student_id is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="학생 QR 형식이 아닙니다.")

    try:
        event = db.get(DBEvent, event_id)
        if event is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail=f"ID {event_id}에 해당하는 행사를 찾을 수 없습니다."
            )

        res = CheckInResponse(result=CheckInResult.UNKNOWN_STUDENT, event_id=event_id, user_id=student_id)

        student = db.get(DBUser, student_id)
        # 임원 계정 ID 를 QR 에 넣어 와도 학생이 아니므로 입장시키지 않는다
        if student is None or student.role != Role.STUDENT.value:
            return res
        res.student_no, res.name = student.student_no, student.name

        # 이미 입장했으면 회원권을 다시 볼 필요 없이 중복으로 막는다
        prior = _find_check_in(db, event_id, student_id)
        if prior is not None:
            res.result, res.checked_in_at = CheckInResult.ALREADY_CHECKED_IN, prior.scanned_at
            return res

        try:
            member = await has_membership(db, student_id, event.term_id)
        except MembershipUnavailable:
            logger.warning("회원권 확인 불가: event=%s user=%s", event_id, student_id)
            res.result = CheckInResult.UNVERIFIABLE
            return res
        if not member:
            res.result = CheckInResult.NOT_MEMBER
            return res

        record = DBCheckIn(event_id=event_id, user_id=student_id, scanned_by=user.id)
        db.add(record)
        try:
            db.commit()
        except IntegrityError:
            # 스캐너 두 대가 같은 학생을 동시에 찍은 경우. 위의 조회는 둘 다 통과했지만 유일 제약이 하나만 받는다
            db.rollback()
            prior = _find_check_in(db, event_id, student_id)
            if prior is None:
                raise  # 유일 제약이 아닌 다른 무결성 오류 — 아래 except 에서 503
            res.result, res.checked_in_at = CheckInResult.ALREADY_CHECKED_IN, prior.scanned_at
            return res

        db.refresh(record)
        res.result, res.checked_in_at = CheckInResult.ADMITTED, record.scanned_at
        return res
    except SQLAlchemyError as e:
        raise _db_error(e, db, "입장 처리")
