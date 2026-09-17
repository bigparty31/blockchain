"""주기 작업 — 대조(reconcile)와 장부 잔액 집계(refresh)를 일정 간격으로 돌린다.

서버 시작 때 백그라운드 태스크로 띄우고, 끝낼 때 stop 을 켠다.

    stop = asyncio.Event()
    task = asyncio.create_task(run_periodically(
        [("등록 대조", registration.reconcile), ("결정 대조", decisions.reconcile), ("잔액 집계", aggregator.refresh)],
        interval_seconds=30, stop=stop,
    ))
    ...
    stop.set(); await task
"""
import asyncio
import logging
from collections.abc import Awaitable, Sequence
from typing import Any, Callable

logger = logging.getLogger(__name__)

PeriodicTask = tuple[str, Callable[[], Awaitable[Any]]]


async def run_periodically(tasks: Sequence[PeriodicTask], *, interval_seconds: float, stop: asyncio.Event) -> None:
    """stop 이 켜질 때까지 tasks 를 차례로 부르고 interval_seconds 만큼 쉰다.

    한 작업이 실패해도 로그만 남기고 다음 작업과 다음 회차를 계속한다. 대조가 한 번 실패했다고 멈추면
    SUBMITTING 이 영영 마무리되지 않기 때문이다.
    """
    while not stop.is_set():
        for name, task in tasks:
            if stop.is_set():
                return
            try:
                await task()
            except Exception:
                logger.exception("주기 작업 실패: %s", name)
        try:
            await asyncio.wait_for(stop.wait(), timeout=interval_seconds)
        except asyncio.TimeoutError:
            pass
