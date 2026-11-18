"""영수증 판독 기록 — 판독값을 사진 해시로 저장하고, 등록 때 꺼내 서버가 다시 판정한다 (PRD §6, #36 리뷰).

앱이 보낸 ocr_* 를 그대로 믿으면 MISMATCH 를 MATCH 로 바꿔 보내 승인 때의 경고 사유를 건너뛸 수 있다.
그래서 판독은 서버가 한 것만 쓴다: /ocr/receipt 가 저장하고, /entries 가 receipt_hash 로 찾는다.
"""
import hashlib
from typing import Optional

from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.models import OcrReading
from app.ocr.parser import ParsedReceipt


def receipt_hash_of(image: bytes) -> str:
    """영수증 업로드(POST /receipts)와 같은 규칙 — 0x + SHA-256 소문자 hex. 같은 사진이면 등록의 receipt_hash 와 같다."""
    return "0x" + hashlib.sha256(image).hexdigest().lower()


def is_confident(parsed: ParsedReceipt) -> bool:
    """판독값으로 일치·중복을 말할 수 있는가 (judge 의 UNREADABLE 조건의 반대). 아니면 승인번호·결제시각을 중복 비교에 쓰지 않는다."""
    if not parsed.readable or parsed.amount is None or parsed.low_confidence:
        return False
    return not (parsed.approval_label_found and parsed.approval_no is None)


def save_reading(db: Session, receipt_hash: str, parsed: ParsedReceipt, user_id: int) -> None:
    """판독값을 저장한다. 같은 사진은 최신 판독으로 덮어쓴다. 커밋은 여기서 한다."""
    values = dict(
        readable=parsed.readable,
        amount=parsed.amount,
        approval_no=parsed.approval_no,
        paid_at=parsed.paid_at,
        approval_label_found=parsed.approval_label_found,
        low_confidence=parsed.low_confidence,
        read_by=user_id,
    )
    for attempt in range(2):
        row = db.get(OcrReading, receipt_hash)
        if row is None:
            db.add(OcrReading(receipt_hash=receipt_hash, **values))
        else:
            for k, v in values.items():
                setattr(row, k, v)
        try:
            db.commit()
            return
        except IntegrityError:
            # 같은 사진을 동시에 처음 읽었다 — 먼저 들어간 행을 다시 읽어 덮어쓴다
            db.rollback()
            if attempt:
                raise


def load_reading(db: Session, receipt_hash: Optional[str]) -> Optional[ParsedReceipt]:
    """저장된 판독값. 서버가 이 사진을 읽은 적이 없으면 None."""
    if not receipt_hash:
        return None
    row = db.get(OcrReading, receipt_hash.lower())
    if row is None:
        return None
    return ParsedReceipt(
        amount=row.amount,
        approval_no=row.approval_no,
        paid_at=row.paid_at,
        approval_label_found=row.approval_label_found,
        low_confidence=row.low_confidence,
        readable=row.readable,
    )
