"""POST /ocr/receipt 테스트. CLOVA 대신 가짜 클라이언트가 저장된 CU 영수증 응답을 돌려준다."""
import asyncio
import base64
import copy
import json
from datetime import datetime, timezone
from pathlib import Path

import pytest
from aiohttp import web
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.auth import users
from app.database import Base, get_db
from app.main import app
from app.models import Entry as DBEntry, Term as DBTerm, User as DBUser
from app.ocr import ClovaOcrClient, OcrUnavailable, get_ocr_client
from app.ocr.clova import build_request
from app.schemas.auth import Role

client = TestClient(app)

CU = json.loads((Path(__file__).resolve().parents[2] / "docs" / "samples" / "clova_ocr_response_example.json").read_text(encoding="utf-8"))
CU_APPROVAL_NO = "39007018"
CU_PAID_AT = int(datetime(2026, 9, 18, 4, 22, tzinfo=timezone.utc).timestamp())  # 13:22 KST
IMAGE = base64.b64encode(b"fake-jpeg-bytes").decode()


class FakeOcr:
    def __init__(self, response=None, error=None):
        self.response, self.error, self.calls = response, error, []

    async def recognize(self, image, image_format):
        self.calls.append((image, image_format))
        if self.error:
            raise self.error
        return self.response


_session = None


@pytest.fixture(autouse=True)
def setup(tmp_path):
    global _session
    engine = create_engine(f"sqlite:///{tmp_path / 'test.db'}", connect_args={"check_same_thread": False})
    Base.metadata.create_all(bind=engine)
    _session = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    with _session() as db:
        for u in users.SEED_USERS:
            db.add(DBUser(id=u.id, student_no=u.student_no, password_hash=u.password_hash, name=u.name,
                          role=u.role.value, wallet_index=u.wallet_index,
                          wallet_address=u.wallet_address.lower() if u.wallet_address else None))  # ck_users_wallet_address_lower
        db.add(DBTerm(id=1, term_code=20262, name="2026-2학기",
                      started_at=datetime(2026, 9, 1, tzinfo=timezone.utc), ended_at=datetime(2026, 12, 31, tzinfo=timezone.utc)))
        db.commit()

    def override_db():
        with _session() as db:
            yield db

    app.dependency_overrides[get_db] = override_db
    app.dependency_overrides[get_ocr_client] = lambda: FakeOcr(CU)
    yield
    app.dependency_overrides.clear()


def _use_ocr(fake):
    app.dependency_overrides[get_ocr_client] = lambda: fake
    return fake


def _add_entry(entry_id, status, amount=4600, approval_no=CU_APPROVAL_NO, paid_at=CU_PAID_AT):
    treasurer = next(u for u in users.SEED_USERS if u.role == Role.TREASURER)
    with _session() as db:
        db.add(DBEntry(id=entry_id, term_id=1, kind="EXPENSE", amount=amount, counterparty="CU", purpose="소모품",
                       occurred_at=1789657200, ocr_approval_no=approval_no, ocr_paid_at=paid_at,
                       status=status, created_by=treasurer.id,
                       reject_reason="총무 수정 요청" if status == "REJECTED" else None))  # ck_entries_reject_reason
        db.commit()


def _post(auth_header, amount=4600, role=Role.TREASURER, **overrides):
    body = {"image_base64": IMAGE, "format": "jpg", "amount": amount, **overrides}
    return client.post("/ocr/receipt", json=body, headers=auth_header(role))


# --- 판정 결과 ----------------------------------------------------------------


def test_match_returns_prd_shape(auth_header):
    fake = _use_ocr(FakeOcr(CU))
    res = _post(auth_header)
    assert res.status_code == 200
    assert res.json() == {
        "ocr_status": "MATCH", "ocr_amount": 4600, "input_amount": 4600, "duplicate_of": None,
        "ocr_approval_no": CU_APPROVAL_NO, "ocr_paid_at": CU_PAID_AT,
    }
    assert fake.calls == [(b"fake-jpeg-bytes", "jpg")]  # base64 를 풀어 원본 바이트를 넘긴다


def test_mismatch(auth_header):
    assert _post(auth_header, amount=5000).json()["ocr_status"] == "MISMATCH"


@pytest.mark.parametrize("status", ["PENDING", "CONFIRMED"])
def test_duplicate_links_existing_entry(auth_header, status):
    _add_entry(7, status)
    data = _post(auth_header).json()
    assert data["ocr_status"] == "DUPLICATE"
    assert data["duplicate_of"] == 7


