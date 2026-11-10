import pytest
from datetime import datetime, timezone
from fastapi.testclient import TestClient

from app.main import app
from app.database import get_db
from app.models import Term as DBTerm
from app.models import Base
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

client = TestClient(app)


@pytest.fixture
def term_test_db(tmp_path):
    test_db_path = tmp_path / "test_terms.db"
    engine = create_engine(
        f"sqlite:///{test_db_path}",
        connect_args={"check_same_thread": False},
    )
    TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    Base.metadata.create_all(bind=engine)

    db = TestingSessionLocal()
    # 테스트 학기 데이터 생성
    t1 = DBTerm(
        id=1,
        term_code=20262,
        name="2026학년도 2학기",
        started_at=datetime(2026, 9, 1, 0, 0, 0, tzinfo=timezone.utc),
        ended_at=datetime(2026, 12, 14, 23, 59, 59, tzinfo=timezone.utc),
    )
    t2 = DBTerm(
        id=2,
        term_code=20271,
        name="2027학년도 1학기",
        started_at=datetime(2027, 3, 1, 0, 0, 0, tzinfo=timezone.utc),
        ended_at=datetime(2027, 6, 21, 23, 59, 59, tzinfo=timezone.utc),
    )
    db.add(t1)
    db.add(t2)
    db.commit()
    db.close()

    def override_get_db():
        db = TestingSessionLocal()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    yield
    app.dependency_overrides.pop(get_db, None)


def test_get_terms_list(term_test_db):
    res = client.get("/terms")
    assert res.status_code == 200
    data = res.json()
    assert len(data) == 2
    assert data[0]["id"] == 1
    assert data[0]["term_code"] == 20262
    assert data[0]["name"] == "2026학년도 2학기"
    assert data[1]["id"] == 2
    assert data[1]["term_code"] == 20271


def test_get_term_by_id_success(term_test_db):
    res = client.get("/terms/1")
    assert res.status_code == 200
    data = res.json()
    assert data["id"] == 1
    assert data["term_code"] == 20262
    assert data["name"] == "2026학년도 2학기"


def test_get_term_by_id_not_found(term_test_db):
    res = client.get("/terms/999")
    assert res.status_code == 404
    assert "찾을 수 없습니다" in res.json()["detail"]

