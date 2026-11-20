"""카드 승인 문자 붙여넣기 어댑터 — PRD v0.15 §4.6 "카드 승인 문자 대조".

총무가 카드사 승인·취소 문자를 붙여넣으면 메시지별로 읽어서 은행 CSV 와 같은 공통 형태(BankRow)로
바꾼다. 그러면 매칭(matcher.match)은 CSV 와 똑같이 쓴다.

- 승인 → 출금(OUT), 취소 → 입금(IN) (PRD: 취소 문자는 환불(입금)로 처리)
- 같은 붙여넣기 안에 승인과 그 취소가 함께 있으면 서로 상쇄된 것으로 보고 대조에서 뺀다.
  원장에도 그 결제는 없거나(등록 전 취소) 전액 환불 정정으로 순금액 0 이라 후보가 아니다.
  빼지 않으면 승인 문자가 '미등록'으로 잘못 잡힌다
- 문자에는 연도가 없다(MM/DD). 학기 기간 안에 들어가는 연도로 정한다
"""
import re
from dataclasses import dataclass
from datetime import date, datetime
from typing import Callable, Dict, List, Optional, Set, Tuple

APPROVAL = "APPROVAL"
CANCEL = "CANCEL"


class CardSmsError(ValueError):
    """메시지 하나를 읽지 못함. 붙여넣기 전체를 거부하지 않고 그 메시지만 '읽지 못함'으로 돌려준다."""


@dataclass(frozen=True)
class CardSms:
    company: str             # NH | KB
    kind: str                # APPROVAL | CANCEL
    month: int
    day: int
    time: Optional[str]      # HH:MM:SS
    merchant: str
    amount: int              # 양의 정수 (원)
    approval_no: Optional[str]


# 카드사별 파서. 메시지 원문 하나를 받아 CardSms 를 돌려주고, 못 읽으면 CardSmsError.
# 실제 문자 형식에 맞춰 채운다 (_PARSERS 아래 parse_nh / parse_kb)
Parser = Callable[[str], CardSms]
_PARSERS: Dict[str, Parser] = {}

# 붙여넣기에서 메시지를 나누는 기준. 문자 앱에서 복사하면 메시지마다 [Web발신] 이 앞에 붙는다
_WEB_SENT = re.compile(r"^\s*\[\s*Web\s*발신\s*\]", re.MULTILINE)


