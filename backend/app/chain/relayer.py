"""릴레이어 계정 하나로 여러 컨트랙트에 트랜잭션을 보내고 읽는다.

nonce 를 이 객체가 관리하므로 같은 계정을 쓰는 클라이언트(원장·이의 등)는 반드시 하나를 나눠 쓴다.
따로 만들면 둘이 같은 nonce 를 골라 한쪽 트랜잭션이 밀려난다.
"""
import asyncio
import math
from collections.abc import Awaitable, Sequence
from typing import Any, Optional, TypeVar

import aiohttp
from eth_account import Account
from eth_utils import keccak, to_checksum_address
from hexbytes import HexBytes
from web3 import AsyncHTTPProvider, AsyncWeb3
from web3.exceptions import BlockNotFound, ContractLogicError, ProviderConnectionError, Web3RPCError

from app.chain.eip712 import Eip712Domain, domain_separator
from app.chain.models import ChainConfigError, ChainNotSent, ChainRevert, ChainUnavailable, RevertReason
from app.chain.revert import decode_revert, load_abi, signature
from app.chain.settings import ChainSettings

T = TypeVar("T")

# 노드가 요청을 받았는지조차 모르는 실패. revert 가 아니다
TRANSPORT_ERRORS = (Web3RPCError, ProviderConnectionError, aiohttp.ClientError, asyncio.TimeoutError, OSError)

# eth_sendRawTransaction 이 이렇게 거부하면 이미 멤풀에 있는 것이다 — 보낸 것으로 본다
_ALREADY_KNOWN = ("already known", "known transaction", "already imported")


class _NotMined(Exception):
    """재전송까지 했는데 시한 안에 블록에 들어가지 않았다. tx 는 마지막으로 보낸 것."""

    def __init__(self, tx: dict, tx_hash: str):
        self.tx = tx
        self.tx_hash = tx_hash


class Contract:
    """주소·ABI·이벤트 topic 과, 이 컨트랙트 호출이 revert 할 때 해석에 쓸 ABI 이름들."""

    def __init__(self, w3: AsyncWeb3, address: str, abi_name: str, errors: tuple[str, ...]):
        abi = load_abi(abi_name)
        self.web3 = w3.eth.contract(address=to_checksum_address(address), abi=abi)
        self.address: str = self.web3.address
        self.errors = errors
        self.topics = {i["name"]: "0x" + keccak(text=signature(i)).hex() for i in abi if i["type"] == "event"}

    def encode(self, function: str, args: list) -> str:
        return self.web3.encode_abi(function, args=args)

    def decode_logs(self, logs: Sequence[Any], names: tuple[str, ...]) -> list:
        """이 컨트랙트의 names 이벤트만 해석한다. names 순서로 정렬하고, 같은 이벤트끼리는 받은 순서를 지킨다."""
        wanted = {self.topics[n]: n for n in names}
        found = []
        for log in logs:
            if log["address"].lower() != self.address.lower() or not log["topics"]:
                continue
            name = wanted.get(HexBytes(log["topics"][0]).to_0x_hex())
            if name:
                found.append(getattr(self.web3.events, name)().process_log(log))
        return sorted(found, key=lambda e: names.index(e["event"]))


