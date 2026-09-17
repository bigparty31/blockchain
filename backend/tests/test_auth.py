import asyncio

import jwt
import pytest
from eth_account import Account
from eth_account.messages import encode_defunct
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

from app.auth import (
    AuthError,
    AuthErrorCode,
    AuthService,
    AuthSettings,
    InMemoryUserStore,
    User,
    UserRole,
    get_auth_service,
    require_roles,
)
from app.auth.passwords import hash_password, verify_password
from app.auth.router import router
from app.auth.tokens import issue_token
from app.chain.wallets import StudentWallets

SECRET = "s" * 32
HARDHAT_MNEMONIC = "test test test test test test test test test test test junk"
NOW = 1_790_000_000.0


class Clock:
    def __init__(self, now):
        self.now = now

    def __call__(self):
        return self.now


def run(coro):
    return asyncio.run(coro)


@pytest.fixture
def clock():
    return Clock(NOW)


@pytest.fixture
def service(clock):
    return AuthService(InMemoryUserStore(), AuthSettings(secret=SECRET), student_wallets=StudentWallets(HARDHAT_MNEMONIC), clock=clock)


def make_user(service, student_no="20231234", role=UserRole.STUDENT, password="initial-pass", change=True):
    user = run(service.create_user(student_no=student_no, name="손종인", role=role, password=password))
    if change:
        _, user = run(service.change_password(user, password, "changed-pass"))
    return user


def login(service, student_no="20231234", password="changed-pass"):
    return run(service.login(student_no, password))


def sign(account, message):
    return Account.sign_message(encode_defunct(text=message), account.key).signature.to_0x_hex()


def expect(code, coro):
    with pytest.raises(AuthError) as e:
        run(coro)
    assert e.value.code == code


# ---------------------------------------------------------------- 비밀번호·설정


def test_password_hash_roundtrip_and_salt():
    stored = hash_password("correct horse")
    assert stored.startswith("scrypt$")
    assert verify_password("correct horse", stored)
    assert not verify_password("wrong horse", stored)
    assert hash_password("correct horse") != stored
    assert not verify_password("x", "garbage")


def test_secret_must_be_long_enough():
    with pytest.raises(ValueError):
        AuthSettings(secret="short")
    assert AuthSettings.from_env({"AUTH_SECRET": SECRET, "AUTH_TOKEN_TTL_SECONDS": "60"}).token_ttl_seconds == 60


# ---------------------------------------------------------------- 로그인·토큰


def test_login_and_authenticate(service):
    user = make_user(service)
    token, logged_in = login(service)
    assert logged_in.id == user.id
    assert run(service.authenticate(token)).student_no == "20231234"


@pytest.mark.parametrize("student_no, password", [("20231234", "wrong-pass"), ("99999999", "changed-pass")])
def test_login_failures_look_the_same(service, student_no, password):
    make_user(service)
    expect(AuthErrorCode.INVALID_CREDENTIALS, service.login(student_no, password))


def test_new_account_must_change_password_first(service):
    user = make_user(service, change=False)
    token, _ = login(service, password="initial-pass")
    expect(AuthErrorCode.PASSWORD_CHANGE_REQUIRED, service.authenticate(token))
    assert run(service.authenticate(token, allow_password_change=True)).id == user.id

    new_token, _ = run(service.change_password(user, "initial-pass", "changed-pass"))
    assert run(service.authenticate(new_token)).password_change_required is False


def test_password_change_revokes_other_tokens(service):
    make_user(service)
    old_token, _ = login(service)
    run(service.change_password(run(service.authenticate(old_token)), "changed-pass", "another-pass"))
    expect(AuthErrorCode.INVALID_TOKEN, service.authenticate(old_token))

    _, latest = login(service, password="another-pass")
    expect(AuthErrorCode.INVALID_CREDENTIALS, service.change_password(latest, "changed-pass", "third-pass"))
    expect(AuthErrorCode.WEAK_PASSWORD, service.change_password(latest, "another-pass", "short"))
    expect(AuthErrorCode.WEAK_PASSWORD, service.change_password(latest, "another-pass", "another-pass"))


def test_role_change_and_deactivation_revoke_tokens(service):
    user = make_user(service)
    token, _ = login(service)
    run(service.change_role(user.id, UserRole.TREASURER))
    expect(AuthErrorCode.INVALID_TOKEN, service.authenticate(token))

    token, _ = login(service)
    run(service.deactivate(user.id))
    expect(AuthErrorCode.INVALID_TOKEN, service.authenticate(token))
    expect(AuthErrorCode.INVALID_CREDENTIALS, service.login("20231234", "changed-pass"))


