from app.chain.client import ChainClient
from app.chain.fake import FakeChainClient

# 전역 체인 클라이언트 인스턴스 (기본값은 FakeChainClient)
_chain_client: ChainClient = FakeChainClient()


def get_chain_client() -> ChainClient:
    """FastAPI Depends용 체인 클라이언트 주입 함수"""
    return _chain_client


def set_chain_client(client: ChainClient) -> None:
    """테스트 또는 실제 릴레이어 교체용 체인 클라이언트 설정 함수"""
    global _chain_client
    _chain_client = client
