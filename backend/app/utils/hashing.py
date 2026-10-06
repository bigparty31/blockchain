import hashlib
import re
import unicodedata
from typing import Optional

US = "\x1f"  # U+001F (Unit Separator)
TRIM = " "   # U+0020 만 제거
TRIM_TEXT = " \t\n"  # U+0020, U+0009, U+000A

# 금지 문자: 제어문자 U+0000 ~ U+001F, NBSP(U+00A0), ZWSP(U+200B), 전각공백(U+3000), BOM(U+FEFF)
_DISALLOWED_PATTERN = re.compile(r"[\x00-\x1f\u00a0\u200b\u3000\ufeff]")


def validate_text_for_hash(s: str, field_name: str) -> None:
    """단일 줄 텍스트(counterparty, purpose)의 금지 제어문자 및 공백류 검사 (docs/HASHING.md §1.1, §5)"""
    if _DISALLOWED_PATTERN.search(s):
        raise ValueError(f"{field_name}에 허용되지 않는 제어문자 또는 공백 문자가 포함되어 있습니다.")


def canonical(s: str) -> str:
    """단일 줄 텍스트 앞뒤 U+0020 제거 및 NFC 정규화 (docs/HASHING.md §1.1)"""
    return unicodedata.normalize("NFC", s.strip(TRIM))


def _int(v, field: str) -> str:
    """정수만 받는다. ORM이 Decimal·datetime을 넘겨도 조용히 통과하지 않게 방어."""
    if isinstance(v, bool) or not isinstance(v, int):
        raise TypeError(f"{field}: int 여야 한다 (받은 타입 {type(v).__name__})")
    return str(v)


def calculate_meta_hash(
    amount: int,
    counterparty: str,
    purpose: str,
    occurred_at: int,
    receipt_hash: Optional[str] = None,
) -> str:
    """docs/HASHING.md §1 규격의 meta_hash 계산. 결과는 0x + 64자 소문자 hex."""
    pre = US.join([
        _int(amount, "amount"),
        counterparty,
        purpose,
        _int(occurred_at, "occurred_at"),
        receipt_hash or "",
    ])
    return "0x" + hashlib.sha256(pre.encode("utf-8")).hexdigest()


def canonical_text(s: str) -> str:
    """여러 줄 텍스트용 (사유 등). 개행을 LF로 통일하고 앞뒤 공백·탭·개행 제거 (docs/HASHING.md §3)"""
    s = s.replace("\r\n", "\n").replace("\r", "\n")
    return unicodedata.normalize("NFC", s.strip(TRIM_TEXT))


def text_hash(text: str) -> str:
    """정본화된 여러 줄 텍스트의 SHA-256 해시 (docs/HASHING.md §3)"""
    return "0x" + hashlib.sha256(text.encode("utf-8")).hexdigest()
