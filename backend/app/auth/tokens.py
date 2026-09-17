"""액세스 토큰 (JWT, HS256).

토큰에는 사용자 id·역할·token_version 만 담는다. 요청마다 사용자를 다시 읽어 token_version·활성 여부를 확인하므로,
비밀번호·역할을 바꾸거나 계정을 막으면 이미 나간 토큰도 바로 무효가 된다. 역할은 토큰이 아니라 다시 읽은 사용자 값을 믿는다.
"""
import os
from collections.abc import Mapping

import jwt
from pydantic import BaseModel, ConfigDict, Field, SecretStr, field_validator

from app.auth.models import AuthError, AuthErrorCode, User

ALGORITHM = "HS256"
ISSUER = "student-council-ledger"
CLOCK_SKEW_SECONDS = 60


class AuthSettings(BaseModel):
    model_config = ConfigDict(frozen=True)

    secret: SecretStr = Field(..., description="AUTH_SECRET. 32바이트 이상 무작위 값. 저장소에 넣지 않는다")
    token_ttl_seconds: int = Field(12 * 3600, gt=0, description="AUTH_TOKEN_TTL_SECONDS")
    challenge_ttl_seconds: int = Field(300, gt=0, description="AUTH_CHALLENGE_TTL_SECONDS. 지갑 등록 문장의 유효 시간")

    @field_validator("secret")
    @classmethod
    def _long_enough(cls, v: SecretStr) -> SecretStr:
        if len(v.get_secret_value().encode("utf-8")) < 32:
            raise ValueError("AUTH_SECRET 은 32바이트 이상이어야 한다")
        return v

    @classmethod
    def from_env(cls, env: Mapping[str, str] = os.environ) -> "AuthSettings":
        values = {}
        for field, key in (("secret", "AUTH_SECRET"), ("token_ttl_seconds", "AUTH_TOKEN_TTL_SECONDS"),
                           ("challenge_ttl_seconds", "AUTH_CHALLENGE_TTL_SECONDS")):
            if key in env:
                values[field] = env[key]
        return cls(**values)


def issue_token(settings: AuthSettings, user: User, now: float) -> str:
    claims = {
        "iss": ISSUER,
        "sub": str(user.id),
        "role": user.role.value,
        "ver": user.token_version,
        "iat": int(now),
        "exp": int(now) + settings.token_ttl_seconds,
    }
    return jwt.encode(claims, settings.secret.get_secret_value(), algorithm=ALGORITHM)


def read_token(settings: AuthSettings, token: str, now: float) -> dict:
    """서명·발급자·만료를 확인한 claims. 사용자와의 대조(버전·활성)는 AuthService 가 한다."""
    try:
        claims = jwt.decode(
            token,
            settings.secret.get_secret_value(),
            algorithms=[ALGORITHM],  # 알고리즘을 고정해 none·RS/HS 혼동 공격을 막는다
            issuer=ISSUER,
            # 시각 확인은 주입받은 시계로 아래에서 직접 한다 (테스트·서버 시계를 한 곳에서 다루려고)
            options={"require": ["sub", "ver", "iat", "exp"], "verify_exp": False, "verify_iat": False, "verify_nbf": False},
        )
    except jwt.PyJWTError as e:
        raise AuthError(AuthErrorCode.INVALID_TOKEN, type(e).__name__) from e
    if claims["exp"] <= now:
        raise AuthError(AuthErrorCode.INVALID_TOKEN, "만료")
    if claims["iat"] > now + CLOCK_SKEW_SECONDS:
        raise AuthError(AuthErrorCode.INVALID_TOKEN, "발급 시각이 미래")
    return claims
