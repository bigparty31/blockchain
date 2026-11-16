"""회원권 일괄 발행 API (app/routers/membership_mint.py, docs/API.md 「회원권 2」). 가짜 체인으로 끝까지 본다."""
import asyncio
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
import sqlite3
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.auth import users
from app.auth.security import create_access_token
from app.chain import ChainUnavailable, FakeChainClient, fake_signature, get_chain_client
from app.chain.models import MembershipRevertReason
from app.database import Base, get_db
from app.main import app
from app.models import Membership, MembershipMintBatch, Term, User
from app.schemas.auth import Role
from app.services import membership_mint, student_wallet
from app.services.student_wallet import MNEMONIC_ENV, student_address

client = TestClient(app)

TEST_MNEMONIC = "test test test test test test test test test test test junk"
NOW = datetime.now(timezone.utc)
TERM_ID, TERM_CODE = 2, 20262
FUTURE = int((NOW + timedelta(hours=1)).timestamp())
# 시드 학생(20240001, index 0) 외에 이 시험에서 더하는 학생
EXTRA = [(101, "20250101", "이학생", 1), (102, "20250102", "박학생", 2), (103, "20250103", "최학생", 3)]

_session = None
_chain: FakeChainClient = None


@pytest.fixture(autouse=True)
def setup(tmp_path, monkeypatch):
    global _session, _chain
    monkeypatch.setenv(MNEMONIC_ENV, TEST_MNEMONIC)
    student_wallet._derive.cache_clear()
    student_wallet._seed.cache_clear()
    _chain = FakeChainClient()
    engine = create_engine(f"sqlite:///{tmp_path / 'mint.db'}", connect_args={"check_same_thread": False})
    Base.metadata.create_all(bind=engine)
    _session = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    with _session() as db:
        for u in users.SEED_USERS:
            db.add(
                User(
                    id=u.id,
                    student_no=u.student_no,
                    password_hash=u.password_hash,
                    name=u.name,
                    role=u.role.value,
                    wallet_index=u.wallet_index,
                    wallet_address=u.wallet_address.lower() if u.wallet_address else None,
                )
            )
        for user_id, student_no, name, index in EXTRA:
            db.add(User(id=user_id, student_no=student_no, password_hash="x", name=name, role="STUDENT", wallet_index=index))
        db.add(Term(id=1, term_code=20261, name="지난 학기", started_at=NOW - timedelta(days=300), ended_at=NOW - timedelta(days=150)))
        db.add(Term(id=TERM_ID, term_code=TERM_CODE, name="이번 학기", started_at=NOW - timedelta(days=30), ended_at=NOW + timedelta(days=90)))
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


def seed(role: Role) -> users.User:
    return next(u for u in users.SEED_USERS if u.role == role)


def header(role: Role = Role.PRESIDENT, user_id: int = None) -> dict:
    return {"Authorization": f"Bearer {create_access_token(user_id or seed(role).id)}"}


def address_of(index: int) -> str:
    return student_address(index)


def prepare(student_nos, role=Role.PRESIDENT, term_id=TERM_ID, user_id=None):
    return client.post("/memberships/mint-batches", json={"term_id": term_id, "student_nos": student_nos}, headers=header(role, user_id))


def submit(batch_id, signer=None, deadline=FUTURE, role=Role.PRESIDENT, user_id=None):
    signer = signer or seed(role).wallet_address
    body = {"deadline": deadline, "signature": fake_signature(signer)}
    return client.post(f"/memberships/mint-batches/{batch_id}/submit", json=body, headers=header(role, user_id))


def get(batch_id, role=Role.PRESIDENT):
    return client.get(f"/memberships/mint-batches/{batch_id}", headers=header(role))


def memberships() -> list:
    with _session() as db:
        return [(m.user_id, m.term_id, m.token_id) for m in db.query(Membership).order_by(Membership.id)]


# ---------------------------------------------------------------- 준비


def test_prepare_returns_what_to_sign_and_why_others_are_left_out():
    _chain.grant_membership(address_of(2), TERM_CODE)  # 박학생은 이미 보유
    with _session() as db:  # 최학생은 DB 에만 유효한 기록이 있다
        db.add(Membership(user_id=103, term_id=TERM_ID, token_id=500, minted_at=NOW))
        db.commit()
    res = prepare([" 20250101 ", "20240001", "20250101", "20250102", "20250103", "20249999", "20240004"])
    assert res.status_code == 201, res.text
    body = res.json()
    assert body["status"] == "PREPARED" and body["term_code"] == TERM_CODE and body["nonce"] == 0
    assert body["signer_address"] == seed(Role.PRESIDENT).wallet_address
    assert body["recipients"] == [address_of(1), address_of(0)]  # 명단 순서 그대로
    assert [(t["student_no"], t["status"], t["token_id"]) for t in body["targets"]] == [
        ("20250101", "PENDING", None),
        ("20240001", "PENDING", None),
    ]
    assert [(x["student_no"], x["status"]) for x in body["excluded"]] == [  # 명단 순서대로
        ("20250101", "DUPLICATE"),
        ("20250102", "ALREADY_MEMBER"),
        ("20250103", "DB_MISMATCH"),
        ("20249999", "NOT_FOUND"),
        ("20240004", "NOT_STUDENT"),
    ]


