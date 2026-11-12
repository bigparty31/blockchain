"""행사·입장 API 테스트 — PRD v0.16 §4.2 (QR 입장, 중복 차단, 판정 불가 구분), §10 (회원권 확인은 체인 기준 공용 함수)."""
import asyncio
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app import membership_check
from app.auth import users as seed
from app.chain import ChainSetupError, ChainUnavailable, FakeChainClient, get_chain_client
from app.database import get_db
from app.main import app
from app.membership_check import MembershipUnavailable, get_membership_checker
from app.models import Base, CheckIn, Event, Membership, Term, User
from app.routers.events import parse_qr
from app.schemas.auth import Role
from app.services import student_wallet
from app.services.student_wallet import MNEMONIC_ENV, student_address

client = TestClient(app)

TEST_MNEMONIC = "test test test test test test test test test test test junk"

STUDENT = 1          # 시드 학생 (회원권 있음)
NON_MEMBER = 10      # 회원권 없는 학생
BURNED = 11          # 환불로 회원권이 소각된 학생
TERM, OTHER_TERM = 1, 2
TERM_CODE, OTHER_TERM_CODE = 20262, 20271


def qr(user_id: int, term: str = "2026-2") -> str:
    return f"SCA:{term}:U{user_id:06d}"


@pytest.fixture
def chain(monkeypatch):
    """회원권의 기준인 체인. 학생 지갑 주소는 시험용 니모닉에서 파생한다 (test_memberships_api 와 같다)."""
    monkeypatch.setenv(MNEMONIC_ENV, TEST_MNEMONIC)
    student_wallet._derive.cache_clear()
    student_wallet._seed.cache_clear()
    fake = FakeChainClient()
    app.dependency_overrides[get_chain_client] = lambda: fake
    yield fake
    app.dependency_overrides.pop(get_chain_client, None)
    student_wallet._derive.cache_clear()
    student_wallet._seed.cache_clear()


def wallet(user_id: int) -> str:
    index = {STUDENT: 0, NON_MEMBER: 10, BURNED: 11}[user_id]
    return student_address(index)


@pytest.fixture
def db_session(tmp_path, chain):
    engine = create_engine(f"sqlite:///{tmp_path / 'events.db'}", connect_args={"check_same_thread": False})
    Session = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    Base.metadata.create_all(bind=engine)

    db = Session()
    for u in seed.SEED_USERS:
        db.add(User(
            id=u.id, student_no=u.student_no, name=u.name, role=u.role.value, password_hash=u.password_hash,
            wallet_index=u.wallet_index, wallet_address=u.wallet_address.lower() if u.wallet_address else None,
        ))
    db.add(User(id=NON_MEMBER, student_no="20240010", name="미납생", role="STUDENT", password_hash="x", wallet_index=10))
    db.add(User(id=BURNED, student_no="20240011", name="환불생", role="STUDENT", password_hash="x", wallet_index=11))
    db.add(Term(id=TERM, term_code=20262, name="2026-2학기",
                started_at=datetime(2026, 9, 1, tzinfo=timezone.utc), ended_at=datetime(2026, 12, 20, tzinfo=timezone.utc)))
    db.add(Term(id=OTHER_TERM, term_code=20271, name="2027-1학기",
                started_at=datetime(2027, 3, 1, tzinfo=timezone.utc), ended_at=datetime(2027, 6, 20, tzinfo=timezone.utc)))
    minted = datetime(2026, 9, 2, tzinfo=timezone.utc)
    db.add(Membership(user_id=STUDENT, term_id=TERM, token_id=1, minted_at=minted))
    db.add(Membership(user_id=BURNED, term_id=TERM, token_id=2, minted_at=minted,
                      burned_at=datetime(2026, 9, 10, tzinfo=timezone.utc), burn_reason="REFUND"))
    # 다른 학기 회원권만 있는 학생 — 이번 학기 행사엔 못 들어가야 한다
    db.add(Membership(user_id=NON_MEMBER, term_id=OTHER_TERM, token_id=3, minted_at=minted))
    db.add(Event(id=1, term_id=TERM, name="축제", held_at=datetime(2026, 10, 1, tzinfo=timezone.utc), created_by=2))
    db.commit()
    db.close()

    # 판정의 기준은 체인이다. DB 행(위)은 발급 정보 표시용이라 체인과 같게 맞춰 둔다
    chain.grant_membership(wallet(STUDENT), TERM_CODE)
    chain.grant_membership(wallet(BURNED), TERM_CODE)
    chain.burn_membership(wallet(BURNED), TERM_CODE)
    chain.grant_membership(wallet(NON_MEMBER), OTHER_TERM_CODE)

    def override():
        s = Session()
        try:
            yield s
        finally:
            s.close()

    app.dependency_overrides[get_db] = override
    yield Session
    app.dependency_overrides.pop(get_db, None)
    app.dependency_overrides.pop(get_membership_checker, None)
    engine.dispose()


