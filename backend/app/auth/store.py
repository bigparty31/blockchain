"""사용자·지갑 이력·지갑 등록 문장 저장소. 실제 구현은 DB 이고, 지켜야 할 조건은 각 메서드 설명에 있다.

사용자를 통째로 덮어쓰는 save 는 두지 않는다. 요청 처음에 읽은 사용자로 덮으면 그사이 관리자가 한 비활성화·역할 변경이
되살아나기 때문이다. 바꿀 칼럼만, token_version 이 읽었을 때 그대로일 때만 바꾼다.
"""
from datetime import datetime
from enum import Enum
from typing import Any, Optional, Protocol

from app.auth.models import User, WalletChallenge, WalletRecord


class WalletResult(str, Enum):
    ADDED = "ADDED"
    TAKEN = "TAKEN"  # 다른 사용자가 쓰고 있거나 쓴 적 있는 주소, 또는 자기 옛 주소
    STALE = "STALE"  # 그사이 token_version 이 바뀌었다 (비활성화·역할·비밀번호 변경)


class UserStore(Protocol):
    async def add(self, user: User) -> User:
        """id 를 매겨 넣는다. 학번이 이미 있으면 ValueError (student_no 유니크 인덱스)."""
        ...

    async def get(self, user_id: int) -> Optional[User]:
        ...

    async def get_by_student_no(self, student_no: str) -> Optional[User]:
        ...

    async def update(
        self, user_id: int, changes: dict[str, Any], *, expected_token_version: int, retire_wallet_at: Optional[datetime] = None
    ) -> Optional[User]:
        """token_version 이 expected_token_version 일 때만 changes 칼럼을 바꾸고 바뀐 사용자를 돌려준다. 아니면 None.

        retire_wallet_at 을 주면 그 사용자의 현재 지갑을 같은 트랜잭션에서 은퇴시킨다.
        (UPDATE users SET ... WHERE id = :id AND token_version = :v RETURNING *)
        """
        ...

    async def next_wallet_index(self) -> int:
        """학생 지갑 인덱스 하나를 받는다 (시퀀스). 한 번 준 번호는 다시 주지 않는다 — 주소가 사람과 1:1 이어야 한다."""
        ...

    async def add_wallet(self, record: WalletRecord, *, expected_token_version: int) -> WalletResult:
        """임원 지갑을 등록하고 users.wallet_address 를 바꾼다. 같은 사용자의 현재 주소는 record.registered_at 으로 은퇴시킨다.

        token_version 이 다르면 STALE, 그 주소를 쓴 적이 있으면(남이든 자기 옛 주소든) TAKEN 이고 아무것도 바꾸지 않는다.
        이미 자기 현재 주소면 ADDED. 확인·은퇴·등록·사용자 갱신은 한 트랜잭션이어야 한다 (address 유니크 인덱스).
        """
        ...

    async def find_wallet(self, address: str) -> Optional[WalletRecord]:
        """은퇴한 주소도 찾는다. 대소문자 구분 없이 찾는다."""
        ...

    async def save_challenge(self, challenge: WalletChallenge) -> None:
        ...

    async def take_challenge(self, user_id: int, nonce: str) -> Optional[WalletChallenge]:
        """있으면 지우면서 돌려준다. 같은 문장으로 두 번 등록하지 못하게, 확인과 삭제가 한 번에 일어나야 한다."""
        ...


class InMemoryUserStore:
    def __init__(self):
        self._users: dict[int, User] = {}
        self._wallets: list[WalletRecord] = []
        self._challenges: dict[tuple[int, str], WalletChallenge] = {}
        self._next_wallet_index = 0

    async def add(self, user: User) -> User:
        if any(u.student_no == user.student_no for u in self._users.values()):
            raise ValueError(f"학번 {user.student_no} 이 이미 있다")
        user = user.model_copy(update={"id": len(self._users) + 1})
        self._users[user.id] = user
        return user

    async def get(self, user_id: int) -> Optional[User]:
        return self._users.get(user_id)

    async def get_by_student_no(self, student_no: str) -> Optional[User]:
        return next((u for u in self._users.values() if u.student_no == student_no), None)

    async def update(
        self, user_id: int, changes: dict[str, Any], *, expected_token_version: int, retire_wallet_at: Optional[datetime] = None
    ) -> Optional[User]:
        user = self._users.get(user_id)
        if user is None or user.token_version != expected_token_version:
            return None
        if retire_wallet_at is not None:
            self._retire(user_id, retire_wallet_at)
        self._users[user_id] = user = user.model_copy(update=changes)
        return user

    async def next_wallet_index(self) -> int:
        index, self._next_wallet_index = self._next_wallet_index, self._next_wallet_index + 1
        return index

    async def add_wallet(self, record: WalletRecord, *, expected_token_version: int) -> WalletResult:
        user = self._users.get(record.user_id)
        if user is None or user.token_version != expected_token_version:
            return WalletResult.STALE
        taken = await self.find_wallet(record.address)
        if taken is not None and taken.user_id != record.user_id:
            return WalletResult.TAKEN
        if taken is not None and taken.retired_at is None:
            return WalletResult.ADDED  # 이미 이 사용자의 현재 주소다
        if taken is not None:
            return WalletResult.TAKEN  # 자기 옛 주소로 되돌리는 것도 막는다 — 은퇴 시점 앞뒤 서명이 섞인다
        self._retire(record.user_id, record.registered_at)
        self._wallets.append(record)
        self._users[user.id] = user.model_copy(update={"wallet_address": record.address})
        return WalletResult.ADDED

    def _retire(self, user_id: int, at: datetime) -> None:
        self._wallets = [
            w.model_copy(update={"retired_at": at}) if w.user_id == user_id and w.retired_at is None else w
            for w in self._wallets
        ]

    async def find_wallet(self, address: str) -> Optional[WalletRecord]:
        return next((w for w in self._wallets if w.address.lower() == address.lower()), None)

    async def save_challenge(self, challenge: WalletChallenge) -> None:
        self._challenges[(challenge.user_id, challenge.nonce)] = challenge

    async def take_challenge(self, user_id: int, nonce: str) -> Optional[WalletChallenge]:
        return self._challenges.pop((user_id, nonce), None)
