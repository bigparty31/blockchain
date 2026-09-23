from typing import List, Optional
from pydantic import BaseModel

from app.auth.security import hash_password
from app.schemas.auth import Role


class User(BaseModel):
    """PRD §8 User. 학생은 wallet_index(서버 HD 월렛 파생), 임원은 wallet_address(기기 키)."""

    id: int
    student_no: str
    name: str
    role: Role
    password_hash: str
    wallet_index: Optional[int] = None
    wallet_address: Optional[str] = None


# DB 도입 전 시드 계정. id 는 기존 더미 데이터(entries: created_by=2, approved_by=3)와
# 앱 데모 지갑 매핑(#2 총무, #3 감사, #4 회장)에 맞춘다. 비밀번호는 docs/API.md 예시값.
SEED_PASSWORD = "userPassword123!"
_seed_hash = hash_password(SEED_PASSWORD)

SEED_USERS: List[User] = [
    User(id=1, student_no="20240001", name="김학생", role=Role.STUDENT, password_hash=_seed_hash, wallet_index=0),
    User(
        id=2,
        student_no="20240002",
        name="김총무",
        role=Role.TREASURER,
        password_hash=_seed_hash,
        wallet_address="0x71C7656EC7ab88b098defB751B7401B5f6d8976F",
    ),
    User(
        id=3,
        student_no="20240003",
        name="이감사",
        role=Role.AUDITOR,
        password_hash=_seed_hash,
        wallet_address="0x2546BcD3c84621e976D8185a91A922aE77ECEc30",
    ),
    User(
        id=4,
        student_no="20240004",
        name="박회장",
        role=Role.PRESIDENT,
        password_hash=_seed_hash,
        wallet_address="0xbDA5747bFD65F08deb54cb465eB87D40e51B197E",
    ),
]


def get_user_by_student_no(student_no: str) -> Optional[User]:
    return next((u for u in SEED_USERS if u.student_no == student_no), None)


def get_user_by_id(user_id: int) -> Optional[User]:
    return next((u for u in SEED_USERS if u.id == user_id), None)
