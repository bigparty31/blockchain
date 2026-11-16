"""은행 거래내역 CSV 파서 — docs/BANK_CSV.md §1·§2.

은행마다 컬럼 이름·순서가 달라서, 헤더 이름으로 컬럼을 찾아 공통 형태(BankRow)로 바꾼다.
매칭 로직(matcher.py)은 BankRow 만 보므로, 은행이나 카드 승인 문자가 늘어도 매칭 코드는 그대로다.

- NH농협: 거래일시 한 컬럼 / KB국민: 거래일자 + 거래시각 두 컬럼 — 둘 다 헤더 이름으로 처리된다
- 실제 다운로드 파일은 위쪽에 계좌번호·조회기간 같은 안내 줄이 붙는 경우가 많아, 헤더 줄을 찾아서 시작한다
- 해시는 이 파일에서 하지 않는다. 해시는 원본 바이트 그대로 (docs/HASHING.md §4), 디코딩은 파싱할 때만
"""
import csv
import io
import re
from dataclasses import dataclass
from typing import Dict, List, Optional

MAX_ROWS = 5000
DESCRIPTION_MAX = 100  # BankTransaction.description 컬럼 길이

# 같은 뜻의 헤더 이름들. 은행마다 표현이 다르다 (맡기신금액 = 입금액 등)
_HEADERS = {
    "datetime": ("거래일시",),
    "date": ("거래일자", "거래일"),
    "time": ("거래시각", "거래시간"),
    "description": ("적요", "내용", "거래내용"),
    "out": ("출금액", "찾으신금액", "출금"),
    "in": ("입금액", "맡기신금액", "입금"),
    "balance": ("거래후잔액", "잔액"),
    "branch": ("거래점", "취급점", "거래점명"),
}


class BankCsvError(ValueError):
    """파일을 읽을 수 없거나 형식이 맞지 않음. 메시지는 총무에게 그대로 보여 줄 수 있게 쓴다."""


@dataclass(frozen=True)
class BankRow:
    row_no: int            # 파일에서 몇 번째 거래인지 (1부터). 오류·결과 안내용
    tran_date: str         # YYYY-MM-DD
    tran_time: Optional[str]  # HH:MM:SS
    description: str
    direction: str         # IN | OUT
    amount: int            # 양의 정수 (원)
    balance_after: int


def decode(raw: bytes) -> str:
    """UTF-8 을 먼저, 실패하면 CP949 로 읽는다.

    BANK_CSV.md 초안은 CP949 먼저였지만 순서를 바꿨다. UTF-8 은 규칙이 엄격해서 CP949 파일을 UTF-8 로
    읽으면 거의 항상 실패한다. 반대로 UTF-8 파일을 CP949 로 읽으면 오류 없이 깨진 한글이 나올 수 있다.
    """
    try:
        return raw.decode("utf-8-sig")  # 엑셀이 붙이는 BOM 도 벗긴다
    except UnicodeDecodeError:
        pass
    try:
        return raw.decode("cp949")
    except UnicodeDecodeError:
        raise BankCsvError("파일 인코딩을 읽을 수 없습니다. 은행에서 받은 CSV 원본을 올려 주세요.")


def _find_columns(header: List[str]) -> Optional[Dict[str, int]]:
    names = [h.strip().replace(" ", "") for h in header]
    cols: Dict[str, int] = {}
    for key, aliases in _HEADERS.items():
        for alias in aliases:
            if alias in names:
                cols[key] = names.index(alias)
                break
    has_date = "datetime" in cols or "date" in cols
    if has_date and {"out", "in", "balance"} <= cols.keys():
        return cols
    return None


def _amount(value: str, row_no: int, what: str) -> int:
    v = value.strip().replace(",", "").replace("원", "").replace(" ", "")
    if v in ("", "-"):
        return 0
    if not v.isdigit():
        raise BankCsvError(f"{row_no}번째 거래의 {what}을(를) 숫자로 읽을 수 없습니다: {value!r}")
    return int(v)


_DATE = re.compile(r"(\d{4})[-./]?(\d{2})[-./]?(\d{2})")
_TIME = re.compile(r"(\d{2}):?(\d{2})(?::?(\d{2}))?")


def _date_time(date_part: str, time_part: Optional[str], row_no: int):
    text = date_part.strip()
    m = _DATE.match(text)
    if not m:
        raise BankCsvError(f"{row_no}번째 거래의 날짜를 읽을 수 없습니다: {date_part!r}")
    y, mo, d = m.groups()
    if not (1 <= int(mo) <= 12 and 1 <= int(d) <= 31):
        raise BankCsvError(f"{row_no}번째 거래의 날짜가 올바르지 않습니다: {date_part!r}")
    rest = text[m.end():].strip() if time_part is None else time_part.strip()
    t = None
    if rest:
        tm = _TIME.fullmatch(rest)
        if not tm:
            raise BankCsvError(f"{row_no}번째 거래의 시각을 읽을 수 없습니다: {rest!r}")
        hh, mm, ss = tm.groups()
        t = f"{hh}:{mm}:{ss or '00'}"
    return f"{y}-{mo}-{d}", t


def parse_bank_csv(raw: bytes) -> List[BankRow]:
    text = decode(raw)
    lines = list(csv.reader(io.StringIO(text)))

    cols = None
    start = 0
    for i, line in enumerate(lines[:30]):  # 안내 줄은 보통 몇 줄 안 된다
        cols = _find_columns(line)
        if cols:
            start = i + 1
            break
    if cols is None:
        raise BankCsvError("거래내역 헤더(거래일시·출금액·입금액·거래후잔액)를 찾을 수 없습니다.")

    def cell(line: List[str], key: str) -> str:
        idx = cols.get(key)
        return line[idx] if idx is not None and idx < len(line) else ""

    rows: List[BankRow] = []
    for line in lines[start:]:
        date_cell = cell(line, "datetime") or cell(line, "date")
        if not date_cell.strip():
            continue  # 빈 줄, 합계 줄 등
        row_no = len(rows) + 1
        if row_no > MAX_ROWS:
            raise BankCsvError(f"거래가 {MAX_ROWS}건을 넘습니다. 기간을 나눠 올려 주세요.")

        if "datetime" in cols:
            tran_date, tran_time = _date_time(date_cell, None, row_no)
        else:
            tran_date, tran_time = _date_time(date_cell, cell(line, "time"), row_no)

        out_amt = _amount(cell(line, "out"), row_no, "출금액")
        in_amt = _amount(cell(line, "in"), row_no, "입금액")
        if (out_amt > 0) == (in_amt > 0):
            raise BankCsvError(f"{row_no}번째 거래는 출금액과 입금액 중 하나만 있어야 합니다.")

        desc = " ".join(p for p in (cell(line, "description").strip(), cell(line, "branch").strip()) if p)
        rows.append(BankRow(
            row_no=row_no,
            tran_date=tran_date,
            tran_time=tran_time,
            description=desc[:DESCRIPTION_MAX],
            direction="OUT" if out_amt else "IN",
            amount=out_amt or in_amt,
            balance_after=_amount(cell(line, "balance"), row_no, "거래후잔액"),
        ))

    if not rows:
        raise BankCsvError("거래내역이 한 건도 없습니다.")
    return rows
