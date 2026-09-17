"""비밀번호 해시. 표준 라이브러리 scrypt 를 써서 의존성을 늘리지 않는다.

저장 형식: scrypt$<n>$<r>$<p>$<salt base64>$<hash base64>. 설정을 올려도 옛 해시를 계속 확인할 수 있게 값을 함께 둔다.
"""
import base64
import hashlib
import hmac
import secrets

N, R, P = 2**14, 8, 1
SALT_BYTES = 16
KEY_BYTES = 32
MIN_LENGTH = 8


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(SALT_BYTES)
    key = hashlib.scrypt(password.encode("utf-8"), salt=salt, n=N, r=R, p=P, dklen=KEY_BYTES)
    return f"scrypt${N}${R}${P}${_b64(salt)}${_b64(key)}"


def verify_password(password: str, stored: str) -> bool:
    try:
        scheme, n, r, p, salt, key = stored.split("$")
        if scheme != "scrypt":
            return False
        expected = base64.b64decode(key)
        actual = hashlib.scrypt(
            password.encode("utf-8"), salt=base64.b64decode(salt), n=int(n), r=int(r), p=int(p), dklen=len(expected)
        )
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(actual, expected)


# 없는 학번으로 로그인해도 같은 만큼 시간을 쓰게 해서, 응답 시간으로 가입 여부를 알 수 없게 한다
DUMMY_HASH = hash_password(secrets.token_hex(16))
