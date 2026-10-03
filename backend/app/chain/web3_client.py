"""ChainClient 의 실제 구현 — 서버 릴레이어.

임원 기기가 서명한 값을 받아 릴레이어 계정으로 트랜잭션을 보낸다. 가스는 릴레이어가 낸다 (PRD §9.2).
릴레이어 키는 전송에만 쓰고 서명 대상에는 서명하지 않는다. 임원 롤을 가진 주소의 키면 시작을 거부한다 —
서버가 임원 키를 가지면 승인 없이 확정을 올릴 수 있어 신뢰 모델이 무너진다.

connect() 가 연결과 시작 점검을 끝낸 클라이언트만 돌려준다. 배포 기록은 그때 읽어 두고, is_current() 로
배포 기록·ABI 파일이 그대로인지·원장에 아직 코드가 있는지 확인한다. provider 가 요청마다 이걸 보고, 재배포로 주소나
ABI 가 바뀌었거나 노드가 재시작돼 체인이 비었으면 클라이언트를 새로 만든다.

트랜잭션은 로컬에서 서명해 raw 로 보낸다. 브로드캐스트 전에 tx hash 를 알아야 tx_pending 을 먼저 기록할 수 있다.
쓰기는 릴레이어 주소마다 lock 하나로 직렬화한다 — 키가 하나라 동시에 보내면 nonce 가 겹친다. lock 은 클라이언트가
아니라 주소에 붙어 있어 교체 전후의 클라이언트도 같은 lock 을 쓰고, close() 는 보내던 트랜잭션이 끝난 뒤 닫는다.
다른 프로세스와는 나누지 못하니 uvicorn 워커는 1개로 띄운다.
"""
import asyncio
import json
import re
import time
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
from app.chain.revert import RevertDecoder

LEDGER = "AccountingLedger"
ROLE_MANAGER = "RoleManager"
BUDGET_TOKEN = "BudgetToken"
CONTRACTS = (LEDGER, ROLE_MANAGER, BUDGET_TOKEN)

RPC_TIMEOUT_SECONDS = 10
RECEIPT_TIMEOUT_SECONDS = 30  # 쓰기 메서드가 receipt 를 기다리는 한도. 넘으면 ChainUnavailable
CODE_CHECK_SECONDS = 5  # is_current 가 원장 코드를 다시 확인하는 간격. 그 사이 요청은 RPC 없이 통과한다

# 노드에 닿지 못한 실패
CONNECTION_ERRORS = (aiohttp.ClientError, OSError, ProviderConnectionError)  # asyncio·aiohttp 타임아웃은 OSError 계열
# 주소의 서버가 JSON-RPC 가 아닌 응답(HTML 점검 페이지 등)을 줬다. 예외 메시지에 응답 본문이 들어 있어 그대로 내보내지 않는다
RESPONSE_ERRORS = (json.JSONDecodeError,)
# 노드 상태를 확인할 수 없는 실패. 확인할 수 없는 것과 낡은 것은 다르다 (is_current)
UNREACHABLE = CONNECTION_ERRORS + RESPONSE_ERRORS

_PRIVATE_KEY = re.compile(r"0x[0-9a-fA-F]{64}")
_NO_ROLE = b"\x00" * 32

# 릴레이어 주소 → (이벤트 루프, lock). asyncio.Lock 은 루프에 묶이니 루프가 바뀌면 새로 만든다
_send_locks: dict[str, tuple[asyncio.AbstractEventLoop, asyncio.Lock]] = {}


def _send_lock_for(address: str) -> asyncio.Lock:
    loop = asyncio.get_running_loop()
    held = _send_locks.get(address)
    if held is None or held[0] is not loop:
        held = (loop, asyncio.Lock())
        _send_locks[address] = held
    return held[1]


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
    """점검 중 난 예외를 원인에 맞는 안내로 바꾼다. 노드가 멀쩡한데 재시작하라고 하지 않게 원인을 가른다."""
    if isinstance(e, CONNECTION_ERRORS):
        return ChainSetupError(f"노드에 연결할 수 없다 ({type(e).__name__}). 노드가 켜져 있는지, CHAIN_RPC_URL 을 확인한다")
    if isinstance(e, RESPONSE_ERRORS):
        return ChainSetupError(
            "CHAIN_RPC_URL 의 서버가 JSON-RPC 응답을 주지 않는다 (다른 서버이거나 점검 페이지). 주소와 포트를 확인한다"
        )
    return ChainSetupError(
        f"노드는 응답했지만 배포 기록·ABI 가 지금 체인의 컨트랙트와 맞지 않는다 ({type(e).__name__}). "
        "contracts 에서 다시 배포해 배포 기록과 ABI 를 갱신한다"
    )


