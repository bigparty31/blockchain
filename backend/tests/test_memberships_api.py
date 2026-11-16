"""회원권 확인(app/services/membership.py)과 GET /memberships/me."""
import asyncio
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import sessionmaker

from app.auth import users
from app.chain import ChainSetupError, ChainUnavailable, FakeChainClient, get_chain_client
from app.database import Base, get_db
from app.main import app
from app.models import Membership as DBMembership
from app.models import Term as DBTerm
from app.models import User as DBUser
from app.schemas.auth import Role
from app.routers import memberships as memberships_router
from app.services import student_wallet
from app.services.membership import MembershipUnavailable, check_membership, current_term, qr_payload
from app.services.student_wallet import MNEMONIC_ENV, student_address

client = TestClient(app)

TEST_MNEMONIC = "test test test test test test test test test test test junk"
NOW = datetime.now(timezone.utc)
CURRENT_CODE = 20262
PAST_CODE = 20261

_session = None
_chain: FakeChainClient = None


@pytest.fixture(autouse=True)
def setup(tmp_path, monkeypatch):
    global _session, _chain
    monkeypatch.setenv(MNEMONIC_ENV, TEST_MNEMONIC)
    student_wallet._derive.cache_clear()
    student_wallet._seed.cache_clear()
    _chain = FakeChainClient()
    engine = create_engine(f"sqlite:///{tmp_path / 'm.db'}", connect_args={"check_same_thread": False})
    Base.metadata.create_all(bind=engine)
    _session = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    with _session() as db:
        for u in users.SEED_USERS:
            db.add(
                DBUser(
                    id=u.id,
                    student_no=u.student_no,
                    password_hash=u.password_hash,
                    name=u.name,
                    role=u.role.value,
                    wallet_index=u.wallet_index,
                    wallet_address=u.wallet_address.lower() if u.wallet_address else None,
                )
            )
        # 지난 학기와 진행 중인 학기
        db.add(DBTerm(id=1, term_code=PAST_CODE, name="지난 학기", started_at=NOW - timedelta(days=300), ended_at=NOW - timedelta(days=150)))
        db.add(DBTerm(id=2, term_code=CURRENT_CODE, name="이번 학기", started_at=NOW - timedelta(days=30), ended_at=NOW + timedelta(days=90)))
        db.commit()

    def override_db():
        db = _session()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_db
    app.dependency_overrides[get_chain_client] = lambda: _chain
    yield
    app.dependency_overrides.pop(get_db, None)
    app.dependency_overrides.pop(get_chain_client, None)
    engine.dispose()
    student_wallet._derive.cache_clear()
    student_wallet._seed.cache_clear()


def _student():
    return next(u for u in users.SEED_USERS if u.role == Role.STUDENT)


def _grant(code=CURRENT_CODE):
    return _chain.grant_membership(student_address(_student().wallet_index), code)


def _db_membership(token_id, term_id=2, burned=False):
    with _session() as db:
        row = DBMembership(
            user_id=_student().id,
            term_id=term_id,
            token_id=token_id,
            minted_at=NOW - timedelta(days=10),
            burned_at=NOW - timedelta(days=1) if burned else None,
            burn_reason="REFUND" if burned else None,
        )
        db.add(row)
        db.commit()
        return row.id


def _check(user_id, term_id):
    with _session() as db:
        return asyncio.run(check_membership(db, _chain, user_id, term_id))


# ---------------------------------------------------------------- 확인 함수 (입장 판정과 공용)


def test_check_follows_chain():
    assert _check(_student().id, 2) is False
    _grant()
    assert _check(_student().id, 2) is True
    assert _check(_student().id, 1) is False  # 다른 학기


def test_check_trusts_chain_over_db():
    # DB 행만 있고 체인에 없으면 미보유다 (서버 기록만으로 자격을 주지 않는다)
    _db_membership(token_id=77)
    assert _check(_student().id, 2) is False


def test_check_after_burn():
    _grant()
    _chain.burn_membership(student_address(_student().wallet_index), CURRENT_CODE)
    assert _check(_student().id, 2) is False


@pytest.mark.parametrize("role", [Role.TREASURER, Role.AUDITOR, Role.PRESIDENT])
def test_check_officer_is_never_member(role):
    officer = next(u for u in users.SEED_USERS if u.role == role)
    assert _check(officer.id, 2) is False


def test_check_unknown_user_or_term():
    assert _check(99999, 2) is False
    assert _check(_student().id, 99999) is False


@pytest.mark.parametrize("error", [ChainUnavailable("down"), ChainSetupError("MembershipSBT 없음")])
def test_check_chain_failure_is_unknown(monkeypatch, error):
    async def fail(account, term):
        raise error

    monkeypatch.setattr(_chain, "has_valid_membership", fail)
    with pytest.raises(MembershipUnavailable):
        _check(_student().id, 2)


def test_check_without_mnemonic_is_unknown(monkeypatch):
    monkeypatch.delenv(MNEMONIC_ENV)
    with pytest.raises(MembershipUnavailable):
        _check(_student().id, 2)


def test_qr_payload_format():
    assert qr_payload(1, 20262) == "SCA:2026-2:U000001"
    assert qr_payload(123456789, 20271) == "SCA:2027-1:U123456789"


def test_current_term_prefers_ongoing_then_latest_started():
    with _session() as db:
        assert current_term(db).id == 2
        assert current_term(db, NOW + timedelta(days=200)).id == 2  # 끝났지만 가장 최근에 시작한 학기
        assert current_term(db, NOW - timedelta(days=400)) is None  # 아직 시작한 학기가 없다


