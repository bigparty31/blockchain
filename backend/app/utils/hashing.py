"""해시 및 텍스트 정규화 유틸리티.

docs/HASHING.md 규격을 엄격히 준수한다.
규칙 버전: v1
- meta_hash: SHA-256( amount ␟ counterparty ␟ purpose ␟ occurred_at ␟ receipt_hash )
- 텍스트 정규화: canonical (단일 라인), canonical_text (여러 줄 사유 등)
"""
import hashlib
import re
import unicodedata
from typing import Optional

UNIT_SEPARATOR = "\x1f"
ZERO_BYTES32 = "0x" + "0" * 64

# 금지 제어문자 (U+0000 ~ U+001F) 및 보이지 않는 공백류
_FORBIDDEN_CONTROL_CHARS = re.compile(r"[\x00-\x1f\u00a0\u200b\u3000\ufeff]")

# 여러 줄 텍스트에서 허용되는 제어문자는 \t (U+0009)와 \n (U+000A)뿐임
_FORBIDDEN_MULTILINE_CONTROL_CHARS = re.compile(r"[\x00-\x08\x0b-\x1f\u00a0\u200b\u3000\ufeff]")


def validate_canonical_input(text: str) -> None:
    """1차 입력 검증: 보이지 않는 문자 또는 제어문자 거부 (docs/HASHING.md §1.1).
    
    제어문자 U+0000 ~ U+001F (탭 U+0009 포함) 및 U+00A0, U+200B, U+3000, U+FEFF 거부.
    """
    if _FORBIDDEN_CONTROL_CHARS.search(text):
        raise ValueError("보이지 않는 문자 또는 제어문자가 포함되어 있습니다.")


def canonical(text: str) -> str:
    """단일 라인 문자열 정본화 (docs/HASHING.md §1.1).
    
    1. 앞뒤의 U+0020(공백)만 제거 (strip(' '))
    2. NFC 정규화
    (BOM, NBSP 등은 1차 검증에서 걸러지나, canonical 자체는 U+0020 외 다른 문자를 임의로 trim하지 않음)
    """
    trimmed = text.strip(" ")
    normalized = unicodedata.normalize("NFC", trimmed)
    return normalized


def validate_multiline_input(text: str) -> str:
    """여러 줄 텍스트 1차 검증: CRLF/CR -> LF 변환 및 제어문자 검사 (docs/HASHING.md §3)."""
    converted = text.replace("\r\n", "\n").replace("\r", "\n")
    if _FORBIDDEN_MULTILINE_CONTROL_CHARS.search(converted):
        raise ValueError("허용되지 않는 제어문자 또는 보이지 않는 공백이 포함되어 있습니다.")
    return converted


def canonical_text(text: str) -> str:
    """여러 줄 텍스트 정본화 (docs/HASHING.md §3).
    
    1. CRLF · CR -> LF 변환
    2. 제어문자 검사 (U+0009, U+000A 외 거부)
    3. 앞뒤 trim (U+0020, U+0009, U+000A)
    4. NFC 정규화
    """
    converted = validate_multiline_input(text)
    trimmed = converted.strip(" \t\n")
    return unicodedata.normalize("NFC", trimmed)


def calculate_meta_hash(
    amount: int,
    counterparty: str,
    purpose: str,
    occurred_at: int,
    receipt_hash: Optional[str] = None,
) -> str:
    """meta_hash 계산 (docs/HASHING.md §1).
    
    식: SHA256( amount ␟ counterparty ␟ purpose ␟ occurred_at ␟ receipt_hash )
    - receipt_hash가 None이면 빈 문자열
    - 구분자는 U+001F
    - 반환: 0x + 64자리 소문자 hex
    """
    receipt_val = receipt_hash.lower() if receipt_hash else ""
    preimage = f"{amount}{UNIT_SEPARATOR}{counterparty}{UNIT_SEPARATOR}{purpose}{UNIT_SEPARATOR}{occurred_at}{UNIT_SEPARATOR}{receipt_val}"
    digest = hashlib.sha256(preimage.encode("utf-8")).hexdigest()
    return f"0x{digest}"


def calculate_text_hash(text: Optional[str]) -> str:
    """사유 등 단일 텍스트의 SHA-256 해시 (docs/HASHING.md §3).
    
    빈 값이거나 None이면 bytes32(0)인 0x000...000 반환.
    """
    if not text:
        return ZERO_BYTES32
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    return f"0x{digest}"


def calculate_file_hash(content: bytes) -> str:
    """파일 바이트 원본 SHA-256 해시 (docs/HASHING.md §4)."""
    digest = hashlib.sha256(content).hexdigest()
    return f"0x{digest}"
