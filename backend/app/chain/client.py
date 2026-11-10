"""백엔드가 블록체인을 부르는 입구.

모양만 정한다. 실제 구현(릴레이어)을 붙이기 전까지는 fake.py 를 쓴다.
범위는 AccountingLedger 의 등록·확정·반려와 조회, BudgetToken 의 발행·증액과 조회다. 예산 회수·롤(RoleManager)도 서명 + 릴레이어
방식이라 나중에 같은 방식으로 더한다.

서명은 여기서 만들지 않는다. 임원 기기가 서명한 값을 받아 릴레이만 한다 (PRD §9.2).
모든 쓰기 메서드는 트랜잭션이 블록에 들어갈 때까지 기다린 뒤 최종 상태를 돌려준다.
호출자는 앱이 준 서명을 그대로 넘긴다. 컨트랙트가 받는 모양(v 27·28, low-s)으로 맞추는 것은 실제 구현이 보내기 전에 한다.
"""
from typing import Awaitable, Callable, Optional, Protocol, Union

from app.chain.models import (
    BudgetTxResult,
    ChainBudget,
    ChainEntry,
    EntryTxDetail,
    ConfirmApproval,
    IncreaseRequest,
    IssueRequest,
    RecordRequest,
    RejectDecision,
    TxResult,
)

# 트랜잭션에 서명해 hash 가 정해진 뒤, 체인에 보내기 직전에 그 hash 로 불린다 (쓰기 메서드의 before_broadcast).
# 서비스는 여기서 DB 의 tx_pending(확정·반려는 tx_confirm)을 조건부 UPDATE 로 선점한다 — 처리 중 상태를 보내기 전에 남겨,
# 같은 항목을 두 번 보내지 않게 하고 응답을 잃어도 어느 트랜잭션인지 알 수 있게 한다.
# 예외를 던지면 보내지 않고 그 예외가 그대로 올라간다 (선점 실패 = 다른 요청이 이미 처리 중).
# 검사에서 걸리는 요청(시뮬레이션 revert)이나 보내기 전 연결 실패는 hash 가 정해지기 전에 끝나 불리지 않는다.
# 그래서 서비스는 자기 콜백이 불렸을 때만 선점을 다룬다 — 불린 뒤 ChainRevert·ChainSetupError 면 비우고,
# ChainUnavailable 이면 둔 채 그 hash 로 결과를 확인한다(tx_result). 이 규칙은 app/services/chain_tx.py 가 구현한다 (CHAIN_CLIENT §3).
# 콜백은 릴레이어 lock 을 쥔 채 불린다. 그 안에서 같은 클라이언트로 다시 보내거나 닫으면 RuntimeError 다.
BeforeBroadcast = Callable[[str], Awaitable[None]]


