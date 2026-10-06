import logging
import os
import re
from datetime import datetime, timedelta, timezone

import bcrypt
import jwt

logger = logging.getLogger(__name__)

# 운영에서는 반드시 JWT_SECRET 을 설정한다. 기본값은 로컬 개발용이다.
# `or` 로 받는다 — .env.example 을 그대로 복사하면 JWT_SECRET= 빈 값이 들어오기 때문
_DEV_SECRET = "dev-only-insecure-secret-change-me"
JWT_SECRET = os.environ.get("JWT_SECRET") or _DEV_SECRET
if JWT_SECRET == _DEV_SECRET:
    # 배포 전에는 기본값을 없애고 키가 없으면 서버가 뜨지 않게 바꾼다. 그때까지는 로그로 드러낸다
    logger.warning(
        "JWT_SECRET 미설정: 저장소에 공개된 개발용 키로 토큰을 서명합니다. "
        "이 키로 누구나 토큰을 위조할 수 있으니 배포 환경에서는 반드시 JWT_SECRET 을 설정하세요 "
        "(환경변수 또는 저장소 루트의 .env)."
    )
JWT_ALGORITHM = "HS256"
ACCESS_TOKEN_TTL = timedelta(hours=12)

# bcrypt 는 72바이트까지만 본다. 5.x 는 넘으면 ValueError 를 던진다 (4.x 는 조용히 잘랐다)
BCRYPT_MAX_BYTES = 72

# sub 는 우리가 str(user_id) 로만 만든다. " 2 ", "+2", "0002", "٢" 같은 변형은 거부한다.
# 길이도 20자리(uint64 최댓값 자릿수)로 막는다 — 파이썬 int() 는 4300자리를 넘으면 ValueError 를 던진다
_USER_ID_PATTERN = re.compile(r"[1-9][0-9]{0,19}")


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def verify_password(password: str, password_hash: str) -> bool:
    encoded = password.encode("utf-8")
    if len(encoded) > BCRYPT_MAX_BYTES:
        # 이런 비밀번호로는 hash_password 도 실패하므로 맞을 수가 없다
        return False
    return bcrypt.checkpw(encoded, password_hash.encode("utf-8"))


def create_access_token(user_id: int, ttl: timedelta = ACCESS_TOKEN_TTL) -> str:
    now = datetime.now(timezone.utc)
    # JWT 표준상 sub 는 문자열이다 (PyJWT 2.10+ 는 decode 때 강제한다)
    payload = {"sub": str(user_id), "iat": now, "exp": now + ttl}
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)


def decode_access_token(token: str) -> int:
    """토큰의 user id 를 돌려준다. 서명·만료·sub 형식이 틀리면 jwt.PyJWTError 를 던진다."""
    payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM], options={"require": ["sub", "exp"]})
    sub = payload["sub"]
    if not isinstance(sub, str) or not _USER_ID_PATTERN.fullmatch(sub):
        raise jwt.InvalidTokenError("sub 가 user id 형식이 아님")
    return int(sub)
