"""알림 API 응답과 알림 종류 (docs/NOTIFICATION_API.md, PRD §4.8)."""
from enum import Enum
from typing import Optional

from pydantic import BaseModel, Field


class NotificationKind(str, Enum):
    """docs/enums.md notification kind 와 같다. 값을 바꾸면 양쪽과 DB CHECK(마이그레이션)를 같이 고친다.

    호출하는 쪽은 app.services.notifications 에서 가져다 쓴다. 모델의 CHECK 제약이 이 값을 읽어서 여기에 둔다.
    """

    ENTRY_REGISTERED = "ENTRY_REGISTERED"
    ENTRY_EDIT_REQUESTED = "ENTRY_EDIT_REQUESTED"
    ENTRY_CONFIRMED = "ENTRY_CONFIRMED"
    ENTRY_REJECTED = "ENTRY_REJECTED"
    ENTRY_CONFIRM_FAILED = "ENTRY_CONFIRM_FAILED"
    ENTRY_BLOCKED = "ENTRY_BLOCKED"
    REVISION_REQUESTED = "REVISION_REQUESTED"
    REVISION_PRESIDENT_SIGNED = "REVISION_PRESIDENT_SIGNED"
    REVISION_APPROVED = "REVISION_APPROVED"
    REVISION_REJECTED = "REVISION_REJECTED"
    ROLE_CHANGE_REQUESTED = "ROLE_CHANGE_REQUESTED"
    PRESIDENT_RECOVERY_PROPOSED = "PRESIDENT_RECOVERY_PROPOSED"
    RECLASSIFY_PAIR_UNCONFIRMED = "RECLASSIFY_PAIR_UNCONFIRMED"
    SIGNATURE_DEADLINE_NEAR = "SIGNATURE_DEADLINE_NEAR"


class NotificationResponse(BaseModel):
    """GET /notifications 의 한 행."""

    id: int
    kind: NotificationKind
    entry_id: Optional[int] = Field(None, description="이동할 항목. budget_revision_request_id 와 둘 중 하나만 있다")
    budget_revision_request_id: Optional[int] = Field(None, description="이동할 증액 요청")
    body: str = Field(..., description="서버가 만든 문구. 앱은 그대로 표시한다")
    created_at: int = Field(..., description="처음 알린 시각 (Unix 초)")
    notified_at: int = Field(..., description="마지막으로 알린 시각. 재알림 때 갱신된다. 목록 정렬 기준")
    read_at: Optional[int] = Field(None, description="읽은 시각. 재알림이 오면 다시 비워진다")
    remind_count: int = Field(..., description="재알림 횟수 (최대 3)")


class UnreadCountResponse(BaseModel):
    count: int


class ReadResponse(BaseModel):
    id: int
    read_at: int


class DeviceTokenRequest(BaseModel):
    """임원 앱의 FCM 등록 토큰. platform 은 android 만 받는다 (iOS 제외, PRD §4.8) — 다른 값은 라우터가 400 으로 막는다."""

    platform: str = Field(..., min_length=1, max_length=20, description='"android"')
    token: str = Field(..., min_length=1, max_length=512, description="FCM 등록 토큰")


class DeviceTokenResponse(BaseModel):
    id: int
    registered_at: int


class DeviceTokenRevokeResponse(BaseModel):
    revoked: bool = Field(..., description="이 요청으로 해제했으면 true. 없거나 남의 토큰이면 false (그래도 200)")
