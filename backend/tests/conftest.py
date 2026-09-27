"""테스트 공용 도우미."""
import pytest

from app.auth import users
from app.auth.security import create_access_token
from app.schemas.auth import Role


@pytest.fixture
def auth_header():
    """역할을 받아 그 역할 시드 사용자의 Authorization 헤더를 돌려준다.

        res = client.post("/entries", json=body, headers=auth_header(Role.TREASURER))

    id 는 SEED_USERS 에서 찾으므로 시드 계정이 바뀌어도 따라간다.
    """

    def make(role: Role) -> dict:
        user = next(u for u in users.SEED_USERS if u.role == role)
        return {"Authorization": f"Bearer {create_access_token(user.id)}"}

    return make
