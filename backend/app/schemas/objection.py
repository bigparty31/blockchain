from enum import Enum
from typing import Any, Dict, Optional

from pydantic import BaseModel, ConfigDict, Field, StrictInt

INT64_MAX = (1 << 63) - 1
UINT256_MAX = (1 << 256) - 1
OBJECTION_TEXT_MAX_LENGTH = 5000


class ObjectionStatus(str, Enum):
    OPEN = "OPEN"
    ANSWERED = "ANSWERED"


class ObjectionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int = Field(..., description="이의 제기 고유 ID")
    entry_id: int = Field(..., description="대상 원장 항목 ID")
    user_id: int = Field(..., description="제기 학생 User ID")
    content: str = Field(..., description="정본화된 이의 질문 본문")
    answer: Optional[str] = Field(None, description="학생회 공식 답변 본문")
    answered_by: Optional[int] = Field(None, description="답변한 임원 User ID")
    status: ObjectionStatus = Field(..., description="상태 (OPEN | ANSWERED)")
    raised_at: int = Field(..., description="이의 제기 일시 (Unix 초)")
    answered_at: Optional[int] = Field(None, description="답변 완료 일시 (Unix 초)")
    tx_raise: Optional[str] = Field(None, description="이의 제기 온체인 트랜잭션 해시")
    tx_answer: Optional[str] = Field(None, description="답변 기록 온체인 트랜잭션 해시")


class ObjectionCreateRequest(BaseModel):
    entry_id: StrictInt = Field(..., ge=1, le=INT64_MAX, description="대상 원장 항목 ID")
    content: str = Field(..., min_length=1, max_length=OBJECTION_TEXT_MAX_LENGTH, description="이의 질문 본문")


class ObjectionOpenCountResponse(BaseModel):
    count: int = Field(..., ge=0, description="미답변(OPEN) 이의 제기 건수")


class ObjectionAnswerPrepareRequest(BaseModel):
    answer: str = Field(..., min_length=1, max_length=OBJECTION_TEXT_MAX_LENGTH, description="답변 본문")


class ObjectionAnswerPrepareResponse(BaseModel):
    objection_id: int = Field(..., description="이의 제기 ID")
    answer_hash: str = Field(..., description="정본화된 답변 본문 SHA-256 해시")
    deadline: int = Field(..., description="서명 유효 시한 (Unix 초)")
    domain: Dict[str, Any] = Field(..., description="ObjectionRegistry EIP-712 도메인 정보")
    types: Dict[str, Any] = Field(..., description="EIP-712 AnswerRequest 타입 정의")
    message: Dict[str, Any] = Field(..., description="EIP-712 AnswerRequest 서명 메시지")


class ObjectionAnswerSubmitRequest(BaseModel):
    answer: str = Field(..., min_length=1, max_length=OBJECTION_TEXT_MAX_LENGTH, description="답변 본문")
    answer_hash: str = Field(..., description="prepare-answer로 발급받은 답변 해시 (0x + 64자 hex)")
    deadline: StrictInt = Field(..., ge=0, le=UINT256_MAX, description="서명 유효 시한 (Unix 초)")
    signature: str = Field(..., description="임원의 EIP-712 AnswerRequest 기기 서명값 (0x...)")
