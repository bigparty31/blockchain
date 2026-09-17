"""테스트용 가짜 JSON-RPC 노드와 값 만들기 도구. web3.py 를 실제로 거치게 하려고 provider 로 붙인다.

컨트랙트 로직은 흉내 내지 않는다. 각 테스트가 노드 응답(eth_call 결과, 가스 추정 revert, 영수증 로그)을 정한다.
"""
import asyncio
from typing import Callable

import aiohttp
from eth_abi import encode
from eth_account import Account
from eth_account.typed_transactions import TypedTransaction
from eth_utils import keccak, to_checksum_address
from hexbytes import HexBytes
from web3 import AsyncWeb3
from web3.providers.async_base import AsyncBaseProvider

from app.chain.revert import load_abi, signature
from app.chain.settings import ChainSettings

CHAIN_ID = 31337
LEDGER = to_checksum_address("0x" + "33" * 20)
ROLES = to_checksum_address("0x" + "66" * 20)
OBJECTIONS = to_checksum_address("0x" + "77" * 20)
SBT = to_checksum_address("0x" + "88" * 20)
BUDGET = to_checksum_address("0x" + "aa" * 20)
RELAYER_KEY = "0x" + "11" * 32
RELAYER = Account.from_key(RELAYER_KEY)

ABIS = {
    LEDGER: load_abi("IAccountingLedger"),
    ROLES: load_abi("IRoleManager"),
    OBJECTIONS: load_abi("IObjectionRegistry"),
    SBT: load_abi("IMembershipSBT"),
    BUDGET: load_abi("IBudgetToken"),
}
LEDGER_ABI = ABIS[LEDGER]
BUDGET_ABI = ABIS[BUDGET]
OBJECTION_ABI = ABIS[OBJECTIONS]


def run(coro):
    return asyncio.run(coro)


def settings(**overrides) -> ChainSettings:
    values = dict(
        rpc_url="http://unused", chain_id=CHAIN_ID, ledger_address=LEDGER, relayer_private_key=RELAYER_KEY,
        role_manager_address=ROLES, objection_address=OBJECTIONS, membership_address=SBT, budget_address=BUDGET,
        receipt_timeout_seconds=0.3, poll_seconds=0.01, min_relayer_balance_wei=10**17,
    )
    return ChainSettings(**{**values, **overrides})


def error_data(abi, name, *values) -> str:
    item = next(i for i in abi if i["type"] == "error" and i["name"] == name)
    return "0x" + (keccak(text=signature(item))[:4] + encode([i["type"] for i in item["inputs"]], values)).hex()


def encoded(types, values) -> str:
    return "0x" + encode(types, values).hex()


def contract_log(address, name, block, tx_hash, **args) -> dict:
    item = next(i for i in ABIS[address] if i["type"] == "event" and i["name"] == name)
    topics = ["0x" + keccak(text=signature(item)).hex()]
    data_types, data_values = [], []
    for i in item["inputs"]:
        if i["indexed"]:
            topics.append("0x" + encode([i["type"]], [args[i["name"]]]).hex())
        else:
            data_types.append(i["type"])
            data_values.append(args[i["name"]])
    return {
        "address": address, "topics": topics, "data": "0x" + encode(data_types, data_values).hex(),
        "blockNumber": hex(block), "blockHash": "0x" + f"{block:064x}", "transactionHash": tx_hash,
        "transactionIndex": "0x0", "logIndex": "0x0", "removed": False,
    }


def event_log(name, block, tx_hash, **args) -> dict:
    return contract_log(LEDGER, name, block, tx_hash, **args)