def test_prepare_with_nobody_to_mint_is_400_and_saves_nothing():
    _chain.grant_membership(address_of(1), TERM_CODE)
    res = prepare(["20250101", "20249999"])
    assert res.status_code == 400
    assert [x["status"] for x in res.json()["detail"]["excluded"]] == ["ALREADY_MEMBER", "NOT_FOUND"]
    with _session() as db:
        assert db.query(MembershipMintBatch).count() == 0


def test_prepare_reads_the_signers_current_nonce():
    signer = seed(Role.PRESIDENT).wallet_address
    _chain._sbt_nonces[signer.lower()] = 7
    assert prepare(["20250101"]).json()["nonce"] == 7


@pytest.mark.parametrize("role", [Role.STUDENT, Role.TREASURER])
def test_only_president_and_auditor(role):
    assert prepare(["20250101"], role=role).status_code == 403
    assert prepare(["20250101"], role=Role.AUDITOR).status_code == 201


def test_prepare_input_checks():
    assert prepare([]).status_code == 422
    assert prepare([f"2025{i:04d}" for i in range(101)]).status_code == 422
    assert prepare(["20250101"], term_id=999).status_code == 404
    assert prepare(["20250101"], term_id=1).status_code == 201  # 끝난 학기도 준비할 수 있다


def test_prepare_when_chain_or_wallet_setup_fails_is_503(monkeypatch):
    async def down(account, term):
        raise ChainUnavailable("down")

    monkeypatch.setattr(_chain, "has_valid_membership", down)
    assert prepare(["20250101"]).status_code == 503
    monkeypatch.setattr(_chain, "has_valid_membership", FakeChainClient.has_valid_membership.__get__(_chain))
    monkeypatch.delenv(MNEMONIC_ENV)
    student_wallet._derive.cache_clear()
    assert prepare(["20250101"]).status_code == 503
    with _session() as db:
        assert db.query(MembershipMintBatch).count() == 0


# ---------------------------------------------------------------- 제출


def test_submit_mints_records_and_shows_up_in_my_membership():
    batch = prepare(["20250101", "20240001"]).json()
    res = submit(batch["id"])
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["status"] == "MINTED" and body["tx_hash"] and body["deadline"] == FUTURE
    assert [(t["status"], t["token_id"]) for t in body["targets"]] == [("MINTED", 1), ("MINTED", 2)]
    assert all(t["membership_id"] for t in body["targets"])
    assert memberships() == [(101, TERM_ID, 1), (1, TERM_ID, 2)]
    assert asyncio.run(_chain.membership_nonce(seed(Role.PRESIDENT).wallet_address)) == 1
    # 학생 화면: 체인 보유 + DB 기록 id (앱 MembershipModel.isValid 는 id > 0 을 요구한다)
    me = client.get("/memberships/me", headers=header(Role.STUDENT)).json()
    assert me["token_id"] == 2 and me["id"] == body["targets"][1]["membership_id"]
    # 다시 제출하면 409
    assert submit(batch["id"]).status_code == 409
    assert get(batch["id"]).json()["status"] == "MINTED"


def test_holder_minted_between_prepare_and_submit_is_skipped_and_recorded():
    batch = prepare(["20250101", "20250102"]).json()
    token = _chain.grant_membership(address_of(2), TERM_CODE)  # 다른 경로로 먼저 발행됨 (DB 기록 없음)
    body = submit(batch["id"]).json()
    assert [(t["student_no"], t["status"], t["token_id"]) for t in body["targets"]] == [
        ("20250101", "MINTED", token + 1),
        ("20250102", "SKIPPED", token),
    ]
    assert (102, TERM_ID, token) in memberships()  # 건너뛴 학생도 기록이 없으면 만든다


def test_record_conflict_fails_only_that_student():
    # 체인만 재배포한 환경: 체인이 줄 tokenId 1 이 DB 의 다른 기록에 이미 있다
    with _session() as db:
        db.add(Membership(user_id=103, term_id=1, token_id=1, minted_at=NOW))
        db.commit()
    batch = prepare(["20250101", "20250102"]).json()
    body = submit(batch["id"]).json()
    assert body["status"] == "MINTED"
    assert [(t["token_id"], t["membership_id"] is None) for t in body["targets"]] == [(1, True), (2, False)]
    assert memberships() == [(103, 1, 1), (102, TERM_ID, 2)]


