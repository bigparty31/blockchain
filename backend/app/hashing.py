"""해시 계산과 해시에 들어가는 입력 검사. 규칙의 정본은 docs/HASHING.md (규칙 v1) 이고, 테스트는 docs/hashing_vectors.json 을 읽는다.

저장 시점에 prepare_field / prepare_text 로 한 번만 다듬어 DB 에 넣고, 이후 해시는 그 정본 값으로 계산한다.
"""
import hashlib
import re
import unicodedata
from datetime import date, datetime, timedelta, timezone
from typing import Optional

HASH_RULE_VERSION = 1
ZERO_BYTES32 = "0x" + "0" * 64

US = "\x1f"  # 구분자 U+001F. 파이프가 아니다 (§1)
TRIM = " "  # meta_hash 텍스트 필드는 U+0020 만 지운다 (§1.1)
TRIM_TEXT = " \t\n"  # 여러 줄 텍스트는 U+0020·U+0009·U+000A 를 지운다 (§3)
KST = timezone(timedelta(hours=9))  # 서머타임이 없어 고정 오프셋으로 충분하다. Windows 에 tz 데이터가 없어도 된다

_INVISIBLE = "\u00a0\u200b\u3000\ufeff"  # NBSP, ZWSP, 전각공백, BOM (§1.1)
_FIELD_REJECT = re.compile(f"[\x00-\x1f{_INVISIBLE}]")
_TEXT_REJECT = re.compile(f"[\x00-\x08\x0b-\x1f{_INVISIBLE}]")  # 탭·LF 만 허용 (§3)
_LOWER_BYTES32 = re.compile(r"0x[0-9a-f]{64}")
KST_MIDNIGHT_REMAINDER = 54000  # KST 00:00 = UTC 15:00 → Unix 초 % 86400 (§1.3)


# ---------------------------------------------------------------- 정본 문자열


def canonical(s: str) -> str:
    """meta_hash 텍스트 필드(상호·목적)의 정본. 앞뒤 U+0020 만 지우고 NFC (§1.1)."""
    return unicodedata.normalize("NFC", s.strip(TRIM))


def canonical_text(s: str) -> str:
    """여러 줄 텍스트(사유·이의 본문)의 정본. 개행을 LF 로, 앞뒤 공백·탭·개행 제거, NFC (§3)."""
    s = s.replace("\r\n", "\n").replace("\r", "\n")
    return unicodedata.normalize("NFC", s.strip(TRIM_TEXT))


def prepare_field(value: str, field: str) -> str:
    """상호·목적을 저장 전에 검사하고 정본으로 만든다. 제어문자·보이지 않는 공백·빈 값이면 ValueError (§5)."""
    bad = _FIELD_REJECT.search(value)
    if bad:
        raise ValueError(f"{field}: 허용하지 않는 문자 U+{ord(bad.group()):04X}")
    result = canonical(value)
    if not result:
        raise ValueError(f"{field}: 비어 있다")
    return result


def prepare_text(value: Optional[str], field: str, *, required: bool) -> Optional[str]:
    """사유·이의 본문을 저장 전에 검사하고 정본으로 만든다. 다듬은 뒤 비면 None, required 면 ValueError (§3, §5).

    순서를 지킨다 — 개행 통일을 제어문자 검사보다 먼저 해야 CR 이 섞인 정상 입력이 거부되지 않는다.
    """
    if value is not None:
        value = value.replace("\r\n", "\n").replace("\r", "\n")
        bad = _TEXT_REJECT.search(value)
        if bad:
            raise ValueError(f"{field}: 허용하지 않는 문자 U+{ord(bad.group()):04X}")
        value = canonical_text(value) or None
    if value is None and required:
        raise ValueError(f"{field}: 필수다")
    return value


# ---------------------------------------------------------------- 해시


def _int(v: object, field: str) -> str:
    """정수만 받는다. ORM 이 Decimal·datetime 을 넘겨도 조용히 다른 preimage 가 되지 않게 한다 (§6)."""
    if isinstance(v, bool) or not isinstance(v, int):
        raise TypeError(f"{field}: int 여야 한다 (받은 타입 {type(v).__name__})")
    return str(v)


def meta_preimage(amount: int, counterparty: str, purpose: str, occurred_at: int, receipt_hash: Optional[str]) -> bytes:
    return US.join(
        [_int(amount, "amount"), counterparty, purpose, _int(occurred_at, "occurred_at"), receipt_hash or ""]
    ).encode("utf-8")


def meta_hash(amount: int, counterparty: str, purpose: str, occurred_at: int, receipt_hash: Optional[str]) -> str:
    """counterparty·purpose 는 이미 정본 값이어야 한다. 여기서 다시 다듬지 않는다."""
    return "0x" + hashlib.sha256(meta_preimage(amount, counterparty, purpose, occurred_at, receipt_hash)).hexdigest()


def text_hash(text: str) -> str:
    """text 는 canonical_text 를 거친 정본 값이어야 한다."""
    return "0x" + hashlib.sha256(text.encode("utf-8")).hexdigest()


def reason_hash(text: Optional[str]) -> str:
    """사유가 없으면 bytes32(0). 빈 문자열을 해시하지 않는다 (§3)."""
    return text_hash(text) if text else ZERO_BYTES32


def file_hash(data: bytes) -> str:
    """파일은 바이트 그대로 (§4)."""
    return "0x" + hashlib.sha256(data).hexdigest()


# ---------------------------------------------------------------- 값 검사


def kst_midnight(day: date) -> int:
    """사용일을 KST 자정 Unix 초로 (§1.3)."""
    return int(datetime(day.year, day.month, day.day, tzinfo=KST).timestamp())


def check_occurred_at(ts: int) -> int:
    """사용일의 KST 자정 Unix 초인지 (§1.3). 음수는 % 연산으로 자정처럼 보일 수 있어 따로 막는다 (-32400 % 86400 == 54000)."""
    if ts < 0 or ts % 86400 != KST_MIDNIGHT_REMAINDER:
        raise ValueError("occurred_at: 사용일의 KST 자정이어야 한다 (HASHING §1.3)")
    return ts


def check_bytes32(value: str, field: str = "해시") -> str:
    """0x + 소문자 hex 64자 (§5). 대문자를 고쳐 주지 않는다 — 앱이 서명한 해시와 값이 갈린다 (§4)."""
    if not _LOWER_BYTES32.fullmatch(value):
        raise ValueError(f"{field}: 0x + 소문자 hex 64자여야 한다 (docs/HASHING.md §5)")
    return value


def check_receipt_hash(value: Optional[str]) -> Optional[str]:
    """check_bytes32 와 같고 None(영수증 없음)을 받는다."""
    return None if value is None else check_bytes32(value, "receipt_hash")
