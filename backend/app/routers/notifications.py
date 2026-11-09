"""알림 API (docs/NOTIFICATION_API.md). 학생회 서버에만 붙는다 (PRD §9.1).

임원만 쓴다 — 학생에게는 알림 행이 없고 FCM 토픽 푸시만 간다 (§4.8). 학생 토큰은 403 이다.
본인 알림만 조회·처리한다. 처리돼 닫힌 알림(resolved_at)은 목록과 안 읽은 수에서 빠진다.
"""
import logging
from datetime import datetime, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Path, Query, status
from sqlalchemy import case, func, update
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session

from app.auth import User, require_roles
from app.database import get_db
from app.models import DeviceToken, Notification
from app.schemas.auth import Role
from app.schemas.notification import (
    DeviceTokenRequest,
    DeviceTokenResponse,
    DeviceTokenRevokeResponse,
    NotificationResponse,
    ReadResponse,
    UnreadCountResponse,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/notifications", tags=["Notifications"])

council_only = require_roles(Role.TREASURER, Role.AUDITOR, Role.PRESIDENT)

PLATFORMS = ("android",)  # iOS 는 하지 않는다 (PRD §4.8)


def _unix(value: Optional[datetime]) -> Optional[int]:
    if value is None:
        return None
    if value.tzinfo is None:  # SQLite 는 시간대 없이 돌려준다. 저장은 UTC 로만 한다
        value = value.replace(tzinfo=timezone.utc)
    return int(value.timestamp())


def _db_unavailable(e: SQLAlchemyError) -> HTTPException:
    logger.exception("알림 처리 중 데이터베이스 오류: %s", e)
    return HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="데이터베이스 처리 중 오류가 발생했습니다.")


def _open(user_id: int):
    return (Notification.user_id == user_id, Notification.resolved_at.is_(None))


@router.get("", response_model=List[NotificationResponse], summary="내 알림 목록")
@router.get("/", response_model=List[NotificationResponse], include_in_schema=False)
def list_notifications(
    unread_only: bool = Query(False, description="true 면 안 읽은 알림만"),
    limit: int = Query(50, ge=1, le=100),
    user: User = Depends(council_only),
    db: Session = Depends(get_db),
):
    """안 읽은 알림 먼저, 그 안에서 notified_at(마지막으로 알린 시각) 최신순. 재알림이 오면 위로 올라온다."""
    try:
        query = db.query(Notification).filter(*_open(user.id))
        if unread_only:
            query = query.filter(Notification.read_at.is_(None))
        rows = (
            query.order_by(
                case((Notification.read_at.is_(None), 0), else_=1),
                Notification.notified_at.desc(),
                Notification.id.desc(),
            )
            .limit(limit)
            .all()
        )
    except SQLAlchemyError as e:
        raise _db_unavailable(e) from e
    return [
        NotificationResponse(
            id=n.id,
            kind=n.kind,
            entry_id=n.entry_id,
            budget_revision_request_id=n.budget_revision_request_id,
            body=n.body,
            created_at=_unix(n.created_at),
            notified_at=_unix(n.notified_at),
            read_at=_unix(n.read_at),
            remind_count=n.remind_count,
        )
        for n in rows
    ]


@router.get("/unread-count", response_model=UnreadCountResponse, summary="안 읽은 알림 수 (뱃지 폴링)")
def unread_count(user: User = Depends(council_only), db: Session = Depends(get_db)):
    try:
        count = (
            db.query(func.count(Notification.id)).filter(*_open(user.id), Notification.read_at.is_(None)).scalar()
        )
    except SQLAlchemyError as e:
        raise _db_unavailable(e) from e
    return UnreadCountResponse(count=count or 0)


@router.post("/{id}/read", response_model=ReadResponse, summary="읽음 처리")
def mark_read(
    id: int = Path(..., ge=1),
    user: User = Depends(council_only),
    db: Session = Depends(get_db),
):
    """이미 읽었으면 그 시각 그대로 200. 없는 알림과 남의 알림은 구분하지 않고 404."""
    try:
        notification = db.query(Notification).filter(Notification.id == id, Notification.user_id == user.id).first()
        if notification is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="알림을 찾을 수 없습니다.")
        if notification.read_at is None:
            notification.read_at = datetime.now(timezone.utc)
            db.commit()
        return ReadResponse(id=notification.id, read_at=_unix(notification.read_at))
    except SQLAlchemyError as e:
        db.rollback()
        raise _db_unavailable(e) from e


