"""CLOVA OCR General 응답에서 금액·승인번호·결제일시를 뽑는다 (docs/OCR.md).

CLOVA General 은 "승인번호: 39007018" 을 이름표 붙은 필드로 주지 않고, 글자 덩어리(field)마다 좌표만 준다.
그래서 ① 좌표로 같은 줄끼리 묶고 ② 줄에서 라벨을 찾은 뒤 ③ 라벨 오른쪽에 있는 값을 집는다.
CLOVA 의 lineBreak 는 열 순서가 섞여 나와(샘플의 "HANA" 등) 믿지 않고 y 좌표로 줄을 다시 만든다.
"""
import re
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import List, Optional, Sequence

KST = timezone(timedelta(hours=9))

# 이 값보다 신뢰도가 낮은 글자로 금액·승인번호를 읽었으면 판독 불가로 본다.
# 실측: 금액·승인번호 숫자는 0.998 이상, 흐린 글자(카드회사 "003")가 0.69
MIN_CONFIDENCE = 0.85

# 우선순위 순. 앞의 라벨이 있으면 뒤의 라벨은 보지 않는다 (합계보다 실제 결제금액이 정확)
AMOUNT_LABELS = ("결제금액", "받을금액", "승인금액", "합계금액", "총결제금액", "합계", "총구매액", "총액")
APPROVAL_LABELS = ("승인번호",)
APPROVAL_NO_DIGITS = (6, 12)  # 카드 승인번호 자릿수 범위. 벗어나면 자릿수 미달/초과로 판독 불가

_AMOUNT_RE = re.compile(r"^\d{1,3}(,\d{3})+원?$|^\d+원?$")
_DATE_RE = re.compile(r"(20\d{2})[-./](\d{1,2})[-./](\d{1,2})")
_TIME_RE = re.compile(r"(?<!\d)([01]?\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?(?!\d)")


@dataclass
class Token:
    text: str
    x0: float
    x1: float
    y0: float
    y1: float
    confidence: float

    @property
    def cy(self) -> float:
        return (self.y0 + self.y1) / 2

    @property
    def height(self) -> float:
        return self.y1 - self.y0


@dataclass
class ParsedReceipt:
    amount: Optional[int] = None
    approval_no: Optional[str] = None
    paid_at: Optional[int] = None  # Unix 초 (KST 로 읽은 영수증 시각)
    approval_label_found: bool = False  # 라벨은 있는데 값을 못 읽으면 NO_NUMBER 가 아니라 UNREADABLE
    low_confidence: bool = False  # 금액·승인번호를 흐린 글자로 읽었음
    readable: bool = True  # CLOVA 가 이미지 자체를 실패(inferResult != SUCCESS)
    notes: List[str] = field(default_factory=list)  # 왜 이렇게 판정했는지 (디버깅·로그용)


def _tokens(image: dict) -> List[Token]:
    out = []
    for f in image.get("fields", []):
        v = f.get("boundingPoly", {}).get("vertices", [])
        xs = [p.get("x", 0) for p in v]
        ys = [p.get("y", 0) for p in v]
        if not xs or not ys:
            continue
        out.append(Token(f.get("inferText", ""), min(xs), max(xs), min(ys), max(ys), f.get("inferConfidence", 0.0)))
    return out


def _group_lines(tokens: Sequence[Token]) -> List[List[Token]]:
    """세로 중심이 가까운 글자끼리 한 줄로 묶고, 줄 안은 왼쪽→오른쪽으로 정렬한다."""
    lines: List[List[Token]] = []
    for t in sorted(tokens, key=lambda t: t.cy):
        if lines:
            last = lines[-1]
            ref = sum(x.cy for x in last) / len(last)
            if abs(t.cy - ref) <= max(t.height, 1) / 2:
                last.append(t)
                continue
        lines.append([t])
    return [sorted(line, key=lambda t: t.x0) for line in lines]


def _hangul_only(text: str) -> str:
    return re.sub(r"[^가-힣]", "", text)


