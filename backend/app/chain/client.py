"""백엔드가 블록체인을 부르는 입구.

이번 주는 모양만 정한다. 실제 구현(릴레이어)은 다음 주에 붙이고, 그 전까지는 fake.py 를 쓴다.
범위는 AccountingLedger 의 등록·확정·반려와 조회뿐이다. 예산·이의·SBT·롤은 다음 주.

서명은 여기서 만들지 않는다. 임원 기기가 서명한 값을 받아 릴레이만 한다 (PRD §9.2).
모든 쓰기 메서드는 트랜잭션이 블록에 들어갈 때까지 기다린 뒤 최종 상태를 돌려준다.
"""
from typing import Optional, Protocol

from app.chain.models import ChainEntry, ConfirmApproval, RecordRequest, RejectDecision, TxResult


class ChainClient(Protocol):
    async def record_pending(self, request: RecordRequest, signature: str) -> TxResult:
        """AccountingLedger.recordPending 을 릴레이한다.

        status 는 PENDING 또는 BLOCKED 다. BLOCKED 는 예외가 아니다 — 트랜잭션은 성공했고
        예산 조건 위반이 기록된 것이다. 사유는 block_reason 에 있다.

        Raises:
            ChainRevert: 서명 불일치·권한 없음·중복 id·금액 규칙·정정 대상 오류 등.
                         온체인에 아무것도 남지 않으므로 DB 의 status 는 NULL 그대로 둔다.
            ChainUnavailable: 트랜잭션이 들어갔는지 모른다. get_entry 로 먼저 확인한 뒤 재시도한다.
                              확인 없이 재시도하면 이미 들어간 경우 ENTRY_ALREADY_EXISTS 로 revert 된다.
        """
        ...

    async def confirm_entry(self, approval: ConfirmApproval, signature: str) -> TxResult:
        """AccountingLedger.confirmEntry 를 릴레이한다. status 는 CONFIRMED.

        Raises:
            ChainRevert: INSUFFICIENT_BUDGET 이면 항목은 PENDING 그대로다 — 반려 흐름으로 넘긴다.
                         그 밖에 HASH_MISMATCH·SELF_APPROVAL·INVALID_STATUS(BLOCKED 포함) 등.
            ChainUnavailable: record_pending 과 같다.
        """
        ...

    async def reject_entry(self, decision: RejectDecision, signature: str) -> TxResult:
        """AccountingLedger.rejectEntry 를 릴레이한다. status 는 REJECTED.

        Raises:
            ChainRevert: SELF_APPROVAL·INVALID_STATUS 등.
            ChainUnavailable: record_pending 과 같다.
        """
        ...

    async def get_entry(self, entry_id: int) -> Optional[ChainEntry]:
        """AccountingLedger.getEntry. 온체인에 없으면 None."""
        ...