def split_messages(text: str) -> List[str]:
    """붙여넣은 텍스트를 메시지 단위로 나눈다. [Web발신] 이 있으면 그 기준, 없으면 빈 줄 기준."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    starts = [m.start() for m in _WEB_SENT.finditer(text)]
    if starts:
        if text[: starts[0]].strip():  # [Web발신] 앞에 붙은 메시지(머리말 없이 복사된 것)
            starts.insert(0, 0)
        parts = [text[s:e] for s, e in zip(starts, starts[1:] + [len(text)])]
    else:
        parts = re.split(r"\n\s*\n", text)
    return [p.strip() for p in parts if p.strip()]


def detect_company(message: str) -> Optional[str]:
    head = message[:40]
    if "NH" in head or "농협" in head:
        return "NH"
    if "KB" in head or "국민" in head:
        return "KB"
    return None


def parse_message(message: str) -> CardSms:
    company = detect_company(message)
    if company is None:
        raise CardSmsError("카드사를 알 수 없습니다 (NH농협·KB국민만 지원)")
    parser = _PARSERS.get(company)
    if parser is None:
        raise CardSmsError(f"{company} 문자 형식은 아직 지원하지 않습니다")
    return parser(message)


def resolve_date(month: int, day: int, started_at: datetime, ended_at: datetime) -> Optional[str]:
    """MM/DD 에 학기 기간 안에 들어가는 연도를 붙인다. 어느 연도로도 기간 밖이면 None.

    2학기(9월~다음 해 2월처럼 해를 넘기는 학기)도 시작·종료 연도 두 후보를 모두 본다.
    """
    start, end = started_at.date(), ended_at.date()
    for year in sorted({start.year, end.year}):
        try:
            d = date(year, month, day)
        except ValueError:  # 2/30 같은 없는 날짜
            continue
        if start <= d <= end:
            return d.isoformat()
    return None


def pair_cancellations(items: List[Tuple[int, CardSms]], dates: Optional[Dict[int, str]] = None) -> Set[int]:
    """취소와 그 승인을 짝지어, 서로 상쇄된 메시지 번호들을 돌려준다.

    같은 카드사·금액·가맹점이고, 승인번호가 둘 다 있으면 그것도 같아야 한다. 승인 하나는 취소 하나와만 짝.
    [dates] (메시지 번호 → 학기 연도를 붙인 ISO 날짜)를 주면 **취소보다 늦은 승인과는 짝짓지 않는다** —
    3/9 취소가 3/10 승인을 지우면 그 승인이 미등록이어도 대조에서 빠진다 (#135 리뷰).
    짝이 될 수 있는 승인이 여럿이면 취소 직전의 것(가장 늦은 것)을 고른다.
    """

    def when(n: int, s: CardSms) -> Optional[str]:
        return None if dates is None or n not in dates else f"{dates[n]} {s.time}"  # ISO 날짜·시각은 문자열 비교 = 시간 비교

    paired: Set[int] = set()
    approvals = [(n, s) for n, s in items if s.kind == APPROVAL]
    for n, c in items:
        if c.kind != CANCEL:
            continue
        best: Optional[int] = None
        best_at: Optional[str] = None
        for an, a in approvals:
            if an in paired:
                continue
            same_no = a.approval_no is None or c.approval_no is None or a.approval_no == c.approval_no
            if (a.company, a.amount, a.merchant) != (c.company, c.amount, c.merchant) or not same_no:
                continue
            a_at, c_at = when(an, a), when(n, c)
            if a_at is not None and c_at is not None:
                if a_at > c_at:
                    continue
                if best is not None and best_at is not None and a_at <= best_at:
                    continue
                best, best_at = an, a_at
            elif best is None:
                best = an
        if best is not None:
            paired.update((best, n))
    return paired


# ---------------------------------------------------------------- 카드사 파서 (NH농협·KB국민)
#
# 표본 형식 (이름·카드번호는 가려 둔 것):
#   [Web발신]                [Web발신]                 [Web발신]
#   KB국민카드0*0*승인        KB국민체크(0000)           NH카드0*0*취소
#   홍*동                    홍*동님                    홍*동
#   10,000원 일시불           11/19 11:30               10,000원 체크
#   11/19 11:30              10,000원                  11/19 11:35
#   가맹점명                  가맹점명 사용               가맹점명
#   누적100,000원                                       잔액000,000원
#
# 카드사·종류(신용·체크)마다 금액과 날짜 줄의 순서가 달라서 줄 번호로 읽지 않는다.
# 날짜·시각 줄과 금액 줄을 어디에 있든 찾고, **둘 중 뒤에 오는 줄의 다음 줄**을 가맹점으로 읽는다.
# 승인번호는 이 형식들에 없다 — 대조는 CSV 와 같이 방향·금액·날짜로 한다.

_DATETIME_LINE = re.compile(r"^(\d{1,2})/(\d{1,2})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?$")
# 「10,000원」, 「10,000원 일시불」, 「10,000원 체크」, 「10,000원 03개월」
_AMOUNT_LINE = re.compile(r"^([\d,]+)\s*원(?:\s+(?:일시불|체크|\d{1,2}\s*개월))?$")
# 가맹점이 아닌 꼬리 줄 — 누적 사용액·체크카드 잔액
_TAIL_LINE = re.compile(r"^(누적|잔액)")


def _lines(message: str) -> List[str]:
    body = _WEB_SENT.sub("", message, count=1)
    return [ln.strip() for ln in body.split("\n") if ln.strip()]


def _parse_common(company: str, message: str) -> CardSms:
    lines = _lines(message)
    if not lines:
        raise CardSmsError("빈 문자입니다")
    header = lines[0]
    # 신용카드는 첫 줄 끝에 승인·취소가 붙는다. KB 체크는 아래 가맹점 줄에서 다시 본다
    kind = CANCEL if "취소" in header else APPROVAL

    dt_idx = next((i for i, ln in enumerate(lines) if _DATETIME_LINE.match(ln)), None)
    if dt_idx is None:
        raise CardSmsError("날짜·시각(MM/DD HH:MM) 줄을 찾지 못했습니다")
    amt_idx = next((i for i, ln in enumerate(lines) if i != dt_idx and _AMOUNT_LINE.match(ln)), None)
    if amt_idx is None:
        raise CardSmsError("금액(0,000원) 줄을 찾지 못했습니다")

    mo, d, hh, mm, ss = _DATETIME_LINE.match(lines[dt_idx]).groups()
    month, day, hour, minute, second = int(mo), int(d), int(hh), int(mm), int(ss or 0)
    if not (1 <= month <= 12 and 1 <= day <= 31 and hour <= 23 and minute <= 59 and second <= 59):
        raise CardSmsError(f"날짜·시각이 올바르지 않습니다: {lines[dt_idx]!r}")

    digits = _AMOUNT_LINE.match(lines[amt_idx]).group(1).replace(",", "")
    if not digits.isdigit() or int(digits) <= 0:
        raise CardSmsError(f"금액을 읽을 수 없습니다: {lines[amt_idx]!r}")

    rest = [ln for ln in lines[max(dt_idx, amt_idx) + 1:] if not _TAIL_LINE.match(ln)]
    if not rest:
        raise CardSmsError("가맹점 줄을 찾지 못했습니다")
    # KB 체크는 첫 줄에 승인·취소가 없고 가맹점 줄 끝에 붙는다: 「가맹점명 사용」·「가맹점명 취소」 (#135 리뷰)
    if re.search(r"\s취소$", rest[0]):
        kind = CANCEL
    merchant = re.sub(r"\s*(사용|취소)$", "", rest[0]).strip()
    if not merchant:
        raise CardSmsError("가맹점 이름이 비어 있습니다")

    return CardSms(
        company=company,
        kind=kind,
        month=month,
        day=day,
        time=f"{hour:02d}:{minute:02d}:{second:02d}",
        merchant=merchant,
        amount=int(digits),
        approval_no=None,  # 이 형식들에는 승인번호가 없다
    )


def parse_nh(message: str) -> CardSms:
    return _parse_common("NH", message)


def parse_kb(message: str) -> CardSms:
    return _parse_common("KB", message)


_PARSERS["NH"] = parse_nh
_PARSERS["KB"] = parse_kb