def test_signature_from_another_wallet_is_400_and_nothing_is_sent():
    batch = prepare(["20250101"]).json()
    res = submit(batch["id"], signer=seed(Role.AUDITOR).wallet_address)
    assert res.status_code == 400
    assert get(batch["id"]).json()["status"] == "PREPARED"
    assert not asyncio.run(_chain.has_valid_membership(address_of(1), TERM_CODE))


def test_only_the_preparer_can_submit():
    batch = prepare(["20250101"], role=Role.AUDITOR).json()
    other_auditor = next(u for u in users.SEED_USERS if u.role == Role.AUDITOR and u.id != seed(Role.AUDITOR).id)
    res = submit(batch["id"], signer=other_auditor.wallet_address, role=Role.AUDITOR, user_id=other_auditor.id)
    assert res.status_code == 403
    assert submit(batch["id"], role=Role.PRESIDENT).status_code == 403
    assert submit(batch["id"], role=Role.AUDITOR).status_code == 200


def test_nonce_moved_since_prepare_is_409_not_sent():
    first = prepare(["20250101"]).json()
    second = prepare(["20250102"]).json()  # 같은 nonce 0 으로 준비됨
    assert submit(first["id"]).json()["status"] == "MINTED"
    res = submit(second["id"])
    assert res.status_code == 409
    assert get(second["id"]).json()["status"] == "PREPARED"


def test_expired_signature_is_rejected_then_resubmitted_with_a_new_deadline():
    batch = prepare(["20250101"]).json()
    rejected = submit(batch["id"], deadline=1).json()
    assert (rejected["status"], rejected["reason"]) == ("REJECTED", "SignatureExpired")
    assert submit(batch["id"]).json()["status"] == "MINTED"


def test_chain_refusal_is_reported_with_its_reason():
    batch = prepare(["20250101"]).json()
    _chain.fail_next("mint_memberships", MembershipRevertReason.NOT_APPROVER)
    body = submit(batch["id"]).json()
    assert (body["status"], body["reason"]) == ("REJECTED", "NotApprover")
    assert [t["status"] for t in body["targets"]] == ["PENDING"]


def test_lost_response_is_not_resent_and_is_resolved_by_hash():
    batch = prepare(["20250101"]).json()
    _chain.unavailable_next("mint_memberships", landed=True)
    body = submit(batch["id"]).json()
    assert body["status"] == "NO_RESPONSE" and body["tx_hash"]
    assert submit(batch["id"]).status_code == 409  # 같은 서명을 다시 보내지 않는다
    resolved = get(batch["id"]).json()
    assert resolved["status"] == "MINTED" and resolved["tx_hash"] == body["tx_hash"]
    assert resolved["targets"][0]["membership_id"] is not None
    assert get(batch["id"]).json()["status"] == "MINTED"  # 두 번 반영하지 않는다
    assert len(memberships()) == 1


def test_lost_transaction_that_never_landed_stays_unknown():
    batch = prepare(["20250101"]).json()
    _chain.unavailable_next("mint_memberships", landed=False)
    assert submit(batch["id"]).json()["status"] == "NO_RESPONSE"
    assert get(batch["id"]).json()["status"] == "NO_RESPONSE"  # 모르는 것을 실패로 단정하지 않는다


def test_reprepare_after_lost_response_fills_the_missing_record():
    # 결과를 모른 채(NO_RESPONSE) 끝난 발행을 조회 없이 다시 준비하면 그 학생은 ALREADY_MEMBER 로 빠진다.
    # 그때 DB 기록이 없으면 채워야 /memberships/me 의 id 가 생긴다 (앱 MembershipModel.isValid 는 id > 0)
    first = prepare(["20240001"]).json()
    _chain.unavailable_next("mint_memberships", landed=True)
    assert submit(first["id"]).json()["status"] == "NO_RESPONSE"
    res = prepare(["20240001"])
    assert res.status_code == 400
    assert [x["status"] for x in res.json()["detail"]["excluded"]] == ["ALREADY_MEMBER"]
    token = asyncio.run(_chain.membership_token_of(address_of(0), TERM_CODE))
    assert memberships() == [(1, TERM_ID, token)]
    me = client.get("/memberships/me", headers=header(Role.STUDENT)).json()
    assert me["id"] is not None and me["token_id"] == token
    # 나중에 조회로 앞선 발행을 반영해도 같은 기록을 잇는다 (새 기록·충돌 없음)
    resolved = get(first["id"]).json()
    assert resolved["status"] == "MINTED" and resolved["targets"][0]["membership_id"] == me["id"]
    assert len(memberships()) == 1