def test_token_expiry_and_tampering(service, clock):
    make_user(service)
    token, user = login(service)
    clock.now = NOW + service.token_ttl_seconds
    expect(AuthErrorCode.INVALID_TOKEN, service.authenticate(token))

    clock.now = NOW
    forged = jwt.encode({"iss": "student-council-ledger", "sub": str(user.id), "ver": 0, "iat": int(NOW), "exp": int(NOW) + 60,
                         "role": "PRESIDENT"}, "x" * 32, algorithm="HS256")
    expect(AuthErrorCode.INVALID_TOKEN, service.authenticate(forged))
    unsigned = jwt.encode({"iss": "student-council-ledger", "sub": str(user.id), "ver": user.token_version, "iat": int(NOW),
                           "exp": int(NOW) + 60}, None, algorithm="none")
    expect(AuthErrorCode.INVALID_TOKEN, service.authenticate(unsigned))


def test_role_comes_from_store_not_token(service):
    """토큰의 role 은 참고용이다. 권한 판단은 다시 읽은 사용자 값으로 한다."""
    user = make_user(service)
    settings = AuthSettings(secret=SECRET)
    token = issue_token(settings, user.model_copy(update={"role": UserRole.PRESIDENT}), NOW)
    assert run(service.authenticate(token)).role == UserRole.STUDENT


def test_duplicate_student_no(service):
    make_user(service)
    expect(AuthErrorCode.STUDENT_NO_TAKEN, service.create_user(student_no=" 20231234 ", name="x", role=UserRole.STUDENT, password="12345678"))


# ---------------------------------------------------------------- 지갑


def test_student_wallet_is_derived_and_unique(service):
    first = make_user(service, "20230001")
    second = make_user(service, "20230002")
    assert service.wallet_address(first) == "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    assert service.wallet_address(second) == "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

    unconfigured = AuthService(InMemoryUserStore(), AuthSettings(secret=SECRET))
    expect(AuthErrorCode.WALLET_NOT_CONFIGURED, _async(lambda: unconfigured.wallet_address(first)))


def _async(fn):
    async def call():
        return fn()

    return call()


def test_officer_registers_wallet_by_signature(service, clock):
    officer = make_user(service, role=UserRole.AUDITOR)
    account = Account.create()
    challenge = run(service.wallet_challenge(officer))

    updated = run(service.register_wallet(officer, challenge.nonce, account.address.lower(), sign(account, challenge.message)))
    assert updated.wallet_address == account.address
    owner = run(service.owner_of(account.address.lower()))
    assert (owner.user_id, owner.role, owner.current) == (officer.id, UserRole.AUDITOR, True)

    expect(AuthErrorCode.CHALLENGE_INVALID, service.register_wallet(updated, challenge.nonce, account.address, sign(account, challenge.message)))


def test_wallet_registration_rejects_bad_proofs(service, clock):
    officer = make_user(service, role=UserRole.TREASURER)
    student = make_user(service, "20230002")
    expect(AuthErrorCode.FORBIDDEN, service.wallet_challenge(student))

    other = Account.create()
    challenge = run(service.wallet_challenge(officer))  # 다른 문장에 서명하면 다른 주소가 복구된다 — 엉뚱한 주소가 등록되면 안 된다
    expect(AuthErrorCode.SIGNATURE_INVALID, service.register_wallet(officer, challenge.nonce, other.address, sign(other, challenge.message + " ")))
    challenge = run(service.wallet_challenge(officer))  # 남의 서명으로 내 주소라고 우길 수 없다
    expect(AuthErrorCode.SIGNATURE_INVALID, service.register_wallet(officer, challenge.nonce, Account.create().address, sign(other, challenge.message)))
    challenge = run(service.wallet_challenge(officer))
    expect(AuthErrorCode.SIGNATURE_INVALID, service.register_wallet(officer, challenge.nonce, other.address, "0x1234"))
    assert run(service.owner_of(other.address)) is None

    challenge = run(service.wallet_challenge(officer))
    clock.now = NOW + 301
    expect(AuthErrorCode.CHALLENGE_INVALID, service.register_wallet(officer, challenge.nonce, other.address, sign(other, challenge.message)))