class ChainClient(Protocol):
    def signer_of(
        self, payload: Union[RecordRequest, ConfirmApproval, RejectDecision, IssueRequest, IncreaseRequest], signature: str
    ) -> str:
        """payload 에 대한 signature 의 서명자 주소 (EIP-55 체크섬). 체인에 보내지 않는다.

        도메인은 payload 로 정해진다 — 발행·증액은 BudgetToken, 나머지는 AccountingLedger.

        서비스는 릴레이 전에 이 주소를 기대 지갑(등록은 created_by 의 지갑, 확정·반려는 요청한 감사·회장의 지갑)과
        소문자로 맞춰 비교하고, 다르면 체인에 보내지 않고 400 으로 끝낸다. 컨트랙트는 다른 값에 대한 서명을
        NotRegistrant·NotApprover 로만 거부해서 revert 로는 "앱이 다른 값에 서명함" 과 "권한 없음" 을 가를 수 없다.
        실제 구현은 배포 기록의 도메인으로 EIP-712 복구를 하고(app/chain/eip712.py), 가짜는 fake_signature 의 주소를 돌려준다.

        Raises:
            ValueError: 서명 형식이 틀렸거나 복구할 수 없다. 실제 구현은 컨트랙트가 거부할 v·high-s 서명도 여기서 막는다.
        """
        ...

    async def record_pending(
        self, request: RecordRequest, signature: str, before_broadcast: Optional[BeforeBroadcast] = None
    ) -> TxResult:
        """AccountingLedger.recordPending 을 릴레이한다.

        status 는 PENDING 또는 BLOCKED 다. BLOCKED 는 예외가 아니다 — 트랜잭션은 성공했고
        예산 조건 위반이 기록된 것이다. 사유는 block_reason 에 있다.
        before_broadcast 는 BeforeBroadcast 설명대로 보내기 직전에 불린다. 그 뒤 ChainRevert(Hardhat 은 revert 하는
        트랜잭션도 블록에 넣는다)나 ChainSetupError(전송 거절)가 나면 체인에 남은 것이 없으니 선점한 tx_pending 을 비운다.

        Raises:
            ValueError: 서명 형식이 틀렸다 (0x + hex 130자 아님). 체인에 보내기 전에 막힌다.
                        ChainError 가 아니므로 따로 잡거나 API 입력 검증에서 먼저 막는다.
            ChainRevert: 권한 없음·중복 id·해시·금액·학기·정정 규칙 오류 등.
                         온체인에 아무것도 남지 않으므로 DB 의 status 는 NULL 그대로 둔다.
                         앱이 다른 값에 서명해도 INVALID_SIGNATURE 가 아니라 NOT_REGISTRANT 로 온다.
                         RESERVED_ID(id 0)는 중복이 아니다 — 재시도 판정에 쓰지 않는다.
            ChainUnavailable: 트랜잭션이 들어갔는지 모른다. 먼저 확인한 뒤 재시도한다 — 콜백이 불렸으면 그 hash 로
                              tx_result 를(결과·BLOCKED 사유까지), 아니면 get_entry 를 본다. None 이 아니면 이미 들어간 것이다.
                              확인 없이 재시도하면 이미 들어간 경우 ENTRY_ALREADY_EXISTS 로 revert 된다.
            ChainSetupError: 릴레이어가 보낼 수 없는 상태다 — 노드·배포 기록 문제, 릴레이어 잔액 부족,
                             다른 프로세스가 같은 키로 보냄(nonce). 트랜잭션은 들어가지 않았다. API 는 503.
        """
        ...

    async def confirm_entry(
        self, approval: ConfirmApproval, signature: str, before_broadcast: Optional[BeforeBroadcast] = None
    ) -> TxResult:
        """AccountingLedger.confirmEntry 를 릴레이한다. status 는 CONFIRMED. before_broadcast 는 record_pending 과 같다.

        Raises:
            ValueError: record_pending 과 같다.
            ChainRevert: INSUFFICIENT_BUDGET·BUDGET_EXPIRED 면 항목은 PENDING 그대로다 — 반려 흐름으로 넘긴다.
                         BudgetToken 이 낸 에러지만 원장 ABI 에도 선언돼 있어 원장 ABI 로 해석된다.
                         그 밖에 HASH_MISMATCH·ENTRY_COMMIT_MISMATCH(승인자가 본 값 ≠ 등록 값)·
                         REASON_REQUIRED/NOT_ALLOWED·SELF_APPROVAL·INVALID_STATUS(BLOCKED 포함) 등.
                         앱이 다른 값에 서명하면 NOT_APPROVER 로 온다.
            ChainUnavailable: 콜백이 불렸으면 그 hash 로 tx_result 를, 아니면 get_entry 를 먼저 본다. 항목은 원래 있으므로
                              None 인지가 아니라 status 로 판단한다 — CONFIRMED 면 이미 들어간 것이다.
                              확인 없이 재시도하면 이미 들어간 경우 INVALID_STATUS 로 revert 된다.
        """
        ...

    async def reject_entry(
        self, decision: RejectDecision, signature: str, before_broadcast: Optional[BeforeBroadcast] = None
    ) -> TxResult:
        """AccountingLedger.rejectEntry 를 릴레이한다. status 는 REJECTED. before_broadcast 는 record_pending 과 같다.

        Raises:
            ValueError: record_pending 과 같다.
            ChainRevert: ENTRY_COMMIT_MISMATCH·REASON_REQUIRED(사유 없음)·SELF_APPROVAL·INVALID_STATUS 등.
                         앱이 다른 값에 서명하면 NOT_APPROVER 로 온다.
            ChainUnavailable: confirm_entry 와 같다. status 가 REJECTED 면 이미 들어간 것이다.
        """
        ...

    async def tx_result(self, tx_hash: str, entry_id: int) -> Optional[TxResult]:
        """보낸 트랜잭션의 결과를 receipt 로 다시 읽는다. 체인에 보내지 않는다.

        응답을 잃은 뒤(ChainUnavailable) DB 에 남긴 tx_pending·tx_confirm 으로 결과를 되찾을 때 쓴다.
        get_entry 는 상태만 알려 주고 BLOCKED 사유는 이벤트에만 있어서, 사유까지 되찾으려면 그 트랜잭션을 읽어야 한다.
        등록·확정·반려 어느 트랜잭션이든 그 receipt 에 남은 이 id 의 결과를 돌려준다.

        None 은 "아직 블록에 없다" 다 — 노드가 모르는 hash 다. 들어가지 않았다고 단정하지 않는다 (나중에 들어갈 수 있다).

        Raises:
            ValueError: tx_hash 형식이 틀렸다 (0x + hex 64자 아님).
            ChainRevert: 블록에 들어갔지만 실패로 끝났다. 체인에 남은 것이 없다 — 선점을 비운다. 사유는 UNKNOWN 일 수 있다.
            ChainUnavailable: 노드에 닿지 못했거나, 그 트랜잭션에 이 id 의 결과 이벤트가 없다.
            ChainSetupError: 클라이언트가 교체돼 닫혔다 (다시 요청한다). 결과를 확인하지 못한 것이다.
        """
        ...

    async def entry_tx_detail(self, tx_hash: str, entry_id: int) -> Optional[EntryTxDetail]:
        """그 트랜잭션이 항목에 남긴 기록을 receipt 로 읽는다. 블록 번호와 사유 해시가 있다. None 은 아직 블록에 없다는 뜻이다.

        이벤트를 블록 범위로 훑지 않는다. RPC 의 조회 범위 제한에 걸리지 않게, DB 에 저장한 hash(tx_pending·tx_confirm)로 읽는다.

        Raises:
            tx_result 와 같다.
        """
        ...

    async def get_entry(self, entry_id: int) -> Optional[ChainEntry]:
        """AccountingLedger.getEntry. 온체인에 없으면 None.

        getEntry 는 없는 id 에도 0 으로 채운 구조체를 돌려주고, status 0 은 PENDING 이다.
        그대로 옮기면 없는 항목이 PENDING 으로 보이므로 실제 구현은 exists(id) 를 먼저 확인한다.
        """
        ...

    async def issue_budget(
        self, request: IssueRequest, signature: str, before_broadcast: Optional[BeforeBroadcast] = None
    ) -> BudgetTxResult:
        """BudgetToken.issue 를 릴레이한다. signature 는 회장 서명. before_broadcast 는 record_pending 과 같다.

        Raises:
            ValueError: record_pending 과 같다.
            ChainRevert: 사유는 BudgetRevertReason. BUDGET_ALREADY_EXISTS(같은 id)·BUDGET_ALREADY_ISSUED(같은 학기·항목)·
                         BUDGET_EXPIRED·SIGNATURE_EXPIRED 등. 앱이 다른 값에 서명하면 NOT_PRESIDENT 로 온다.
            ChainUnavailable: 들어갔는지 모른다. 콜백이 불렸으면 그 hash 로 budget_tx_result 를, 아니면 get_budget 을 본다.
            ChainSetupError: record_pending 과 같다.
        """
        ...

    async def increase_budget(
        self,
        request: IncreaseRequest,
        requester_signature: str,
        approver_signature: str,
        before_broadcast: Optional[BeforeBroadcast] = None,
    ) -> BudgetTxResult:
        """BudgetToken.increase 를 릴레이한다. 회장(요청)과 감사(승인)가 같은 값에 서명한다.

        Raises:
            ValueError: 어느 서명이든 형식이 틀렸다.
            ChainRevert: 사유는 BudgetRevertReason. VERSION_MISMATCH(다른 증액이 먼저 들어감·서명 재사용)·SIGNATURE_EXPIRED·
                         BUDGET_EXPIRED·AMOUNT_OUT_OF_RANGE 등. 앱이 다른 값에 서명하면 NOT_PRESIDENT·NOT_AUDITOR 로 온다.
            ChainUnavailable: 콜백이 불렸으면 그 hash 로 budget_tx_result 를 본다. version 만 보고 판단하지 않는다 —
                              올라갔어도 다른 증액 때문일 수 있다. 확인 없이 재서명하면 이중 증액이 된다
                              (컨트랙트는 시한을 version 보다 먼저 봐서, 시한이 지난 재시도는 SIGNATURE_EXPIRED 다).
        """
        ...

    async def budget_tx_result(self, tx_hash: str, budget_id: int) -> Optional[BudgetTxResult]:
        """발행·증액 트랜잭션의 결과를 receipt 로 다시 읽는다. tx_result 의 예산판이다. None 은 아직 블록에 없다는 뜻이다."""
        ...

    async def get_budget(self, budget_id: int) -> Optional[ChainBudget]:
        """BudgetToken.getBudget. 최신 블록 기준이고 온체인에 없으면 None. 대기열의 트랜잭션은 보이지 않는다."""
        ...

    async def budget_id_of(self, term: int, category: str) -> int:
        """BudgetToken.budgetIdOf. 그 학기·항목의 예산 id. 최신 블록 기준이고 없으면 0."""
        ...

    async def has_valid_membership(self, account: str, term: int) -> bool:
        """MembershipSBT.hasValidMembership. 그 학기(term = 학기 코드 YYYYS)의 소각되지 않은 회원권이 있으면 True.

        Raises:
            ChainUnavailable: 노드에 닿지 못했다. 미보유가 아니라 '모름'이다.
            ChainSetupError: 배포 기록에 MembershipSBT 가 없다 (아직 배포 전).
        """
        ...

    async def membership_token_of(self, account: str, term: int) -> int:
        """MembershipSBT.tokenOf. 그 학기의 유효한 tokenId. 없거나 소각됐으면 0. 예외는 has_valid_membership 과 같다."""
        ...
