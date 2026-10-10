import logging
import os
import re
from datetime import datetime, timedelta, timezone

import bcrypt
import jwt

logger = logging.getLogger(__name__)

# JWT_SECRET 이 없으면 서버가 뜨지 않는다. 저장소에 공개된 개발용 키는 JWT_DEV_SECRET=1 로 명시했을 때만 쓴다
# (CHAIN_FAKE 와 같은 방식). 운영에서 설정 하나가 빠졌다고 누구나 위조할 수 있는 키로 넘어가면 안 된다.
# 빈 값도 없는 것으로 본다 — .env.example 을 그대로 복사하면 JWT_SECRET= 빈 값이 들어오기 때문
_DEV_SECRET = "dev-only-insecure-secret-change-me"
if os.environ.get("JWT_SECRET"):
    JWT_SECRET = os.environ["JWT_SECRET"]
elif os.environ.get("JWT_DEV_SECRET", "").strip() == "1":
    JWT_SECRET = _DEV_SECRET
    logger.warning(
        "JWT_DEV_SECRET=1: 저장소에 공개된 개발용 키로 토큰을 서명합니다. "
        "이 키로 누구나 토큰을 위조할 수 있으니 개발용으로만 쓰세요."
    )
else:
    raise RuntimeError(
        "JWT_SECRET 미설정: 토큰 서명 키가 없어 서버를 시작하지 않습니다. JWT_SECRET 을 설정하거나, "
        "로컬 개발이면 JWT_DEV_SECRET=1 로 개발용 키를 쓰세요 (환경변수 또는 저장소 루트의 .env)."
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
