"""revision_requested_at 등 DB 시각 → Unix 초 변환 규칙 (#76 Codex 4차).

SQLite 는 timezone=True 컬럼도 시간대 없는(naive) datetime 으로 돌려준다.
naive 값에 .timestamp() 를 바로 쓰면 서버 로컬 시간대로 해석되어 KST 서버에서는 9시간 이른 값이 된다.
"""
import calendar
from datetime import datetime, timedelta, timezone

from app.routers.entries import _to_unix_seconds_utc


def test_naive_datetime_is_treated_as_utc():
    naive = datetime(2026, 11, 9, 3, 0, 0)
    assert _to_unix_seconds_utc(naive) == calendar.timegm(naive.timetuple())


def test_aware_datetime_keeps_its_offset():
    kst = timezone(timedelta(hours=9))
    aware = datetime(2026, 11, 9, 12, 0, 0, tzinfo=kst)  # = 03:00 UTC
    assert _to_unix_seconds_utc(aware) == calendar.timegm(datetime(2026, 11, 9, 3, 0, 0).timetuple())


def test_none_and_int_passthrough():
    assert _to_unix_seconds_utc(None) is None
    assert _to_unix_seconds_utc(1794193200) == 1794193200
