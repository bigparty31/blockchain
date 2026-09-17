"""실제 체인 연결 설정. 값은 환경변수로 받는다."""
import os
from collections.abc import Mapping
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field, SecretStr, field_validator

from app.chain.eip712 import Eip712Domain
from app.chain.models import check_address

_ENV_NAMES = {
    "rpc_url": "CHAIN_RPC_URL",
    "chain_id": "CHAIN_ID",
    "ledger_address": "CHAIN_LEDGER_ADDRESS",
    "relayer_private_key": "CHAIN_RELAYER_KEY",
}


class ChainSettings(BaseModel):
    model_config = ConfigDict(frozen=True)

    rpc_url: str
    chain_id: int = Field(..., description="31337 Hardhat 로컬, 80002 Polygon Amoy")
    ledger_address: str
    relayer_private_key: SecretStr = Field(..., description="가스를 대납하는 서버 계정. 임원 키가 아니다")
    role_manager_address: Optional[str] = Field(None, description="없으면 롤 조회를 붙이지 않는다")
    objection_address: Optional[str] = Field(None, description="없으면 이의 클라이언트를 붙이지 않는다")
    membership_address: Optional[str] = Field(None, description="없으면 SBT 조회를 붙이지 않는다")
    budget_address: Optional[str] = Field(None, description="없으면 예산 조회를 붙이지 않는다")
    deploy_block: int = Field(0, ge=0, description="컨트랙트 중 가장 이른 배포 블록. 이벤트를 여기까지만 거슬러 찾는다")
    confirmations: int = Field(1, ge=1, description="포함된 블록을 1 로 세어 이만큼 쌓이면 들어간 것으로 본다")
    finality_blocks: int = Field(64, ge=0, description="노드가 finalized 태그를 못 줄 때, head 에서 이만큼 뒤까지만 뒤집히지 않는다고 본다 (잔액 집계)")
    receipt_timeout_seconds: float = Field(120, gt=0, description="넘으면 ChainUnavailable. 재전송·확인 블록 대기도 여기 포함")
    poll_seconds: float = Field(2, gt=0)
    replace_after_seconds: float = Field(30, gt=0, description="이만큼 기다려도 블록에 안 들어가면 수수료를 올려 같은 nonce 로 다시 보낸다")
    max_replacements: int = Field(3, ge=0)
    fee_bump: float = Field(1.25, ge=1.1, description="재전송 때 수수료 배수. 노드는 10% 이상 올려야 교체를 받는다")
    gas_buffer: float = Field(1.2, ge=1, description="추정 가스에 곱하는 여유")
    log_chunk_blocks: int = Field(2000, ge=1, description="eth_getLogs 한 번에 볼 블록 수. 공개 RPC 는 범위를 제한한다")
    min_relayer_balance_wei: int = Field(10**17, ge=0, description="이보다 적으면 시작 점검에서 경고")

    @field_validator("ledger_address", "role_manager_address", "objection_address", "membership_address", "budget_address")
    @classmethod
    def _address(cls, v: Optional[str]) -> Optional[str]:
        return None if v is None else check_address(v)

    @property
    def domain(self) -> Eip712Domain:
        """AccountingLedger 서명 도메인."""
        return Eip712Domain(chain_id=self.chain_id, verifying_contract=self.ledger_address)

    @property
    def objection_domain(self) -> Optional[Eip712Domain]:
        """ObjectionRegistry 서명 도메인. name 이 컨트랙트명이라 원장과 다르다 (docs/CONTRACTS.md EIP-712)."""
        if self.objection_address is None:
            return None
        return Eip712Domain(name="ObjectionRegistry", chain_id=self.chain_id, verifying_contract=self.objection_address)

    @classmethod
    def from_env(cls, env: Mapping[str, str] = os.environ) -> "ChainSettings":
        """CHAIN_RPC_URL · CHAIN_ID · CHAIN_LEDGER_ADDRESS · CHAIN_RELAYER_KEY 는 필수.
        나머지는 CHAIN_ + 필드 이름 대문자 (예: CHAIN_CONFIRMATIONS). 없으면 기본값."""
        values = {}
        for field in cls.model_fields:
            key = _ENV_NAMES.get(field, "CHAIN_" + field.upper())
            if key in env:
                values[field] = env[key]
        return cls(**values)
