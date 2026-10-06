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
        ("20240002", "TREASURER", "김총무", "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"),
        ("20240003", "AUDITOR", "이감사", "0x90F79bf6EB2c4f870365E785982E1f101E93b906"),
        ("20240004", "PRESIDENT", "박회장", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
        ("20240005", "AUDITOR", "최감사", "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc"),
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


@pytest.mark.parametrize(
    "sub",
    [" 2 ", "+2", "0002", "\u0662", "2\n", 2, [2], pytest.param("1" * 21, id="21-digits"), pytest.param("1" * 5000, id="5000-digits")],
)
def test_me_with_non_canonical_sub_is_401(sub):
    # 올바른 키로 서명됐어도 sub 가 str(user_id) 형식이 아니면 거부한다
    token = jwt.encode({"sub": sub, "exp": 9999999999}, JWT_SECRET, algorithm=JWT_ALGORITHM)
    res = client.get("/auth/me", headers=bearer(token))
    assert res.status_code == 401


def import_security(**env):
    """주어진 값으로 환경변수를 바꾼 새 프로세스에서 security 를 불러온다 (모듈 상수라 이 프로세스에선 못 바꾼다).

    None 을 준 이름은 지운다. 결과의 returncode 가 0 이 아니면 import 가 거부된 것이다.
    """
    code = "from app.auth.security import JWT_SECRET; print(len(JWT_SECRET))"
    merged = {**os.environ, **{k: v for k, v in env.items() if v is not None}}
    for name in (k for k, v in env.items() if v is None):
        merged.pop(name, None)
    return subprocess.run(
        [sys.executable, "-c", code],
        cwd=Path(__file__).resolve().parents[1],
        env=merged,
        capture_output=True,
        text=True,
    )


@pytest.mark.parametrize("jwt_secret", [None, ""])
def test_missing_jwt_secret_refuses_to_start(jwt_secret):
    # 운영에서 설정이 빠졌다고 저장소에 공개된 키로 넘어가지 않는다 (PR #20 2차 리뷰).
    # .env.example 을 그대로 복사하면 JWT_SECRET= 빈 값이 들어온다. 빈 값도 없는 것이다
    result = import_security(JWT_SECRET=jwt_secret, JWT_DEV_SECRET=None)
    assert result.returncode != 0
    assert "JWT_SECRET 미설정" in result.stderr


def test_dev_secret_needs_explicit_flag_and_warns():
    result = import_security(JWT_SECRET="", JWT_DEV_SECRET="1")
    assert result.returncode == 0 and int(result.stdout) > 0
    assert "JWT_DEV_SECRET=1" in result.stderr


@pytest.mark.parametrize("flag", ["true", "yes", "0", ""])
def test_only_1_turns_on_dev_secret(flag):
    # "true" 같은 값을 켠 것으로 읽지 않는다. 켜는 값은 하나다
    result = import_security(JWT_SECRET=None, JWT_DEV_SECRET=flag)
    assert result.returncode != 0


def test_set_jwt_secret_has_no_warning():
    result = import_security(JWT_SECRET="x" * 32, JWT_DEV_SECRET="1")
    assert result.returncode == 0 and int(result.stdout) == 32
    assert "JWT_DEV_SECRET" not in result.stderr


def run_security(env):
    """주어진 환경변수만으로 새 프로세스에서 security 를 불러와 JWT_SECRET 길이와 stderr 를 돌려준다."""
    code = "from app.auth.security import JWT_SECRET; print(len(JWT_SECRET))"
    result = subprocess.run(
        [sys.executable, "-c", code], cwd=Path(__file__).resolve().parents[1],
        env=env, capture_output=True, text=True, check=True,
    )
    return int(result.stdout), result.stderr


def test_jwt_secret_is_read_from_env_file(tmp_path):
    # .env.example 을 .env 로 복사해 채운 경우. README 대로 uvicorn 을 띄워도 이 값을 써야 한다
    env_file = tmp_path / ".env"
    env_file.write_text("JWT_SECRET=" + "x" * 33 + "\n")
    env = {k: v for k, v in os.environ.items() if k != "JWT_SECRET"}
    length, stderr = run_security({**env, "ENV_FILE": str(env_file)})
    assert length == 33
    assert "JWT_SECRET 미설정" not in stderr


def test_real_env_wins_over_env_file(tmp_path):
    # 배포 환경에서 주입한 값을 .env 가 덮어쓰지 않는다
    env_file = tmp_path / ".env"
    env_file.write_text("JWT_SECRET=" + "x" * 33 + "\n")
    length, _ = run_security({**os.environ, "ENV_FILE": str(env_file), "JWT_SECRET": "y" * 40})
    assert length == 40


def test_seed_hash_matches_seed_password():
    # 시드 해시는 미리 계산해 둔 상수다. 비밀번호를 바꾸고 해시를 안 바꾸면 여기서 드러난다
    from app.auth.security import verify_password
    from app.auth.users import _seed_hash

    assert verify_password(SEED_PASSWORD, _seed_hash)
