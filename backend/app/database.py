import os
from typing import Generator
from sqlalchemy import create_engine, event
from sqlalchemy.engine import Engine
from sqlalchemy.orm import declarative_base, sessionmaker, Session

# 환경 변수에서 DATABASE_URL 읽기 (기본값은 SQLite 파일)
DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    # 기본 개발/테스트용 SQLite
    DATABASE_URL = "sqlite:///./student_council.db"

# SQLite의 경우 check_same_thread 파라미터 필요
connect_args = {}
if DATABASE_URL.startswith("sqlite"):
    connect_args["check_same_thread"] = False

engine = create_engine(DATABASE_URL, connect_args=connect_args)


@event.listens_for(Engine, "connect")
def set_sqlite_pragma(dbapi_connection, connection_record):
    """SQLite 사용 시 외래키 무결성 제약 조건(PRAGMA foreign_keys=ON)을 강제 활성화"""
    if type(dbapi_connection).__module__ == "sqlite3":
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.close()


SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

Base = declarative_base()


def get_db() -> Generator[Session, None, None]:
    """FastAPI 종속성 주입용 DB 세션 제너레이터"""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
