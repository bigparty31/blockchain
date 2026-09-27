"""require_roles 의존성. 실제 API 에 붙이기 전이라 테스트 전용 라우트로 확인한다."""
import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

from app.auth import User, require_roles
from app.auth.security import create_access_token
from app.schemas.auth import Role

# 시드 계정 id (app/auth/users.py)
USER_IDS = {Role.STUDENT: 1, Role.TREASURER: 2, Role.AUDITOR: 3, Role.PRESIDENT: 4}

roles_app = FastAPI()


@roles_app.post("/register")
async def register(user: User = Depends(require_roles(Role.TREASURER))):
    return {"id": user.id}


@roles_app.post("/approve")
async def approve(user: User = Depends(require_roles(Role.AUDITOR, Role.PRESIDENT))):
    return {"id": user.id}


client = TestClient(roles_app)


def bearer(role):
    return {"Authorization": f"Bearer {create_access_token(USER_IDS[role])}"}


@pytest.mark.parametrize(
    "path, role, expected",
    [
        ("/register", Role.TREASURER, 200),
        ("/register", Role.STUDENT, 403),
        ("/register", Role.AUDITOR, 403),
        ("/register", Role.PRESIDENT, 403),  # 위계 없음 — 회장도 등록은 못 한다
        ("/approve", Role.AUDITOR, 200),
        ("/approve", Role.PRESIDENT, 200),
        ("/approve", Role.STUDENT, 403),
        ("/approve", Role.TREASURER, 403),
    ],
)
def test_only_allowed_roles_pass(path, role, expected):
    res = client.post(path, headers=bearer(role))
    assert res.status_code == expected
    if expected == 200:
        # 통과하면 로그인 사용자를 그대로 돌려준다
        assert res.json() == {"id": USER_IDS[role]}
    else:
        assert res.json() == {"detail": "이 작업을 할 권한이 없습니다."}


def test_without_token_is_401_not_403():
    res = client.post("/register")
    assert res.status_code == 401


def test_requires_at_least_one_role():
    with pytest.raises(ValueError):
        require_roles()


@pytest.mark.parametrize(
    "roles",
    [("TREASURE",), ((Role.AUDITOR, Role.PRESIDENT),), (Role,)],
    ids=["typo", "tuple-as-one-arg", "enum-class"],
)
def test_invalid_role_fails_at_definition_not_silently_403(roles):
    with pytest.raises(ValueError):
        require_roles(*roles)
