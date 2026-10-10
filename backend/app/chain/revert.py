"""체인이 거부한 응답(revert 데이터)을 ChainRevert 로 바꾼다.

web3 는 커스텀 에러를 해석하지 않고 원본만 준다 — selector 4바이트 + ABI 인코딩 인자 (ContractCustomError.data).
해석 표는 원장 ABI 와 BudgetToken ABI 에서 만든다. ABI 가 배포 산출물이라 정본이고, 컨트랙트를 고쳐 다시 배포하면 따라간다.
RevertReason 의 값은 Solidity 에러 이름이다 (CHAIN_CLIENT §4). 원장은 확정 안에서 BudgetToken.spend·refund 를 부르고,
그 revert 는 원장 호출의 revert 로 그대로 올라온다. InsufficientBudget·BudgetExpired 는 원장 ABI 에도 같은 시그니처로
있지만 BudgetNotFound·RefundExceedsSpent·인자 없는 ZeroAmount() 는 BudgetToken ABI 에만 있다 (PR #20 2차 리뷰).

BudgetToken 에러는 spend·refund 가 내는 것만 이름으로 분류한다(_BUDGET_TOKEN_REASONS). TermRequired()·ReasonRequired()
처럼 원장 에러와 이름이 같아도 예산 발행·증액에서만 나는 것은 원장 호출에서 날 수 없어, 이름으로 붙이면 잘못 분류한다.
selector 가 원장 에러와 같으면(같은 시그니처) 원장 쪽을 쓴다.

어느 ABI 에도 없는 selector, RevertReason 에 없는 에러(생성자 전용 등), 빈 데이터, Panic, Error(string) 은
RevertReason.UNKNOWN 이다. revert 인 것은 확실하니 ChainRevert 로 두고 원인만 모른다고 알린다.

revert 는 두 경로로 온다. eth_call·eth_estimateGas 는 web3 가 ContractLogicError 로, eth_sendRawTransaction 은
노드의 JSON-RPC 에러(Web3RPCError)로 준다 — Hardhat automine 은 revert 하는 트랜잭션도 블록에 넣고 에러를 돌려준다.
revert 가 아닌 예외(연결 실패, 노드가 전송을 거절한 잔액 부족·nonce 등)는 None 이다. 그 둘을 가르는 것은 전송 경로다.
"""
from dataclasses import dataclass
from typing import Optional, Union

from eth_abi import decode as abi_decode
from eth_abi.exceptions import DecodingError
from eth_utils import function_signature_to_4byte_selector, to_checksum_address
from eth_utils.abi import abi_to_signature, collapse_if_tuple, filter_abi_by_type
from web3.exceptions import ContractLogicError, Web3RPCError

from app.chain.models import KIND_ORDER, STATUS_ORDER, ChainRevert, RevertReason

# Solidity 가 내장으로 쓰는 두 에러. 원장 ABI 에는 없다
_ERROR_STRING = function_signature_to_4byte_selector("Error(string)")
_PANIC = function_signature_to_4byte_selector("Panic(uint256)")

# web3 가 데이터 없는 revert 에 넣는 표식과, 일부 노드가 데이터 앞에 붙이는 접두사 (web3._utils.error_formatters_utils)
_MISSING_DATA = "no data"
_REVERTED_PREFIX = "Reverted "

# 이 원장의 enum 만 이름으로 바꾼다. 다른 컨트랙트에 같은 이름의 enum 이 있어도 원장 순서로 잘못 붙이지 않는다.
# 컨트랙트에서 enum 위치가 바뀌면 숫자로 보이고, tests/test_revert.py 가 알려준다
_ENUMS = {"enum IAccountingLedger.Status": STATUS_ORDER, "enum IAccountingLedger.Kind": KIND_ORDER}

# JSON-RPC 에러 코드 3 = execution reverted (EIP-1474). Hardhat·Geth 가 revert 에 쓴다
_RPC_REVERTED = 3

_KNOWN = {reason.value: reason for reason in RevertReason if reason is not RevertReason.UNKNOWN}
# 원장이 부르는 BudgetToken.spend·refund 가 내는 에러 (IBudgetToken). 이것만 BudgetToken ABI 에서 이름으로 분류한다
_BUDGET_TOKEN_REASONS = {
    RevertReason.INSUFFICIENT_BUDGET,
    RevertReason.BUDGET_EXPIRED,
    RevertReason.BUDGET_NOT_FOUND,
    RevertReason.REFUND_EXCEEDS_SPENT,
    RevertReason.ZERO_AMOUNT,
}
_DECODE_ERRORS = (DecodingError, ValueError, OverflowError)


def _show(value, item: dict) -> str:
    """로그·디버깅용 표기. 화면 문구로 쓰지 않는다."""
    enum = _ENUMS.get(item.get("internalType", ""))
    if enum is not None:
        return enum[value].value if 0 <= value < len(enum) else str(value)
    if item["type"] == "address":
        return to_checksum_address(value)
    if isinstance(value, bytes):
        return "0x" + value.hex()
    return str(value)


@dataclass(frozen=True)
class _Error:
    name: str
    reason: Optional[RevertReason]
    inputs: tuple
    source: str = "원장"

    def detail(self, body: bytes) -> str:
        try:
            values = abi_decode([collapse_if_tuple(i) for i in self.inputs], body)
        except _DECODE_ERRORS:
            return "인자 해석 실패"
        return ", ".join(f"{i.get('name') or f'arg{n}'}={_show(v, i)}" for n, (i, v) in enumerate(zip(self.inputs, values)))


