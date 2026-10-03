"""ChainClient 의 실제 구현 — 서버 릴레이어.

임원 기기가 서명한 값을 받아 릴레이어 계정으로 트랜잭션을 보낸다. 가스는 릴레이어가 낸다 (PRD §9.2).
릴레이어 키는 전송에만 쓰고 서명 대상에는 서명하지 않는다. 임원 롤을 가진 주소의 키면 시작을 거부한다 —
서버가 임원 키를 가지면 승인 없이 확정을 올릴 수 있어 신뢰 모델이 무너진다.

connect() 가 연결과 시작 점검을 끝낸 클라이언트만 돌려준다. 배포 기록은 그때 읽어 두고, is_current() 로
배포 기록 파일이 그대로인지·원장에 아직 코드가 있는지 확인한다. provider 가 요청마다 이걸 보고, 재배포로 주소가
바뀌었거나 노드가 재시작돼 체인이 비었으면 클라이언트를 새로 만든다.

트랜잭션은 로컬에서 서명해 raw 로 보낸다. 브로드캐스트 전에 tx hash 를 알아야 tx_pending 을 먼저 기록할 수 있다.
쓰기는 lock 하나로 직렬화한다 — 릴레이어 키가 하나라 동시에 보내면 nonce 가 겹친다. uvicorn 워커는 1개로 띄운다.
"""
import asyncio
import re
from pathlib import Path
from typing import Optional, Union

import aiohttp
from eth_account import Account
from eth_account.signers.local import LocalAccount
from web3 import AsyncHTTPProvider, AsyncWeb3
from web3.exceptions import ProviderConnectionError, Web3Exception

from app.chain import eip712
from app.chain.deployment import Deployment, DeploymentError, deployment_path, load_abi, load_deployment
from app.chain.models import (
    ChainEntry,
    ChainSetupError,
    ConfirmApproval,
    RecordRequest,
    RejectDecision,
    TxResult,
)

LEDGER = "AccountingLedger"
ROLE_MANAGER = "RoleManager"
BUDGET_TOKEN = "BudgetToken"

RPC_TIMEOUT_SECONDS = 10
RECEIPT_TIMEOUT_SECONDS = 30  # 쓰기 메서드가 receipt 를 기다리는 한도. 넘으면 ChainUnavailable

# 노드에 닿지 못한 실패. 그 밖의 web3 예외는 노드는 응답했지만 배포 기록·ABI 가 체인과 맞지 않는 경우다
CONNECTION_ERRORS = (aiohttp.ClientError, OSError, ProviderConnectionError)  # asyncio·aiohttp 타임아웃은 OSError 계열

_PRIVATE_KEY = re.compile(r"0x[0-9a-fA-F]{64}")
_NO_ROLE = b"\x00" * 32


def _relayer_account(private_key: str) -> LocalAccount:
    # 키 값은 어떤 메시지에도 넣지 않는다
    if not isinstance(private_key, str) or not _PRIVATE_KEY.fullmatch(private_key):
        raise ChainSetupError("RELAYER_PRIVATE_KEY 는 0x + hex 64자여야 한다")
    try:
        return Account.from_key(private_key)
    except ValueError:
        # 0 이나 곡선 위수 이상은 형식이 맞아도 개인키가 아니다. 원래 예외는 메시지에 키 길이 등을 담으니 잇지 않는다
        raise ChainSetupError("RELAYER_PRIVATE_KEY 가 유효한 개인키 범위(1 이상, 곡선 위수 미만)가 아니다") from None


def _setup_error(e: Exception) -> ChainSetupError:
    """점검 중 난 예외를 원인에 맞는 안내로 바꾼다. 노드가 멀쩡한데 재시작하라고 하지 않게 연결 실패와 나머지를 가른다."""
    if isinstance(e, CONNECTION_ERRORS):
        return ChainSetupError(f"노드에 연결할 수 없다 ({type(e).__name__}). 노드가 켜져 있는지, CHAIN_RPC_URL 을 확인한다")
    return ChainSetupError(
        f"노드는 응답했지만 배포 기록·ABI 가 지금 체인의 컨트랙트와 맞지 않는다 ({type(e).__name__}). "
        "contracts 에서 다시 배포해 배포 기록과 ABI 를 갱신한다"
    )