@router.post("/device-tokens", response_model=DeviceTokenResponse, summary="임원 기기 FCM 토큰 등록")
def register_device_token(
    req: DeviceTokenRequest,
    user: User = Depends(council_only),
    db: Session = Depends(get_db),
):
    """같은 사람이 같은 토큰을 다시 올려도 200. 다른 사람이 쓰던 토큰이면 이 사람에게 넘긴다 — 한 기기에서 계정을 바꿔
    로그인하면 이전 사람의 알림이 그 기기로 가지 않는다."""
    if req.platform not in PLATFORMS:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="platform 은 android 만 지원합니다.")
    for attempt in range(2):
        try:
            return _register(db, user.id, req)
        except IntegrityError:
            # 같은 토큰을 동시에 처음 올렸다. 한쪽이 넣은 행을 넘겨받는다
            db.rollback()
            if attempt == 1:
                raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="같은 토큰이 동시에 등록되고 있습니다. 다시 시도해 주세요.") from None
        except SQLAlchemyError as e:
            db.rollback()
            raise _db_unavailable(e) from e


def _register(db: Session, user_id: int, req: DeviceTokenRequest) -> DeviceTokenResponse:
    row = db.query(DeviceToken).filter(DeviceToken.token == req.token).first()
    now = datetime.now(timezone.utc)
    if row is None:
        row = DeviceToken(user_id=user_id, platform=req.platform, token=req.token, registered_at=now)
        db.add(row)
    elif row.user_id != user_id or row.revoked_at is not None:
        # ORM 속성 대입으로 하지 않는다. 읽을 때 revoked_at 이 이미 None(앞사람의 활성 토큰)이면 None 대입은 바뀐 게 없어
        # UPDATE 에서 빠진다. 그 사이 앞사람의 해제가 먼저 커밋되면 넘겨받은 토큰이 해제된 채 남아 푸시가 안 간다 (#78 codex 2차)
        db.execute(
            update(DeviceToken)
            .where(DeviceToken.id == row.id)
            .values(user_id=user_id, platform=req.platform, registered_at=now, revoked_at=None)
            .execution_options(synchronize_session=False)
        )
        db.commit()
        return DeviceTokenResponse(id=row.id, registered_at=_unix(now))
    else:
        return DeviceTokenResponse(id=row.id, registered_at=_unix(row.registered_at))
    db.commit()
    return DeviceTokenResponse(id=row.id, registered_at=_unix(row.registered_at))


@router.delete("/device-tokens/{token}", response_model=DeviceTokenRevokeResponse, summary="임원 기기 FCM 토큰 해제 (로그아웃)")
def revoke_device_token(
    token: str = Path(..., min_length=1, max_length=512),
    user: User = Depends(council_only),
    db: Session = Depends(get_db),
):
    """본인 토큰이 아니거나 없는 토큰이어도 200 이다 — 앱이 결과에 따라 할 일이 없다. 남의 토큰은 건드리지 않는다.

    조회 후 저장으로 나누지 않고 조건부 UPDATE 한 번으로 한다. 나누면 그 사이 같은 기기에서 다른 임원이 토큰을 넘겨받았을 때
    늦게 도착한 이 해제가 그 사람의 토큰을 해제한다.
    """
    try:
        revoked = db.execute(
            update(DeviceToken)
            .where(DeviceToken.token == token, DeviceToken.user_id == user.id, DeviceToken.revoked_at.is_(None))
            .values(revoked_at=datetime.now(timezone.utc))
            .execution_options(synchronize_session=False)
        ).rowcount
        db.commit()
        return DeviceTokenRevokeResponse(revoked=revoked == 1)
    except SQLAlchemyError as e:
        db.rollback()
        raise _db_unavailable(e) from e
