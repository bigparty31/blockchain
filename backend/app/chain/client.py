"""백엔드가 블록체인을 부르는 입구. 구현은 fake.py(테스트)와 web3_client.py·web3_contracts.py(실제).

서명은 여기서 만들지 않는다. 임원 기기가 서명한 값을 받아 릴레이만 한다 (PRD §9.2).
모든 쓰기 메서드는 트랜잭션이 블록에 들어갈 때까지 기다린 뒤 최종 상태를 돌려준다.
예산 발행·롤 부여·SBT 발급은 호출자가 회장이라 릴레이할 수 없어 두지 않았다 (docs/CHAIN_CLIENT.md §8).
"""
from typing import Optional, Protocol

from app.chain.models import (
    AnswerRequest,
    ChainBudget,
    ChainEntry,
    ChainMembership,
    ChainObjection,
    ConfirmApproval,
    ConfirmedEntry,
    DecisionRecord,
    ObjectionTx,
    RecordRequest,
    RejectDecision,
    Role,
    TxResult,
)


class ChainClient(Protocol):
    async def record_pending(self, request: RecordRequest, signature: str) -> TxResult:
        """AccountingLedger.recordPending 을 릴레이한다.

        status 는 PENDING 또는 BLOCKED 다. BLOCKED 는 예외가 아니다 — 트랜잭션은 성공했고
        예산 조건 위반이 기록된 것이다. 사유는 block_reason 에 있다.

        Raises:
            ValueError: 서명 형식이 틀렸다 (0x + hex 130자 아님). 체인에 보내기 전에 막힌다.
                        ChainError 가 아니므로 따로 잡거나 API 입력 검증에서 먼저 막는다.
            ChainRevert: 권한 없음·중복 id·금액 규칙·정정 대상 오류 등. 온체인에 아무것도 남지 않는다.
                         앱이 다른 값에 서명해도 INVALID_SIGNATURE 가 아니라 NOT_REGISTRANT 로 온다.
            ChainUnavailable: 트랜잭션이 들어갔는지 모른다. get_entry 로 먼저 확인한 뒤 재시도한다.
                              None 이 아니면 이미 들어간 것이다. 확인 없이 재시도하면
                              이미 들어간 경우 ENTRY_ALREADY_EXISTS 로 revert 된다.
        """
        ...

    async def confirm_entry(self, approval: ConfirmApproval, signature: str) -> TxResult:
        """AccountingLedger.confirmEntry 를 릴레이한다. status 는 CONFIRMED.

        Raises:
            ValueError: record_pending 과 같다.
            ChainRevert: INSUFFICIENT_BUDGET 이면 항목은 PENDING 그대로다 — 반려 흐름으로 넘긴다.
                         그 밖에 HASH_MISMATCH·SELF_APPROVAL·INVALID_STATUS(BLOCKED 포함) 등.
                         앱이 다른 값에 서명하면 NOT_APPROVER 로 온다.
            ChainUnavailable: get_entry 로 먼저 확인한다. 항목은 원래 있으므로 None 인지가 아니라
                              status 로 판단한다 — CONFIRMED 면 이미 들어간 것이다.
                              확인 없이 재시도하면 이미 들어간 경우 INVALID_STATUS 로 revert 된다.
        """
        ...

    async def reject_entry(self, decision: RejectDecision, signature: str) -> TxResult:
        """AccountingLedger.rejectEntry 를 릴레이한다. status 는 REJECTED.

        Raises:
            ValueError: record_pending 과 같다.
            ChainRevert: SELF_APPROVAL·INVALID_STATUS 등. 앱이 다른 값에 서명하면 NOT_APPROVER 로 온다.
            ChainUnavailable: confirm_entry 와 같다. status 가 REJECTED 면 이미 들어간 것이다.
        """
        ...

    async def get_entry(self, entry_id: int) -> Optional[ChainEntry]:
        """AccountingLedger.getEntry. 온체인에 없으면 None.

        getEntry 는 없는 id 에도 0 으로 채운 구조체를 돌려주고, status 0 은 PENDING 이다.
        그대로 옮기면 없는 항목이 PENDING 으로 보이므로 실제 구현은 exists(id) 를 먼저 확인한다.
        """
        ...

    async def get_record_result(self, entry_id: int) -> Optional[TxResult]:
        """등록 트랜잭션의 결과를 EntryPending / EntryBlocked 이벤트에서 찾는다. 없으면 None.

        record_pending 의 응답을 못 받았을 때(ChainUnavailable, 서버 재시작) tx 해시와 BLOCKED 사유를
        되찾는 데 쓴다. getEntry 에는 둘 다 없다. 둘 다 id 가 indexed 라 id 로 걸러 읽는다.
        """
        ...

    async def get_decision_result(self, entry_id: int) -> Optional[DecisionRecord]:
        """확정·반려 트랜잭션의 결과를 EntryConfirmed / EntryRejected 이벤트에서 찾는다. 없으면 None.

        용도는 get_record_result 와 같다. status 는 CONFIRMED 또는 REJECTED.
        단건 검증이 읽는 경고 무시 승인 사유·반려 사유 해시도 함께 담는다 (docs/HASHING.md §2).
        confirm_entry·reject_entry 도 같은 DecisionRecord 를 돌려준다.
        """
        ...


