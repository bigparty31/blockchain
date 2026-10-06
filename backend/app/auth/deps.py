from typing import Awaitable, Callable, Optional

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.auth.security import decode_access_token
from app.auth.users import User, get_user_by_id
from app.schemas.auth import Role

# auto_error 를 끄고 직접 401 을 낸다 (토큰 없음·형식 오류 모두 401 로 통일)
_bearer = HTTPBearer(auto_error=False)


def _unauthorized(detail: str) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )


async def get_current_user(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(_bearer),
) -> User:
    """Authorization: Bearer <token> 의 사용자. 토큰이 없거나 틀리면 401."""
    if credentials is None:
        raise _unauthorized("로그인이 필요합니다.")
    try:
        user_id = decode_access_token(credentials.credentials)
    except jwt.ExpiredSignatureError:
        raise _unauthorized("세션이 만료되었습니다. 다시 로그인해 주세요.")
    except jwt.PyJWTError:
        raise _unauthorized("유효하지 않은 토큰입니다.")

    user = get_user_by_id(user_id)
    if user is None:
        raise _unauthorized("유효하지 않은 토큰입니다.")
    return user


def require_roles(*roles: Role) -> Callable[..., Awaitable[User]]:
    """허용 역할만 통과시키는 의존성. 로그인 안 했으면 401, 역할이 다르면 403.

    역할에 위계는 없다. API 마다 허용 역할을 직접 나열한다 — 회장은 승인은 되지만
    등록은 안 된다 (컨트랙트 NotRegistrant: 등록은 TREASURER 만).

        user: User = Depends(require_roles(Role.TREASURER))
    """
    if not roles:
        raise ValueError("허용 역할을 하나 이상 지정해야 합니다.")
    # Role(...) 로 한 번 거른다. 오타 문자열·튜플 한 덩어리 같은 실수는 서버가 뜰 때 바로
    # ValueError 가 난다 — 그냥 두면 모든 사용자가 조용히 403 을 받는다.
    allowed = frozenset(Role(r) for r in roles)

    async def dependency(user: User = Depends(get_current_user)) -> User:
        if user.role not in allowed:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="이 작업을 할 권한이 없습니다.")
        return user

    return dependency
