"""FastAPI 의존성 — 다른 라우터가 로그인 사용자와 역할을 요구할 때 쓴다.

    @router.post("/entries/drafts")
    async def open_draft(user: User = Depends(require_roles(UserRole.TREASURER))): ...

get_auth_service 는 서버 연결 때 app.dependency_overrides 로 실제 AuthService 를 넣는다 (docs/AUTH.md §5).
"""
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.auth.models import AuthError, AuthErrorCode, User, UserRole
from app.auth.service import AuthService

_bearer = HTTPBearer(auto_error=False)

HTTP_STATUS = {
    AuthErrorCode.INVALID_CREDENTIALS: status.HTTP_401_UNAUTHORIZED,
    AuthErrorCode.INVALID_TOKEN: status.HTTP_401_UNAUTHORIZED,
    AuthErrorCode.PASSWORD_CHANGE_REQUIRED: status.HTTP_403_FORBIDDEN,
    AuthErrorCode.FORBIDDEN: status.HTTP_403_FORBIDDEN,
    AuthErrorCode.USER_NOT_FOUND: status.HTTP_404_NOT_FOUND,
    AuthErrorCode.STUDENT_NO_TAKEN: status.HTTP_409_CONFLICT,
    AuthErrorCode.WALLET_TAKEN: status.HTTP_409_CONFLICT,
    AuthErrorCode.CONFLICT: status.HTTP_409_CONFLICT,
    AuthErrorCode.WALLET_NOT_CONFIGURED: status.HTTP_503_SERVICE_UNAVAILABLE,
}


def http_error(error: AuthError) -> HTTPException:
    code = HTTP_STATUS.get(error.code, status.HTTP_400_BAD_REQUEST)
    headers = {"WWW-Authenticate": "Bearer"} if code == status.HTTP_401_UNAUTHORIZED else None
    return HTTPException(status_code=code, detail={"code": error.code.value, "detail": error.detail}, headers=headers)


def get_auth_service() -> AuthService:
    raise RuntimeError("AuthService 가 연결되지 않았다. app.dependency_overrides[get_auth_service] 로 넣는다")


async def _user(
    credentials: HTTPAuthorizationCredentials | None,
    service: AuthService,
    allow_password_change: bool,
) -> User:
    if credentials is None:
        raise http_error(AuthError(AuthErrorCode.INVALID_TOKEN, "Authorization: Bearer 토큰이 없다"))
    try:
        return await service.authenticate(credentials.credentials, allow_password_change=allow_password_change)
    except AuthError as e:
        raise http_error(e) from e


async def current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    service: AuthService = Depends(get_auth_service),
) -> User:
    return await _user(credentials, service, allow_password_change=False)


async def current_user_allowing_password_change(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    service: AuthService = Depends(get_auth_service),
) -> User:
    """비밀번호를 바꿔야 하는 계정도 통과한다. 비밀번호 변경과 내 정보 조회에만 쓴다."""
    return await _user(credentials, service, allow_password_change=True)


def require_roles(*roles: UserRole):
    """그 역할 중 하나가 아니면 403."""

    async def dependency(user: User = Depends(current_user)) -> User:
        try:
            AuthService.require(user, *roles)
        except AuthError as e:
            raise http_error(e) from e
        return user

    return dependency