def scan(auth_header, user_id=STUDENT, event_id=1, role=Role.TREASURER, payload=None):
    return client.post(
        f"/events/{event_id}/check-in",
        json={"qr_payload": payload if payload is not None else qr(user_id)},
        headers=auth_header(role),
    )


def count_check_ins(Session) -> int:
    s = Session()
    try:
        return s.query(CheckIn).count()
    finally:
        s.close()


# ---------------------------------------------------------------- QR 파서


@pytest.mark.parametrize("payload,expected", [
    ("SCA:2026-2:U000003", 3),
    ("  SCA:2026-2:U000003\n", 3),   # 스캐너가 붙이는 앞뒤 공백·개행
    ("SCA:2026-2:U123456789012", 123456789012),
    ("SCA:2026-2:3", None),          # U 없음
    ("SCA:2026-2:U", None),
    ("SCA:2026-2:U1234567890123", None),  # 13자리 — BIGINT 넘칠 수 있음
    ("SCA::U000003", None),          # 학기 비어 있음
    ("XYZ:2026-2:U000003", None),
    ("SCA:2026-2:U000003:paid", None),  # 자격 정보를 덧붙인 QR 은 받지 않는다
    ("https://example.com", None),
])
def test_parse_qr(payload, expected):
    assert parse_qr(payload) == expected


# ---------------------------------------------------------------- 입장 판정


def test_member_admitted_then_duplicate_blocked(db_session, auth_header):
    first = scan(auth_header)
    assert first.status_code == 200
    body = first.json()
    assert body["result"] == "ADMITTED"
    assert body["user_id"] == STUDENT
    assert body["student_no"] == "20240001"
    assert body["name"] == "김학생"
    assert body["checked_in_at"] is not None

    # 다른 임원이 다시 찍어도 막힌다. 처음 입장 시각을 돌려준다
    again = scan(auth_header, role=Role.AUDITOR)
    assert again.status_code == 200
    assert again.json()["result"] == "ALREADY_CHECKED_IN"
    assert again.json()["checked_in_at"] == body["checked_in_at"]
    assert count_check_ins(db_session) == 1


def test_check_in_records_scanner(db_session, auth_header):
    scan(auth_header, role=Role.PRESIDENT)
    s = db_session()
    row = s.query(CheckIn).one()
    assert (row.event_id, row.user_id, row.scanned_by) == (1, STUDENT, 4)
    s.close()


def test_same_student_can_enter_other_event(db_session, auth_header):
    s = db_session()
    s.add(Event(id=2, term_id=TERM, name="체육대회", held_at=datetime(2026, 10, 8, tzinfo=timezone.utc), created_by=2))
    s.commit()
    s.close()
    assert scan(auth_header, event_id=1).json()["result"] == "ADMITTED"
    assert scan(auth_header, event_id=2).json()["result"] == "ADMITTED"


def test_non_member_rejected(db_session, auth_header):
    # 다른 학기 회원권만 있으면 이번 학기 행사엔 회원이 아니다
    res = scan(auth_header, user_id=NON_MEMBER)
    assert res.json()["result"] == "NOT_MEMBER"
    assert res.json()["checked_in_at"] is None
    assert count_check_ins(db_session) == 0


def test_burned_membership_rejected(db_session, auth_header):
    assert scan(auth_header, user_id=BURNED).json()["result"] == "NOT_MEMBER"
    assert count_check_ins(db_session) == 0


def test_old_term_qr_judged_by_event_term(db_session, auth_header):
    # QR 의 학기 부분은 판정에 안 쓴다. 회원이면 학기 표기가 달라도 입장, 비회원이면 거부
    assert scan(auth_header, payload=qr(STUDENT, term="2026-1")).json()["result"] == "ADMITTED"
    assert scan(auth_header, payload=qr(NON_MEMBER, term="2027-1")).json()["result"] == "NOT_MEMBER"