def _find_label(line: List[Token], label: str) -> Optional[int]:
    """줄에서 label 이 끝나는 글자의 인덱스. "*결제" "금액" 처럼 쪼개진 라벨도 이어 붙여 찾는다."""
    joined = ""
    for i, t in enumerate(line):
        joined += _hangul_only(t.text)
        if joined.endswith(label) or label in joined:
            return i
    return None


def _to_amount(text: str) -> Optional[int]:
    s = text.strip()
    if not _AMOUNT_RE.match(s):
        return None
    return int(s.replace(",", "").replace("원", ""))


def _extract_amount(lines: List[List[Token]], result: ParsedReceipt) -> None:
    for label in AMOUNT_LABELS:
        for line in lines:
            idx = _find_label(line, label)
            if idx is None:
                continue
            # 라벨 오른쪽에서 금액 모양인 것 중 가장 오른쪽 (영수증은 금액이 오른쪽 끝에 정렬됨)
            for t in reversed(line[idx + 1:]):
                value = _to_amount(t.text)
                if value is not None:
                    result.amount = value
                    if t.confidence < MIN_CONFIDENCE:
                        result.low_confidence = True
                    result.notes.append(f"금액: '{label}' 줄에서 {value}")
                    return


def _extract_approval_no(lines: List[List[Token]], result: ParsedReceipt) -> None:
    for line in lines:
        for label in APPROVAL_LABELS:
            idx = _find_label(line, label)
            if idx is None:
                continue
            result.approval_label_found = True
            # 라벨 바로 오른쪽 글자 (가장 가까운 것). 라벨과 값이 한 덩어리("승인번호:39007018")인 경우도 처리
            candidates = [line[idx]] + line[idx + 1:]
            for t in candidates:
                digits = re.sub(r"\D", "", t.text)
                if not digits:
                    continue
                lo, hi = APPROVAL_NO_DIGITS
                if lo <= len(digits) <= hi:
                    result.approval_no = digits
                    if t.confidence < MIN_CONFIDENCE:
                        result.low_confidence = True
                    result.notes.append(f"승인번호: {digits}")
                else:
                    result.notes.append(f"승인번호 자릿수 이상: '{t.text}'")
                return
            result.notes.append("승인번호 라벨은 있으나 값 없음")
            return


def _extract_paid_at(lines: List[List[Token]], result: ParsedReceipt) -> None:
    """날짜는 라벨 없이 찍히는 경우가 많아(CU: "2026-09-18(금)") 모양으로 찾는다. 시각은 같은 줄을 먼저 본다."""
    date_line, date = None, None
    for i, line in enumerate(lines):
        m = _DATE_RE.search(" ".join(t.text for t in line))
        if m:
            date_line, date = i, m
            break
    if date is None:
        return

    def find_time(line: List[Token]):
        text = " ".join(t.text for t in line)
        text = _DATE_RE.sub("", text)  # 날짜 숫자가 시각으로 잘못 잡히지 않게
        return _TIME_RE.search(text)

    time = find_time(lines[date_line])
    if time is None:
        for line in lines:
            time = find_time(line)
            if time:
                break

    y, mo, d = (int(x) for x in date.groups())
    h, mi, s = (int(time.group(1)), int(time.group(2)), int(time.group(3) or 0)) if time else (0, 0, 0)
    try:
        dt = datetime(y, mo, d, h, mi, s, tzinfo=KST)
    except ValueError:
        result.notes.append(f"날짜 형식 이상: {date.group(0)}")
        return
    result.paid_at = int(dt.timestamp())
    if time is None:
        result.notes.append("결제 시각 없음 — 날짜 자정으로 저장")


def parse_clova_response(response: dict) -> ParsedReceipt:
    """CLOVA General 응답 전체(dict)를 받아 첫 번째 이미지를 해석한다."""
    result = ParsedReceipt()
    images = response.get("images") or []
    if not images or images[0].get("inferResult") != "SUCCESS":
        result.readable = False
        result.notes.append("CLOVA 판독 실패")
        return result

    lines = _group_lines(_tokens(images[0]))
    _extract_amount(lines, result)
    _extract_approval_no(lines, result)
    _extract_paid_at(lines, result)
    return result