def test_member_without_record_is_filled_even_when_others_are_minted():
    token = _chain.grant_membership(address_of(1), TERM_CODE)
    assert prepare(["20250101", "20250102"]).status_code == 201
    assert memberships() == [(101, TERM_ID, token)]


def test_token_read_failure_leaves_no_record_and_prepare_goes_on(monkeypatch):
    _chain.grant_membership(address_of(1), TERM_CODE)

    async def down(account, term):
        raise ChainUnavailable("down")

    monkeypatch.setattr(_chain, "membership_token_of", down)
    assert prepare(["20250101"]).status_code == 400
    assert prepare(["20250101", "20250102"]).status_code == 201
    assert memberships() == []


def test_backfill_conflict_skips_only_that_student():
    a = _chain.grant_membership(address_of(1), TERM_CODE)
    b = _chain.grant_membership(address_of(2), TERM_CODE)
    with _session() as db:  # 체인만 재배포한 환경: 101 의 tokenId 가 DB 의 다른 기록에 이미 있다
        db.add(Membership(user_id=103, term_id=1, token_id=a, minted_at=NOW))
        db.commit()
    assert prepare(["20250101", "20250102"]).status_code == 400
    assert memberships() == [(103, 1, a), (102, TERM_ID, b)]


def test_failure_before_sending_is_503_and_can_be_retried():
    batch = prepare(["20250101"]).json()
    _chain.unavailable_next("mint_memberships", sent=False)
    assert submit(batch["id"]).status_code == 503
    assert get(batch["id"]).json()["status"] == "PREPARED"
    assert submit(batch["id"]).json()["status"] == "MINTED"


def test_two_submits_race_for_the_claim():
    batch = prepare(["20250101"]).json()

    async def both():
        with _session() as db1, _session() as db2:
            president = seed(Role.PRESIDENT)
            return await asyncio.gather(
                membership_mint.submit(db1, _chain, president, batch["id"], FUTURE, fake_signature(president.wallet_address)),
                membership_mint.submit(db2, _chain, president, batch["id"], FUTURE, fake_signature(president.wallet_address)),
                return_exceptions=True,
            )

    results = asyncio.run(both())
    ok = [r for r in results if not isinstance(r, Exception)]
    failed = [r for r in results if isinstance(r, Exception)]
    assert len(ok) == 1 and ok[0].status == "MINTED"
    assert len(failed) == 1 and failed[0].code == 409
    assert asyncio.run(_chain.membership_nonce(seed(Role.PRESIDENT).wallet_address)) == 1


def test_unknown_batch_is_404():
    assert submit(999).status_code == 404
    assert get(999).status_code == 404


# ---------------------------------------------------------------- 마이그레이션


def test_migration_matches_the_rules(tmp_path):
    db_file = tmp_path / "migrated.db"
    config = Config(str(Path(__file__).parents[1] / "alembic.ini"))
    config.set_main_option("sqlalchemy.url", f"sqlite:///{db_file.as_posix()}")
    command.upgrade(config, "head")
    conn = sqlite3.connect(db_file)
    conn.execute("PRAGMA foreign_keys=OFF")
    insert = "INSERT INTO membership_mint_batches(term_id, requested_by, signer_address, nonce, status, signature, tx_hash, reason) VALUES (1, 4, '0x', 0, ?, ?, ?, ?)"
    conn.execute(insert, ("PREPARED", None, None, None))
    for bad in [("BOGUS", None, None, None), ("SUBMITTING", "0xsig", None, None), ("REJECTED", "0xsig", None, None), ("MINTED", None, "0xa", None)]:
        with pytest.raises(sqlite3.IntegrityError):
            conn.execute(insert, bad)
    conn.execute(insert, ("MINTED", "0xsig", "0xtx", None))
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(insert, ("NO_RESPONSE", "0xsig", "0xtx", None))  # 같은 tx hash
    target = "INSERT INTO membership_mint_targets(batch_id, position, user_id, address, status, token_id) VALUES (1, ?, ?, '0x', ?, ?)"
    conn.execute(target, (0, 1, "PENDING", None))
    conn.execute(target, (1, 2, "SKIPPED", None))  # 건너뛴 학생은 tokenId 를 읽지 못했을 수 있다
    for bad in [(0, 3, "PENDING", None), (2, 1, "PENDING", None), (3, 4, "MINTED", None), (100, 5, "PENDING", None)]:
        with pytest.raises(sqlite3.IntegrityError):
            conn.execute(target, bad)
    conn.close()
    command.downgrade(config, "-1")
    command.upgrade(config, "head")