@pytest.mark.parametrize("user_id", [999, 2])  # 없는 사용자, 임원(총무)
def test_unknown_or_non_student(db_session, auth_header, user_id):
    res = scan(auth_header, user_id=user_id)
    assert res.status_code == 200
    body = res.json()
    assert body["result"] == "UNKNOWN_STUDENT"
    assert body["student_no"] is None and body["name"] is None
    assert count_check_ins(db_session) == 0


def test_unverifiable_is_not_rejection(db_session, auth_header):
    async def broken(db, user_id, term_id):
        raise MembershipUnavailable("RPC 연결 실패")

    app.dependency_overrides[get_membership_checker] = lambda: broken
    res = scan(auth_header)
    assert res.status_code == 200
    assert res.json()["result"] == "UNVERIFIABLE"
    assert res.json()["student_no"] == "20240001"
    assert count_check_ins(db_session) == 0

    # 복구되면 같은 학생이 정상 입장한다 (판정 불가가 기록을 남기지 않았다)
    app.dependency_overrides.pop(get_membership_checker)
    assert scan(auth_header).json()["result"] == "ADMITTED"


def test_already_checked_in_skips_membership_check(db_session, auth_header):
    scan(auth_header)
    calls = []

    async def spy(db, user_id, term_id):
        calls.append(user_id)
        raise MembershipUnavailable()

    app.dependency_overrides[get_membership_checker] = lambda: spy
    assert scan(auth_header).json()["result"] == "ALREADY_CHECKED_IN"
    assert calls == []


def test_concurrent_scan_returns_already_checked_in(db_session, auth_header):
    # 회원권 확인과 기록 사이에 다른 스캐너가 먼저 기록한 상황을 재현한다
    async def racing(db, user_id, term_id):
        other = db_session()
        other.add(CheckIn(event_id=1, user_id=user_id, scanned_by=3))
        other.commit()
        other.close()
        return True

    app.dependency_overrides[get_membership_checker] = lambda: racing
    res = scan(auth_header)
    assert res.status_code == 200
    assert res.json()["result"] == "ALREADY_CHECKED_IN"
    assert count_check_ins(db_session) == 1


# ---------------------------------------------------------------- 판정의 기준은 체인 (PRD §10, §13)


def test_db_row_without_chain_membership_is_not_member(db_session, auth_header, chain):
    # DB 에 회원권 행이 있어도 체인에 없으면 회원이 아니다. DB 만 고쳐서 입장시킬 수 없다
    chain.burn_membership(wallet(STUDENT), TERM_CODE)
    assert scan(auth_header).json()["result"] == "NOT_MEMBER"
    assert count_check_ins(db_session) == 0


def test_chain_membership_without_db_row_is_admitted(db_session, auth_header, chain):
    # 체인에 회원권이 있으면 DB 행이 없어도 입장한다 (DB 행은 발급 정보 표시용)
    s = db_session()
    s.query(Membership).filter(Membership.user_id == NON_MEMBER).delete()
    s.commit()
    s.close()
    chain.grant_membership(wallet(NON_MEMBER), TERM_CODE)
    assert scan(auth_header, user_id=NON_MEMBER).json()["result"] == "ADMITTED"


@pytest.mark.parametrize("error", [ChainSetupError("CHAIN_RPC_URL 없음"), ChainUnavailable("노드 무응답")])
def test_chain_connection_failure_is_unverifiable(db_session, auth_header, error):
    # 체인에 붙지 못하면 503 이 아니라 200 + UNVERIFIABLE 이다. 스캐너가 '미납'으로 안내하지 않고 다시 찍게 한다
    def broken():
        raise error

    app.dependency_overrides[get_chain_client] = broken
    res = scan(auth_header)
    assert res.status_code == 200
    assert res.json()["result"] == "UNVERIFIABLE"
    assert count_check_ins(db_session) == 0


def test_chain_down_does_not_block_scans_that_need_no_membership(db_session, auth_header):
    # 중복 입장·없는 학생은 회원권을 볼 필요가 없다. 체인이 죽어도 그대로 판정한다
    scan(auth_header)

    def broken():
        raise ChainUnavailable("노드 무응답")

    app.dependency_overrides[get_chain_client] = broken
    assert scan(auth_header).json()["result"] == "ALREADY_CHECKED_IN"
    assert scan(auth_header, user_id=999).json()["result"] == "UNKNOWN_STUDENT"


