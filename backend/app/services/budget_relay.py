"""예산 발행·증액을 체인에 보내고 결과를 나눈다. 예산 API 가 부른다.

경계 (김경윤과 합의): 예산·증액 API 가 서명자 대조(ChainClient.signer_of)·권한·DB 저장을 맡고, 이 모듈은 체인에 보내는 일만 한다.
DB 를 읽지도 쓰지도 않는다. 결과의 hash·version 을 Budget.tx_issue·BudgetVersion·tx_increase 에 남기는 것은 부른 쪽이다.
사유 원문과 서명된 해시의 대조는 확정·반려와 같은 규칙이라 여기서 한다.

항목별 결과는 앱의 BudgetIssueStatus(app/lib/services/budget_issuer.dart)와 맞춘다. 발행은 한 줄이 트랜잭션 하나라 일부만 성공할 수
있어서, 체인·릴레이어 쪽 실패를 예외가 아니라 결과로 돌려준다 — 한 줄이 실패해도 앞줄 결과를 잃지 않고 다음 줄을 계속 보낼 수 있다.

    ISSUED          체인에 기록됐다
    ALREADY_ISSUED  같은 학기·항목의 예산이 이미 있다. 앞서 응답을 잃은 시도가 사실은 성공했을 때도 여기로 온다.
                    existing 이 체인의 그 예산이다. existing.id 가 요청과 다르면 DB 의 id 가 체인과 어긋난 것이고,
                    금액도 서명과 다를 수 있다 — 서명한 값이 아니라 existing 을 믿는다
    INCREASED       증액이 기록됐다
    REJECTED        들어가지 않았다. reason 은 Solidity 에러 이름, 해석할 수 없으면 "Unknown", 보내기 전 검사면 아래 두 값이다
    NO_RESPONSE     결과를 모른다. 고쳐서 보내면 안 된다. 같은 값으로 다시 부르면 결과를 확인한다 (증액은 previous_tx_hash 필수)
    NOT_SENT        릴레이어가 보낼 수 없는 상태다(ChainSetupError). 들어가지 않았다. 고친 뒤 다시 보낸다. 단건 API 면 503 이다

앱에는 NOT_SENT 를 rejected 로 전달한다 (들어가지 않았고 다시 보낼 수 있다).

증액은 previous_tx_hash 없이 다시 보내면 안 된다. 컨트랙트는 시한을 version 보다 먼저 보므로, 응답을 잃은 증액이 사실은 들어갔어도
시한이 지난 재시도는 SignatureExpired 다. 이를 보고 재서명하면 한 번 승인한 증액이 두 번 들어간다. 그래서 인자를 필수로 두고,
저장한 hash 로 앞선 결과를 먼저 확인한다. 그 hash 를 보내기 전에 남기는 칸이 tx_increase 다 (before_broadcast 로 선점).

증액의 REJECTED 중 부른 쪽이 따로 처리할 것 (PRD §4.1). 앞선 hash 를 넘겼으면 그 트랜잭션은 들어가지 않은 것이 확인된 뒤다:
    SignatureExpired   PRESIDENT_SIGNED → PENDING 으로 되돌리고 회장에게 재서명을 요청한다
    VersionMismatch    서명한 version 이 낡았다 (다른 증액이 먼저 들어감). 재서명한다

선점 규칙: 결과의 failed_tx_hash 는 보냈거나 앞서 보냈지만 체인에 남지 않은 hash 다. 칸에 이 값이 있으면 비운다. NO_RESPONSE 의 tx_hash 는
결과를 모르는 hash 라 칸에 둔다. previous_tx_hash 가 실패로 끝나 새로 보낼 때는 before_broadcast 에서 칸을 새 hash 로 바꾼다.

before_broadcast 가 던진 예외(선점 실패 등)는 그대로 올라간다. 이때는 보내지 않았다.
"""
from dataclasses import dataclass
from enum import Enum
from typing import Awaitable, Callable, Optional

from app.chain.client import BeforeBroadcast, ChainClient
from app.chain.models import (
    BudgetRevertReason,
    BudgetTxResult,
    ChainBudget,
    ChainError,
    ChainRevert,
    ChainSetupError,
    ChainUnavailable,
    IncreaseRequest,
    IssueRequest,
)
from app.utils.hashing import text_hash

# 보내기 전 검사의 REJECTED reason. 체인 에러가 아니라 앱·호출 쪽 문제다
MALFORMED_SIGNATURE = "MalformedSignature"  # 서명 형식이 틀렸거나 컨트랙트가 받지 않는 모양이다 (v·high-s)
REASON_HASH_MISMATCH = "ReasonHashMismatch"  # 사유 원문의 해시가 서명된 reason_hash 와 다르다 (HASHING §3)


