import time
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from app.auth import users
from app.auth.security import create_access_token
from app.chain import FakeChainClient, fake_signature, get_chain_client, set_chain_client
from app.chain.models import BlockReason
from app.main import app
from app.routers.entries import DUMMY_ENTRIES
from app.schemas.auth import Role

client = TestClient(app)

TREASURER_WALLET = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"  # 시드 총무 지갑
AUDITOR_WALLET = "0x90F79bf6EB2c4f870365E785982E1f101E93b906"    # 시드 감사 지갑
PRESIDENT_WALLET = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"  # 시드 회장 지갑


@pytest.fixture(autouse=True)
def restore_entries():
    """테스트가 DUMMY_ENTRIES 에 남긴 초안·상태 변경 및 FakeChainClient 상태를 테스트마다 되돌린다."""
    saved = [e.model_copy() for e in DUMMY_ENTRIES]
    set_chain_client(FakeChainClient())
    yield
    DUMMY_ENTRIES[:] = saved
    set_chain_client(FakeChainClient())


def test_get_entries():
    """초기 더미 데이터 3건(status가 존재하는 확정/대기 항목)만 조회되는지 검증"""
    response = client.get("/entries")
    assert response.status_code == 200
    data = response.json()
    assert len(data) >= 3
    # 모든 조회 결과는 status와 tx_pending이 존재해야 함 (초안 status IS NULL 제외 필터 검증)
    for entry in data:
        assert entry["status"] is not None
        assert entry["tx_pending"] is not None


def test_create_entry_draft_and_submit(auth_header):
    """1단계 초안 생성(id만 발급, 목록 미노출) 및 2단계 submit(signer_of 통과, PENDING 전환, 목록 노출) 검증"""
    now = int(time.time())

    # 1. 초안 등록 (1단계)
    req_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 45000,
        "counterparty": "알파문구",
        "purpose": "중간고사 간식 박스 테이프 구매",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "receipt_hash": "0x11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff",
        "ocr_amount": 45000,
        "ocr_approval_no": "99887766",
        "ocr_paid_at": 1788829999,
        "ocr_status": "MATCH",
    }
    res_draft = client.post("/entries", json=req_body, headers=auth_header(Role.TREASURER))
    assert res_draft.status_code == 201
    draft_data = res_draft.json()

    draft_id = draft_data["id"]
    # 1단계 응답에는 status와 tx_pending이 없어야 함 (초안 status IS NULL)
    assert "status" not in draft_data or draft_data.get("status") is None
    assert "tx_pending" not in draft_data or draft_data.get("tx_pending") is None

    # submit 전에는 GET /entries 목록에 노출되지 않아야 함
    res_list_before = client.get("/entries")
    entries_before = res_list_before.json()
    assert not any(e["id"] == draft_id for e in entries_before)

    # 2. 기기 서명 제출 (2단계) - 등록 총무의 지갑으로 생성한 정상 서명
    submit_body = {
        "deadline": now + 600,
        "signature": fake_signature(TREASURER_WALLET),
    }
    res_submit = client.post(f"/entries/{draft_id}/submit", json=submit_body, headers=auth_header(Role.TREASURER))
    assert res_submit.status_code == 200
    submit_data = res_submit.json()

    assert submit_data["id"] == draft_id
    assert submit_data["status"] == "PENDING"
    assert submit_data["tx_pending"] is not None
    assert submit_data["tx_pending"].startswith("0x")

    # submit 후에는 GET /entries 목록에 정상 노출되어야 함
    res_list_after = client.get("/entries")
    entries_after = res_list_after.json()
    new_entry = next((e for e in entries_after if e["id"] == draft_id), None)
    assert new_entry is not None
    assert new_entry["counterparty"] == "알파문구"
    assert new_entry["status"] == "PENDING"
    assert new_entry["tx_pending"] == submit_data["tx_pending"]