def test_key_rotation_keeps_history_and_addresses_stay_unique(service):
    auditor = make_user(service, "20230001", role=UserRole.AUDITOR)
    president = make_user(service, "20230002", role=UserRole.PRESIDENT)
    old_key, new_key = Account.create(), Account.create()

    def register(user, account):
        challenge = run(service.wallet_challenge(user))
        return run(service.register_wallet(user, challenge.nonce, account.address, sign(account, challenge.message)))

    auditor = register(auditor, old_key)
    auditor = register(auditor, new_key)
    old_owner = run(service.owner_of(old_key.address))
    assert (old_owner.user_id, old_owner.current, old_owner.retired_at is not None) == (auditor.id, False, True)
    assert run(service.owner_of(new_key.address)).current

    challenge = run(service.wallet_challenge(president))  # 다른 임원이 지금 쓰는 주소 (기기 키를 같이 쓰는 경우)
    expect(AuthErrorCode.WALLET_TAKEN, service.register_wallet(president, challenge.nonce, new_key.address, sign(new_key, challenge.message)))
    assert run(service.owner_of(new_key.address)).user_id == auditor.id
    challenge = run(service.wallet_challenge(president))  # 다른 임원이 예전에 쓴 주소
    expect(AuthErrorCode.WALLET_TAKEN, service.register_wallet(president, challenge.nonce, old_key.address, sign(old_key, challenge.message)))
    challenge = run(service.wallet_challenge(auditor))
    expect(AuthErrorCode.WALLET_TAKEN, service.register_wallet(auditor, challenge.nonce, old_key.address, sign(old_key, challenge.message)))


def test_student_addresses_are_not_exposed_by_owner_lookup(service):
    student = make_user(service)
    assert run(service.owner_of(service.wallet_address(student))) is None


# ---------------------------------------------------------------- HTTP


@pytest.fixture
def client(service):
    app = FastAPI()
    app.include_router(router)

    @app.get("/treasurer-only")
    async def treasurer_only(user: User = Depends(require_roles(UserRole.TREASURER))):
        return {"id": user.id}

    app.dependency_overrides[get_auth_service] = lambda: service
    return TestClient(app)


def test_http_login_me_and_roles(client, service):
    make_user(service)
    response = client.post("/auth/login", json={"student_no": "20231234", "password": "changed-pass"})
    assert response.status_code == 200
    body = response.json()
    headers = {"Authorization": f"Bearer {body['access_token']}"}
    assert body["user"]["wallet_address"] == "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

    assert client.get("/auth/me", headers=headers).json()["role"] == "STUDENT"
    assert client.get("/treasurer-only", headers=headers).status_code == 403
    assert client.get("/auth/me").status_code == 401
    assert client.get("/auth/me", headers={"Authorization": "Bearer nope"}).status_code == 401

    wrong = client.post("/auth/login", json={"student_no": "20231234", "password": "nope-nope"})
    assert (wrong.status_code, wrong.json()["detail"]["code"]) == (401, "INVALID_CREDENTIALS")


def test_http_password_change_gate(client, service):
    make_user(service, role=UserRole.TREASURER, change=False)
    token = client.post("/auth/login", json={"student_no": "20231234", "password": "initial-pass"}).json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    assert client.get("/auth/me", headers=headers).json()["password_change_required"] is True
    blocked = client.get("/treasurer-only", headers=headers)
    assert (blocked.status_code, blocked.json()["detail"]["code"]) == (403, "PASSWORD_CHANGE_REQUIRED")

    changed = client.post("/auth/password", headers=headers, json={"old_password": "initial-pass", "new_password": "changed-pass"})
    new_headers = {"Authorization": f"Bearer {changed.json()['access_token']}"}
    assert client.get("/treasurer-only", headers=new_headers).status_code == 200
    assert client.get("/auth/me", headers=headers).status_code == 401  # 바꾸기 전 토큰은 무효


def test_http_wallet_registration_and_lookup(client, service):
    make_user(service, role=UserRole.AUDITOR)
    token = client.post("/auth/login", json={"student_no": "20231234", "password": "changed-pass"}).json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}
    account = Account.create()

    challenge = client.post("/auth/wallet/challenge", headers=headers).json()
    registered = client.post("/auth/wallet", headers=headers, json={"nonce": challenge["nonce"], "address": account.address, "signature": sign(account, challenge["message"])})
    assert registered.json()["wallet_address"] == account.address

    owner = client.get(f"/auth/addresses/{account.address}", headers=headers).json()
    assert (owner["role"], owner["current"]) == ("AUDITOR", True)
    assert client.get(f"/auth/addresses/{Account.create().address}", headers=headers).json() is None


# ---------------------------------------------------------------- 리뷰 반영


def test_deactivation_during_wallet_registration_is_not_undone(service):
    make_user(service, role=UserRole.AUDITOR)
    token, _ = login(service)
    snapshot = run(service.authenticate(token))  # 요청 처음에 읽은 사용자
    account = Account.create()
    challenge = run(service.wallet_challenge(snapshot))

    run(service.deactivate(snapshot.id))  # 그사이 관리자가 계정을 막는다
    expect(AuthErrorCode.INVALID_TOKEN, service.register_wallet(snapshot, challenge.nonce, account.address, sign(account, challenge.message)))

    stored = run(service._store.get(snapshot.id))
    assert (stored.active, stored.token_version, stored.wallet_address) == (False, snapshot.token_version + 1, None)
    assert run(service.owner_of(account.address)) is None
    expect(AuthErrorCode.INVALID_TOKEN, service.authenticate(token))  # 막을 때 무효로 만든 토큰이 되살아나지 않는다