# 컨트랙트끼리 가리키는 주소. (컨트랙트, 함수) → 그 함수가 돌려줘야 하는 배포 기록의 컨트랙트.
# deploy.ts 가 배포 직후 확인하는 네 가지와 같다
_LINKS = {
    (LEDGER, "roleManager"): ROLE_MANAGER,
    (LEDGER, "budgetToken"): BUDGET_TOKEN,
    (BUDGET_TOKEN, "ledger"): LEDGER,
    (BUDGET_TOKEN, "roleManager"): ROLE_MANAGER,
}


def _link_problem(d: Deployment, links: dict) -> Optional[str]:
    """컨트랙트끼리 가리키는 주소가 배포 기록과 맞는지. links 는 {(컨트랙트, 함수): 체인이 돌려준 주소}.

    하나라도 다르면 일부만 다시 배포된 조합이다 — 예를 들어 원장만 새로 배포하면 BudgetToken.ledger() 는
    옛 원장이라(setLedger 는 한 번만) 모든 지출 확정이 BudgetToken 에서 막힌다.
    """
    for (owner, function), target in _LINKS.items():
        if links[(owner, function)].lower() != d.contracts[target].address.lower():
            return (
                f"{owner}.{function}() 가 배포 기록의 {target} 와 다르다. 컨트랙트가 일부만 다시 배포됐다 — "
                "contracts 에서 전체를 다시 배포한다"
            )
    return None


def _stamp(path: Path) -> Optional[tuple]:
    try:
        stat = path.stat()
    except OSError:
        return None
    return (stat.st_mtime_ns, stat.st_size)


async def _attempt(make):
    # 호출을 만드는 것부터 코루틴 안에서 한다. ABI 에 함수가 없을 때의 동기 예외(ABIFunctionNotFound)도
    # gather 가 결과로 받고, 이미 만든 다른 코루틴이 기다려지지 않은 채 버려지지 않는다
    return await make()


