from typing import Dict

from pydantic import BaseModel, ConfigDict, Field

from app.chain.deployment import Eip712Domain


class DomainsResponse(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    chain_id: int = Field(..., alias="chainId", description="배포된 체인 id")
    domains: Dict[str, Eip712Domain] = Field(
        ..., description="컨트랙트 이름 → EIP-712 도메인. 앱은 서명 대상 컨트랙트의 도메인을 고른다"
    )
