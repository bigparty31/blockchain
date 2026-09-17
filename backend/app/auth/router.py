"""인증 API. main.py 에는 아직 붙이지 않았다 (docs/AUTH.md §5)."""
from datetime import datetime
from typing import Optional

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from app.auth.deps import current_user, current_user_allowing_password_change, get_auth_service, http_error
from app.auth.models import AddressOwner, AuthError, User, UserRole
from app.auth.service import AuthService

router = APIRouter(prefix="/auth", tags=["Auth"])


class LoginRequest(BaseModel):
    student_no: str
    password: str


class UserView(BaseModel):
    id: int
    student_no: str
    name: str
    role: UserRole
    wallet_address: Optional[str] = Field(None, description="임원은 등록한 기기 주소(없으면 null), 학생은 서버 파생 주소")
    password_change_required: bool


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int
    user: UserView


class PasswordChangeRequest(BaseModel):
    old_password: str
    new_password: str


class ChallengeResponse(BaseModel):
    nonce: str
    message: str = Field(..., description="이 문장 그대로 personal_sign(EIP-191) 한다")
    expires_at: datetime


class WalletRegisterRequest(BaseModel):
    nonce: str
    address: str = Field(..., description="기기 키스토어 주소. 서명에서 복구한 주소와 같아야 한다")
    signature: str


def _view(service: AuthService, user: User) -> UserView:
    return UserView(
        id=user.id, student_no=user.student_no, name=user.name, role=user.role,
        wallet_address=service.wallet_address(user), password_change_required=user.password_change_required,
    )


def _token(service: AuthService, token: str, user: User) -> TokenResponse:
    return TokenResponse(access_token=token, expires_in=service.token_ttl_seconds, user=_view(service, user))


@router.post("/login", response_model=TokenResponse, summary="학번·비밀번호 로그인")
async def login(body: LoginRequest, service: AuthService = Depends(get_auth_service)):
    try:
        token, user = await service.login(body.student_no, body.password)
        return _token(service, token, user)  # 응답을 만들다 나는 설정 오류(학생 지갑)도 매핑한다
    except AuthError as e:
        raise http_error(e) from e


@router.get("/me", response_model=UserView, summary="내 정보")
async def me(
    user: User = Depends(current_user_allowing_password_change), service: AuthService = Depends(get_auth_service)
):
    try:
        return _view(service, user)
    except AuthError as e:
        raise http_error(e) from e


@router.post("/password", response_model=TokenResponse, summary="비밀번호 변경. 다른 기기의 토큰은 모두 무효가 된다")
async def change_password(
    body: PasswordChangeRequest,
    user: User = Depends(current_user_allowing_password_change),
    service: AuthService = Depends(get_auth_service),
):
    try:
        token, updated = await service.change_password(user, body.old_password, body.new_password)
        return _token(service, token, updated)
    except AuthError as e:
        raise http_error(e) from e


@router.post("/wallet/challenge", response_model=ChallengeResponse, summary="임원 지갑 등록 문장 받기")
async def wallet_challenge(user: User = Depends(current_user), service: AuthService = Depends(get_auth_service)):
    try:
        challenge = await service.wallet_challenge(user)
    except AuthError as e:
        raise http_error(e) from e
    return ChallengeResponse(nonce=challenge.nonce, message=challenge.message, expires_at=challenge.expires_at)


@router.post("/wallet", response_model=UserView, summary="서명으로 임원 지갑 등록")
async def register_wallet(
    body: WalletRegisterRequest, user: User = Depends(current_user), service: AuthService = Depends(get_auth_service)
):
    try:
        updated = await service.register_wallet(user, body.nonce, body.address, body.signature)
        return _view(service, updated)
    except AuthError as e:
        raise http_error(e) from e


@router.get("/addresses/{address}", response_model=Optional[AddressOwner], summary="임원 지갑 주소의 주인 (단건 검증용)")
async def address_owner(address: str, _: User = Depends(current_user), service: AuthService = Depends(get_auth_service)):
    return await service.owner_of(address)
