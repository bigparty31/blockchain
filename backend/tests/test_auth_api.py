"""로그인·세션 API (docs/API.md 「인증」)."""
from datetime import timedelta

import jwt
import pytest
from fastapi.testclient import TestClient

from app.auth.security import JWT_ALGORITHM, create_access_token
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
