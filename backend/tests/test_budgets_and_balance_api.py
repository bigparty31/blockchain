import time
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import sessionmaker

from app.auth import users
from app.auth.security import create_access_token
from app.chain import (
    BudgetRevertReason,
    ChainBudget,
    ChainSetupError,
    ChainUnavailable,
    FakeChainClient,
    IssueRequest,
    fake_signature,
    get_chain_client,
)
from app.chain.eip712 import category_hash
from app.database import Base, get_db
from app.main import app
from app.models import (
    Budget as DBBudget,
    BudgetRevisionRequest as DBBudgetRevisionRequest,
    BudgetVersion as DBBudgetVersion,
    Entry as DBEntry,
    Term as DBTerm,
    User as DBUser,
)
from app.schemas.auth import Role
from scripts.seed import seed_database

client = TestClient(app)

TREASURER_WALLET = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
AUDITOR_WALLET = "0x90F79bf6EB2c4f870365E785982E1f101E93b906"
PRESIDENT_WALLET = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

_test_session_factory = None
_test_chain = FakeChainClient()


@pytest.fixture(autouse=True)
def setup_test_db(tmp_path):
    global _test_session_factory, _test_chain
    _test_chain = FakeChainClient()
    db_file = tmp_path / "test_budgets_balance.db"
    engine = create_engine(
        f"sqlite:///{db_file}",
        connect_args={"check_same_thread": False},
    )
    Base.metadata.create_all(bind=engine)
    TestingSession = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    _test_session_factory = TestingSession

    with TestingSession() as db:
        for u in users.SEED_USERS:
            db.add(
                DBUser(
                    id=u.id,
                    student_no=u.student_no,
                    password_hash=u.password_hash,
                    name=u.name,
                    role=u.role.value if hasattr(u.role, "value") else u.role,
                    wallet_index=u.wallet_index,
                    wallet_address=u.wallet_address.lower() if u.wallet_address else None,
                )
            )
        db.add(
            DBTerm(
                id=1,
                term_code=20262,
                name="2026-2학기",
                started_at=datetime(2026, 9, 1, tzinfo=timezone.utc),
                ended_at=datetime(2027, 2, 28, tzinfo=timezone.utc),
            )
        )
        db.add(
            DBTerm(
                id=2,
                term_code=20271,
                name="2027-1학기",
                started_at=datetime(2027, 3, 1, tzinfo=timezone.utc),
                ended_at=datetime(2027, 8, 31, tzinfo=timezone.utc),
            )
        )
        db.commit()

    def override_get_db():
        db = TestingSession()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_chain_client] = lambda: _test_chain
    yield
    app.dependency_overrides.pop(get_db, None)
    app.dependency_overrides.pop(get_chain_client, None)
    engine.dispose()


@pytest.fixture
def auth_header():
    def _make(role: Role):
        matched = next(u for u in users.SEED_USERS if u.role == role)
        token = create_access_token(matched.id)
        return {"Authorization": f"Bearer {token}"}

    return _make


