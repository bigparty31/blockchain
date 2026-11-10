"""행사·입장 API 스키마 — PRD v0.15 §4.2 (QR 입장), §8 (Event, CheckIn)."""
from datetime import datetime
from enum import Enum
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field


class EventCreate(BaseModel):
    term_id: int = Field(..., gt=0, description="학기 ID. 이 학기 회원권(SBT)을 가진 학생만 입장한다")
    name: str = Field(..., min_length=1, max_length=100, description="행사명")
    held_at: datetime = Field(..., description="행사 일시")


class EventResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    term_id: int
    name: str
    held_at: datetime
    created_by: int
    created_at: datetime


class CheckInRequest(BaseModel):
    # QR 에는 학생 식별자만 들어 있다. 자격(납부 여부)은 서버가 조회해서 판정한다 (PRD §4.2 QR 설계)
    qr_payload: str = Field(..., max_length=64, description='학생 QR 문자열 (예: "SCA:2026-2:U000003")')


class CheckInResult(str, Enum):
    ADMITTED = "ADMITTED"                      # 입장 처리됨 (이번 스캔으로 기록)
    ALREADY_CHECKED_IN = "ALREADY_CHECKED_IN"  # 이 행사에 이미 입장한 학생 — 중복 입장 차단
    NOT_MEMBER = "NOT_MEMBER"                  # 이 학기 회원권이 없음 (미납·환불 회수)
    UNKNOWN_STUDENT = "UNKNOWN_STUDENT"        # QR 의 학생 ID 가 없는 사용자이거나 학생이 아님
    UNVERIFIABLE = "UNVERIFIABLE"              # 회원권 확인 자체를 못 함 (체인·네트워크 장애). 거부와 구분한다


class CheckInResponse(BaseModel):
    result: CheckInResult
    event_id: int
    user_id: Optional[int] = Field(None, description="QR 에서 읽은 학생 ID")
    student_no: Optional[str] = Field(None, description="스캐너가 본인 확인에 쓰는 학번 (학생일 때만)")
    name: Optional[str] = Field(None, description="학생 이름 (학생일 때만)")
    checked_in_at: Optional[datetime] = Field(
        None, description="입장 기록 시각. ADMITTED 는 이번, ALREADY_CHECKED_IN 은 처음 입장한 시각"
    )
