from typing import Literal, Optional

from pydantic import BaseModel, Field

from app.schemas.entry import OCRStatus


class OcrRequest(BaseModel):
    image_base64: str = Field(..., description="영수증 이미지 바이트를 base64 로 인코딩한 값")
    format: Literal["jpg", "jpeg", "png"] = Field(..., description="이미지 형식")
    amount: int = Field(..., gt=0, description="총무가 입력한 금액 (원 단위 정수)")


class OcrResult(BaseModel):
    """PRD §6 응답 형태 + 등록(POST /entries)에 그대로 넘길 판독값."""

    ocr_status: OCRStatus = Field(..., description="판정 결과")
    ocr_amount: Optional[int] = Field(None, description="OCR 판독 금액")
    input_amount: int = Field(..., description="총무가 입력한 금액")
    duplicate_of: Optional[int] = Field(None, description="같은 승인번호·결제일시·금액으로 이미 올라간 내역 ID")
    ocr_approval_no: Optional[str] = Field(None, description="OCR 판독 카드 승인번호")
    ocr_paid_at: Optional[int] = Field(None, description="OCR 판독 결제 일시 (Unix 초)")
