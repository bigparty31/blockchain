"""체인 서비스 및 릴레이어 계층.

FastAPI 라우터와 ChainClient 사이의 결합도를 낮추고, 
다음 주 실제 Web3 블록체인 릴레이어 구현체로 교체하기 위한 어댑터/팩토리를 제공한다.
"""
from typing import Optional
from app.chain.client import ChainClient
from app.chain.fake import FakeChainClient
from app.chain.models import (
    RecordRequest,
    TxResult,
    ChainUnavailable,
    BlockReason,
)
from app.schemas.entry import EntryKind, EntryStatus, EntryResponse

_chain_client_instance: Optional[ChainClient] = None


class RegistrationRelay:
    """총무 기기 서명을 받아 컨트랙트(AccountingLedger.recordPending)로 릴레이하는 서비스."""

    def __init__(self, client: ChainClient):
        self.client = client

    async def submit_record(
        self,
        entry: EntryResponse,
        signature: str,
        deadline: int,
    ) -> TxResult:
        """초안 내역과 기기 서명을 받아 체인에 기록 요청을 전달한다.
        
        Raises:
            ValueError: 서명 형식 또는 날짜 규격 위반
            ChainRevert: 온체인 revert (권한 없음, 중복 ID 등)
            ChainUnavailable: RPC 연결 실패 (get_entry 확인 후에도 미반영된 경우)
        """
        budget_id = 0
        if entry.kind == EntryKind.EXPENSE and entry.budget_id is not None:
            budget_id = entry.budget_id

        corrects_id = entry.corrects_entry_id if entry.corrects_entry_id is not None else 0

        request = RecordRequest(
            id=entry.id,
            hash=entry.meta_hash,
            amount=entry.amount,
            kind=entry.kind,
            occurred_at=entry.occurred_at,
            budget_id=budget_id,
            corrects_id=corrects_id,
            deadline=deadline,
        )

        try:
            return await self.client.record_pending(request, signature=signature)
        except ChainUnavailable:
            # docs/CHAIN_CLIENT.md §4: ChainUnavailable이면 get_entry로 들어갔는지 먼저 확인
            landed = await self.client.get_entry(entry.id)
            if landed is not None:
                return TxResult(
                    tx_hash="0x" + "0" * 64,
                    status=landed.status,
                    block_reason=BlockReason.BUDGET_NOT_FOUND if (landed.status == EntryStatus.BLOCKED and landed.budget_id == 0) else None,
                )
            raise


def create_chain_services(chain_client: Optional[ChainClient] = None) -> RegistrationRelay:
    """ChainClient 인스턴스를 주입받아 RegistrationRelay를 생성하는 팩토리 함수."""
    client = chain_client if chain_client is not None else get_chain_client()
    return RegistrationRelay(client)


def get_chain_client() -> ChainClient:
    """싱글톤 ChainClient 인스턴스를 반환한다 (기본값: FakeChainClient)."""
    global _chain_client_instance
    if _chain_client_instance is None:
        _chain_client_instance = FakeChainClient()
    return _chain_client_instance


def set_chain_client(client: Optional[ChainClient]) -> None:
    """테스트 또는 실구현체 교체를 위해 ChainClient 인스턴스를 재설정한다."""
    global _chain_client_instance
    _chain_client_instance = client


def get_registration_relay() -> RegistrationRelay:
    """FastAPI Depends용 릴레이어 의존성 주입 함수."""
    return create_chain_services(get_chain_client())
