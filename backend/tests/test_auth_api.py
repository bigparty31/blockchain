"""로그인·세션 API (docs/API.md 「인증」)."""
import os
import subprocess
import sys
from datetime import timedelta
from pathlib import Path

import jwt
import pytest
from fastapi.testclient import TestClient

from app.auth.security import JWT_ALGORITHM, JWT_SECRET, create_access_token
from app.auth.users import SEED_PASSWORD
from app.main import app

client = TestClient(app)


def login(student_no, password=SEED_PASSWORD):
    return client.post("/auth/login", json={"student_no": student_no, "password": password})


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


@pytest.mark.parametrize(
    "student_no, role, name, wallet_address",
    [
        ("20240001", "STUDENT", "김학생", None),
        ("20240002", "TREASURER", "김총무", "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"),
        ("20240003", "AUDITOR", "이감사", "0x2546BcD3c84621e976D8185a91A922aE77ECEc30"),
        ("20240004", "PRESIDENT", "박회장", "0xbDA5747bFD65F08deb54cb465eB87D40e51B197E"),
    ],
)
def test_login_returns_token_and_role(student_no, role, name, wallet_address):
    res = login(student_no)
    assert res.status_code == 200
    data = res.json()
    assert data["access_token"]
    assert data["token_type"] == "bearer"
    assert data["role"] == role
    assert data["name"] == name
    assert data["wallet_address"] == wallet_address


def test_login_wrong_password_and_unknown_student_no_look_the_same():
    wrong_password = login("20240002", "wrong")
    unknown_user = login("99999999")
    assert wrong_password.status_code == unknown_user.status_code == 401
    # 학번 존재 여부가 응답으로 드러나지 않아야 한다
    assert wrong_password.json() == unknown_user.json()


def test_me_returns_logged_in_user():
    token = login("20240003").json()["access_token"]
    res = client.get("/auth/me", headers=bearer(token))
    assert res.status_code == 200
    assert res.json() == {"id": 3, "student_no": "20240003", "name": "이감사", "role": "AUDITOR"}


def test_me_without_token_is_401():
    res = client.get("/auth/me")
    assert res.status_code == 401
    assert res.headers["www-authenticate"] == "Bearer"


@pytest.mark.parametrize(
    "token",
    [
        "not-a-jwt",
        create_access_token(2, ttl=timedelta(seconds=-1)),  # 만료
        jwt.encode({"sub": "2", "exp": 9999999999}, "some-other-secret-that-is-32-bytes-long", algorithm=JWT_ALGORITHM),  # 다른 키로 서명
        create_access_token(999),  # 없는 사용자
    ],
    ids=["garbage", "expired", "wrong-secret", "unknown-user"],
)
def test_me_with_invalid_token_is_401(token):
    res = client.get("/auth/me", headers=bearer(token))
    assert res.status_code == 401


@pytest.mark.parametrize("password", ["a" * 73, "가" * 25], ids=["ascii-73B", "korean-75B"])
@pytest.mark.parametrize("student_no", ["20240002", "99999999"], ids=["existing", "unknown"])
def test_login_with_password_over_72_bytes_is_401_not_500(student_no, password):
    # bcrypt 5.x 는 72바이트 초과 비밀번호에 ValueError 를 던진다
    assert login(student_no, password).status_code == 401


@pytest.mark.parametrize("sub", [" 2 ", "+2", "0002", "\u0662", "2\n", 2, [2]])
def test_me_with_non_canonical_sub_is_401(sub):
    # 올바른 키로 서명됐어도 sub 가 str(user_id) 형식이 아니면 거부한다
    token = jwt.encode({"sub": sub, "exp": 9999999999}, JWT_SECRET, algorithm=JWT_ALGORITHM)
    res = client.get("/auth/me", headers=bearer(token))
    assert res.status_code == 401


def import_security(jwt_secret):
    """JWT_SECRET 을 지정한 새 프로세스에서 security 를 불러온다 (모듈 상수라 이 프로세스에선 못 바꾼다)."""
    code = "from app.auth.security import JWT_SECRET; print(len(JWT_SECRET))"
    return subprocess.run(
        [sys.executable, "-c", code],
        cwd=Path(__file__).resolve().parents[1],
        env={**os.environ, "JWT_SECRET": jwt_secret},
        capture_output=True,
        text=True,
        check=True,
    )


def test_empty_jwt_secret_env_falls_back_to_default_with_warning():
    # .env.example 을 그대로 복사하면 JWT_SECRET= 빈 값이 들어온다. 빈 키로는 서명 자체가 안 된다
    result = import_security("")
    assert int(result.stdout) > 0
    assert "JWT_SECRET 미설정" in result.stderr


def test_set_jwt_secret_has_no_warning():
    result = import_security("x" * 32)
    assert int(result.stdout) == 32
    assert "JWT_SECRET 미설정" not in result.stderr