def rpc_error_of(e: BaseException) -> dict:
    """Web3RPCError 의 JSON-RPC error 를 {code, message, data} 로. 노드 에러를 읽는 곳은 모두 이것을 쓴다.

    규격은 error 를 객체로 주지만 문자열만 주는 노드·프록시도 있다. message 는 없으면 예외 문자열이다.
    """
    response = getattr(e, "rpc_response", None)
    error = response.get("error") if isinstance(response, dict) else None
    if not isinstance(error, dict):
        error = {"message": str(error or e)}
    return {"code": error.get("code"), "message": str(error.get("message") or ""), "data": error.get("data")}


def _to_bytes(data: Union[str, bytes, None]) -> Optional[bytes]:
    """revert 데이터를 바이트로. 데이터가 없으면 b"", 형식이 틀리면 None."""
    if data is None or data == "" or data == _MISSING_DATA:
        return b""
    if isinstance(data, (bytes, bytearray)):
        return bytes(data)
    if isinstance(data, str):
        if data.startswith(_REVERTED_PREFIX):
            data = data[len(_REVERTED_PREFIX) :]
        if data.startswith("0x"):
            try:
                return bytes.fromhex(data[2:])
            except ValueError:
                return None
    return None


class RevertDecoder:
    """원장 ABI(와 BudgetToken ABI)로 만든 revert 해석기. 네트워크를 쓰지 않는다."""

    def __init__(self, abi: list, budget_token_abi: Optional[list] = None):
        self._errors: dict[bytes, _Error] = {}
        for item in filter_abi_by_type("error", abi):
            selector = function_signature_to_4byte_selector(abi_to_signature(item))
            self._errors[selector] = _Error(item["name"], _KNOWN.get(item["name"]), tuple(item.get("inputs", ())))
        for item in filter_abi_by_type("error", budget_token_abi or []):
            selector = function_signature_to_4byte_selector(abi_to_signature(item))
            if selector in self._errors:
                continue  # 원장에도 같은 시그니처로 있다 (InsufficientBudget·BudgetExpired)
            reason = _KNOWN.get(item["name"])
            self._errors[selector] = _Error(
                item["name"],
                reason if reason in _BUDGET_TOKEN_REASONS else None,
                tuple(item.get("inputs", ())),
                "BudgetToken",
            )

    def missing_reasons(self) -> list:
        """ABI 에 없는 RevertReason. 비어 있지 않으면 컨트랙트 에러 이름·시그니처가 백엔드와 달라졌다."""
        present = {e.reason for e in self._errors.values()}
        return [reason for reason in _KNOWN.values() if reason not in present]

    def decode(self, data: Union[str, bytes, None]) -> ChainRevert:
        raw = _to_bytes(data)
        if raw is None or 0 < len(raw) < 4:
            return ChainRevert(RevertReason.UNKNOWN, "revert 데이터 형식 오류")
        if not raw:
            return ChainRevert(RevertReason.UNKNOWN, "revert 데이터 없음")
        selector, body = raw[:4], raw[4:]
        if selector == _ERROR_STRING:
            try:
                (message,) = abi_decode(["string"], body)
            except _DECODE_ERRORS:
                message = "?"
            return ChainRevert(RevertReason.UNKNOWN, f'Error("{message}")')
        if selector == _PANIC:
            try:
                (code,) = abi_decode(["uint256"], body)
            except _DECODE_ERRORS:
                return ChainRevert(RevertReason.UNKNOWN, "Panic(?)")
            return ChainRevert(RevertReason.UNKNOWN, f"Panic({hex(code)})")
        error = self._errors.get(selector)
        if error is None:
            return ChainRevert(RevertReason.UNKNOWN, f"알 수 없는 에러 selector 0x{selector.hex()}")
        if error.reason is None:
            return ChainRevert(
                RevertReason.UNKNOWN, f"{error.name}({error.detail(body)}) — RevertReason 에 없는 {error.source} 에러"
            )
        # 인자가 깨져도 selector 가 맞으면 원인은 정해진다. 분류가 인자 때문에 UNKNOWN 이 되지 않게 한다
        return ChainRevert(error.reason, error.detail(body))

    def from_web3_error(self, e: BaseException) -> Optional[ChainRevert]:
        """web3 예외가 revert 면 ChainRevert, 아니면 None.

        None 은 "revert 가 아니다" 일 뿐이다. 연결 실패(들어갔는지 모름)와 노드가 전송을 확정적으로 거절한 경우
        (잔액 부족·nonce 등, 들어가지 않음)는 결과가 다르니 전송 경로가 가른다.
        """
        if isinstance(e, ContractLogicError):  # ContractCustomError·ContractPanicError 도 이 하위 클래스다
            data, message = e.data, e.message
        elif isinstance(e, Web3RPCError):
            error = rpc_error_of(e)
            message = error["message"]
            if error["code"] != _RPC_REVERTED and "revert" not in message.lower():
                return None
            data = error["data"]
        else:
            return None
        if isinstance(data, dict):
            data = data.get("data")
        if _to_bytes(data) == b"" and message:
            # 데이터가 없으면 노드가 붙인 설명이 유일한 단서다 (Hardhat: "couldn't infer the reason")
            return ChainRevert(RevertReason.UNKNOWN, f"revert 데이터 없음 — {message}")
        return self.decode(data)