class Web3Relayer:
    def __init__(self, settings: ChainSettings, w3: Optional[AsyncWeb3] = None):
        self.settings = settings
        self.w3 = w3 or AsyncWeb3(AsyncHTTPProvider(settings.rpc_url))
        self._account = Account.from_key(settings.relayer_private_key.get_secret_value())
        self._nonce_lock = asyncio.Lock()
        self._next_nonce: Optional[int] = None

    @property
    def address(self) -> str:
        return self._account.address

    def contract(self, address: str, abi_name: str, errors: tuple[str, ...] = ()) -> Contract:
        return Contract(self.w3, address, abi_name, errors)

    # ------------------------------------------------------------ 시작 점검

    async def check(self) -> list[str]:
        """노드가 설정한 체인인지 본다. 어긋나면 ChainConfigError, 잔고가 적으면 경고 문구."""
        s = self.settings
        chain_id = await self.rpc(self.w3.eth.chain_id)
        if chain_id != s.chain_id:
            raise ChainConfigError(f"chainId 가 다르다: 설정 {s.chain_id}, 노드 {chain_id}")
        balance = await self.rpc(self.w3.eth.get_balance(self.address))
        if balance < s.min_relayer_balance_wei:
            return [f"릴레이어 {self.address} 잔고가 {balance} wei 다. 가스를 대납하지 못할 수 있다"]
        return []

    async def check_contract(self, contract: Contract, domain: Optional[Eip712Domain] = None) -> None:
        """주소에 컨트랙트가 있는지, 서명 도메인이 서버 계산값과 같은지."""
        if not await self.rpc(self.w3.eth.get_code(contract.address)):
            raise ChainConfigError(f"{contract.address} 에 컨트랙트가 없다")
        if domain is None:
            return
        onchain = HexBytes(await self.rpc(contract.web3.functions.DOMAIN_SEPARATOR().call())).to_0x_hex()
        expected = domain_separator(domain)
        if onchain != expected:
            raise ChainConfigError(
                f"{domain.name} DOMAIN_SEPARATOR 가 다르다: 컨트랙트 {onchain}, 서버 {expected}. "
                "이대로면 모든 서명이 권한 없음으로 실패한다"
            )

    # ------------------------------------------------------------ 읽기

    async def rpc(self, awaitable: Awaitable[T], errors: tuple[str, ...] = (), tx_hash: Optional[str] = None) -> T:
        try:
            return await awaitable
        except ContractLogicError as e:
            raise decode_revert(e.data, str(e), errors) from e
        except TRANSPORT_ERRORS as e:
            raise ChainUnavailable(f"RPC 실패: {e}", tx_hash) from e

    async def safe_block(self) -> int:
        """뒤집히지 않는다고 보는 마지막 블록. 장부 잔액 집계가 여기까지만 읽는다.

        노드가 finalized 태그를 주면 그 블록, 못 주면 head − finality_blocks. 보낼 때의 confirmations 와는 따로다 —
        그 값은 요청 응답을 얼마나 기다릴지이고, 한번 저장하면 되돌리지 않는 합계에는 더 깊은 확정이 필요하다.
        """
        try:
            block = await self.w3.eth.get_block("finalized")
            return block["number"]
        except (Web3RPCError, BlockNotFound):  # 태그를 모르는 노드이거나 아직 확정 블록이 없다
            pass
        except TRANSPORT_ERRORS as e:
            raise ChainUnavailable(f"RPC 실패: {e}") from e
        head = await self.rpc(self.w3.eth.block_number)
        return max(head - self.settings.finality_blocks, -1)

    async def find_events(self, contract: Contract, names: tuple[str, ...], topic1: str) -> list:
        """첫 indexed 인자가 topic1 인 이벤트를 최신 블록부터 deploy_block 까지 나눠 거슬러 찾는다. 대조는 대개 최근 것을 찾는다."""
        s = self.settings
        to_block = await self.rpc(self.w3.eth.block_number)
        while to_block >= s.deploy_block:
            from_block = max(s.deploy_block, to_block - s.log_chunk_blocks + 1)
            events = await self._logs(contract, names, from_block, to_block, topic1)
            if events:
                return events
            to_block = from_block - 1
        return []

    async def events_between(self, contract: Contract, names: tuple[str, ...], from_block: int, to_block: int) -> list:
        """두 블록을 포함한 구간의 이벤트를 앞에서부터 나눠 읽는다. 블록 순서대로."""
        s = self.settings
        found = []
        start = max(from_block, s.deploy_block)
        while start <= to_block:
            end = min(to_block, start + s.log_chunk_blocks - 1)
            found.extend(await self._logs(contract, names, start, end))
            start = end + 1
        return found

    async def _logs(self, contract: Contract, names, from_block: int, to_block: int, topic1: Optional[str] = None) -> list:
        topics: list = [[contract.topics[n] for n in names]]
        if topic1 is not None:
            topics.append(topic1)
        logs = await self.rpc(
            self.w3.eth.get_logs(
                {"address": contract.address, "fromBlock": from_block, "toBlock": to_block, "topics": topics}
            )
        )
        return contract.decode_logs(logs, names)

    # ------------------------------------------------------------ 보내기

    async def send(self, contract: Contract, data: str) -> Any:
        """보내고 확인 블록까지 기다린 영수증을 돌려준다.

        Raises:
            ChainRevert: 가스 추정에서 revert (보내지 않았다), 또는 블록에 들어갔지만 실패.
            ChainNotSent: 보내기 전 RPC 실패, 또는 노드가 거부했다 (잔고 부족·nonce 어긋남 등). 체인에 없는 것이 확정.
            ChainUnavailable: 보낸 뒤 결과를 모른다 (tx_hash 있음).
        """
        s = self.settings
        call = {"from": self.address, "to": contract.address, "data": data}
        try:
            gas = await self.rpc(self.w3.eth.estimate_gas(call), contract.errors)  # revert 될 호출은 여기서 걸러져 가스를 안 쓴다
        except ChainUnavailable as e:
            raise ChainNotSent(f"가스 추정 실패: {e}") from e

        async with self._nonce_lock:  # 계정 하나로 동시에 보내므로 nonce 를 순서대로 준다
            try:
                if self._next_nonce is None:
                    self._next_nonce = await self.rpc(self.w3.eth.get_transaction_count(self.address, "pending"))
                fees = await self._market_fees()
            except ChainUnavailable as e:
                raise ChainNotSent(f"전송 준비 실패: {e}") from e
            tx = {
                "type": 2,
                "chainId": s.chain_id,
                "nonce": self._next_nonce,
                "to": contract.address,
                "data": data,
                "value": 0,
                "gas": int(gas * s.gas_buffer),
                **fees,
            }
            tx_hash, raw = self._sign(tx)
            try:
                await self.w3.eth.send_raw_transaction(raw)
            except Web3RPCError as e:
                if not any(known in str(e).lower() for known in _ALREADY_KNOWN):
                    self._next_nonce = None  # nonce 가 어긋났을 수 있다. 다음 전송 때 체인에서 다시 읽는다
                    raise ChainNotSent(f"노드가 받지 않았다: {e}", tx_hash) from e
            except TRANSPORT_ERRORS as e:
                self._next_nonce = None  # 노드가 받았는지 모르므로 다음 전송 때 체인에서 다시 읽는다
                raise ChainUnavailable(f"전송 실패: {e}", tx_hash) from e
            self._next_nonce += 1

        try:
            receipt = await self._wait(tx, tx_hash)
        except _NotMined as stuck:
            await self._abandon(stuck.tx)
            raise ChainUnavailable("영수증을 기다리다 시간이 지났다", stuck.tx_hash) from None
        if receipt["status"] != 1:
            raise await self._replay(contract, call, receipt)
        return receipt

    def _sign(self, tx: dict) -> tuple[str, bytes]:
        signed = self._account.sign_transaction(tx)
        return HexBytes(signed.hash).to_0x_hex(), signed.raw_transaction

    async def _market_fees(self) -> dict:
        block = await self.rpc(self.w3.eth.get_block("latest"))
        priority = await self.rpc(self.w3.eth.max_priority_fee)
        return {"maxPriorityFeePerGas": priority, "maxFeePerGas": block["baseFeePerGas"] * 2 + priority}  # 기본료가 두 배가 돼도 버틴다

    async def _wait(self, tx: dict, tx_hash: str) -> Any:
        """영수증을 기다린다. replace_after_seconds 동안 안 들어가면 수수료를 올려 같은 nonce 로 다시 보낸다.

        보낸 것 중 어느 것이든 먼저 들어간 것의 영수증을 돌려준다. 같은 nonce 라 둘 이상 들어갈 수는 없다.
        """
        s = self.settings
        loop = asyncio.get_running_loop()
        give_up = loop.time() + s.receipt_timeout_seconds
        replace_at = loop.time() + s.replace_after_seconds
        hashes, replacements = [tx_hash], 0
        while True:
            for sent in hashes:
                receipt = await self._receipt(sent)
                if receipt is not None:
                    return await self._confirm(receipt, sent, give_up)
            now = loop.time()
            if now > give_up:
                raise _NotMined(tx, hashes[-1])
            if now >= replace_at and replacements < s.max_replacements:
                replacements += 1
                replace_at = now + s.replace_after_seconds
                replacement = await self._replace(tx)
                if replacement is not None:
                    tx, new_hash = replacement
                    hashes.append(new_hash)
            await asyncio.sleep(s.poll_seconds)

    async def _bumped_fees(self, tx: dict) -> Optional[dict]:
        """같은 nonce 를 교체할 수수료. 직전 수수료 × fee_bump 와 지금 시세 중 큰 값. 시세를 못 읽으면 None."""
        s = self.settings
        try:
            market = await self._market_fees()
        except ChainUnavailable:
            return None
        priority = max(math.ceil(tx["maxPriorityFeePerGas"] * s.fee_bump), market["maxPriorityFeePerGas"])
        max_fee = max(math.ceil(tx["maxFeePerGas"] * s.fee_bump), market["maxFeePerGas"], priority)
        return {"maxPriorityFeePerGas": priority, "maxFeePerGas": max_fee}

    async def _replace(self, tx: dict) -> Optional[tuple[dict, str]]:
        fees = await self._bumped_fees(tx)
        if fees is None:
            return None
        bumped = {**tx, **fees}
        tx_hash, raw = self._sign(bumped)
        try:
            await self.w3.eth.send_raw_transaction(raw)
        except TRANSPORT_ERRORS:
            return None  # 앞선 것이 이미 들어갔거나(nonce too low) 노드가 거부했다. 앞선 것을 계속 기다린다
        return bumped, tx_hash

    async def _abandon(self, tx: dict) -> None:
        """끝내 안 들어간 nonce 를 0원 자기 전송으로 덮어 비운다. 그대로 두면 뒤 트랜잭션이 전부 그 뒤에 줄을 선다.

        기다리지 않고 보내기만 한다. 원래 트랜잭션이 먼저 들어갔으면 nonce too low 로 거부되는데, 어느 쪽이든 nonce 는 소모된다.
        덮어쓰기를 보내지 못하면(노드가 그 nonce 를 잃어버렸거나 연결 실패) 다음 전송 때 nonce 를 체인에서 다시 읽는다.
        """
        fees = await self._bumped_fees(tx) or {k: tx[k] for k in ("maxPriorityFeePerGas", "maxFeePerGas")}
        cancel = {
            "type": 2, "chainId": tx["chainId"], "nonce": tx["nonce"], "to": self.address,
            "data": "0x", "value": 0, "gas": 21_000, **fees,
        }
        _, raw = self._sign(cancel)
        try:
            await self.w3.eth.send_raw_transaction(raw)
        except TRANSPORT_ERRORS:
            async with self._nonce_lock:
                self._next_nonce = None

    async def _receipt(self, tx_hash: str) -> Optional[Any]:
        try:
            return await self.w3.eth.get_transaction_receipt(tx_hash)
        except TRANSPORT_ERRORS:  # 아직 없음(TransactionNotFound)이거나 잠시 연결 실패. 계속 기다린다
            return None

    async def _confirm(self, receipt: Any, tx_hash: str, give_up: float) -> Any:
        s = self.settings
        if s.confirmations == 1:
            return receipt
        loop = asyncio.get_running_loop()
        while True:
            try:
                head = await self.rpc(self.w3.eth.block_number, tx_hash=tx_hash)
            except ChainUnavailable:
                head = None  # 잠깐 끊겼다. 시한까지는 계속 기다린다
            if head is not None and head - receipt["blockNumber"] + 1 >= s.confirmations:
                break
            if loop.time() > give_up:
                raise ChainUnavailable("확인 블록을 기다리다 시간이 지났다", tx_hash)
            await asyncio.sleep(s.poll_seconds)
        again = await self._receipt(tx_hash)
        if again is None or again["blockHash"] != receipt["blockHash"]:  # 기다리는 사이 블록이 바뀌었다. 대조에 맡긴다
            raise ChainUnavailable("확인 블록을 기다리는 사이 트랜잭션이 다른 블록으로 옮겨졌다", tx_hash)
        return receipt

    async def _replay(self, contract: Contract, call: dict, receipt: Any) -> ChainRevert:
        """실패한 영수증에는 이유가 없어서 직전 블록 상태로 다시 실행해 revert 데이터를 얻는다."""
        tx_hash = HexBytes(receipt["transactionHash"]).to_0x_hex()
        try:
            await self.w3.eth.call(call, block_identifier=receipt["blockNumber"] - 1)
        except ContractLogicError as e:
            return decode_revert(e.data, str(e), contract.errors)
        except TRANSPORT_ERRORS:
            return ChainRevert(RevertReason.UNKNOWN, f"tx={tx_hash} 실패. 이유를 다시 읽지 못했다")
        return ChainRevert(
            RevertReason.UNKNOWN, f"tx={tx_hash} 실패. 직전 블록에서는 성공한다 — 같은 블록의 앞선 트랜잭션 영향이거나 가스 부족"
        )


def tx_hash_of(event_or_receipt: Any) -> str:
    return HexBytes(event_or_receipt["transactionHash"]).to_0x_hex()


def bytes32(value: str) -> bytes:
    return bytes.fromhex(value[2:])


def topic_uint(value: int) -> str:
    return "0x" + value.to_bytes(32, "big").hex()
