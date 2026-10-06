from enum import Enum
from typing import Optional
from pydantic import BaseModel, Field


class Role(str, Enum):
    """docs/enums.md 의 role. STUDENT 는 온체인 롤이 아니다 (SBT 보유로 판별)."""

    STUDENT = "STUDENT"
    TREASURER = "TREASURER"
    AUDITOR = "AUDITOR"
    PRESIDENT = "PRESIDENT"


class LoginRequest(BaseModel):
    student_no: str = Field(..., description="학번")
    password: str = Field(..., description="비밀번호")


class LoginResponse(BaseModel):
    access_token: str = Field(..., description="세션 JWT (Authorization: Bearer 헤더로 보낸다)")
    token_type: str = Field("bearer", description="토큰 종류 (항상 bearer)")
    role: Role = Field(..., description="역할 (STUDENT | TREASURER | AUDITOR | PRESIDENT)")
    name: str = Field(..., description="이름")
    wallet_address: Optional[str] = Field(None, description="임원 지갑 주소 (학생은 null)")


class MeResponse(BaseModel):
    id: int = Field(..., description="User ID")
    student_no: str = Field(..., description="학번")
    name: str = Field(..., description="이름")
    role: Role = Field(..., description="역할")
