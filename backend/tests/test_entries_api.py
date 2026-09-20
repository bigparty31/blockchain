import time
import pytest
from fastapi.testclient import TestClient
from app.main import app
from app.chain.services import get_chain_client
from app.chain.models import BlockReason, RevertReason
from app.chain.fake import fake_signature
from app.routers.entries import DUMMY_ENTRIES

client = TestClient(app)
TREASURER = "0x1111111111111111111111111111111111111111"


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


def test_create_entry_draft_and_submit():
    """1단계 초안 생성(id만 발급, 목록 미노출, meta_hash 정확성) 및 2단계 submit(PENDING 전환, 목록 노출) 검증"""
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
    res_draft = client.post("/entries", json=req_body)
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

    # 2. 기기 서명 제출 (2단계)
    submit_body = {
        "deadline": now + 600,
        "signature": fake_signature(TREASURER),
    }
    res_submit = client.post(f"/entries/{draft_id}/submit", json=submit_body)
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


def test_submit_blocked_budget_exceeded():
    """예산 초과 시 2단계 submit에서 BLOCKED 상태, block_reason 및 체인 tx_pending 반환 검증"""
    chain = get_chain_client()
    chain.block_next(BlockReason.BUDGET_EXCEEDED)

    req_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 15000000,
        "counterparty": "대형장비업체",
        "purpose": "축제 음향 장비 렌탈",
        "budget_id": 1,
        "occurred_at": 1788793200,
    }
    res_draft = client.post("/entries", json=req_body)
    assert res_draft.status_code == 201
    draft_id = res_draft.json()["id"]

    submit_body = {
        "deadline": int(time.time()) + 600,
        "signature": fake_signature(TREASURER),
    }
    res_submit = client.post(f"/entries/{draft_id}/submit", json=submit_body)
    assert res_submit.status_code == 200
    submit_data = res_submit.json()

    assert submit_data["id"] == draft_id
    assert submit_data["status"] == "BLOCKED"
    assert submit_data["block_reason"] == "BUDGET_EXCEEDED"
    # 체인의 recordPending은 예산 초과여도 트랜잭션이 성공하고 BLOCKED로 저장하므로 tx_pending이 존재해야 함
    assert submit_data["tx_pending"] is not None
    assert submit_data["tx_pending"].startswith("0x")

    # PRD §8 "BLOCKED 기록은 남겨 개정 요청 근거로 사용" - 목록 조회 시 포함되어야 함
    res_list = client.get("/entries")
    entries = res_list.json()
    blocked_entry = next((e for e in entries if e["id"] == draft_id), None)
    assert blocked_entry is not None
    assert blocked_entry["status"] == "BLOCKED"
    assert blocked_entry["tx_pending"] == submit_data["tx_pending"]


def test_ocr_duplication_conflict():
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
    res = client.post("/entries", json=dup_body)
    assert res.status_code == 409
    assert "이미 등록된 영수증입니다" in res.json()["detail"]


def test_forbidden_characters_rejected():
    """제어문자(탭 등) 및 보이지 않는 공백 입력 시 400 Bad Request 검증"""
    # 탭 문자 포함
    req_body_tab = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 10000,
        "counterparty": "한결\t문구",
        "purpose": "비품 구매",
        "budget_id": 1,
        "occurred_at": 1788793200,
    }
    res = client.post("/entries", json=req_body_tab)
    assert res.status_code == 400
    assert "보이지 않는 문자 또는 제어문자" in res.json()["detail"]

    # occurred_at KST 자정 미준수
    req_body_bad_time = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 10000,
        "counterparty": "한결문구",
        "purpose": "비품 구매",
        "budget_id": 1,
        "occurred_at": 1788793201,  # 1초 어긋남
    }
    res2 = client.post("/entries", json=req_body_bad_time)
    assert res2.status_code == 400
    assert "KST 자정" in res2.json()["detail"]


