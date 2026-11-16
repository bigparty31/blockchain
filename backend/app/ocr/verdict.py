"""OCR 판정 — 상태 하나를 고른다 (PRD §6). 차단이 아니라 경고라서 어떤 결과든 등록은 계속된다.

상태가 여러 개 해당할 때의 우선순위:
  UNREADABLE > DUPLICATE > MISMATCH > NO_NUMBER > MATCH
- 못 읽은 값으로는 일치·중복을 말할 수 없으니 UNREADABLE 이 먼저
- 중복 청구가 금액 차이보다 무거운 부정이라 DUPLICATE 가 MISMATCH 보다 먼저 (기존 건 링크도 같이 보여줌)
- NO_NUMBER 는 계좌이체처럼 승인번호가 원래 없는 정상 건이라, 금액이 틀리면 MISMATCH 가 이긴다
"""
from typing import Optional

from app.ocr.parser import ParsedReceipt
from app.schemas.entry import OCRStatus


def judge(parsed: ParsedReceipt, input_amount: int, duplicate_of: Optional[int] = None) -> OCRStatus:
    """duplicate_of: 승인번호+결제일시+금액이 같은 기존 내역 ID (호출하는 쪽이 DB 에서 찾아 넘긴다)."""
    if not parsed.readable or parsed.amount is None or parsed.low_confidence:
        return OCRStatus.UNREADABLE
    # 라벨은 있는데 숫자를 못 읽음 = 자릿수 미달 (PRD §6 UNREADABLE 조건)
    if parsed.approval_label_found and parsed.approval_no is None:
        return OCRStatus.UNREADABLE
    if duplicate_of is not None:
        return OCRStatus.DUPLICATE
    if parsed.amount != input_amount:
        return OCRStatus.MISMATCH
    if parsed.approval_no is None:
        return OCRStatus.NO_NUMBER
    return OCRStatus.MATCH