def test_submit_signature_mismatch_fails(auth_header):
    """서명자가 등록자와 다르면(체인 가스 낭비 방지) 400 Bad Request 반환 검증 (CHAIN_CLIENT.md §4)"""
    now = int(time.time())
    req_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 25000,
        "counterparty": "베타문구",
        "purpose": "서명 불일치 검증용",
        "budget_id": 2,
        "occurred_at": 1788793200,
    }
    res_draft = client.post("/entries", json=req_body, headers=auth_header(Role.TREASURER))
    assert res_draft.status_code == 201
    draft_id = res_draft.json()["id"]

    # 다른 사람(예: 0x9999...)의 지갑 주소로 서명한 경우
    submit_body = {
        "deadline": now + 600,
        "signature": fake_signature("0x9999999999999999999999999999999999999999"),
    }
    res_submit = client.post(f"/entries/{draft_id}/submit", json=submit_body, headers=auth_header(Role.TREASURER))
    assert res_submit.status_code == 400
    assert "서명자가 등록자와 일치하지 않습니다" in res_submit.json()["detail"]


def test_submit_invalid_signature_format_fails(auth_header):
    """서명 형식이 0x + 130자 hex가 아니면 ValueError -> 400 Bad Request 반환 검증"""
    now = int(time.time())
    req_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 25000,
        "counterparty": "감마문구",
        "purpose": "서명 형식 오류 검증용",
        "budget_id": 2,
        "occurred_at": 1788793200,
    }
    res_draft = client.post("/entries", json=req_body, headers=auth_header(Role.TREASURER))
    draft_id = res_draft.json()["id"]

    submit_body = {
        "deadline": now + 600,
        "signature": "0xinvalid_signature_length",
    }
    res_submit = client.post(f"/entries/{draft_id}/submit", json=submit_body, headers=auth_header(Role.TREASURER))
    assert res_submit.status_code == 400
    assert "유효하지 않은 서명 형식입니다" in res_submit.json()["detail"]


def test_submit_blocked_budget_exceeded(auth_header):
    """예산 초과 시 2단계 submit에서 BLOCKED 상태, block_reason 및 체인 tx_pending 반환 검증"""
    chain: FakeChainClient = get_chain_client()
    chain.block_next(BlockReason.BUDGET_EXCEEDED)

    req_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 15000000,
        "counterparty": "대형장비업체",
        "purpose": "축제 음향 장비 렌탈",
        "budget_id": 2,
        "occurred_at": 1788793200,
    }
    res_draft = client.post("/entries", json=req_body, headers=auth_header(Role.TREASURER))
    assert res_draft.status_code == 201
    draft_id = res_draft.json()["id"]

    submit_body = {
        "deadline": int(time.time()) + 600,
        "signature": fake_signature(TREASURER_WALLET),
    }
    res_submit = client.post(f"/entries/{draft_id}/submit", json=submit_body, headers=auth_header(Role.TREASURER))
    if res_submit.status_code != 200:
        print("BLOCKED ERROR:", res_submit.json())
    assert res_submit.status_code == 200
    submit_data = res_submit.json()

    assert submit_data["id"] == draft_id
    assert submit_data["status"] == "BLOCKED"
    assert submit_data["block_reason"] == "BUDGET_EXCEEDED"
    assert submit_data["tx_pending"] is not None
    assert submit_data["tx_pending"].startswith("0x")

    # PRD §8 "BLOCKED 기록은 남겨 개정 요청 근거로 사용" - 목록 조회 시 포함되어야 함
    res_list = client.get("/entries")
    entries = res_list.json()
    blocked_entry = next((e for e in entries if e["id"] == draft_id), None)
    assert blocked_entry is not None
    assert blocked_entry["status"] == "BLOCKED"
    assert blocked_entry["tx_pending"] == submit_data["tx_pending"]


def test_ocr_duplication_conflict(auth_header):
    """동일한 승인번호/결제일시/금액 중복 등록 시 409 Conflict 발생 검증"""
    dup_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 35000,
        "counterparty": "다른문구점",
        "purpose": "명찰 중복 구매 시도",
        "budget_id": 2,
        "occurred_at": 1788793200,
        "ocr_amount": 35000,
        "ocr_approval_no": "12345678",
        "ocr_paid_at": 1788825820,
        "ocr_status": "MATCH",
    }
    res = client.post("/entries", json=dup_body, headers=auth_header(Role.TREASURER))
    assert res.status_code == 409
    assert "이미 등록된 영수증입니다" in res.json()["detail"]


# ---------------------------------------------------------------- 역할 권한 검사

DRAFT_BODY = {
    "term_id": 1,
    "kind": "EXPENSE",
    "amount": 12000,
    "counterparty": "권한테스트문구",
    "purpose": "권한 검사용 초안",
    "budget_id": 2,
    "occurred_at": 1788793200,
}
SUBMIT_BODY = {"deadline": 9999999999, "signature": fake_signature(TREASURER_WALLET)}


