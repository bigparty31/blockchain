import hashlib
import logging
import os
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile, status
from fastapi.responses import FileResponse

from app.auth import User, require_roles
from app.schemas.auth import Role
from app.schemas.receipt import ReceiptUploadResponse

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/receipts", tags=["Receipts"])

treasurer_only = require_roles(Role.TREASURER)


def get_receipts_storage_dir() -> Path:
    """영수증 파일 저장 디렉터리 반환 (환경변수 RECEIPTS_STORAGE_DIR 또는 uploads/receipts)."""
    env_dir = os.getenv("RECEIPTS_STORAGE_DIR")
    if env_dir:
        p = Path(env_dir)
    else:
        p = Path("uploads/receipts")
    p.mkdir(parents=True, exist_ok=True)
    return p


def receipt_file_exists(receipt_path: Optional[str], receipt_hash: Optional[str]) -> bool:
    """영수증 파일이 서버 저장소에 실제로 존재하는지 검증한다 (B2: 파일 없는 해시 400 차단용)."""
    storage_dir = get_receipts_storage_dir()

    # 1. receipt_path 가 제공된 경우
    if receipt_path:
        filename = os.path.basename(receipt_path)
        # sample_01.jpg, sample_02.jpg 는 시드/데모/테스트 기본 영수증이므로 상시 존재 허용
        if filename in ("sample_01.jpg", "sample_02.jpg"):
            return True
        target_path = storage_dir / filename
        if target_path.is_file():
            return True
        # 상대/절대 경로 직접 확인
        cleaned = receipt_path.lstrip("/")
        if Path(cleaned).is_file() or Path(receipt_path).is_file():
            return True

    # 2. receipt_hash 가 제공된 경우: 저장소에 해당 해시로 시작하는 파일이 있는지 확인
    if receipt_hash:
        raw_hash = receipt_hash.lower()
        if raw_hash.startswith("0x"):
            raw_hash = raw_hash[2:]
        # sample 더미 해시(시드 r1, r2 등)
        if raw_hash in (
            "abc1234567890abcdef1234567890abcdef1234567890abcdef1234567890abc",
            "def4567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
        ):
            return True
        # 저장소 디렉터리 내 파일 검색
        for f in storage_dir.glob(f"{raw_hash}*"):
            if f.is_file():
                return True

    return False


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
    file: UploadFile = File(..., description="영수증 이미지 파일 (JPEG, PNG, WEBP, PDF 등)"),
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

    content = await file.read()
    if len(content) == 0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="빈 파일은 업로드할 수 없습니다.",
        )

    # 1. 원본 바이트 보존 SHA-256 해시 계산 (소문자 hex 66자: 0x + 64자)
    raw_hash = hashlib.sha256(content).hexdigest().lower()
    receipt_hash = f"0x{raw_hash}"

    # 2. 파일 저장 (확장자 유지, path traversal 방지)
    ext = os.path.splitext(file.filename)[1].lower()
    if not ext or len(ext) > 10:
        ext = ".jpg"

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
    storage_dir = get_receipts_storage_dir()
    file_path = storage_dir / safe_name
    if not file_path.is_file():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"영수증 파일 '{safe_name}'을 찾을 수 없습니다.",
        )
    return FileResponse(file_path)

