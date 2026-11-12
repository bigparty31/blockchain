"""행사 입장 판정에 쓰는 회원권(SBT) 보유 확인.

PRD v0.16 §10: `GET /memberships/me` 와 입장 판정은 같은 확인 함수를 써야 한다. 그 함수가
app/services/membership.py 의 check_membership(db, chain, user_id, term_id) 이고, 기준은 체인(hasValidMembership)이다.
DB Membership 행은 기준이 아니다 — DB 만 보면 서버가 바꿔도 학생·임원이 알아챌 수 없다 (PRD §13).

라우터는 get_membership_checker 의존성으로 받는다 (#68 리뷰). 시험은 이 의존성을 바꿔 끼운다.

규칙
- async (db, user_id, term_id) -> bool
- 확인하지 못하면 MembershipUnavailable 을 던진다. 라우터는 이것을 UNVERIFIABLE(거부 아님)로 돌려준다.
  체인 연결 실패, 노드 지연(MEMBERSHIP_TIMEOUT_SECONDS 초과), 지갑 파생 설정 없음이 모두 여기로 온다.
- 예외 클래스는 공용 것을 그대로 쓴다. 따로 두면 공용 함수가 던진 예외를 라우터가 못 잡아 '판정 불가'가 500 이 된다
"""
import asyncio
import inspect
from typing import Awaitable, Callable

from fastapi import Request
from sqlalchemy.orm import Session

from app.chain import ChainClient, get_chain_client
from app.chain.models import ChainError
from app.services.membership import MembershipUnavailable, check_membership

__all__ = ["MEMBERSHIP_TIMEOUT_SECONDS", "MembershipChecker", "MembershipUnavailable", "get_membership_checker"]

# (db, user_id, term_id) -> 보유 여부. 확인을 못 하면 MembershipUnavailable 을 던진다
MembershipChecker = Callable[[Session, int, int], Awaitable[bool]]

# 체인 연결부터 hasValidMembership 응답까지. 넘으면 UNVERIFIABLE 이다. 앱의 요청 제한(3초)과 같게 둔다 —
# 그대로 두면 RPC 기본 대기(10초) 동안 스캐너가 멈춘다
MEMBERSHIP_TIMEOUT_SECONDS = 3.0


def get_membership_checker(request: Request) -> MembershipChecker:
    """체인 기준 회원권 확인 함수를 돌려준다.

    체인 클라이언트는 의존성(Depends)으로 미리 받지 않고 확인할 때 얻는다. 미리 받으면 노드가 죽었을 때
    회원권을 볼 필요도 없는 스캔(중복 입장·없는 학생)까지 503 이 되고, 판정 결과를 200 + result 로 주는
    입장 API 규칙(docs/API.md 입장 §3)이 깨진다. 시험이 get_chain_client 를 바꿔 끼운 것은 그대로 따른다.
    """
    get_chain = request.app.dependency_overrides.get(get_chain_client, get_chain_client)

    async def check(db: Session, user_id: int, term_id: int) -> bool:
        try:
            return await asyncio.wait_for(_check(get_chain, db, user_id, term_id), timeout=MEMBERSHIP_TIMEOUT_SECONDS)
        except asyncio.TimeoutError as e:
            raise MembershipUnavailable(f"회원권 확인이 {MEMBERSHIP_TIMEOUT_SECONDS:g}초 안에 끝나지 않았다") from e

    return check


async def _check(get_chain: Callable[[], object], db: Session, user_id: int, term_id: int) -> bool:
    try:
        chain: ChainClient = get_chain()  # type: ignore[assignment]
        if inspect.isawaitable(chain):
            chain = await chain
    except ChainError as e:  # ChainSetupError(설정 없음)·ChainUnavailable(노드 무응답)
        raise MembershipUnavailable(f"체인에 연결하지 못했다: {e}") from e
    return await check_membership(db, chain, user_id, term_id)
