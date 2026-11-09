"""테스트 공용 도우미."""
import os

# 개발자의 .env(JWT_SECRET, DEPLOYMENTS_FILE 등)가 테스트 결과를 바꾸지 않게, app 을 import 하기 전에 빈 파일을 가리킨다
os.environ["ENV_FILE"] = os.devnull
# 키가 없으면 app.auth.security 를 import 할 수 없다. 셸에 JWT_SECRET 이 없으면 개발용 키를 쓴다
os.environ.setdefault("JWT_DEV_SECRET", "1")

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


# ---------------------------------------------------------------- 체인 테스트


@pytest.fixture
def node():
    """로컬 Hardhat 노드가 필요한 테스트. 노드가 없으면 건너뛴다."""
    import chain_support

    if not chain_support.node_available():
        pytest.skip("로컬 Hardhat 노드가 없다 (contracts 에서 npx hardhat node → npm run deploy:local)")


@pytest.fixture
def clean_chain_env(monkeypatch):
    """셸의 체인 설정(CHAIN_RPC_URL·CHAIN_FAKE·RELAYER_PRIVATE_KEY·DEPLOYMENTS_FILE)이 체인 테스트 결과를 바꾸지 않게 지운다."""
    for name in ("CHAIN_RPC_URL", "CHAIN_FAKE", "RELAYER_PRIVATE_KEY", "DEPLOYMENTS_FILE"):
        monkeypatch.delenv(name, raising=False)


# ---------------------------------------------------------------- 로그인


@pytest.fixture
def login_db(tmp_path):
    """로그인 API 가 쓰는 DB(login_attempts)를 시험마다 새 SQLite 파일로 바꾼다. 엔진을 돌려준다.

    메모리 DB 가 아니라 파일로 둔다. 동시 요청 시험에서 스레드마다 다른 연결이 같은 DB 를 봐야 한다.
    """
    from sqlalchemy import create_engine
    from sqlalchemy.orm import sessionmaker

    from app.database import Base, get_db
    from app.main import app

    engine = create_engine(
        f"sqlite:///{tmp_path / 'login.db'}",
        # 동시 요청이 쓰기 잠금을 기다리게 한다 (기본 5초로도 되지만 느린 CI 를 위해 넉넉히)
        connect_args={"check_same_thread": False, "timeout": 30},
    )
    Base.metadata.create_all(bind=engine)
    session = sessionmaker(autocommit=False, autoflush=False, bind=engine)

    def override():
        db = session()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override
    yield engine
    app.dependency_overrides.pop(get_db, None)
    engine.dispose()
