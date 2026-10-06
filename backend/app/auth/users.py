from typing import List, Optional
from pydantic import BaseModel

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


# DB 도입 전 시드 계정. id 는 기존 더미 데이터(entries: created_by=2, approved_by=3)에 맞춘다.
# 임원 지갑은 로컬 배포의 임원 계정(contracts/deployments/localhost.json "accounts")과 같아야 한다 —
# 체인의 registrant·approver 를 사용자와 대조하는 기준이다. 감사는 컨트랙트 규칙상 최소 2명.
# tests/test_seed_wallets.py 가 두 값이 어긋나지 않는지 확인한다. 비밀번호는 docs/API.md 예시값.
SEED_PASSWORD = "userPassword123!"
# SEED_PASSWORD 의 bcrypt(cost 12) 해시를 미리 계산해 둔 값. import 할 때마다 해시하면 서버 시작·reload·pytest 마다
# 약 0.25초가 든다. 비밀번호를 바꾸면 hash_password 로 다시 뽑는다 (tests/test_auth_api.py 가 둘이 맞는지 확인한다)
_seed_hash = "$2b$12$9Zc4eRdESnfVfjsmQeu4TuqvtygpI4x/XSACfPfjjsjHJYZrYjcdG"

SEED_USERS: List[User] = [
    User(id=1, student_no="20240001", name="김학생", role=Role.STUDENT, password_hash=_seed_hash, wallet_index=0),
    User(
        id=2,
        student_no="20240002",
        name="김총무",
        role=Role.TREASURER,
        password_hash=_seed_hash,
        wallet_address="0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",  # Hardhat 계정 2
    ),
    User(
        id=3,
        student_no="20240003",
        name="이감사",
        role=Role.AUDITOR,
        password_hash=_seed_hash,
        wallet_address="0x90F79bf6EB2c4f870365E785982E1f101E93b906",  # Hardhat 계정 3
    ),
    User(
        id=4,
        student_no="20240004",
        name="박회장",
        role=Role.PRESIDENT,
        password_hash=_seed_hash,
        wallet_address="0x70997970C51812dc3A010C7d01b50e0d17dc79C8",  # Hardhat 계정 1
    ),
    User(
        id=5,
        student_no="20240005",
        name="최감사",
        role=Role.AUDITOR,
        password_hash=_seed_hash,
        wallet_address="0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc",  # Hardhat 계정 5
    ),
]


def get_user_by_student_no(student_no: str) -> Optional[User]:
    return next((u for u in SEED_USERS if u.student_no == student_no), None)


def get_user_by_id(user_id: int) -> Optional[User]:
    return next((u for u in SEED_USERS if u.id == user_id), None)