def test_submit_revert_keeps_status_null():
    """서명 불일치 등 Revert 발생 시 400 반환 및 초안 status NULL 유지 검증"""
    chain = get_chain_client()
    chain.fail_next("record_pending", RevertReason.NOT_REGISTRANT)

    req_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 20000,
        "counterparty": "알파문구",
        "purpose": "A4 용지 구매",
        "budget_id": 1,
        "occurred_at": 1788793200,
    }
    res_draft = client.post("/entries", json=req_body)
    draft_id = res_draft.json()["id"]

    submit_body = {
        "deadline": int(time.time()) + 600,
        "signature": fake_signature(TREASURER),
    }
    res_submit = client.post(f"/entries/{draft_id}/submit", json=submit_body)
    assert res_submit.status_code == 400
    assert "NotRegistrant" in res_submit.json()["detail"]

    # Revert 후에도 초안의 status는 NULL 유지 (CHAIN_CLIENT.md §4)
    target = next((e for e in DUMMY_ENTRIES if e.id == draft_id), None)
    assert target is not None
    assert target.status is None
    assert target.tx_pending is None


def test_delete_draft_lifecycle():
    """초안 폐기(DELETE) 정상 동작 및 온체인 완료 건 삭제 불가 검증"""
    # 1. 초안 생성 후 삭제
    req_body = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 15000,
        "counterparty": "임시문구",
        "purpose": "테스트 후 삭제할 내역",
        "budget_id": 1,
        "occurred_at": 1788793200,
    }
    res_draft = client.post("/entries/drafts", json=req_body)
    draft_id = res_draft.json()["id"]

    res_del = client.delete(f"/entries/drafts/{draft_id}")
    assert res_del.status_code == 200
    assert "폐기되었습니다" in res_del.json()["message"]

    # 삭제 후 재삭제 시 404
    res_del_again = client.delete(f"/entries/{draft_id}")
    assert res_del_again.status_code == 404

    # 2. 이미 온체인 처리된 내역(ID=1 CONFIRMED) 삭제 시도 시 400
    res_del_confirmed = client.delete("/entries/1")
    assert res_del_confirmed.status_code == 400
    assert "삭제할 수 없습니다" in res_del_confirmed.json()["detail"]


def test_chain_unavailable_handling():
    """연결 실패 시나리오: landed=False면 503 반환, landed=True면 get_entry로 복구 검증"""
    chain = get_chain_client()

    # 케이스 1: landed=False (체인 미반영 -> 503)
    chain.unavailable_next("record_pending", landed=False)
    req_body1 = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 25000,
        "counterparty": "네트워크불안문구",
        "purpose": "노드 장애 테스트",
        "budget_id": 1,
        "occurred_at": 1788793200,
    }
    res_draft1 = client.post("/entries", json=req_body1)
    draft_id1 = res_draft1.json()["id"]

    submit_body = {
        "deadline": int(time.time()) + 600,
        "signature": fake_signature(TREASURER),
    }
    res_submit1 = client.post(f"/entries/{draft_id1}/submit", json=submit_body)
    assert res_submit1.status_code == 503

    # 케이스 2: landed=True (체인 반영 성공 후 응답만 누락 -> get_entry로 복구되어 200)
    chain.unavailable_next("record_pending", landed=True)
    req_body2 = {
        "term_id": 1,
        "kind": "EXPENSE",
        "amount": 28000,
        "counterparty": "복구테스트문구",
        "purpose": "노드 응답 누락 복구 테스트",
        "budget_id": 1,
        "occurred_at": 1788793200,
    }
    res_draft2 = client.post("/entries", json=req_body2)
    draft_id2 = res_draft2.json()["id"]

    res_submit2 = client.post(f"/entries/{draft_id2}/submit", json=submit_body)
    assert res_submit2.status_code == 200
    data2 = res_submit2.json()
    assert data2["id"] == draft_id2
    assert data2["status"] == "PENDING"
