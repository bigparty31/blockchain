"""인증·권한 — 로그인, 토큰 확인, 역할 변경, 임원 지갑 등록, 학생 지갑 주소, 주소 → 임원 매핑. 흐름은 docs/AUTH.md."""
import asyncio
import secrets
import time
from datetime import datetime, timezone
from typing import Any, Callable, Optional

from eth_utils import to_checksum_address

from app.auth.models import (
    AddressOwner,
    AuthError,
    AuthErrorCode,
    User,
    UserRole,
    WalletChallenge,
    WalletRecord,
)
from app.auth.passwords import DUMMY_HASH, MIN_LENGTH, hash_password, verify_password
from app.auth.store import UserStore, WalletResult
from app.auth.tokens import AuthSettings, issue_token, read_token
from app.chain.eip712 import recover_personal_signer
from app.chain.models import check_address
from app.chain.wallets import StudentWallets

CHALLENGE_TITLE = "학생회비 장부 지갑 등록"
ADMIN_RETRIES = 3


class AuthService:
    def __init__(
        self,
        store: UserStore,
        settings: AuthSettings,
        *,
        student_wallets: Optional[StudentWallets] = None,
        clock: Callable[[], float] = time.time,
    ):
        """student_wallets 는 StudentWallets(mnemonic_from_env()) 로 서버 시작 때 한 번 만든다 — 잘못된 니모닉은 거기서 막힌다."""
        self._store = store
        self._settings = settings
        self._wallets = student_wallets
        self._clock = clock

    @property
    def token_ttl_seconds(self) -> int:
        return self._settings.token_ttl_seconds

    # ------------------------------------------------------------ 계정

    async def create_user(self, *, student_no: str, name: str, role: UserRole, password: str) -> User:
        """계정을 만든다. 학생은 지갑 인덱스를 받는다. 처음 로그인하면 비밀번호를 바꾸게 한다.

        누가 어떤 경로로 부르는지(명단 일괄 등록 등)는 정하지 않았다 (docs/AUTH.md §6).
        """
        student_no = student_no.strip()
        if not student_no or not name.strip():
            raise ValueError("학번과 이름은 비울 수 없다")
        _check_password(password)
        if await self._store.get_by_student_no(student_no) is not None:
            raise AuthError(AuthErrorCode.STUDENT_NO_TAKEN, student_no)
        password_hash = await _hash(password)
        wallet_index = await self._store.next_wallet_index() if role == UserRole.STUDENT else None
        user = User(
            id=0, student_no=student_no, name=name.strip(), role=role, password_hash=password_hash,
            wallet_index=wallet_index,
        )
        try:
            return await self._store.add(user)
        except ValueError as e:  # 확인과 넣기 사이에 같은 학번이 들어왔다
            raise AuthError(AuthErrorCode.STUDENT_NO_TAKEN, student_no) from e

    async def change_role(self, user_id: int, role: UserRole) -> User:
        """역할을 바꾸고 이전 토큰을 모두 무효로 만든다.

        체인의 RoleManager 롤은 여기서 바꾸지 않는다 — 회장이 직접 보내야 한다 (docs/CHAIN_CLIENT.md §8).
        임원에서 학생이 되면 지갑을 은퇴시킨다 — 다시 임원이 되면 새로 등록해야 한다 (기기를 잃었을 수 있다).
        임원끼리 바뀌면(감사 → 회장) 지갑을 그대로 둔다.
        """
        for _ in range(ADMIN_RETRIES):
            user = await self._get(user_id)
            changes: dict[str, Any] = {"role": role, "token_version": user.token_version + 1}
            retire_at = None
            if role == UserRole.STUDENT and user.wallet_index is None:
                changes["wallet_index"] = await self._store.next_wallet_index()
            if role == UserRole.STUDENT and user.role.is_officer:
                changes["wallet_address"] = None
                retire_at = _utc(self._clock())
            updated = await self._store.update(
                user_id, changes, expected_token_version=user.token_version, retire_wallet_at=retire_at
            )
            if updated is not None:
                return updated
        raise AuthError(AuthErrorCode.CONFLICT, f"id={user_id} 가 동시에 계속 바뀌고 있다")

    async def deactivate(self, user_id: int) -> User:
        for _ in range(ADMIN_RETRIES):
            user = await self._get(user_id)
            changes = {"active": False, "token_version": user.token_version + 1}
            updated = await self._store.update(user_id, changes, expected_token_version=user.token_version)
            if updated is not None:
                return updated
        raise AuthError(AuthErrorCode.CONFLICT, f"id={user_id} 가 동시에 계속 바뀌고 있다")

    # ------------------------------------------------------------ 로그인·토큰

    async def login(self, student_no: str, password: str) -> tuple[str, User]:
        """학번·비밀번호로 로그인한다. 틀린 이유(없는 학번·틀린 비밀번호·비활성)는 구분해 알려주지 않는다."""
        user = await self._store.get_by_student_no(student_no.strip())
        if user is None:
            await _verify(password, DUMMY_HASH)  # 없는 학번도 같은 시간을 쓴다
            raise AuthError(AuthErrorCode.INVALID_CREDENTIALS)
        if not await _verify(password, user.password_hash) or not user.active:
            raise AuthError(AuthErrorCode.INVALID_CREDENTIALS)
        return issue_token(self._settings, user, self._clock()), user

    async def authenticate(self, token: str, *, allow_password_change: bool = False) -> User:
        """토큰의 사용자. 요청마다 부른다.

        비밀번호를 바꿔야 하는 계정은 비밀번호 변경 요청(allow_password_change=True)에서만 통과한다.
        """
        claims = read_token(self._settings, token, self._clock())
        try:
            user = await self._store.get(int(claims["sub"]))
        except ValueError:
            user = None
        if user is None or not user.active or user.token_version != claims["ver"]:
            raise AuthError(AuthErrorCode.INVALID_TOKEN, "폐기된 토큰")
        if user.password_change_required and not allow_password_change:
            raise AuthError(AuthErrorCode.PASSWORD_CHANGE_REQUIRED)
        return user

    async def change_password(self, user: User, old_password: str, new_password: str) -> tuple[str, User]:
        """비밀번호를 바꾸고 다른 기기의 토큰을 모두 무효로 만든다. 새 토큰을 돌려준다."""
        if not await _verify(old_password, user.password_hash):
            raise AuthError(AuthErrorCode.INVALID_CREDENTIALS)
        _check_password(new_password)
        if new_password == old_password:
            raise AuthError(AuthErrorCode.WEAK_PASSWORD, "이전과 같은 비밀번호")
        changes = {
            "password_hash": await _hash(new_password),
            "password_change_required": False,
            "token_version": user.token_version + 1,
        }
        updated = await self._store.update(user.id, changes, expected_token_version=user.token_version)
        if updated is None:  # 요청 처리 중에 비활성화·역할 변경 등으로 토큰이 무효가 됐다. 그 결정을 덮어쓰지 않는다
            raise AuthError(AuthErrorCode.INVALID_TOKEN, "처리하는 사이 계정이 바뀌었다")
        return issue_token(self._settings, updated, self._clock()), updated

    # ------------------------------------------------------------ 권한

    @staticmethod
    def require(user: User, *roles: UserRole) -> None:
        if user.role not in roles:
            raise AuthError(AuthErrorCode.FORBIDDEN, f"{'/'.join(r.value for r in roles)} 만 할 수 있다")

    # ------------------------------------------------------------ 지갑

    async def wallet_challenge(self, user: User) -> WalletChallenge:
        """임원 기기가 서명할 문장을 만든다. 기기 키스토어의 개인키로 personal_sign(EIP-191) 한다."""
        self.require(user, UserRole.TREASURER, UserRole.AUDITOR, UserRole.PRESIDENT)
        nonce = secrets.token_hex(16)
        expires_at = _utc(self._clock() + self._settings.challenge_ttl_seconds)
        message = f"{CHALLENGE_TITLE}\nuser: {user.id}\nnonce: {nonce}\nexpires: {expires_at.isoformat()}"
        challenge = WalletChallenge(user_id=user.id, nonce=nonce, message=message, expires_at=expires_at)
        await self._store.save_challenge(challenge)
        return challenge

    async def register_wallet(self, user: User, nonce: str, address: str, signature: str) -> User:
        """서명으로 address 의 개인키를 가졌음을 확인하고 임원 지갑으로 등록한다. 이전 주소는 이력으로 남긴다.

        앱이 등록할 주소를 함께 보내고 서버가 서명에서 복구한 주소와 대조한다. 서명만 받으면, 앱이 문장을 조금
        다르게 서명했을 때 아무도 키를 갖지 않은 엉뚱한 주소가 등록된다.
        체인의 롤을 새 주소로 옮기는 것(RoleManager 키 교체)은 따로 해야 한다.
        """
        self.require(user, UserRole.TREASURER, UserRole.AUDITOR, UserRole.PRESIDENT)
        challenge = await self._store.take_challenge(user.id, nonce)
        now = self._clock()
        if challenge is None or challenge.expires_at <= _utc(now):
            raise AuthError(AuthErrorCode.CHALLENGE_INVALID)
        try:
            claimed = to_checksum_address(check_address(address))
            recovered = recover_personal_signer(challenge.message, signature)
        except ValueError as e:
            raise AuthError(AuthErrorCode.SIGNATURE_INVALID, str(e)) from e
        if recovered != claimed:
            raise AuthError(AuthErrorCode.SIGNATURE_INVALID, f"서명한 주소는 {recovered} 다")

        record = WalletRecord(user_id=user.id, address=claimed, registered_at=_utc(now))
        result = await self._store.add_wallet(record, expected_token_version=user.token_version)
        if result == WalletResult.TAKEN:
            raise AuthError(AuthErrorCode.WALLET_TAKEN, record.address)
        if result == WalletResult.STALE:  # 요청 처리 중에 비활성화·역할 변경 등으로 토큰이 무효가 됐다
            raise AuthError(AuthErrorCode.INVALID_TOKEN, "처리하는 사이 계정이 바뀌었다")
        return await self._get(user.id)

    def wallet_address(self, user: User) -> Optional[str]:
        """임원은 등록한 기기 주소, 학생은 서버 HD 지갑에서 파생한 주소 (PRD §9.2)."""
        if user.role.is_officer:
            return user.wallet_address
        if user.wallet_index is None:
            return None
        if self._wallets is None:
            raise AuthError(AuthErrorCode.WALLET_NOT_CONFIGURED, "STUDENT_WALLET_MNEMONIC")
        try:
            return self._wallets.address(user.wallet_index)
        except ValueError as e:  # 인덱스가 범위를 넘는 등. 요청이 500 으로 새지 않게 설정 문제로 알린다
            raise AuthError(AuthErrorCode.WALLET_NOT_CONFIGURED, str(e)) from e

    async def owner_of(self, address: str) -> Optional[AddressOwner]:
        """임원 지갑 주소의 주인. 키를 바꾸기 전 주소도 찾는다. 학생 주소는 알려주지 않는다 — 학번↔주소 매핑은 공개하지 않는다 (PRD §7.1)."""
        record = await self._store.find_wallet(address)
        if record is None:
            return None
        user = await self._get(record.user_id)
        return AddressOwner(
            address=record.address, user_id=user.id, name=user.name, role=user.role,
            current=record.retired_at is None, registered_at=record.registered_at, retired_at=record.retired_at,
        )

    async def _get(self, user_id: int) -> User:
        user = await self._store.get(user_id)
        if user is None:
            raise AuthError(AuthErrorCode.USER_NOT_FOUND, f"id={user_id}")
        return user


async def _hash(password: str) -> str:
    # scrypt 는 수십 ms·16MB 를 쓰는 계산이다. 이벤트 루프에서 돌리면 로그인이 몰릴 때 다른 요청·대조 작업이 전부 멈춘다
    return await asyncio.to_thread(hash_password, password)


async def _verify(password: str, stored: str) -> bool:
    return await asyncio.to_thread(verify_password, password, stored)


def _check_password(password: str) -> None:
    if len(password) < MIN_LENGTH:
        raise AuthError(AuthErrorCode.WEAK_PASSWORD, f"{MIN_LENGTH}자 이상")


def _utc(ts: float) -> datetime:
    return datetime.fromtimestamp(ts, tz=timezone.utc)
