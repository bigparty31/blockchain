"""영수증 OCR 판정 (PRD §6).

- clova: CLOVA OCR General 호출 (키는 .env)
- parser: CLOVA 응답(JSON)에서 금액·승인번호·결제일시를 좌표 기반으로 뽑는다
- verdict: 뽑은 값과 입력 금액·중복 여부로 MATCH/MISMATCH/DUPLICATE/NO_NUMBER/UNREADABLE 을 정한다
"""
from app.ocr.clova import ClovaOcrClient, OcrClient, OcrUnavailable, get_ocr_client
from app.ocr.parser import ParsedReceipt, parse_clova_response
from app.ocr.verdict import judge

__all__ = [
    "ClovaOcrClient",
    "OcrClient",
    "OcrUnavailable",
    "get_ocr_client",
    "ParsedReceipt",
    "parse_clova_response",
    "judge",
]