class Web3ChainClient:
    """AccountingLedger 릴레이어. 만들 때는 connect() 를 쓴다."""

    def __init__(
        self, w3: AsyncWeb3, account: LocalAccount, deployment: Deployment, contracts: dict, deployment_file: Path
    ):
        self._w3 = w3
        self._account = account
        self._deployment = deployment
        self._deployment_file = deployment_file
        self._ledger = contracts[LEDGER]
        self._role_manager = contracts[ROLE_MANAGER]
        self._send_lock = asyncio.Lock()

    @classmethod
    async def connect(
        cls, rpc_url: str, private_key: str, deployment_file: Optional[Path] = None
    ) -> "Web3ChainClient":
        """노드에 연결하고 시작 점검을 통과한 클라이언트를 돌려준다.

        Raises:
            ChainSetupError: 키, 노드 연결, 체인·배포 기록 불일치, 릴레이어 롤·잔액 문제.
                             배포 기록·ABI 파일 문제는 하위 클래스 DeploymentError.
        """
        account = _relayer_account(private_key)
        path = deployment_file or deployment_path()
        deployment = load_deployment(path)
        w3 = AsyncWeb3(
            AsyncHTTPProvider(
                rpc_url,
                request_kwargs={"timeout": aiohttp.ClientTimeout(total=RPC_TIMEOUT_SECONDS)},
                # 재시도는 이번 범위가 아니다. 실패는 바로 올려 보내고, 호출하는 쪽이 get_entry 로 확인한다 (CHAIN_CLIENT §4)
                exception_retry_configuration=None,
            )
        )
        contracts = {
            name: w3.eth.contract(
                address=AsyncWeb3.to_checksum_address(deployment.contracts[name].address),
                abi=load_abi(deployment.contracts[name], path),
            )
            for name in (LEDGER, ROLE_MANAGER)
        }
        client = cls(w3, account, deployment, contracts, path)
        try:
            await client._check_setup()
        except BaseException:
            await client.close()
            raise
        return client

    async def close(self) -> None:
        await self._w3.provider.disconnect()

    async def is_current(self) -> bool:
        """connect 때의 배포 기록·ABI 가 파일과 같고 원장에 아직 코드가 있으면 True.

        재배포로 주소가 바뀌면 /chain/domains 가 내려주는 도메인과 이 클라이언트가 어긋나고,
        컨트랙트를 고쳐 같은 주소에 다시 배포하면 ABI 만 바뀌며, 노드가 재시작되면 체인이 빈다.
        어느 하나면 False — provider 가 새로 connect 해 원인을 점검 메시지로 알린다.
        """
        try:
            deployment = load_deployment(self._deployment_file)
            if deployment != self._deployment:
                return False
            for name, contract in ((LEDGER, self._ledger), (ROLE_MANAGER, self._role_manager)):
                if load_abi(deployment.contracts[name], self._deployment_file) != contract.abi:
                    return False
            return len(await self._w3.eth.get_code(self._ledger.address)) > 0
        except (DeploymentError, *CONNECTION_ERRORS, Web3Exception):
            return False

    @property
    def relayer_address(self) -> str:
        return self._account.address

    def __repr__(self) -> str:
        return f"Web3ChainClient(relayer={self.relayer_address}, chain_id={self._deployment.chain_id})"

    # ------------------------------------------------------------ 시작 점검

    async def _check_setup(self) -> None:
        try:
            await self._run_checks()
        except ChainSetupError:
            raise
        except (*CONNECTION_ERRORS, Web3Exception) as e:
            raise _setup_error(e) from e

    async def _run_checks(self) -> None:
        d = self._deployment
        eth = self._w3.eth
        ledger = self._ledger.functions

        chain_id = await eth.chain_id
        if chain_id != d.chain_id:
            raise ChainSetupError(f"연결한 체인({chain_id})이 배포 기록의 체인({d.chain_id})과 다르다")

        # 나머지는 서로 기다릴 필요가 없다. 판정은 아래에서 순서대로 한다 — 코드가 없으면 다른 호출의 실패는 그 결과일 뿐이다
        code, separator, role_manager, budget_token, relayer_role, balance = await asyncio.gather(
            eth.get_code(self._ledger.address),
            ledger.DOMAIN_SEPARATOR().call(),
            ledger.roleManager().call(),
            ledger.budgetToken().call(),
            self._role_manager.functions.roleOf(self.relayer_address).call(),
            eth.get_balance(self.relayer_address),
            return_exceptions=True,
        )
        if isinstance(code, BaseException):
            raise code
        if len(code) == 0:
            raise ChainSetupError(
                "원장 주소에 컨트랙트가 없다. 노드가 재시작돼 체인이 비었으면 contracts 에서 npm run deploy:local 로 다시 배포한다"
            )
        for result in (separator, role_manager, budget_token, relayer_role, balance):
            if isinstance(result, BaseException):
                raise result

        if "0x" + bytes(separator).hex() != d.eip712[LEDGER].domain_separator:
            raise ChainSetupError("원장의 DOMAIN_SEPARATOR 가 배포 기록과 다르다. 배포 기록이 지금 체인의 것이 아니다")
        # deploy.ts 가 확인하는 것과 같은 조합. 하나라도 다르면 앱에 내려주는 도메인이 엉뚱한 컨트랙트를 가리킨다
        for name, actual in ((ROLE_MANAGER, role_manager), (BUDGET_TOKEN, budget_token)):
            if actual.lower() != d.contracts[name].address.lower():
                raise ChainSetupError(f"원장이 가리키는 {name} 가 배포 기록과 다르다")
        if bytes(relayer_role) != _NO_ROLE:
            raise ChainSetupError(
                f"릴레이어 키({self.relayer_address})가 임원 롤을 가진 주소다. 서버는 임원 키를 갖지 않는다 (PRD §9.2) — "
                "RELAYER_PRIVATE_KEY 에 릴레이어 전용 키를 넣는다"
            )
        if balance == 0:
            raise ChainSetupError(f"릴레이어({self.relayer_address}) 잔액이 0 이라 가스를 낼 수 없다")

    # ------------------------------------------------------------ ChainClient

    def signer_of(self, payload: Union[RecordRequest, ConfirmApproval, RejectDecision], signature: str) -> str:
        return eip712.recover_signer(eip712.typed_data_for(payload, self._deployment.eip712[LEDGER]), signature)

    async def get_entry(self, entry_id: int) -> Optional[ChainEntry]:
        raise NotImplementedError("get_entry 는 아직 구현되지 않았다")

    async def record_pending(self, request: RecordRequest, signature: str) -> TxResult:
        raise NotImplementedError("record_pending 은 아직 구현되지 않았다")

    async def confirm_entry(self, approval: ConfirmApproval, signature: str) -> TxResult:
        raise NotImplementedError("confirm_entry 는 아직 구현되지 않았다")

    async def reject_entry(self, decision: RejectDecision, signature: str) -> TxResult:
        raise NotImplementedError("반려 릴레이는 이번 범위가 아니다")
