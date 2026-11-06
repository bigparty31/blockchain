import hashlib
import io
import os
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.auth.security import create_access_token
from app.main import app
from app.routers.receipts import get_receipts_storage_dir
from app.schemas.auth import Role

client = TestClient(app)


def test_upload_receipt_success(auth_header, tmp_path, monkeypatch):
    """영수증 이미지를 업로드하고 원본 바이트 보존 및 SHA-256 해시 발급 검증"""
    monkeypatch.setenv("RECEIPTS_STORAGE_DIR", str(tmp_path / "receipts"))

    image_content = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x01\x00`\x00`\x00\x00\xff\xdb\x00C\x00test-jpeg-bytes"
    expected_hash = "0x" + hashlib.sha256(image_content).hexdigest().lower()

    files = {"file": ("my_receipt.jpg", io.BytesIO(image_content), "image/jpeg")}
    res = client.post("/receipts", files=files, headers=auth_header(Role.TREASURER))

    assert res.status_code == 201
    data = res.json()
    assert data["receipt_hash"] == expected_hash
    assert data["receipt_path"].startswith("/receipts/")
    assert data["receipt_path"].endswith(".jpg")
    assert data["filename"] == "my_receipt.jpg"
    assert data["size"] == len(image_content)

    # 서버 저장소에 실제로 원본 바이트 그대로 저장되었는지 확인
    saved_filename = Path(data["receipt_path"]).name
    saved_file_path = get_receipts_storage_dir() / saved_filename
    assert saved_file_path.is_file()
    assert saved_file_path.read_bytes() == image_content


def test_upload_receipt_empty_file_returns_400(auth_header, tmp_path, monkeypatch):
    """0바이트 빈 파일 업로드 시 400 Bad Request 반환 검증"""
    monkeypatch.setenv("RECEIPTS_STORAGE_DIR", str(tmp_path / "receipts"))

    files = {"file": ("empty.jpg", io.BytesIO(b""), "image/jpeg")}
    res = client.post("/receipts", files=files, headers=auth_header(Role.TREASURER))

    assert res.status_code == 400
    assert "빈 파일" in res.json()["detail"]


def test_upload_receipt_requires_treasurer_role(auth_header):
    """총무(TREASURER)만 업로드할 수 있으며, 학생/감사/회장은 403, 미인증은 401 반환 검증"""
    files = {"file": ("test.png", io.BytesIO(b"dummy-png-bytes"), "image/png")}

    # 1. 미인증
    assert client.post("/receipts", files=files).status_code == 401

    # 2. 학생 (403)
    files["file"] = ("test.png", io.BytesIO(b"dummy-png-bytes"), "image/png")
    assert client.post("/receipts", files=files, headers=auth_header(Role.STUDENT)).status_code == 403

    # 3. 감사 (403)
    files["file"] = ("test.png", io.BytesIO(b"dummy-png-bytes"), "image/png")
    assert client.post("/receipts", files=files, headers=auth_header(Role.AUDITOR)).status_code == 403


def test_get_receipt_file_success(auth_header, tmp_path, monkeypatch):
    """GET /receipts/{filename}으로 업로드된 영수증 이미지를 다운로드/열람할 수 있다."""
    monkeypatch.setenv("RECEIPTS_STORAGE_DIR", str(tmp_path / "receipts"))

    image_content = b"receipt-content-bytes-12345"
    files = {"file": ("invoice.png", io.BytesIO(image_content), "image/png")}
    res_upload = client.post("/receipts", files=files, headers=auth_header(Role.TREASURER))
    assert res_upload.status_code == 201

    receipt_path = res_upload.json()["receipt_path"]
    filename = Path(receipt_path).name

    res_get = client.get(f"/receipts/{filename}")
    assert res_get.status_code == 200
    assert res_get.content == image_content


def test_get_receipt_file_not_found_returns_404(tmp_path, monkeypatch):
    """존재하지 않는 영수증 파일명 조회 시 404 Not Found 반환"""
    monkeypatch.setenv("RECEIPTS_STORAGE_DIR", str(tmp_path / "receipts"))

    res = client.get("/receipts/non_existent_file.jpg")
    assert res.status_code == 404