@pytest.mark.parametrize("status", ["REJECTED", "BLOCKED", None])
def test_rejected_blocked_draft_are_not_duplicates(auth_header, status):
    # 반려 후 재등록(T4)·증액 후 재등록은 같은 영수증을 다시 쓰는 정상 경로, 초안은 체인에 없다
    _add_entry(7, status)
    data = _post(auth_header).json()
    assert data["ocr_status"] == "MATCH"
    assert data["duplicate_of"] is None


def test_duplicate_even_when_input_amount_differs(auth_header):
    # 4,600원 영수증을 9,999원으로 다시 올려도 기존 건을 찾는다 — DUPLICATE 가 MISMATCH 보다 먼저 (PR #36 리뷰)
    _add_entry(7, "CONFIRMED", amount=4600)
    data = _post(auth_header, amount=9999).json()
    assert data["ocr_status"] == "DUPLICATE"
    assert data["duplicate_of"] == 7


def test_unreadable_does_not_link_duplicate(auth_header):
    # 흐린 글자로 읽은 영수증은 중복 검사에서 빠진다 — 기존 건 링크도 내려가지 않는다 (PR #36 리뷰)
    blurry = copy.deepcopy(CU)
    for f in blurry["images"][0]["fields"]:
        if f["inferText"] == "4,600":
            f["inferConfidence"] = 0.5
    _use_ocr(FakeOcr(blurry))
    _add_entry(7, "CONFIRMED")
    data = _post(auth_header).json()
    assert data["ocr_status"] == "UNREADABLE"
    assert data["duplicate_of"] is None


def test_same_approval_no_other_amount_is_not_duplicate(auth_header):
    _add_entry(7, "CONFIRMED", amount=9900)
    assert _post(auth_header).json()["ocr_status"] == "MATCH"


def test_ocr_unavailable_is_unreadable_not_error(auth_header):
    # OCR 을 못 돌려도 등록을 막지 않는다 — 200 + UNREADABLE (PRD §6)
    _use_ocr(FakeOcr(error=OcrUnavailable("CLOVA 응답 500")))
    res = _post(auth_header)
    assert res.status_code == 200
    assert res.json()["ocr_status"] == "UNREADABLE"
    assert res.json()["ocr_amount"] is None


def test_missing_keys_is_unreadable(auth_header):
    _use_ocr(ClovaOcrClient(invoke_url=None, secret=None))
    assert _post(auth_header).json()["ocr_status"] == "UNREADABLE"


# --- 입력 검증·권한 -------------------------------------------------------------


def test_bad_base64_is_400(auth_header):
    assert _post(auth_header, image_base64="not base64!!").status_code == 400


def test_unsupported_format_is_422(auth_header):
    assert _post(auth_header, format="gif").status_code == 422


def test_too_large_is_413(auth_header, monkeypatch):
    monkeypatch.setattr("app.routers.ocr.MAX_IMAGE_BYTES", 4)
    assert _post(auth_header).status_code == 413


@pytest.mark.parametrize("role", [Role.AUDITOR, Role.PRESIDENT, Role.STUDENT])
def test_only_treasurer(auth_header, role):
    assert _post(auth_header, role=role).status_code == 403


def test_without_token_is_401():
    assert client.post("/ocr/receipt", json={"image_base64": IMAGE, "format": "jpg", "amount": 4600}).status_code == 401


# --- CLOVA 요청 본문 -----------------------------------------------------------


def test_build_request_matches_clova_v2():
    req = build_request(b"abc", "png")
    assert req["version"] == "V2"
    assert req["images"] == [{"format": "png", "name": "receipt", "data": base64.b64encode(b"abc").decode()}]
    assert req["requestId"] and isinstance(req["timestamp"], int)


def test_client_without_keys_raises():
    with pytest.raises(OcrUnavailable):
        asyncio.run(ClovaOcrClient(None, None).recognize(b"x", "jpg"))


@pytest.mark.parametrize(
    "status, body",
    [
        (200, "{not json"),  # 200 인데 JSON 이 깨짐 → ValueError (PR #36 리뷰)
        (500, "error"),
    ],
)
def test_client_bad_response_raises_unavailable(status, body):
    """로컬에 잠깐 띄운 가짜 CLOVA 서버로 실제 HTTP 경로를 돌린다."""

    async def run():
        async def handler(request):
            assert request.headers["X-OCR-SECRET"] == "test-secret"
            return web.Response(status=status, text=body, content_type="application/json")

        server = web.Application()
        server.router.add_post("/ocr", handler)
        runner = web.AppRunner(server)
        await runner.setup()
        site = web.TCPSite(runner, "127.0.0.1", 0)
        await site.start()
        port = site._server.sockets[0].getsockname()[1]
        try:
            await ClovaOcrClient(f"http://127.0.0.1:{port}/ocr", "test-secret").recognize(b"x", "jpg")
        finally:
            await runner.cleanup()

    with pytest.raises(OcrUnavailable):
        asyncio.run(run())