class BudgetRelayStatus(str, Enum):
    ISSUED = "ISSUED"
    ALREADY_ISSUED = "ALREADY_ISSUED"
    INCREASED = "INCREASED"
    REJECTED = "REJECTED"
    NO_RESPONSE = "NO_RESPONSE"
    NOT_SENT = "NOT_SENT"


@dataclass(frozen=True)
class BudgetRelayOutcome:
    status: BudgetRelayStatus
    tx_hash: Optional[str] = None  # ISSUED·INCREASED 의 hash, NO_RESPONSE 면 결과를 모르는 hash. 보내기 전에 끊겼으면 None
    failed_tx_hash: Optional[str] = None  # 체인에 남지 않은 hash. 칸에 이 값이 있으면 비운다 (모듈 설명)
    version: Optional[int] = None  # ISSUED·INCREASED 뒤의 version
    reason: Optional[str] = None  # REJECTED·ALREADY_ISSUED 의 원인
    detail: str = ""  # 로그용. 화면 문구로 쓰지 않는다
    existing: Optional[ChainBudget] = None  # ALREADY_ISSUED 일 때 체인의 예산


@dataclass(frozen=True)
class _Attempt:
    """한 번 보낸 결과. 넷 중 하나만 있다. 모두 비었으면 결과를 모른다는 뜻이고 그 이유가 detail 이다."""

    sent: Optional[str]  # before_broadcast 까지 간 hash
    result: Optional[BudgetTxResult] = None
    revert: Optional[ChainRevert] = None
    not_sent: Optional[ChainSetupError] = None
    detail: str = ""


async def relay_issue(
    chain: ChainClient, request: IssueRequest, signature: str, before_broadcast: Optional[BeforeBroadcast] = None
) -> BudgetRelayOutcome:
    """회장 서명 1개로 예산 한 줄을 발행한다."""
    malformed = _malformed(chain, request, signature)
    if malformed is not None:
        return malformed
    attempt = await _send(chain, request.budget_id, before_broadcast, lambda claim: chain.issue_budget(request, signature, claim))
    if attempt.result is not None:
        return BudgetRelayOutcome(BudgetRelayStatus.ISSUED, tx_hash=attempt.result.tx_hash, version=attempt.result.version)
    if attempt.revert is not None:
        return await _issue_refused(chain, request, attempt)
    return _not_done(attempt)


async def relay_increase(
    chain: ChainClient,
    request: IncreaseRequest,
    reason: str,
    president_signature: str,
    auditor_signature: str,
    *,
    previous_tx_hash: Optional[str],
    before_broadcast: Optional[BeforeBroadcast] = None,
) -> BudgetRelayOutcome:
    """회장·감사 서명 2개로 증액한다.

    reason 은 앱이 해시해 서명한 사유 원문(HASHING §3 정본)이다. 다르면 체인에는 서명된 해시, DB 에는 다른 원문이 영구히 남아
    학생 검증에서 위조로 보인다. previous_tx_hash 는 이 요청으로 앞서 보낸 hash(tx_increase)이고, 처음이면 None 이다.
    """
    if not reason or text_hash(reason) != request.reason_hash:
        return BudgetRelayOutcome(BudgetRelayStatus.REJECTED, reason=REASON_HASH_MISMATCH, detail="사유 원문의 SHA256 이 서명된 reason_hash 와 다르다")
    malformed = _malformed(chain, request, president_signature) or _malformed(chain, request, auditor_signature)
    if malformed is not None:
        return malformed

    failed_previous: Optional[str] = None
    if previous_tx_hash is not None:
        try:
            landed = await chain.budget_tx_result(previous_tx_hash, request.budget_id)
        except ChainRevert:
            failed_previous = previous_tx_hash  # 실패로 끝났다. 체인에 남은 것이 없으니 이 서명으로 보낸다
        except ChainError as e:
            return BudgetRelayOutcome(BudgetRelayStatus.NO_RESPONSE, tx_hash=previous_tx_hash, detail=f"앞선 트랜잭션을 확인하지 못했다: {e}")
        else:
            if landed is None:
                # 아직 들어갈 수 있다. 지금 보내면 둘 다 들어갈 수 있으니 보내지 않는다
                return BudgetRelayOutcome(BudgetRelayStatus.NO_RESPONSE, tx_hash=previous_tx_hash, detail="앞선 트랜잭션이 아직 블록에 없다")
            return BudgetRelayOutcome(BudgetRelayStatus.INCREASED, tx_hash=landed.tx_hash, version=landed.version)

    attempt = await _send(
        chain,
        request.budget_id,
        before_broadcast,
        lambda claim: chain.increase_budget(request, president_signature, auditor_signature, claim),
    )
    if attempt.result is not None:
        return BudgetRelayOutcome(BudgetRelayStatus.INCREASED, tx_hash=attempt.result.tx_hash, version=attempt.result.version)
    if attempt.revert is not None:
        return _rejected(attempt.revert, attempt.sent or failed_previous)
    return _not_done(attempt, failed_previous)


