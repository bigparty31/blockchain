from pydantic import BaseModel, Field


class ReceiptUploadResponse(BaseModel):
    """영수증 업로드 성공 응답 스키마"""
    receipt_hash: str = Field(..., description="영수증 원본 SHA-256 해시 (0x로 시작하는 64자리 소문자 16진수)")
    receipt_path: str = Field(..., description="서버에 저장된 영수증 파일 상대 경로 (/receipts/{filename})")
    filename: str = Field(..., description="업로드된 원본 파일명")
    size: int = Field(..., description="파일 크기 (바이트 단위)")

