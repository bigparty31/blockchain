from fastapi import APIRouter, HTTPException, status

from app.chain.deployment import DeploymentError, load_deployment
from app.schemas.chain import DomainsResponse

router = APIRouter(prefix="/chain", tags=["Chain"])


@router.get("/domains", response_model=DomainsResponse, summary="EIP-712 서명 도메인 (컨트랙트별)")
def get_domains():
    """앱이 서명할 때 쓸 EIP-712 도메인을 배포 기록(contracts/deployments/*.json)에서 읽어 내려줍니다.

    - 도메인은 서명을 받는 컨트랙트마다 따로 있습니다. 등록·승인·반려는 `AccountingLedger`,
      예산 발행·증액·회수는 `BudgetToken`, 롤 변경·회장 복구는 `RoleManager` 도메인으로 서명합니다.
    - 재배포하면 주소와 도메인이 바뀌므로 앱은 값을 하드코딩하지 말고 이 API를 씁니다.
    - `domainSeparator` 는 컨트랙트의 `DOMAIN_SEPARATOR()` 입니다. 앱이 계산한 도메인 해시와 비교하면
      체인 id·주소를 잘못 쓴 것을 서명 전에 잡을 수 있습니다.
    - 배포 기록이 없거나 앞뒤가 맞지 않으면 503 입니다.
    """
    try:
        deployment = load_deployment()
    except DeploymentError as e:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(e))
    return DomainsResponse(chain_id=deployment.chain_id, domains=deployment.eip712)