class FakeNode(AsyncBaseProvider):
    """쓰는 RPC 메서드만 답하는 노드. 요청 기록은 requests 에 남는다.

    mine(tx) 가 False 인 트랜잭션은 멤풀에 남는다. 영수증을 조회할 때마다 다시 판정하므로 테스트가 조건을 바꾸면
    그다음 조회에서 들어간다. 같은 nonce 는 하나만 들어간다.
    """

    def __init__(self):
        super().__init__()
        self.requests: list[str] = []
        self.chain_id = CHAIN_ID
        self.head = 100
        self.nonce = 7
        self.balance = 10**18
        self.base_fee = 3 * 10**9
        self.finalized: int | None = None  # None 이면 finalized 태그를 모르는 노드
        self.priority_fee = 10**9
        self.code = "0x6080"
        self.calls: dict[str, object] = {}  # 함수 이름 → 반환 hex 또는 {"revert": hex}
        self.call_args: list[tuple[str, dict]] = []
        self.estimate: object = 90_000  # 가스 또는 {"revert": hex}
        self.outcome = {"status": 1, "logs": lambda tx_hash, block: []}
        self.mine: Callable[[dict], bool] | bool = True
        self.advance_on_block_number = False
        self.fail: set[str] = set()  # 한 번 연결 실패로 끝낼 메서드
        self.reject_send: str | None = None  # 다음 eth_sendRawTransaction 을 이 RPC 에러로 거부한다
        self.sent: list[dict] = []
        self.mempool: dict[str, dict] = {}
        self.mined_nonces: set[int] = set()
        self.receipts: dict[str, dict] = {}
        self.logs: list[dict] = []
        self.log_ranges: list[tuple[int, int]] = []  # eth_getLogs 가 요청한 (fromBlock, toBlock)
        self._contracts = {address: AsyncWeb3().eth.contract(address=address, abi=abi) for address, abi in ABIS.items()}

    async def is_connected(self, show_traceback=False):
        return True

    def decode_input(self, tx: dict):
        """보낸 트랜잭션의 (함수, 인자)."""
        return self._contracts[to_checksum_address(tx["to"])].decode_function_input(tx["data"])

    async def make_request(self, method, params):
        await asyncio.sleep(0)  # 실제 네트워크처럼 응답을 기다리는 사이 다른 요청이 끼어들게 한다
        self.requests.append(method)
        if method in self.fail:
            self.fail.discard(method)
            raise aiohttp.ClientConnectionError("노드에 닿지 않음")
        result = self._answer(method, params)
        if isinstance(result, dict) and "revert" in result:
            return {"jsonrpc": "2.0", "id": 1, "error": {"code": 3, "message": "execution reverted", "data": result["revert"]}}
        if isinstance(result, dict) and "rpc_error" in result:
            return {"jsonrpc": "2.0", "id": 1, "error": {"code": -32000, "message": result["rpc_error"]}}
        return {"jsonrpc": "2.0", "id": 1, "result": result}

    def _answer(self, method, params):
        if method == "eth_chainId":
            return hex(self.chain_id)
        if method == "eth_blockNumber":
            if self.advance_on_block_number:
                self.head += 1
            return hex(self.head)
        if method == "eth_getCode":
            return self.code
        if method == "eth_getBalance":
            return hex(self.balance)
        if method == "eth_getTransactionCount":  # "pending" — 멤풀·채굴된 것 다음 번호
            used = self.mined_nonces | {tx["nonce"] for tx in self.mempool.values()}
            return hex(max([self.nonce, *(n + 1 for n in used)]))
        if method == "eth_maxPriorityFeePerGas":
            return hex(self.priority_fee)
        if method == "eth_getBlockByNumber" and params[0] == "finalized":
            if self.finalized is None:
                return {"rpc_error": "unknown block tag finalized"}
            return {"number": hex(self.finalized), "hash": "0x" + f"{self.finalized:064x}", "baseFeePerGas": hex(self.base_fee),
                    "timestamp": hex(1_790_000_000), "transactions": []}
        if method == "eth_getBlockByNumber":
            return {"number": hex(self.head), "hash": "0x" + f"{self.head:064x}", "baseFeePerGas": hex(self.base_fee),
                    "timestamp": hex(1_790_000_000), "transactions": []}
        if method == "eth_estimateGas":
            return self.estimate if isinstance(self.estimate, dict) else hex(self.estimate)
        if method == "eth_call":
            contract = self._contracts[to_checksum_address(params[0]["to"])]
            fn, args = contract.decode_function_input(params[0]["data"])
            self.call_args.append((fn.fn_name, args))
            return self.calls[fn.fn_name]
        if method == "eth_sendRawTransaction":
            return self._send(params[0])
        if method == "eth_getTransactionReceipt":
            return self._receipt(params[0])
        if method == "eth_getLogs":
            return self._logs(params[0])
        raise AssertionError(f"FakeNode 가 모르는 메서드: {method}")

    def _send(self, raw_hex):
        raw = HexBytes(raw_hex)
        tx = TypedTransaction.from_bytes(raw).as_dict()
        if self.reject_send is not None:
            message, self.reject_send = self.reject_send, None
            return {"rpc_error": message}
        if tx["nonce"] in self.mined_nonces:
            return {"rpc_error": "nonce too low"}
        tx_hash = "0x" + keccak(raw).hex()
        tx = {**tx, "hash": tx_hash, "from": Account.recover_transaction(raw)}
        self.sent.append(tx)
        self.mempool[tx_hash] = tx
        self._try_mine(tx_hash)
        return tx_hash

    def _receipt(self, tx_hash):
        if tx_hash not in self.receipts and tx_hash in self.mempool:
            self._try_mine(tx_hash)
        return self.receipts.get(tx_hash)

    def _try_mine(self, tx_hash):
        tx = self.mempool[tx_hash]
        allowed = self.mine(tx) if callable(self.mine) else self.mine
        if not allowed or tx["nonce"] in self.mined_nonces:
            return
        self.mined_nonces.add(tx["nonce"])
        del self.mempool[tx_hash]
        self.head += 1
        logs = self.outcome["logs"](tx_hash, self.head)
        self.receipts[tx_hash] = {
            "transactionHash": tx_hash, "blockHash": "0x" + f"{self.head:064x}", "blockNumber": hex(self.head),
            "status": hex(self.outcome["status"]), "logs": logs, "gasUsed": hex(80_000), "cumulativeGasUsed": hex(80_000),
            "effectiveGasPrice": hex(4 * 10**9), "from": RELAYER.address, "to": tx["to"], "contractAddress": None,
            "logsBloom": "0x" + "00" * 256, "transactionIndex": "0x0", "type": "0x2",
        }

    def _logs(self, flt):
        lo, hi = int(flt["fromBlock"], 16), int(flt["toBlock"], 16)
        self.log_ranges.append((lo, hi))
        topic0 = flt["topics"][0]
        topic1 = flt["topics"][1] if len(flt["topics"]) > 1 else None
        addresses = flt["address"] if isinstance(flt["address"], list) else [flt["address"]]
        return [
            log for log in self.logs
            if log["address"].lower() in {a.lower() for a in addresses}
            and lo <= int(log["blockNumber"], 16) <= hi
            and log["topics"][0] in topic0
            and (topic1 is None or log["topics"][1] == topic1)
        ]
