import hashlib
import logging
import os
from pathlib import Path
import re
from typing import Optional

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile, status
from fastapi.responses import FileResponse

from app.auth import User, require_roles
from app.schemas.auth import Role
from app.schemas.receipt import ReceiptUploadResponse

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/receipts", tags=["Receipts"])

treasurer_only = require_roles(Role.TREASURER)

# 허용 파일 확장자 및 최대 파일 크기 (10MB)
ALLOWED_EXTENSIONS = frozenset({".jpg", ".jpeg", ".png", ".webp", ".pdf"})
MAX_FILE_SIZE = 10 * 1024 * 1024  # 10MB

MEDIA_TYPES = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
    ".pdf": "application/pdf",
}


def get_receipts_storage_dir() -> Path:
    """영수증 파일 저장 디렉터리 반환 (환경변수 RECEIPTS_STORAGE_DIR 또는 uploads/receipts)."""
    env_dir = os.getenv("RECEIPTS_STORAGE_DIR")
    if env_dir:
        p = Path(env_dir)
    else:
        p = Path("uploads/receipts")
    p.mkdir(parents=True, exist_ok=True)
    return p


def find_receipt_file(receipt_hash: Optional[str]) -> Optional[Path]:
    """영수증 해시로 저장소에 존재하는 실제 파일({hash}.*)을 찾는다.
    
    경로 조작(Path Traversal)이나 서버 임의 파일 지정을 방지하기 위해 오직 해시 값으로만 저장소 내 파일을 검색합니다.
    """
    if not receipt_hash:
        return None

    raw_hash = receipt_hash.lower()
    if raw_hash.startswith("0x"):
        raw_hash = raw_hash[2:]

    # 소문자 64자리 16진수 검증
    if not re.fullmatch(r"^[0-9a-f]{64}$", raw_hash):
        return None

    storage_dir = get_receipts_storage_dir()
    for f in storage_dir.glob(f"{raw_hash}.*"):
        if f.is_file() and f.suffix.lower() in ALLOWED_EXTENSIONS:
            return f

    return None


def receipt_file_exists(receipt_hash: Optional[str], receipt_path: Optional[str] = None) -> bool:
    """영수증 파일이 서버 저장소에 실제로 존재하는지 검증한다 (B2: 파일 없는 해시 400 차단용)."""
    return find_receipt_file(receipt_hash) is not None


def resolve_receipt_path(receipt_hash: Optional[str]) -> Optional[str]:
    """해시로 저장소 내 실제 파일을 찾아 서버 표준 영수증 경로(/receipts/{filename})를 반환한다."""
    f = find_receipt_file(receipt_hash)
    if f is not None:
        return f"/receipts/{f.name}"
    return None


@router.post(
    "",
    response_model=ReceiptUploadResponse,
    status_code=status.HTTP_201_CREATED,
    summary="영수증 파일 업로드",
)
@router.post(
    "/",
    response_model=ReceiptUploadResponse,
    status_code=status.HTTP_201_CREATED,
    include_in_schema=False,
)
async def upload_receipt(
    file: UploadFile = File(..., description="영수증 이미지 파일 (JPEG, PNG, WEBP, PDF)"),
    user: User = Depends(treasurer_only),
):
    """총무가 영수증 파일을 업로드하고, 원본 바이트를 보존하여 SHA-256 해시를 산출합니다.
    산출된 receipt_hash와 receipt_path는 이후 지출 등록(POST /entries)에 사용됩니다.
    총무(TREASURER)만 호출할 수 있습니다.
    """
    if not file or not file.filename:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="업로드할 영수증 파일이 지정되지 않았습니다.",
        )

    # 1. 파일 확장자 검증 (jpg, jpeg, png, webp, pdf만 허용)
    ext = os.path.splitext(file.filename)[1].lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"지원하지 않는 파일 형식입니다: '{ext}'. (jpg, jpeg, png, webp, pdf만 허용)",
        )

    content = await file.read()
    if len(content) == 0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="빈 파일은 업로드할 수 없습니다.",
        )

    # 2. 파일 크기 제한 (최대 10MB)
    if len(content) > MAX_FILE_SIZE:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"파일 크기가 너무 큽니다 ({len(content)} bytes). 최대 10MB까지 업로드 가능합니다.",
        )

    # 3. 원본 바이트 보존 SHA-256 해시 계산 (소문자 hex 66자: 0x + 64자)
    raw_hash = hashlib.sha256(content).hexdigest().lower()
    receipt_hash = f"0x{raw_hash}"

    # 4. 파일 저장 (확장자 유지)
    filename = f"{raw_hash}{ext}"
    storage_dir = get_receipts_storage_dir()
    file_path = storage_dir / filename

    # 바이트 무손실 보존 저장
    with open(file_path, "wb") as f:
        f.write(content)

    receipt_path = f"/receipts/{filename}"

    logger.info("영수증 업로드 완료 (user_id=%s, hash=%s, path=%s)", user.id, receipt_hash, receipt_path)

    return ReceiptUploadResponse(
        receipt_hash=receipt_hash,
        receipt_path=receipt_path,
        filename=file.filename,
        size=len(content),
    )


@router.get("/{filename}", summary="영수증 이미지 다운로드/열람")
async def get_receipt_file(filename: str):
    """영수증 이미지 파일을 반환합니다 (모바일 앱 영수증 이미지 열람 S3)."""
    safe_name = os.path.basename(filename)
    ext = os.path.splitext(safe_name)[1].lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"허용되지 않는 파일 형식이거나 찾을 수 없습니다: '{safe_name}'",
        )

    storage_dir = get_receipts_storage_dir()
    file_path = storage_dir / safe_name
    if not file_path.is_file():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"영수증 파일 '{safe_name}'을 찾을 수 없습니다.",
        )

    media_type = MEDIA_TYPES.get(ext, "application/octet-stream")
    return FileResponse(file_path, media_type=media_type)
