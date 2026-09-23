from typing import Optional

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.auth.security import decode_access_token
from app.auth.users import User, get_user_by_id

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
