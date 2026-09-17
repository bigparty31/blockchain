"""revert 데이터를 RevertReason 으로 옮긴다.

selector 로 찾으므로 이름이 같고 인자가 다른 에러(ZeroAmount(uint256) / ZeroAmount())도 각각 찾아져 같은 RevertReason 이 된다.
ABI 는 scripts/export_abi.py 가 인터페이스에서 뽑은 abi/*.json 이다.
"""
import json
from functools import lru_cache
from pathlib import Path
from typing import Any, Optional

from eth_abi import decode
from eth_utils import keccak

from app.chain.models import ChainRevert, RevertReason

ABI_DIR = Path(__file__).parent / "abi"
LEDGER_ERRORS = ("IAccountingLedger", "IBudgetToken")  # confirmEntry 가 BudgetToken 을 부른다
OBJECTION_ERRORS = ("IObjectionRegistry",)

_ERROR_STRING = bytes.fromhex("08c379a0")  # Error(string) — require 문자열
_PANIC = bytes.fromhex("4e487b71")  # Panic(uint256) — assert·overflow 등


def load_abi(name: str) -> list[dict]:
    return json.loads((ABI_DIR / f"{name}.json").read_text(encoding="utf-8"))


def signature(item: dict) -> str:
    """ABI 항목의 정규 시그니처. 에러 selector 와 이벤트 topic 계산에 쓴다."""
    return f"{item['name']}({','.join(_type(i) for i in item['inputs'])})"


def _type(param: dict) -> str:
    if param["type"].startswith("tuple"):
        return "(" + ",".join(_type(c) for c in param["components"]) + ")" + param["type"][len("tuple"):]
    return param["type"]


@lru_cache(maxsize=None)
def _errors(sources: tuple[str, ...]) -> dict[bytes, dict]:
    table = {}
    for source in sources:
        for item in load_abi(source):
            if item["type"] == "error":
                table[keccak(text=signature(item))[:4]] = item
    return table


def decode_revert(data: Any, message: str = "", sources: tuple[str, ...] = LEDGER_ERRORS) -> ChainRevert:
    """revert 데이터(0x hex·bytes·None)를 ChainRevert 로. 모르는 에러는 UNKNOWN 이고 이름·원본을 남긴다.

    sources 는 그 호출에서 revert 할 수 있는 컨트랙트들의 ABI 이름. 컨트랙트마다 따로 보는 이유는
    같은 이름·다른 뜻의 에러(RoleManager 의 SelfApproval(uint256) 등)를 엉뚱하게 옮기지 않기 위해서다.
    """
    raw = _bytes(data)
    if not raw:
        return ChainRevert(RevertReason.UNKNOWN, message or "revert 데이터 없음")
    hex_data = "0x" + raw.hex()
    selector, body = raw[:4], raw[4:]

    if selector in (_ERROR_STRING, _PANIC):
        kind = "Error" if selector == _ERROR_STRING else "Panic"
        values = _safe_decode(["string" if kind == "Error" else "uint256"], body)
        shown = repr(values[0]) if isinstance(values, tuple) else values
        return ChainRevert(RevertReason.UNKNOWN, f"{kind}({shown})", hex_data)

    item = _errors(sources).get(selector)
    if item is None:
        return ChainRevert(RevertReason.UNKNOWN, f"알 수 없는 selector 0x{selector.hex()}", hex_data)
    values = _safe_decode([_type(i) for i in item["inputs"]], body)
    if isinstance(values, tuple):
        args = ", ".join(f"{i['name']}={_fmt(v)}" for i, v in zip(item["inputs"], values))
    else:
        args = values
    try:
        return ChainRevert(RevertReason(item["name"]), args, hex_data)
    except ValueError:
        return ChainRevert(RevertReason.UNKNOWN, f"{item['name']}({args})", hex_data)


def _bytes(data: Any) -> Optional[bytes]:
    if data is None:
        return None
    if isinstance(data, (bytes, bytearray)):
        return bytes(data)
    if isinstance(data, dict):  # 일부 노드는 {"data": "0x..."} 모양으로 준다
        return _bytes(data.get("data"))
    text = str(data)
    try:
        return bytes.fromhex(text[2:] if text.startswith("0x") else text)
    except ValueError:
        return None


def _safe_decode(types: list[str], body: bytes) -> Any:
    """값 tuple, 또는 디코딩이 안 되면 그 사실을 적은 문자열."""
    try:
        return tuple(decode(types, body))
    except Exception:
        return f"디코딩 실패 0x{body.hex()}"


def _fmt(value: Any) -> str:
    if isinstance(value, (bytes, bytearray)):
        return "0x" + bytes(value).hex()
    return str(value)
