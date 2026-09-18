import time
import pytest
from fastapi.testclient import TestClient
from app.main import app
from app.chain.fake import fake_signature
from app.routers.entries import DEFAULT_TREASURER_WALLET

client = TestClient(app)


def test_get_entries():
    response = client.get("/entries")
    assert response.status_code == 200
    data = response.json()
    assert len(data) >= 3
    assert data[0]["id"] == 1
    assert data[0]["occurred_at"] == 1788793200


def test_open_draft_and_submit_full_flow():
    now = int(time.time())

    # 1. 초안 등록
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
    res_draft = client.post("/entries/drafts", json=req_body)
    assert res_draft.status_code == 201
    draft_data = res_draft.json()

    draft_id = draft_data["id"]
    assert "status" not in draft_data  # 1단계 응답 status 제거 검증
    assert "sign" in draft_data
    sign_payload = draft_data["sign"]
    assert sign_payload["message"]["id"] == draft_id
    assert sign_payload["message"]["amount"] == 45000

    # 2. 기기 서명 생성 및 제출
    sig = fake_signature(DEFAULT_TREASURER_WALLET)
    deadline = now + 300

    submit_body = {
        "meta_hash": sign_payload["message"]["hash"],
        "deadline": deadline,
        "signature": sig,
    }
    res_submit = client.post(f"/entries/drafts/{draft_id}/submit", json=submit_body)
    assert res_submit.status_code == 200
    submit_data = res_submit.json()

    assert submit_data["id"] == draft_id
    assert submit_data["status"] == "PENDING"
    assert submit_data["tx_pending"] is not None
    assert submit_data["tx_pending"].startswith("0x")

    # 3. GET /entries 에 신규 등록 건 반영 확인
    res_entries = client.get("/entries")
    assert res_entries.status_code == 200
    entries = res_entries.json()
    new_entry = next((e for e in entries if e["id"] == draft_id), None)
    assert new_entry is not None
    assert new_entry["counterparty"] == "알파문구"
    assert new_entry["status"] == "PENDING"
    assert new_entry["tx_pending"] == submit_data["tx_pending"]


def test_ocr_duplication_with_confirmed_entry():
    # 1번 더미(한결문구: 35000, 12345678, 1788825820)와 동일한 OCR 정보로 등록 시도
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
    res = client.post("/entries/drafts", json=dup_body)
    assert res.status_code == 409
    assert "이미 등록된 영수증입니다" in res.json()["detail"]


def test_ocr_duplication_with_open_draft():
    # 1. 초안 하나 생성
    body1 = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 89000,
        "counterparty": "도미노피자",
        "purpose": "임원회의 야식",
        "budget_id": 1,
        "occurred_at": 1788793200,
        "ocr_amount": 89000,
        "ocr_approval_no": "55443322",
        "ocr_paid_at": 1788827777,
        "ocr_status": "MATCH",
    }
    res1 = client.post("/entries/drafts", json=body1)
    assert res1.status_code == 201

    # 2. 서명 전(DRAFT 상태) 동일한 OCR 정보로 다른 초안 생성 시도 -> 409 차단!
    body2 = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 89000,
        "counterparty": "도미노피자",
        "purpose": "중복 초안 생성 시도",
        "budget_id": 1,
        "occurred_at": 1788793200,
        "ocr_amount": 89000,
        "ocr_approval_no": "55443322",
        "ocr_paid_at": 1788827777,
        "ocr_status": "MATCH",
    }
    res2 = client.post("/entries/drafts", json=body2)
    assert res2.status_code == 409
    assert "동일한 영수증으로 처리 중인 초안이 존재합니다" in res2.json()["detail"]


def test_discard_draft_flow():
    # 1. 초안 생성
    body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 15000,
        "counterparty": "카페",
        "purpose": "음료 구매",
        "budget_id": 3,
        "occurred_at": 1788793200,
    }
    res = client.post("/entries/drafts", json=body)
    assert res.status_code == 201
    draft_id = res.json()["id"]

    # 2. 초안 폐기
    res_delete = client.delete(f"/entries/drafts/{draft_id}")
    assert res_delete.status_code == 200
    assert res_delete.json()["status"] == "DISCARDED"

    # 3. 폐기된 초안 제출 시도 -> 409 거절
    submit_body = {
        "meta_hash": res.json()["sign"]["message"]["hash"],
        "deadline": int(time.time()) + 300,
        "signature": fake_signature(DEFAULT_TREASURER_WALLET),
    }
    res_submit = client.post(f"/entries/drafts/{draft_id}/submit", json=submit_body)
    assert res_submit.status_code == 409
    assert "이미 폐기된 초안입니다" in res_submit.json()["detail"]
