"""인증·권한이 다루는 값. 흐름은 docs/AUTH.md."""
from datetime import datetime
from enum import Enum
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field

from app.chain.models import Role


class UserRole(str, Enum):
    """docs/enums.md role. STUDENT 는 온체인 롤이 아니다 (SBT 보유로 판별)."""

    STUDENT = "STUDENT"
    TREASURER = "TREASURER"
    AUDITOR = "AUDITOR"
    PRESIDENT = "PRESIDENT"

    @property
    def is_officer(self) -> bool:
        return self != UserRole.STUDENT

    @property
    def onchain(self) -> Optional[Role]:
        return None if self == UserRole.STUDENT else Role(self.value)


OFFICER_ROLES = (UserRole.TREASURER, UserRole.AUDITOR, UserRole.PRESIDENT)
APPROVER_USER_ROLES = (UserRole.AUDITOR, UserRole.PRESIDENT)


class _Frozen(BaseModel):
    model_config = ConfigDict(frozen=True)


class User(_Frozen):
    id: int = Field(..., ge=0, description="저장소가 매긴다. 넣기 전에는 0")
    student_no: str
    name: str
    role: UserRole
    password_hash: str = Field(..., repr=False)
    password_change_required: bool = Field(True, description="관리자가 만든 비밀번호로는 처음 로그인 뒤 바꾸게 한다")
    wallet_index: Optional[int] = Field(None, description="학생만. 서버 HD 지갑 경로 m/44'/60'/0'/0/{index} (PRD §9.2)")
    wallet_address: Optional[str] = Field(None, description="임원만. 기기 키스토어 주소. 서명 확인으로 등록한다")
    token_version: int = Field(0, description="올리면 이전에 발급한 토큰이 모두 무효가 된다 (비밀번호·역할 변경, 비활성화)")
    active: bool = True


class WalletRecord(_Frozen):
    """임원 지갑 주소 이력. 키를 바꿔도 지난 서명은 옛 주소로 남아 있어서 지우지 않는다."""

    user_id: int
    address: str = Field(..., description="EIP-55 체크섬 형식")
    registered_at: datetime
    retired_at: Optional[datetime] = None


class WalletChallenge(_Frozen):
    """지갑 등록 때 앱이 서명할 문장. 한 번만 쓸 수 있고 시한이 있다."""

    user_id: int
    nonce: str
    message: str
    expires_at: datetime


class AddressOwner(_Frozen):
    """주소 → 임원. 단건 검증이 registrant·approver 를 사람으로 옮길 때 쓴다 (docs/HASHING.md §2)."""

    address: str
    user_id: int
    name: str
    role: UserRole = Field(..., description="지금 역할. 서명 당시 역할이 아닐 수 있다")
    current: bool = Field(..., description="False 면 키를 바꾸기 전 주소다")
    registered_at: datetime
    retired_at: Optional[datetime] = None


class AuthErrorCode(str, Enum):
    INVALID_CREDENTIALS = "INVALID_CREDENTIALS"  # 학번·비밀번호가 틀렸거나 비활성 계정. 어느 쪽인지 알려주지 않는다
    INVALID_TOKEN = "INVALID_TOKEN"  # 서명·만료·버전이 맞지 않는 토큰
    FORBIDDEN = "FORBIDDEN"  # 역할이 없다
    PASSWORD_CHANGE_REQUIRED = "PASSWORD_CHANGE_REQUIRED"
    WEAK_PASSWORD = "WEAK_PASSWORD"
    STUDENT_NO_TAKEN = "STUDENT_NO_TAKEN"
    USER_NOT_FOUND = "USER_NOT_FOUND"
    CHALLENGE_INVALID = "CHALLENGE_INVALID"  # 없거나 이미 썼거나 시한이 지났다
    SIGNATURE_INVALID = "SIGNATURE_INVALID"  # 서명 형식이 틀렸거나 다른 문장에 서명했다
    WALLET_TAKEN = "WALLET_TAKEN"  # 다른 사람이 쓰고 있거나 쓴 적 있는 주소
    WALLET_NOT_CONFIGURED = "WALLET_NOT_CONFIGURED"  # 학생 지갑 니모닉이 설정되지 않았다
    CONFLICT = "CONFLICT"  # 관리 작업을 하는 동안 같은 계정이 계속 바뀌었다


class AuthError(Exception):
    def __init__(self, code: AuthErrorCode, detail: str = ""):
        self.code = code
        self.detail = detail
        super().__init__(f"{code.value}: {detail}" if detail else code.value)