@pytest.fixture
def draft_id(auth_header):
    """시드 총무가 만든 초안 id"""
    res = client.post("/entries", json=DRAFT_BODY, headers=auth_header(Role.TREASURER))
    assert res.status_code == 201
    return res.json()["id"]


@pytest.fixture
def second_treasurer(monkeypatch):
    """시드 총무 말고 총무를 하나 더 둔다. 테스트가 끝나면 monkeypatch 가 되돌린다."""
    new_id = max(u.id for u in users.SEED_USERS) + 1
    second_wallet = "0x2222222222222222222222222222222222222222"
    user = users.User(
        id=new_id,
        student_no=f"2099{new_id:04d}",
        name="최총무",
        role=Role.TREASURER,
        password_hash="unused",
        wallet_address=second_wallet,
    )
    monkeypatch.setattr(users, "SEED_USERS", [*users.SEED_USERS, user])
    return SimpleNamespace(
        id=user.id,
        wallet_address=second_wallet,
        headers={"Authorization": f"Bearer {create_access_token(user.id)}"},
    )


def get_draft(entry_id):
    return next(e for e in DUMMY_ENTRIES if e.id == entry_id)


@pytest.mark.parametrize("role", [Role.STUDENT, Role.AUDITOR, Role.PRESIDENT])
def test_only_treasurer_can_create_entry(role, auth_header):
    count_before = len(DUMMY_ENTRIES)
    res = client.post("/entries", json=DRAFT_BODY, headers=auth_header(role))
    assert res.status_code == 403
    assert len(DUMMY_ENTRIES) == count_before


@pytest.mark.parametrize("role", [Role.STUDENT, Role.AUDITOR, Role.PRESIDENT])
def test_only_treasurer_can_submit_entry(role, auth_header, draft_id):
    res = client.post(f"/entries/{draft_id}/submit", json=SUBMIT_BODY, headers=auth_header(role))
    assert res.status_code == 403
    assert get_draft(draft_id).status is None
    assert get_draft(draft_id).tx_pending is None


def test_write_apis_without_token_are_401(draft_id):
    assert client.post("/entries", json=DRAFT_BODY).status_code == 401
    assert client.post(f"/entries/{draft_id}/submit", json=SUBMIT_BODY).status_code == 401


def test_created_by_is_logged_in_treasurer(second_treasurer):
    res = client.post("/entries", json=DRAFT_BODY, headers=second_treasurer.headers)
    assert res.status_code == 201
    assert get_draft(res.json()["id"]).created_by == second_treasurer.id


def test_other_treasurer_cannot_submit_someone_elses_draft(second_treasurer, draft_id):
    # 다른 총무가 서명하면 체인 등록자와 DB created_by 가 달라진다
    submit_req = {
        "deadline": 9999999999,
        "signature": fake_signature(second_treasurer.wallet_address),
    }
    res = client.post(f"/entries/{draft_id}/submit", json=submit_req, headers=second_treasurer.headers)
    assert res.status_code == 403
    assert res.json() == {"detail": "본인이 등록한 초안만 제출할 수 있습니다."}
    assert get_draft(draft_id).status is None
    assert get_draft(draft_id).tx_pending is None


# ---------------------------------------------------------------- 승인(Confirm) 및 반려(Reject) 테스트


def test_confirm_entry_success(auth_header):
    """감사가 PENDING 항목을 정상 승인(CONFIRMED)하는 흐름 검증"""
    now = int(time.time())
    # 1. 초안 생성 및 온체인 PENDING 등록
    draft_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 50000,
        "counterparty": "승인테스트문구",
        "purpose": "승인 테스트용 구매",
        "budget_id": 2,
        "occurred_at": 1788793200,
    }
    res_draft = client.post("/entries", json=draft_body, headers=auth_header(Role.TREASURER))
    entry_id = res_draft.json()["id"]

    submit_body = {
        "deadline": now + 600,
        "signature": fake_signature(TREASURER_WALLET),
    }
    res_submit = client.post(f"/entries/{entry_id}/submit", json=submit_body, headers=auth_header(Role.TREASURER))
    assert res_submit.status_code == 200

    # 2. 감사 승인 제출
    confirm_body = {
        "deadline": now + 600,
        "signature": fake_signature(AUDITOR_WALLET),
        "warning_reason": None,
    }
    res = client.post(f"/entries/{entry_id}/confirm", json=confirm_body, headers=auth_header(Role.AUDITOR))
    assert res.status_code == 200
    data = res.json()
    assert data["id"] == entry_id
    assert data["status"] == "CONFIRMED"
    assert data["tx_confirm"] is not None