# ---------------------------------------------------------------- GET /memberships/me


def test_me_requires_login():
    assert client.get("/memberships/me").status_code == 401


def test_me_not_member_is_200_null(auth_header):
    res = client.get("/memberships/me", headers=auth_header(Role.STUDENT))
    assert res.status_code == 200
    assert res.json() is None


def test_me_member_with_db_record(auth_header):
    token = _grant()
    row_id = _db_membership(token_id=token)
    res = client.get("/memberships/me", headers=auth_header(Role.STUDENT))
    assert res.status_code == 200
    body = res.json()
    assert body == {
        "id": row_id,
        "user_id": _student().id,
        "term_id": 2,
        "token_id": token,
        "minted_at": int((NOW - timedelta(days=10)).timestamp()),
        "burned_at": None,
        "qr_payload": f"SCA:2026-2:U{_student().id:06d}",
    }
    assert "commit_hash" not in body


def test_me_member_on_chain_without_db_record(auth_header):
    token = _grant()
    body = client.get("/memberships/me", headers=auth_header(Role.STUDENT)).json()
    assert body["id"] is None and body["minted_at"] is None
    assert body["token_id"] == token


def test_me_db_record_with_different_token_is_not_used(auth_header):
    token = _grant()
    _db_membership(token_id=token + 100)
    body = client.get("/memberships/me", headers=auth_header(Role.STUDENT)).json()
    assert body["token_id"] == token
    assert body["id"] is None


def test_me_db_only_is_null(auth_header):
    _db_membership(token_id=5)
    assert client.get("/memberships/me", headers=auth_header(Role.STUDENT)).json() is None


def test_me_term_query(auth_header):
    _grant(PAST_CODE)
    headers = auth_header(Role.STUDENT)
    assert client.get("/memberships/me", headers=headers).json() is None  # 기본은 진행 중인 학기
    body = client.get("/memberships/me", params={"term_id": 1}, headers=headers).json()
    assert body["term_id"] == 1 and body["qr_payload"].startswith("SCA:2026-1:")
    assert client.get("/memberships/me", params={"term_id": 999}, headers=headers).status_code == 404


def test_me_no_current_term_is_null(auth_header):
    with _session() as db:
        db.query(DBTerm).delete()
        db.commit()
    res = client.get("/memberships/me", headers=auth_header(Role.STUDENT))
    assert res.status_code == 200 and res.json() is None


@pytest.mark.parametrize("role", [Role.TREASURER, Role.AUDITOR, Role.PRESIDENT])
def test_me_officer_is_null(auth_header, role):
    res = client.get("/memberships/me", headers=auth_header(role))
    assert res.status_code == 200 and res.json() is None


@pytest.mark.parametrize("error", [ChainUnavailable("down"), ChainSetupError("MembershipSBT 없음")])
def test_me_chain_failure_is_503_not_null(auth_header, monkeypatch, error):
    async def fail(account, term):
        raise error

    monkeypatch.setattr(_chain, "has_valid_membership", fail)
    res = client.get("/memberships/me", headers=auth_header(Role.STUDENT))
    assert res.status_code == 503


def test_me_token_read_failure_is_503(auth_header, monkeypatch):
    _grant()

    async def fail(account, term):
        raise ChainUnavailable("down")

    monkeypatch.setattr(_chain, "membership_token_of", fail)
    assert client.get("/memberships/me", headers=auth_header(Role.STUDENT)).status_code == 503


def test_me_burned_between_reads_is_null(auth_header, monkeypatch):
    # hasValidMembership 뒤 tokenOf 전에 소각되면 tokenOf 가 0 이다. 0 을 회원권으로 보이지 않는다
    _grant()

    async def burned(account, term):
        return 0

    monkeypatch.setattr(_chain, "membership_token_of", burned)
    res = client.get("/memberships/me", headers=auth_header(Role.STUDENT))
    assert res.status_code == 200 and res.json() is None


def test_me_without_mnemonic_is_503(auth_header, monkeypatch):
    monkeypatch.delenv(MNEMONIC_ENV)
    assert client.get("/memberships/me", headers=auth_header(Role.STUDENT)).status_code == 503


def test_me_db_error_is_503(auth_header, monkeypatch):
    def broken(*args, **kwargs):
        raise OperationalError("SELECT", {}, Exception("db down"))

    monkeypatch.setattr(memberships_router, "current_term", broken)
    assert client.get("/memberships/me", headers=auth_header(Role.STUDENT)).status_code == 503


# ---------------------------------------------------------------- FakeChainClient 회원권


def test_fake_membership_grant_is_idempotent_and_burn_clears_token():
    fake = FakeChainClient()
    address = "0x" + "ab" * 20
    first = fake.grant_membership(address, CURRENT_CODE)
    assert fake.grant_membership(address.upper().replace("0X", "0x"), CURRENT_CODE) == first
    assert asyncio.run(fake.membership_token_of(address, CURRENT_CODE)) == first
    fake.burn_membership(address, CURRENT_CODE)
    assert asyncio.run(fake.has_valid_membership(address, CURRENT_CODE)) is False
    assert asyncio.run(fake.membership_token_of(address, CURRENT_CODE)) == 0
    assert fake.grant_membership(address, CURRENT_CODE) != first  # 소각 뒤 재발행은 새 tokenId
