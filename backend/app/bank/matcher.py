"""은행 거래 ↔ 원장 1:1 매칭 — docs/BANK_CSV.md 부록 "매칭 시 상태별 후보 처리".

DB 를 모르는 순수 함수라 규칙만 따로 테스트할 수 있다. 후보를 고르는 일(상태 필터, 정정 반영)은
라우터가 하고, 여기서는 "어느 은행 거래가 어느 원장 항목과 짝인가"만 정한다.

규칙
- 방향(IN=수입, OUT=지출)·금액·날짜가 모두 같아야 짝이다
- 짝이 된 원장 항목은 후보에서 빠진다(소모). 같은 날 같은 금액이 두 번이면 원장도 두 건 있어야 둘 다 맞는다
- 확정(CONFIRMED) 후보를 승인 대기(PENDING)보다 먼저 쓴다. 대기 건은 짝이 돼도 '확정 전'으로 표시한다
"""
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple

from app.bank.parser import BankRow


@dataclass(frozen=True)
class Candidate:
    entry_id: int
    direction: str   # IN | OUT (원장 kind 를 은행 방향으로 바꾼 값)
    amount: int      # 정정을 반영한 순금액
    date: str        # YYYY-MM-DD (KST)
    confirmed: bool  # CONFIRMED 면 True, PENDING 이면 False


def match(rows: Sequence[BankRow], candidates: Sequence[Candidate]) -> List[Optional[Candidate]]:
    """rows 와 같은 순서로, 각 은행 거래의 짝 후보(없으면 None)를 돌려준다."""
    pool: Dict[Tuple[str, int, str], List[Candidate]] = {}
    # 확정 먼저, 같은 상태면 먼저 등록된 것부터
    for c in sorted(candidates, key=lambda c: (not c.confirmed, c.entry_id)):
        pool.setdefault((c.direction, c.amount, c.date), []).append(c)

    result: List[Optional[Candidate]] = []
    for row in rows:
        bucket = pool.get((row.direction, row.amount, row.tran_date))
        result.append(bucket.pop(0) if bucket else None)
    return result