def _draft_and_submit(auth_header, *, term_id=1, category="행사비", planned_amount=2_500_000, expires_at=None, deadline=None, signature=None):
    now = int(time.time())
    exp = expires_at if expires_at is not None else now + 86400
    dl = deadline if deadline is not None else now + 600
    sig = signature if signature is not None else fake_signature(PRESIDENT_WALLET)

    res_draft = client.post(
        "/budgets",
        json={
            "term_id": term_id,
            "category": category,
            "planned_amount": planned_amount,
            "expires_at": exp,
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert res_draft.status_code == 201
    budget_id = res_draft.json()["id"]

    res_submit = client.post(
        f"/budgets/{budget_id}/submit",
        json={
            "planned_amount": planned_amount,
            "expires_at": exp,
            "deadline": dl,
            "signature": sig,
        },
        headers=auth_header(Role.PRESIDENT),
    )
    return res_draft, res_submit


# ---------------------------------------------------------------- POST /budgets & POST /budgets/{id}/submit (A5)


def test_post_budgets_requires_president_role(auth_header):
    now = int(time.time())
    body = {
        "term_id": 1,
        "category": "행사비",
        "planned_amount": 2_500_000,
        "expires_at": now + 86400,
    }
    assert client.post("/budgets", json=body).status_code == 401
    for forbidden_role in (Role.STUDENT, Role.TREASURER, Role.AUDITOR):
        res = client.post("/budgets", json=body, headers=auth_header(forbidden_role))
        assert res.status_code == 403


@pytest.mark.parametrize(
    "bad_category",
    ["없는항목", " 행사비", "행사비 ", "행사비\u200b", "행사\n비"],
)
def test_post_budgets_rejects_unapproved_or_dirty_category(auth_header, bad_category):
    now = int(time.time())
    res = client.post(
        "/budgets",
        json={
            "term_id": 1,
            "category": bad_category,
            "planned_amount": 1_000_000,
            "expires_at": now + 86400,
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert res.status_code == 400


@pytest.mark.parametrize(
    "income_category",
    ["학생회비", "지원금", "후원금", "이자수입"],
)
def test_post_budgets_rejects_income_categories(auth_header, income_category):
    """수입(INCOME) 항목은 예산 편성·발행 대상이 아니므로 지출(EXPENSE) 8종 외에는 400으로 거부한다."""
    now = int(time.time())
    res = client.post(
        "/budgets",
        json={
            "term_id": 1,
            "category": income_category,
            "planned_amount": 1_000_000,
            "expires_at": now + 86400,
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert res.status_code == 400
    assert "지출(EXPENSE)" in res.json()["detail"]


def test_post_budgets_rejects_over_50_char_category(auth_header):
    now = int(time.time())
    res = client.post(
        "/budgets",
        json={
            "term_id": 1,
            "category": "가" * 51,
            "planned_amount": 1_000_000,
            "expires_at": now + 86400,
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert res.status_code == 422


def test_post_budgets_rejects_overflow_expires_at(auth_header):
    """expires_at에 UINT64_MAX 등 datetime 변환 범위를 넘는 값을 보내도 500 대신 422로 거부된다."""
    res = client.post(
        "/budgets",
        json={
            "term_id": 1,
            "category": "행사비",
            "planned_amount": 1_000_000,
            "expires_at": (1 << 64) - 1,
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert res.status_code == 422


def test_post_budgets_term_not_found_returns_404(auth_header):
    now = int(time.time())
    res = client.post(
        "/budgets",
        json={
            "term_id": 999,
            "category": "행사비",
            "planned_amount": 1_000_000,
            "expires_at": now + 86400,
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert res.status_code == 404


def test_post_budgets_two_step_draft_and_submit_success(auth_header):
    now = int(time.time())
    expires_at = now + 86400

    # 1단계: 서명 없이 ID 채번
    res_draft = client.post(
        "/budgets",
        json={
            "term_id": 1,
            "category": "사업비",
            "planned_amount": 1_500_000,
            "expires_at": expires_at,
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert res_draft.status_code == 201
    draft = res_draft.json()
    assert draft["status"] == "DRAFT"
    assert draft["id"] == 1
    assert draft["term_code"] == 20262
    assert draft["category_hash"] == category_hash("사업비")

    # 미발행 초안은 GET /budgets에 노출되지 않음
    assert client.get("/budgets").json() == []

    # 2단계: POST /budgets/{id}/submit 으로 서명 제출
    res_submit = client.post(
        f"/budgets/{draft['id']}/submit",
        json={
            "planned_amount": 1_500_000,
            "expires_at": expires_at,
            "deadline": now + 600,
            "signature": fake_signature(PRESIDENT_WALLET),
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert res_submit.status_code == 200
    issued = res_submit.json()
    assert issued["id"] == 1
    assert issued["term_id"] == 1
    assert issued["term_code"] == 20262
    assert issued["category"] == "사업비"
    assert issued["category_hash"] == category_hash("사업비")
    assert issued["planned_amount"] == 1_500_000
    assert issued["expires_at"] == expires_at
    assert issued["version"] == 1
    assert issued["status"] == "ISSUED"
    assert issued["issue_status"] == "issued"
    assert issued["tx_hash"] and issued["tx_hash"].startswith("0x")

    with _test_session_factory() as db:
        b = db.query(DBBudget).filter(DBBudget.id == 1).first()
        assert b is not None and b.tx_issue == issued["tx_hash"]
        v1 = db.query(DBBudgetVersion).filter(DBBudgetVersion.budget_id == 1, DBBudgetVersion.version == 1).first()
        assert v1 is not None
        assert v1.planned_amount == 1_500_000
        assert v1.tx_hash == issued["tx_hash"]
        assert v1.approved_by == 4

    # 발행 후 GET /budgets에 정상 노출
    listed = client.get("/budgets").json()
    assert len(listed) == 1
    assert listed[0]["id"] == draft["id"]
    assert listed[0]["category"] == "사업비"
    assert listed[0]["planned_amount"] == 1_500_000
    assert listed[0]["remaining_amount"] == 1_500_000
    assert listed[0]["execution_rate"] == 0.0


def test_submit_wrong_signer_or_malformed_signature_returns_400(auth_header):
    now = int(time.time())
    expires_at = now + 86400
    res_draft = client.post(
        "/budgets",
        json={
            "term_id": 1,
            "category": "운영비",
            "planned_amount": 1_000_000,
            "expires_at": expires_at,
        },
        headers=auth_header(Role.PRESIDENT),
    )
    budget_id = res_draft.json()["id"]

    # 1) 다른 지갑(감사) 서명 -> 400
    res_wrong = client.post(
        f"/budgets/{budget_id}/submit",
        json={
            "planned_amount": 1_000_000,
            "expires_at": expires_at,
            "deadline": now + 600,
            "signature": fake_signature(AUDITOR_WALLET),
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert res_wrong.status_code == 400
    assert "지갑 주소" in res_wrong.json()["detail"]

    # 2) 잘못된 서명 형식 -> 400
    res_bad_sig = client.post(
        f"/budgets/{budget_id}/submit",
        json={
            "planned_amount": 1_000_000,
            "expires_at": expires_at,
            "deadline": now + 600,
            "signature": "0x1234",
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert res_bad_sig.status_code == 400

    with _test_session_factory() as db:
        b = db.query(DBBudget).filter(DBBudget.id == budget_id).first()
        assert b.tx_issue is None
        assert db.query(DBBudgetVersion).count() == 0


def test_post_budgets_in_flight_preserves_stored_expires_at(auth_header):
    """처리 중인 건(tx_issue 존재)에 대해 POST /budgets를 다른 expires_at으로 재요청해도
    201 DRAFT로 응답하며 저장된 expires_at이 변경되지 않고 응답도 저장된 expires_at으로 나온다."""
    now = int(time.time())
    original_expires_at = now + 86400
    res_draft = client.post(
        "/budgets",
        json={
            "term_id": 1,
            "category": "홍보비",
            "planned_amount": 1_000_000,
            "expires_at": original_expires_at,
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert res_draft.status_code == 201
    budget_id = res_draft.json()["id"]

    # 임의로 tx_issue를 채워 '처리 중' 상태를 흉내냄
    with _test_session_factory() as db:
        row = db.query(DBBudget).filter(DBBudget.id == budget_id).first()
        row.tx_issue = "0x" + "a" * 64
        db.commit()

    # 다른 만료일로 POST /budgets 재요청
    new_expires_at = now + 999999
    res_retry = client.post(
        "/budgets",
        json={
            "term_id": 1,
            "category": "홍보비",
            "planned_amount": 1_000_000,
            "expires_at": new_expires_at,
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert res_retry.status_code == 201
    data = res_retry.json()
    assert data["status"] == "DRAFT"
    # 응답의 expires_at은 요청 값이 아니라 저장된 original_expires_at이어야 함
    assert data["expires_at"] == original_expires_at

    # DB에 저장된 값도 그대로 original_expires_at 유지
    with _test_session_factory() as db:
        row = db.query(DBBudget).filter(DBBudget.id == budget_id).first()
        dt = row.expires_at if row.expires_at.tzinfo is not None else row.expires_at.replace(tzinfo=timezone.utc)
        assert int(dt.timestamp()) == original_expires_at


def test_already_issued_preserves_existing_tx_and_chain_values(auth_header):
    now = int(time.time())
    expires_at = now + 86400
    _, res_first = _draft_and_submit(
        auth_header,
        category="행사비",
        planned_amount=2_000_000,
        expires_at=expires_at,
    )
    first = res_first.json()
    assert first["status"] == "ISSUED"
    first_tx = first["tx_hash"]

    # 다른 금액으로 submit 재시도해도 ALREADY_ISSUED 및 체인 existing 값(2,000,000)을 반환하고 tx_issue는 유지됨
    res_second = client.post(
        f"/budgets/{first['id']}/submit",
        json={
            "planned_amount": 9_999_999,
            "expires_at": expires_at,
            "deadline": now + 600,
            "signature": fake_signature(PRESIDENT_WALLET),
        },
        headers=auth_header(Role.PRESIDENT),
    )
    assert res_second.status_code == 200
    second = res_second.json()
    assert second["status"] == "ALREADY_ISSUED"
    assert second["issue_status"] == "alreadyIssued"
    assert second["planned_amount"] == 2_000_000
    assert second["tx_hash"] == first_tx


def test_already_issued_with_mismatched_chain_id_returns_409(auth_header):
    """온체인에 같은 학기·항목 예산이 DB와 다른 ID로 이미 발행된 경우 200 대신 409 Conflict로 거부한다."""
    now = int(time.time())
    expires_at = now + 86400

    # 체인에는 budget_id=99로 행사비가 먼저 발행되어 있음
    import asyncio

    asyncio.run(
        _test_chain.issue_budget(
            IssueRequest(
                budget_id=99,
                term=20262,
                category=category_hash("행사비"),
                amount=2_000_000,
                expires_at=expires_at,
                deadline=now + 600,
            ),
            fake_signature(PRESIDENT_WALLET),
        )
    )

    # DB에서는 id=1로 채번되어 제출 시도 -> ALREADY_ISSUED (existing.id=99 != 1) -> 409
    _, res_submit = _draft_and_submit(
        auth_header,
        category="행사비",
        planned_amount=2_000_000,
        expires_at=expires_at,
    )
    assert res_submit.status_code == 409
    assert "다른 ID" in res_submit.json()["detail"]


def test_chain_rejected_and_no_response_and_not_sent(auth_header):
    now = int(time.time())

    # 1) 마감 경과 예산 발행 시도 -> REJECTED (BudgetExpired)
    _, res_expired = _draft_and_submit(
        auth_header,
        category="홍보비",
        planned_amount=500_000,
        expires_at=1,
    )
    assert res_expired.status_code == 200
    assert res_expired.json()["status"] == "REJECTED"
    assert res_expired.json()["issue_status"] == "rejected"
    assert res_expired.json()["reason"] == BudgetRevertReason.BUDGET_EXPIRED.value

    # 2) NO_RESPONSE -> tx_issue 칸에 보낸 hash 유지, GET /budgets 에는 미노출
    _test_chain.unavailable_next("issue_budget", landed=False)
    _, res_no_resp = _draft_and_submit(
        auth_header,
        category="복지비",
        planned_amount=800_000,
        expires_at=now + 86400,
    )
    assert res_no_resp.status_code == 200
    no_resp_data = res_no_resp.json()
    assert no_resp_data["status"] == "NO_RESPONSE"
    assert no_resp_data["issue_status"] == "noResponse"
    assert no_resp_data["tx_hash"] is not None

    with _test_session_factory() as db:
        b_welfare = db.query(DBBudget).filter(DBBudget.category == "복지비").first()
        assert b_welfare.tx_issue == no_resp_data["tx_hash"]

    # 체인 미확정(NO_RESPONSE) 예산은 GET /budgets 에 포함되지 않아야 함
    assert client.get("/budgets").json() == []

    # 3) NOT_SENT (ChainSetupError) -> 단건 API는 503 반환 및 내부 상세 미노출
    async def raise_setup_error(*args, **kwargs):
        raise ChainSetupError("민감한 릴레이어 내부 설정 오류")

    _test_chain.issue_budget = raise_setup_error
    _, res_not_sent = _draft_and_submit(
        auth_header,
        category="회의비",
        planned_amount=300_000,
        expires_at=now + 86400,
    )
    assert res_not_sent.status_code == 503
    assert "민감한" not in res_not_sent.json()["detail"]


def test_seed_then_issue_event_budget_cleans_up_seed_v2_and_matches_chain(auth_header):
    """시드 실행 후 행사비(id=1)에 2,000,000원을 실제 발행하면 시드 더미 v2(2,500,000원)가 정리되어
    GET /budgets 에서 planned=2,000,000, remaining=2,000,000, execution_rate=0.0, version=1 이 반환된다."""
    with _test_session_factory() as db:
        seed_database(db)

    # 발행 전에는 온체인 예산이 없으므로 시드 더미 예산은 GET /budgets 에 노출되지 않음
    assert client.get("/budgets").json() == []

    now = int(time.time())
    expires_at = now + 86400
    _, res_submit = _draft_and_submit(
        auth_header,
        category="행사비",
        planned_amount=2_000_000,
        expires_at=expires_at,
    )
    assert res_submit.status_code == 200
    assert res_submit.json()["status"] == "ISSUED"
    assert res_submit.json()["version"] == 1

    budgets = client.get("/budgets").json()
    assert len(budgets) == 1
    b_event = budgets[0]
    assert b_event["id"] == 1
    assert b_event["category"] == "행사비"
    assert b_event["planned_amount"] == 2_000_000
    assert b_event["remaining_amount"] == 2_000_000
    assert b_event["execution_rate"] == 0.0
    assert b_event["version"] == 1
    assert b_event["revision_reason"] is None

    with _test_session_factory() as db:
        versions = db.query(DBBudgetVersion).filter(DBBudgetVersion.budget_id == 1).all()
        assert len(versions) == 1
        assert versions[0].version == 1
        assert db.query(DBBudgetRevisionRequest).filter(DBBudgetRevisionRequest.budget_id == 1).count() == 0


# ---------------------------------------------------------------- GET /budgets (A6)


def test_get_budgets_reflects_chain_remaining(auth_header):
    now = int(time.time())
    expires_at = now + 86400

    # 행사비(id=1, 2,500,000원), 사업비(id=2, 1,500,000원) 발행
    for cat, amt in (("행사비", 2_500_000), ("사업비", 1_500_000)):
        _, res = _draft_and_submit(
            auth_header,
            category=cat,
            planned_amount=amt,
            expires_at=expires_at,
        )
        assert res.json()["status"] == "ISSUED"

    # 행사비(id=1): 체인 spent 30,000원 직접 모사
    _test_chain._budgets[1] = _test_chain._budgets[1].model_copy(update={"spent": 30_000})

    # 사업비(id=2): 실제 지출 등록 -> 제출 -> 확정(confirm) 흐름으로 FakeChainClient가 spent 35,000원을 반영하는지 검증
    res_entry_draft = client.post(
        "/entries",
        json={
            "term_id": 1,
            "kind": "EXPENSE",
            "amount": 35_000,
            "counterparty": "한결문구",
            "purpose": "명찰 구매",
            "budget_id": 2,
            "occurred_at": 1788793200,
        },
        headers=auth_header(Role.TREASURER),
    )
    assert res_entry_draft.status_code == 201
    entry_id = res_entry_draft.json()["id"]

    res_entry_submit = client.post(
        f"/entries/{entry_id}/submit",
        json={"deadline": now + 600, "signature": fake_signature(TREASURER_WALLET)},
        headers=auth_header(Role.TREASURER),
    )
    assert res_entry_submit.status_code == 200

    res_entry_confirm = client.post(
        f"/entries/{entry_id}/confirm",
        json={"deadline": now + 600, "signature": fake_signature(AUDITOR_WALLET)},
        headers=auth_header(Role.AUDITOR),
    )
    assert res_entry_confirm.status_code == 200

    res = client.get("/budgets")
    assert res.status_code == 200
    budgets = res.json()
    assert len(budgets) == 2

    b_event, b_proj = budgets[0], budgets[1]
    assert b_event["category"] == "행사비"
    assert b_event["planned_amount"] == 2_500_000
    assert b_event["remaining_amount"] == 2_470_000
    assert b_event["execution_rate"] == 0.012

    assert b_proj["category"] == "사업비"
    assert b_proj["planned_amount"] == 1_500_000
    assert b_proj["remaining_amount"] == 1_465_000
    assert b_proj["execution_rate"] == 0.0233

    # 학기 필터 검증
    assert client.get("/budgets?term_id=2").json() == []
    assert len(client.get("/budgets?term_id=1").json()) == 2


def test_get_budgets_chain_error_returns_503(auth_header):
    """체인 get_budget 조회 중 ChainError 발생 시 DB 폴백 없이 503 Service Unavailable을 반환한다."""
    now = int(time.time())
    _, res = _draft_and_submit(
        auth_header,
        category="행사비",
        planned_amount=2_000_000,
        expires_at=now + 86400,
    )
    assert res.status_code == 200

    async def broken_get_budget(budget_id: int):
        raise ChainUnavailable("RPC 연결 실패")

    _test_chain.get_budget = broken_get_budget
    res_list = client.get("/budgets")
    assert res_list.status_code == 503
    assert "블록체인" in res_list.json()["detail"]


# ---------------------------------------------------------------- GET /balance (B4)


def test_get_balance_empty_db_returns_zeros():
    res = client.get("/balance")
    assert res.status_code == 200
    assert res.json() == {"balance": 0, "income": 0, "expense": 0}


def test_get_balance_aggregates_only_confirmed_entries_and_corrections():
    with _test_session_factory() as db:
        db.add(
            DBBudget(
                id=1,
                term_id=1,
                category="사업비",
                expires_at=datetime.fromtimestamp(1797260399, tz=timezone.utc),
                tx_issue="0x" + "1" * 64,
            )
        )
        db.add_all(
            [
                # 1. 확정 수입 5,000,000원
                DBEntry(
                    id=1,
                    term_id=1,
                    kind="INCOME",
                    amount=5_000_000,
                    counterparty="학생회비 수납",
                    purpose="2026-2학기 학생회비",
                    occurred_at=1788620400,
                    meta_hash="0x" + "1" * 64,
                    status="CONFIRMED",
                    created_by=2,
                    approved_by=3,
                    tx_pending="0x" + "a" * 64,
                    tx_confirm="0x" + "b" * 64,
                ),
                # 2. 확정 지출 50,000원
                DBEntry(
                    id=2,
                    term_id=1,
                    kind="EXPENSE",
                    amount=50_000,
                    counterparty="한결문구",
                    purpose="명찰 구매",
                    budget_id=1,
                    occurred_at=1788793200,
                    meta_hash="0x" + "2" * 64,
                    status="CONFIRMED",
                    created_by=2,
                    approved_by=3,
                    tx_pending="0x" + "c" * 64,
                    tx_confirm="0x" + "d" * 64,
                ),
                # 3. 확정 음수 정정 지출 -15,000원 (순 확정 지출 = 35,000원)
                DBEntry(
                    id=3,
                    term_id=1,
                    kind="EXPENSE",
                    amount=-15_000,
                    counterparty="한결문구",
                    purpose="명찰 수량 정정 환불",
                    budget_id=1,
                    occurred_at=1788793200,
                    meta_hash="0x" + "3" * 64,
                    status="CONFIRMED",
                    created_by=2,
                    approved_by=3,
                    tx_pending="0x" + "e" * 64,
                    tx_confirm="0x" + "f" * 64,
                    corrects_entry_id=2,
                    correction_reason="REFUND",
                ),
                # 4. PENDING 지출 120,000원 (제외 대상)
                DBEntry(
                    id=4,
                    term_id=1,
                    kind="EXPENSE",
                    amount=120_000,
                    counterparty="청년피자",
                    purpose="대기중 다과",
                    budget_id=1,
                    occurred_at=1788706800,
                    meta_hash="0x" + "4" * 64,
                    status="PENDING",
                    created_by=2,
                    tx_pending="0x" + "9" * 64,
                ),
                # 5. REJECTED 수입 200,000원 (제외 대상)
                DBEntry(
                    id=5,
                    term_id=1,
                    kind="INCOME",
                    amount=200_000,
                    counterparty="오입력 수입",
                    purpose="반려된 수입",
                    occurred_at=1788706800,
                    meta_hash="0x" + "5" * 64,
                    status="REJECTED",
                    created_by=2,
                    rejected_by=3,
                    reject_reason="오입력",
                    tx_pending="0x" + "8" * 64,
                    tx_confirm="0x" + "7" * 64,
                ),
                # 6. 미제출 초안 지출 90,000원 (제외 대상)
                DBEntry(
                    id=6,
                    term_id=1,
                    kind="EXPENSE",
                    amount=90_000,
                    counterparty="초안상점",
                    purpose="초안 지출",
                    budget_id=1,
                    occurred_at=1788706800,
                    meta_hash="0x" + "6" * 64,
                    status=None,
                    created_by=2,
                ),
                # 7. 다른 학기(term_id=2) 확정 수입 1,000,000원
                DBEntry(
                    id=7,
                    term_id=2,
                    kind="INCOME",
                    amount=1_000_000,
                    counterparty="2027-1 학생회비",
                    purpose="다음 학기 수납",
                    occurred_at=1788706800,
                    meta_hash="0x" + "7" * 64,
                    status="CONFIRMED",
                    created_by=2,
                    approved_by=3,
                    tx_pending="0x" + "5" * 64,
                    tx_confirm="0x" + "6" * 64,
                ),
            ]
        )
        db.commit()

    # term_id=1 필터 조회
    res_t1 = client.get("/balance?term_id=1")
    assert res_t1.status_code == 200
    assert res_t1.json() == {
        "balance": 4_965_000,
        "income": 5_000_000,
        "expense": 35_000,
    }

    # 전체 학기 조회
    res_all = client.get("/balance")
    assert res_all.status_code == 200
    assert res_all.json() == {
        "balance": 5_965_000,
        "income": 6_000_000,
        "expense": 35_000,
    }


def test_get_balance_db_error_returns_503(monkeypatch):
    def broken_db():
        class BrokenSession:
            def query(self, *args, **kwargs):
                raise OperationalError("SELECT", {}, Exception("DB down"))

        yield BrokenSession()

    app.dependency_overrides[get_db] = broken_db
    try:
        res = client.get("/balance")
        assert res.status_code == 503
    finally:
        pass