class Web3ChainClient:
    """AccountingLedger 릴레이어. 만들 때는 connect() 를 쓴다."""

    def __init__(
        self, w3: AsyncWeb3, account: LocalAccount, deployment: Deployment, contracts: dict, deployment_file: Path
    ):
        self._w3 = w3
        self._account = account
        self._deployment = deployment
        self._deployment_file = deployment_file
        self._contracts = contracts
        self._ledger = contracts[LEDGER]
        self._role_manager = contracts.get(ROLE_MANAGER)
        self._budget_token = contracts.get(BUDGET_TOKEN)
        self._reverts = RevertDecoder(self._ledger.abi)
        self._stamps = self._file_stamps()
        self._code_checked_at = time.monotonic()
        self._closed = False

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
        abis = {name: load_abi(deployment.contracts[name], path) for name in CONTRACTS}
        w3 = AsyncWeb3(
            AsyncHTTPProvider(
                rpc_url,
                request_kwargs={"timeout": aiohttp.ClientTimeout(total=RPC_TIMEOUT_SECONDS)},
                # 재시도는 이번 범위가 아니다. 실패는 바로 올려 보내고, 호출하는 쪽이 get_entry 로 확인한다 (CHAIN_CLIENT §4)
                exception_retry_configuration=None,
            )
        )
        try:
            contracts = {
                name: w3.eth.contract(address=AsyncWeb3.to_checksum_address(deployment.contracts[name].address), abi=abi)
                for name, abi in abis.items()
            }
            client = cls(w3, account, deployment, contracts, path)
        except (Web3Exception, ValueError, KeyError, TypeError) as e:
            # load_abi 의 구조 검사를 지난 뒤에도 web3·해석기가 받지 못하는 ABI. 503 으로 가게 배포 문제로 올린다
            raise DeploymentError(
                f"ABI 로 컨트랙트를 만들 수 없습니다 ({type(e).__name__}). contracts 에서 다시 배포해 ABI 를 갱신하세요"
            ) from e
        try:
            await client._check_setup()
        except BaseException:
            await client.close()
            raise
        return client

    async def close(self) -> None:
        """보내던 트랜잭션이 끝난 뒤 연결을 닫는다. 닫힌 클라이언트는 다시 쓰지 않는다 (is_current 가 False)."""
        async with self._send_lock:
            self._closed = True
            await self._w3.provider.disconnect()

    @property
    def _send_lock(self) -> asyncio.Lock:
        return _send_lock_for(self.relayer_address)

    def _file_stamps(self) -> dict:
        files = [self._deployment_file] + [
            self._deployment_file.parent / self._deployment.contracts[name].abi for name in CONTRACTS
        ]
        return {f: _stamp(f) for f in files}

    async def is_current(self) -> bool:
        """이 클라이언트를 계속 써도 되면 True. **확실히 낡았을 때만** False 다.

        낡은 경우: 배포 기록·ABI 가 바뀜(재배포로 주소 변경, 같은 주소에 고친 컨트랙트 재배포), 노드가 재시작돼
        원장에 코드가 없음, 이미 닫힘. 노드에 닿지 못해 확인할 수 없으면 True 다 — 교체해도 나아지지 않고,
        교체가 잦으면 보내던 트랜잭션과 엇갈린다. 실제 호출이 실패를 알린다.
        파일은 수정 시각·크기가 바뀌었을 때만 다시 읽고, 원장 코드는 CODE_CHECK_SECONDS 간격으로만 확인한다.
        """
        if self._closed:
            return False
        stamps = self._file_stamps()
        if stamps != self._stamps:
            try:
                deployment = load_deployment(self._deployment_file)
                if deployment != self._deployment:
                    return False
                for name in CONTRACTS:
                    if load_abi(deployment.contracts[name], self._deployment_file) != self._contracts[name].abi:
                        return False
            except DeploymentError:
                return False
            self._stamps = stamps  # 다시 써졌지만 내용은 같다 (재배포로 deployedAt 만 바뀐 경우 등)
        now = time.monotonic()
        if now - self._code_checked_at < CODE_CHECK_SECONDS:
            return True
        try:
            code = await self._w3.eth.get_code(self._ledger.address)
        except (*UNREACHABLE, Web3Exception):
            return True
        if len(code) == 0:
            return False
        self._code_checked_at = now
        return True

    def _ensure_open(self) -> None:
        """쓰기·조회 전에 부른다. provider 가 교체해 닫은 클라이언트를 쥐고 있던 요청은 다시 요청하게 한다."""
        if self._closed:
            raise ChainSetupError("체인 클라이언트가 교체됐다. 요청을 다시 보낸다")

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
        except (*UNREACHABLE, Web3Exception) as e:
            raise _setup_error(e) from e

    async def _run_checks(self) -> None:
        # 네트워크 없이 먼저 본다. 이름이 어긋나면 revert 가 전부 UNKNOWN 이 돼 원인을 가를 수 없다
        missing = self._reverts.missing_reasons()
        if missing:
            raise ChainSetupError(
                f"원장 ABI 에 백엔드가 아는 에러가 없다: {', '.join(r.value for r in missing)}. "
                "컨트랙트의 에러 이름·시그니처가 바뀌었으면 backend/app/chain/models.py 의 RevertReason 도 맞춘다"
            )

        d = self._deployment
        eth = self._w3.eth
        chain_id = await eth.chain_id
        if chain_id != d.chain_id:
            raise ChainSetupError(f"연결한 체인({chain_id})이 배포 기록의 체인({d.chain_id})과 다르다")

        # 나머지는 서로 기다릴 필요가 없다. 판정은 아래에서 순서대로 한다 — 코드가 없으면 다른 호출의 실패는 그 결과일 뿐이다
        contracts = self._contracts
        calls = {
            **{("code", name): (lambda c=contracts[name]: eth.get_code(c.address)) for name in CONTRACTS},
            **{("separator", name): (lambda c=contracts[name]: c.functions.DOMAIN_SEPARATOR().call()) for name in CONTRACTS},
            **{link: (lambda owner=link[0], fn=link[1]: getattr(contracts[owner].functions, fn)().call()) for link in _LINKS},
            "relayer_role": lambda: contracts[ROLE_MANAGER].functions.roleOf(self.relayer_address).call(),
            "balance": lambda: eth.get_balance(self.relayer_address),
        }
        results = dict(zip(calls, await asyncio.gather(*(_attempt(make) for make in calls.values()), return_exceptions=True)))

        for name in CONTRACTS:
            code = results[("code", name)]
            if isinstance(code, BaseException):
                raise code
            if len(code) == 0:
                raise ChainSetupError(
                    f"{name} 주소에 컨트랙트가 없다. 노드가 재시작돼 체인이 비었으면 contracts 에서 npm run deploy:local 로 다시 배포한다"
                )
        for result in results.values():
            if isinstance(result, BaseException):
                raise result

        for name in CONTRACTS:
            if "0x" + bytes(results[("separator", name)]).hex() != d.eip712[name].domain_separator:
                raise ChainSetupError(f"{name} 의 DOMAIN_SEPARATOR 가 배포 기록과 다르다. 배포 기록이 지금 체인의 것이 아니다")
        problem = _link_problem(d, {link: results[link] for link in _LINKS})
        if problem:
            raise ChainSetupError(problem)
        if bytes(results["relayer_role"]) != _NO_ROLE:
            raise ChainSetupError(
                f"릴레이어 키({self.relayer_address})가 임원 롤을 가진 주소다. 서버는 임원 키를 갖지 않는다 (PRD §9.2) — "
                "RELAYER_PRIVATE_KEY 에 릴레이어 전용 키를 넣는다"
            )
        if results["balance"] == 0:
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