def test_slow_chain_is_unverifiable(db_session, auth_header, chain, monkeypatch):
    # 노드가 느리면 RPC 기본 대기(10초)까지 스캐너가 멈추지 않고 제한 시간에 끊는다
    monkeypatch.setattr(membership_check, "MEMBERSHIP_TIMEOUT_SECONDS", 0.05)

    async def slow(account, term):
        await asyncio.sleep(1)
        return True

    monkeypatch.setattr(chain, "has_valid_membership", slow)
    res = scan(auth_header)
    assert res.json()["result"] == "UNVERIFIABLE"
    assert count_check_ins(db_session) == 0


def test_missing_wallet_mnemonic_is_unverifiable(db_session, auth_header, monkeypatch):
    # 학생 지갑을 파생할 설정이 없으면 회원권을 '모른다' — 미보유로 판정하지 않는다
    monkeypatch.delenv(MNEMONIC_ENV)
    student_wallet._derive.cache_clear()
    student_wallet._seed.cache_clear()
    assert scan(auth_header).json()["result"] == "UNVERIFIABLE"


# ---------------------------------------------------------------- 요청 오류·권한


@pytest.mark.parametrize("payload", ["SCA:2026-2:3", "", "납부함", "x" * 65])
def test_invalid_qr(db_session, auth_header, payload):
    res = scan(auth_header, payload=payload)
    assert res.status_code in (400, 422)
    assert count_check_ins(db_session) == 0


def test_unknown_event_404(db_session, auth_header):
    assert scan(auth_header, event_id=999).status_code == 404


@pytest.mark.parametrize("role", [Role.TREASURER, Role.AUDITOR, Role.PRESIDENT])
def test_council_can_scan(db_session, auth_header, role):
    assert scan(auth_header, role=role).status_code == 200


def test_student_cannot_use_event_api(db_session, auth_header):
    h = auth_header(Role.STUDENT)
    assert client.post("/events/1/check-in", json={"qr_payload": qr(STUDENT)}, headers=h).status_code == 403
    assert client.get("/events", headers=h).status_code == 403
    assert client.post("/events", json={"term_id": TERM, "name": "x", "held_at": "2026-10-01T10:00:00+09:00"},
                       headers=h).status_code == 403
    assert count_check_ins(db_session) == 0


def test_requires_login(db_session):
    assert client.post("/events/1/check-in", json={"qr_payload": qr(STUDENT)}).status_code == 401


# ---------------------------------------------------------------- 행사 등록·목록


def test_create_and_list_events(db_session, auth_header):
    h = auth_header(Role.AUDITOR)
    res = client.post("/events", json={"term_id": TERM, "name": "  해오름제 ", "held_at": "2026-11-20T18:00:00+09:00"},
                      headers=h)
    assert res.status_code == 201
    body = res.json()
    assert body["name"] == "해오름제"
    assert body["term_id"] == TERM
    assert body["created_by"] == 3

    s = db_session()
    s.add(Event(term_id=OTHER_TERM, name="다음 학기", held_at=datetime(2027, 3, 5, tzinfo=timezone.utc), created_by=2))
    s.commit()
    s.close()

    listed = client.get("/events", params={"term_id": TERM}, headers=h).json()
    assert [e["name"] for e in listed] == ["해오름제", "축제"]  # 최근 행사 먼저
    assert len(client.get("/events", headers=h).json()) == 3


def test_create_event_unknown_term(db_session, auth_header):
    res = client.post("/events", json={"term_id": 99, "name": "x", "held_at": "2026-10-01T10:00:00+09:00"},
                      headers=auth_header(Role.TREASURER))
    assert res.status_code == 404


@pytest.mark.parametrize("name", ["", "   ", "x" * 101])
def test_create_event_bad_name(db_session, auth_header, name):
    res = client.post("/events", json={"term_id": TERM, "name": name, "held_at": "2026-10-01T10:00:00+09:00"},
                      headers=auth_header(Role.TREASURER))
    assert res.status_code == 422


def test_shared_membership_exception_is_unverifiable(db_session, auth_header):
    # 공용 함수(app/services/membership.py)가 던지는 예외를 그대로 잡아야 한다 — 클래스가 다르면 500 이 된다
    from app.services import membership as shared

    async def chain_down(db, user_id, term_id):
        raise shared.MembershipUnavailable("노드 응답 없음")

    app.dependency_overrides[get_membership_checker] = lambda: chain_down
    assert scan(auth_header).json()["result"] == "UNVERIFIABLE"