class LedgerEvents(Protocol):
    """장부 잔액 집계가 읽는 이벤트 (app/chain/aggregate.py)."""

    async def safe_block(self) -> int:
        """뒤집히지 않는다고 보는 마지막 블록 (finalized). 보낼 때의 확인 블록 수와는 따로다."""
        ...

    async def confirmed_entries(self, from_block: int, to_block: int) -> list[ConfirmedEntry]:
        """두 블록을 포함한 구간의 EntryConfirmed. 블록 순서대로."""
        ...


class RoleReader(Protocol):
    async def has_role(self, role: Role, account: str) -> bool:
        """RoleManager.hasRole. 릴레이가 체인에 보내기 전에 서명자 역할을 확인하는 데 쓴다."""
        ...


class ObjectionClient(Protocol):
    """ObjectionRegistry. 학생 앱의 이의 제기와 임원 답변."""

    async def raise_objection(self, objection_id: int, entry_id: int, content_hash: str, raiser: str) -> ObjectionTx:
        """raise 를 릴레이한다. 서명이 없다 — 학생 키는 서버가 보관하므로 컨트랙트가 릴레이어를 믿는다.

        Raises:
            ChainRevert: OBJECTION_ALREADY_EXISTS, ENTRY_NOT_FOUND, NOT_MEMBER 등.
            ChainUnavailable: get_objection 으로 들어갔는지 먼저 확인한다.
        """
        ...

    async def answer_objection(self, request: AnswerRequest, signature: str) -> ObjectionTx:
        """answer 를 릴레이한다. 서명자가 답변자(임원)다. ObjectionRegistry 도메인으로 서명한 것이어야 한다.

        Raises:
            ValueError: 서명 형식이 틀렸다.
            ChainRevert: OBJECTION_NOT_FOUND, OBJECTION_ALREADY_ANSWERED, NOT_RESPONDER 등.
            ChainUnavailable: get_objection 의 status 가 ANSWERED 인지 먼저 확인한다.
        """
        ...

    async def get_objection(self, objection_id: int) -> Optional[ChainObjection]:
        """없으면 None. getObjection 도 없는 id 에 0 구조체를 돌려주므로 exists 를 먼저 본다."""
        ...


class MembershipReader(Protocol):
    """MembershipSBT 조회. 발급·소각(mintBatch·burn)은 호출자가 회장이라 릴레이할 수 없어 두지 않았다 (CHAIN_CLIENT §8)."""

    async def has_valid_membership(self, account: str, term: int) -> bool:
        ...

    async def token_of(self, account: str, term: int) -> Optional[int]:
        """그 학기 SBT 의 tokenId. 없으면 None (컨트랙트는 0 을 돌려준다 — tokenId 는 1부터)."""
        ...

    async def get_membership(self, token_id: int) -> Optional[ChainMembership]:
        ...


class BudgetReader(Protocol):
    """BudgetToken 조회. 예산 발행·증액·회수는 호출자가 회장이라 릴레이할 수 없어 두지 않았다 (docs/CHAIN_CLIENT.md §8)."""

    async def get_budget(self, budget_id: int) -> Optional[ChainBudget]:
        """없으면 None. exists 를 먼저 본다."""
        ...

    async def remaining(self, budget_id: int) -> Optional[int]:
        """현재 잔량 (원). 예산 집행률 화면의 정본이다 — 이벤트로 다시 계산하지 않는다. 없으면 None."""
        ...
