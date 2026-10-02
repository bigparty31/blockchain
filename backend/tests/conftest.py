"""테스트 공용 도우미."""
import os

# 개발자의 .env(JWT_SECRET, DEPLOYMENTS_FILE 등)가 테스트 결과를 바꾸지 않게, app 을 import 하기 전에 빈 파일을 가리킨다
os.environ["ENV_FILE"] = os.devnull

import pytest  # noqa: E402

from app.auth import users  # noqa: E402
from app.auth.security import create_access_token
from app.schemas.auth import Role


@pytest.fixture
def seed_user():
    """역할을 받아 그 역할의 시드 사용자를 돌려준다.

    id 를 숫자로 적지 않고 SEED_USERS 에서 찾으므로 시드 계정이 바뀌어도 따라간다.
    호출할 때마다 SEED_USERS 를 다시 읽어 monkeypatch 로 추가한 사용자도 보인다.
    """

    def find(role: Role) -> users.User:
        return next(u for u in users.SEED_USERS if u.role == role)

    return find


@pytest.fixture
def auth_header(seed_user):
    """역할을 받아 그 역할 시드 사용자의 Authorization 헤더를 돌려준다.

        res = client.post("/entries", json=body, headers=auth_header(Role.TREASURER))
    """

    def make(role: Role) -> dict:
        return {"Authorization": f"Bearer {create_access_token(seed_user(role).id)}"}

    return make