def test_confirm_self_approval_is_blocked(auth_header):
    """총무(등록자 본인)가 승인 권한이 있는 경우에도 자기 승인은 403 차단 검증"""
    now = int(time.time())
    # 초안 생성 및 PENDING 등록 (등록자: 시드 총무 id=2)
    draft_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 30000,
        "counterparty": "자기승인방지문구",
        "purpose": "자기 승인 차단 검증",
        "budget_id": 2,
        "occurred_at": 1788793200,
    }
    res_draft = client.post("/entries", json=draft_body, headers=auth_header(Role.TREASURER))
    entry_id = res_draft.json()["id"]

    submit_body = {
        "deadline": now + 600,
        "signature": fake_signature(TREASURER_WALLET),
    }
    res_submit = client.post(f"/entries/{entry_id}/submit", json=submit_body, headers=auth_header(Role.TREASURER))
    assert res_submit.status_code == 200

    # 등록자(id=2)가 회장 권한으로 승인을 시도하는 경우 시뮬레이션
    token = create_access_token(2)
    headers = {"Authorization": f"Bearer {token}"}
    orig_role = users.SEED_USERS[1].role
    users.SEED_USERS[1].role = Role.PRESIDENT
    try:
        confirm_body = {
            "deadline": now + 600,
            "signature": fake_signature(TREASURER_WALLET),
        }
        res = client.post(f"/entries/{entry_id}/confirm", json=confirm_body, headers=headers)
        assert res.status_code == 403
        assert "본인이 등록한 항목은 승인·반려할 수 없습니다" in res.json()["detail"]
    finally:
        users.SEED_USERS[1].role = orig_role


def test_confirm_signer_mismatch_fails(auth_header):
    """승인 시 서명자가 요청자와 다르면 400 Bad Request 반환 검증"""
    now = int(time.time())
    draft_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 20000,
        "counterparty": "서명불일치문구",
        "purpose": "승인 서명 불일치 검증",
        "budget_id": 2,
        "occurred_at": 1788793200,
    }
    res_draft = client.post("/entries", json=draft_body, headers=auth_header(Role.TREASURER))
    entry_id = res_draft.json()["id"]

    submit_body = {
        "deadline": now + 600,
        "signature": fake_signature(TREASURER_WALLET),
    }
    res_submit = client.post(f"/entries/{entry_id}/submit", json=submit_body, headers=auth_header(Role.TREASURER))
    assert res_submit.status_code == 200

    confirm_body = {
        "deadline": now + 600,
        "signature": fake_signature("0x8888888888888888888888888888888888888888"),
    }
    res = client.post(f"/entries/{entry_id}/confirm", json=confirm_body, headers=auth_header(Role.AUDITOR))
    assert res.status_code == 400
    assert "서명자가 승인권자와 일치하지 않습니다" in res.json()["detail"]


def test_reject_entry_success(auth_header):
    """감사가 PENDING 항목을 사유와 함께 정상 반려(REJECTED)하는 흐름 검증"""
    now = int(time.time())
    draft_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 60000,
        "counterparty": "반려테스트문구",
        "purpose": "반려 테스트용 구매",
        "budget_id": 2,
        "occurred_at": 1788793200,
    }
    res_draft = client.post("/entries", json=draft_body, headers=auth_header(Role.TREASURER))
    entry_id = res_draft.json()["id"]

    submit_body = {
        "deadline": now + 600,
        "signature": fake_signature(TREASURER_WALLET),
    }
    res_submit = client.post(f"/entries/{entry_id}/submit", json=submit_body, headers=auth_header(Role.TREASURER))
    assert res_submit.status_code == 200

    reject_body = {
        "deadline": now + 600,
        "signature": fake_signature(AUDITOR_WALLET),
        "reject_reason": "영수증 식별 불가로 인한 반려",
    }
    res = client.post(f"/entries/{entry_id}/reject", json=reject_body, headers=auth_header(Role.AUDITOR))
    assert res.status_code == 200
    data = res.json()
    assert data["id"] == entry_id
    assert data["status"] == "REJECTED"