def _malformed(chain: ChainClient, request, signature: str) -> Optional[BudgetRelayOutcome]:
    """보내기 전에 서명 모양을 본다. signer_of 는 컨트랙트가 거부할 서명에 ValueError 를 낸다."""
    try:
        chain.signer_of(request, signature)
    except ValueError as e:
        return BudgetRelayOutcome(BudgetRelayStatus.REJECTED, reason=MALFORMED_SIGNATURE, detail=str(e))
    return None


async def _send(
    chain: ChainClient,
    budget_id: int,
    before_broadcast: Optional[BeforeBroadcast],
    send: Callable[[BeforeBroadcast], Awaitable[BudgetTxResult]],
) -> _Attempt:
    """보내고 결과를 _Attempt 로 담는다. 응답을 잃었으면 hash 로 한 번 확인한다."""
    sent: Optional[str] = None

    async def claim(tx_hash: str) -> None:
        nonlocal sent
        if before_broadcast is not None:
            await before_broadcast(tx_hash)  # 예외면 보내지 않는다
        sent = tx_hash

    try:
        result = await send(claim)
    except ChainRevert as e:
        return _Attempt(sent, revert=e)
    except ChainSetupError as e:
        return _Attempt(sent, not_sent=e)
    except ChainUnavailable as e:
        lost = str(e)
    else:
        return _Attempt(sent, result=result)

    if sent is None:
        return _Attempt(None, detail=lost)  # 보내기 전에 끊겼다
    try:
        landed = await chain.budget_tx_result(sent, budget_id)
    except ChainRevert as e:
        return _Attempt(sent, revert=e)  # 블록에 들어가 실패로 끝났다
    except ChainError as e:
        return _Attempt(sent, detail=f"{lost} / 결과를 확인하지 못했다: {e}")
    if landed is None:
        return _Attempt(sent, detail=lost)
    return _Attempt(sent, result=landed)


async def _issue_refused(chain: ChainClient, request: IssueRequest, attempt: _Attempt) -> BudgetRelayOutcome:
    """발행이 revert 했다. 어떤 revert 든 앞선 시도가 이미 들어갔을 수 있어(시한이 지난 재시도는 SignatureExpired) 체인을 먼저 읽는다.

    시뮬레이션은 다음 블록 기준이고 조회는 최신 블록 기준이다. 이미 있다고 거부됐는데 읽히지 않으면 대기열에 있다는 뜻이라 거부가 아니다.
    """
    revert = attempt.revert
    try:
        budget_id = await chain.budget_id_of(request.term, request.category)
        issued = await chain.get_budget(budget_id) if budget_id != 0 else None
        # 같은 id 를 다른 예산이 쓰고 있는지. 이미 있다는 거부인데 학기·항목으로 찾지 못한 경우만 본다
        occupant = None
        if issued is None and revert.reason is BudgetRevertReason.BUDGET_ALREADY_EXISTS:
            occupant = await chain.get_budget(request.budget_id)
    except ChainError as e:
        return BudgetRelayOutcome(
            BudgetRelayStatus.NO_RESPONSE, failed_tx_hash=attempt.sent, detail=f"{revert} / 체인의 예산을 확인하지 못했다: {e}"
        )
    if issued is not None:
        return BudgetRelayOutcome(
            BudgetRelayStatus.ALREADY_ISSUED, failed_tx_hash=attempt.sent, reason=revert.reason.value, detail=revert.detail, existing=issued
        )
    if revert.reason is BudgetRevertReason.BUDGET_ALREADY_ISSUED or (
        revert.reason is BudgetRevertReason.BUDGET_ALREADY_EXISTS and occupant is None
    ):
        return BudgetRelayOutcome(BudgetRelayStatus.NO_RESPONSE, failed_tx_hash=attempt.sent, detail=f"{revert} / 대기열에 있어 아직 읽히지 않는다")
    return _rejected(revert, attempt.sent)


def _not_done(attempt: _Attempt, failed_previous: Optional[str] = None) -> BudgetRelayOutcome:
    if attempt.not_sent is not None:
        return BudgetRelayOutcome(BudgetRelayStatus.NOT_SENT, failed_tx_hash=attempt.sent or failed_previous, detail=str(attempt.not_sent))
    return BudgetRelayOutcome(BudgetRelayStatus.NO_RESPONSE, tx_hash=attempt.sent, failed_tx_hash=None if attempt.sent else failed_previous, detail=attempt.detail)


def _rejected(revert: ChainRevert, failed_tx_hash: Optional[str]) -> BudgetRelayOutcome:
    return BudgetRelayOutcome(BudgetRelayStatus.REJECTED, failed_tx_hash=failed_tx_hash, reason=revert.reason.value, detail=revert.detail)
