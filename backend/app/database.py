import os
from typing import Generator
from sqlalchemy import create_engine
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
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

Base = declarative_base()


def get_db() -> Generator[Session, None, None]:
    """FastAPI 종속성 주입용 DB 세션 제너레이터"""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
