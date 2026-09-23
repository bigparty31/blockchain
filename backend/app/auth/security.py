import os
from datetime import datetime, timedelta, timezone

import bcrypt
import jwt

# 운영에서는 반드시 JWT_SECRET 을 설정한다. 기본값은 로컬 개발용이다.
JWT_SECRET = os.environ.get("JWT_SECRET", "dev-only-insecure-secret-change-me")
JWT_ALGORITHM = "HS256"
ACCESS_TOKEN_TTL = timedelta(hours=12)


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def verify_password(password: str, password_hash: str) -> bool:
    return bcrypt.checkpw(password.encode("utf-8"), password_hash.encode("utf-8"))


def create_access_token(user_id: int, ttl: timedelta = ACCESS_TOKEN_TTL) -> str:
    now = datetime.now(timezone.utc)
    # PyJWT 는 sub 가 문자열이어야 검증을 통과시킨다
    payload = {"sub": str(user_id), "iat": now, "exp": now + ttl}
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)


def decode_access_token(token: str) -> int:
    """토큰의 user id 를 돌려준다. 서명·만료가 틀리면 jwt.PyJWTError 를 던진다."""
    payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM], options={"require": ["sub", "exp"]})
    try:
        return int(payload["sub"])
    except ValueError:
        raise jwt.InvalidTokenError("sub 가 user id 가 아님")
