"""학번별 로그인 실패 제한 (PRD v0.15 §9.1, §9.2).

연속 5회 실패하면 15분 동안 그 학번의 로그인을 받지 않는다. 횟수는 DB(`login_attempts`)에 둔다.
서버 메모리에 두면 학생 서버 2대가 횟수를 반씩 나눠 들어 5회 제한이 사실상 10회가 된다 (§9.1).

**시도를 먼저 세고 비밀번호를 나중에 본다.** 횟수를 확인하고 bcrypt(약 0.2초)를 돈 뒤에 실패를 기록하면,
4회째에 동시에 40개를 보낸 요청이 모두 확인을 통과해 40번 검사된다. 그래서 `reserve` 가 한 문장의
UPDATE 로 횟수를 올리고 커밋한 뒤에야 비밀번호를 본다. 증가가 DB 안에서 원자적이라 서버가 몇 대든
한 학번의 비밀번호 검사는 잠금 구간마다 `MAX_FAILURES` 번을 넘지 않는다.

없는 학번도 똑같이 세고 잠근다. 있는 학번만 잠그면 잠기는지로 가입 여부가 드러난다 (§9.2).
"""
import time
from dataclasses import dataclass
from typing import Optional

from sqlalchemy import case, or_, update
from sqlalchemy.orm import Session

from app.models import LoginAttempt

MAX_FAILURES = 5
LOCK_SECONDS = 15 * 60
# 마지막 시도에서 이만큼 지나면 횟수를 처음부터 센다. 몇 주에 걸친 오타 4번이 쌓여 잠기지 않게 한다
RESET_SECONDS = 15 * 60


def now() -> int:
    """현재 시각 (epoch 초). 시험에서 바꿔 끼운다."""
    return int(time.time())


@dataclass(frozen=True)
class Attempt:
    """`reserve` 의 결과. `retry_after` 가 있으면 막힌 것이고, 없으면 비밀번호를 검사해도 된다."""

    student_no: str
    count: int
    retry_after: Optional[int] = None


def _insert_ignore(db: Session, student_no: str, at: int) -> None:
    """행이 없으면 만든다. 동시에 둘이 만들어도 하나만 남는다."""
    dialect = db.get_bind().dialect.name
    if dialect == "postgresql":
        from sqlalchemy.dialects.postgresql import insert
    elif dialect == "sqlite":
        from sqlalchemy.dialects.sqlite import insert
    else:  # pragma: no cover — 운영은 Postgres, 시험은 SQLite 뿐이다
        raise RuntimeError(f"지원하지 않는 DB: {dialect}")
    db.execute(
        insert(LoginAttempt)
        .values(student_no=student_no, failed_count=0, last_attempt_at=at)
        .on_conflict_do_nothing(index_elements=["student_no"])
    )


def reserve(db: Session, student_no: str) -> Attempt:
    """로그인 시도 한 번을 센다. 잠겨 있거나 이번 시도로 한도를 넘으면 `retry_after` 를 채워 돌려준다.

    커밋까지 한다 — bcrypt 를 도는 동안 행을 잡고 있지 않는다.
    """
    at = now()
    _insert_ignore(db, student_no, at)

    t = LoginAttempt
    locked = t.locked_until > at
    # 잠금이 끝났거나 마지막 시도가 오래됐으면 처음부터. locked_until 이 NULL 이면 비교가 NULL 이라 조건이 거짓이 된다
    stale = or_(t.locked_until <= at, t.last_attempt_at <= at - RESET_SECONDS)
    # SET 의 오른쪽은 모두 갱신 전 값을 읽는다 (Postgres·SQLite 공통)
    row = db.execute(
        update(t)
        .where(t.student_no == student_no)
        .values(
            failed_count=case((locked, t.failed_count), (stale, 1), else_=t.failed_count + 1),
            last_attempt_at=case((locked, t.last_attempt_at), else_=at),
            locked_until=case((locked, t.locked_until), (stale, None), else_=t.locked_until),
        )
        .returning(t.failed_count, t.locked_until)
    ).one()
    count, locked_until = row

    if locked_until is not None and locked_until > at:
        db.commit()
        return Attempt(student_no, count, retry_after=locked_until - at)

    if count > MAX_FAILURES:
        # 앞선 시도들이 아직 비밀번호를 검사하는 중이라 잠금이 안 걸린 사이에 들어온 요청이다. 여기서 잠근다
        _lock(db, student_no, at)
        db.commit()
        return Attempt(student_no, count, retry_after=LOCK_SECONDS)

    db.commit()
    return Attempt(student_no, count)


def record_failure(db: Session, attempt: Attempt) -> None:
    """비밀번호가 틀렸다. 횟수는 `reserve` 가 이미 셌으니 한도에 닿았을 때 잠그기만 한다."""
    if attempt.count >= MAX_FAILURES:
        _lock(db, attempt.student_no, now())
    db.commit()


def clear(db: Session, student_no: str) -> None:
    """로그인에 성공했다. 기록을 지워 횟수를 처음으로 돌린다."""
    db.query(LoginAttempt).filter(LoginAttempt.student_no == student_no).delete(synchronize_session=False)
    db.commit()


def _lock(db: Session, student_no: str, at: int) -> None:
    t = LoginAttempt
    db.execute(
        update(t)
        .where(
            t.student_no == student_no,
            # 이미 걸린 잠금은 늘리지 않는다. 잠긴 동안 계속 두드려도 풀리는 시각은 그대로다
            or_(t.locked_until.is_(None), t.locked_until <= at),
            # 지금 행의 횟수로 판단한다. 예약 때 받은 횟수(Attempt.count)는 그사이 성공으로 기록이 지워지고
            # 새로 센 행에는 맞지 않는다 — 성공 뒤 실패 2번에 잠그게 된다 (#89 codex 1차)
            t.failed_count >= MAX_FAILURES,
        )
        .values(locked_until=at + LOCK_SECONDS)
    )