def test_role_change_during_password_change_is_not_undone(service):
    make_user(service)
    token, _ = login(service)
    snapshot = run(service.authenticate(token))

    run(service.change_role(snapshot.id, UserRole.TREASURER))
    expect(AuthErrorCode.INVALID_TOKEN, service.change_password(snapshot, "changed-pass", "another-pass"))

    stored = run(service._store.get(snapshot.id))
    assert stored.role == UserRole.TREASURER
    assert login(service, password="changed-pass")[1].id == snapshot.id  # 비밀번호도 바뀌지 않았다


def test_demotion_retires_wallet_and_promotion_needs_new_registration(service):
    officer = make_user(service, role=UserRole.TREASURER)
    account = Account.create()
    challenge = run(service.wallet_challenge(officer))
    officer = run(service.register_wallet(officer, challenge.nonce, account.address, sign(account, challenge.message)))

    student = run(service.change_role(officer.id, UserRole.STUDENT))
    assert student.wallet_address is None
    assert student.wallet_index is not None  # 학생 파생 주소를 받는다
    owner = run(service.owner_of(account.address))
    assert (owner.current, owner.retired_at is not None) == (False, True)

    promoted = run(service.change_role(officer.id, UserRole.AUDITOR))
    assert service.wallet_address(promoted) is None  # 잃어버렸을 수 있는 옛 기기 키를 그대로 쓰지 않는다

    same_person = run(service.change_role(officer.id, UserRole.PRESIDENT))  # 임원끼리는 지갑을 그대로 둔다
    challenge = run(service.wallet_challenge(same_person))
    new_key = Account.create()
    same_person = run(service.register_wallet(same_person, challenge.nonce, new_key.address, sign(new_key, challenge.message)))
    run(service.change_role(officer.id, UserRole.AUDITOR))
    assert run(service._store.get(officer.id)).wallet_address == new_key.address


def test_bad_mnemonic_fails_at_startup():
    with pytest.raises(ValueError):
        StudentWallets("not a valid mnemonic")


def test_password_hashing_runs_off_the_event_loop(service, monkeypatch):
    """scrypt 를 이벤트 루프 스레드에서 돌리면 로그인이 몰릴 때 서버 전체가 멈춘다."""
    import threading

    import app.auth.service as auth_service

    threads = []
    real_hash, real_verify = auth_service.hash_password, auth_service.verify_password

    def hash_spy(*args):
        threads.append(threading.get_ident())
        return real_hash(*args)

    def verify_spy(*args):
        threads.append(threading.get_ident())
        return real_verify(*args)

    monkeypatch.setattr(auth_service, "hash_password", hash_spy)
    monkeypatch.setattr(auth_service, "verify_password", verify_spy)

    async def scenario():
        loop_thread = threading.get_ident()
        user = await service.create_user(student_no="20239999", name="x", role=UserRole.STUDENT, password="initial-pass")
        await service.login("20239999", "initial-pass")
        with pytest.raises(AuthError):
            await service.login("00000000", "whatever-pass")  # 없는 학번도 같은 계산을 스레드에서 한다
        await service.change_password(user, "initial-pass", "changed-pass")
        return loop_thread

    loop_thread = run(scenario())
    assert len(threads) == 5  # 가입 해시, 로그인 확인 2, 변경 확인·해시
    assert loop_thread not in threads


def test_http_student_login_without_mnemonic_is_mapped_not_500(clock):
    service = AuthService(InMemoryUserStore(), AuthSettings(secret=SECRET), clock=clock)
    make_user(service)
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[get_auth_service] = lambda: service
    client = TestClient(app, raise_server_exceptions=False)

    response = client.post("/auth/login", json={"student_no": "20231234", "password": "changed-pass"})
    assert (response.status_code, response.json()["detail"]["code"]) == (503, "WALLET_NOT_CONFIGURED")


@pytest.mark.parametrize("signature", ["0x" + "ff" * 64 + "1b", "0x" + "11" * 64 + "05", "0x" + "00" * 65])
def test_out_of_range_signature_is_signature_invalid(service, signature):
    officer = make_user(service, role=UserRole.AUDITOR)
    challenge = run(service.wallet_challenge(officer))
    expect(AuthErrorCode.SIGNATURE_INVALID, service.register_wallet(officer, challenge.nonce, Account.create().address, signature))
