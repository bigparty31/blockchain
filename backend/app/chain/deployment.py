"""배포 기록(contracts/deployments/<network>.json) 읽기.

컨트랙트 주소·chainId·EIP-712 도메인은 재배포하면 바뀌어서 코드에 적지 않고 이 파일에서 읽는다 (PR #13, contracts/README).
서명 도메인 API 와 릴레이어가 같이 쓴다.

파일 위치는 환경변수 DEPLOYMENTS_FILE 로 바꿀 수 있고, 없으면 저장소의 로컬 배포 기록을 쓴다.
파일이 작아서 부를 때마다 새로 읽는다 — 서버를 다시 띄우지 않아도 재배포가 반영된다.
"""
import json
import os
import re
from pathlib import Path
from typing import Optional

from eth_utils import keccak
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

from app.chain import abi
from app.chain.models import ChainSetupError

DEFAULT_PATH = Path(__file__).resolve().parents[3] / "contracts" / "deployments" / "localhost.json"

# 백엔드가 릴레이하고 앱이 서명하는 컨트랙트. 하나라도 도메인이 없으면 그 서명을 만들 수 없다
REQUIRED_DOMAINS = ("AccountingLedger", "BudgetToken", "RoleManager")

_DOMAIN_TYPEHASH = keccak(text="EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
_BYTES32 = re.compile(r"0x[0-9a-fA-F]{64}")
# chainId 는 EIP-712 에서 uint256 이다. 0 이하·범위 밖이면 도메인 해시를 만들 수 없다
_CHAIN_ID = dict(gt=0, lt=2**256)


class DeploymentError(ChainSetupError):
    """배포 기록이 없거나 깨졌거나 앞뒤가 맞지 않는다. 릴레이할 수 없는 설정 상태의 하나라 API 는 503 으로 바꾼다."""


class _Model(BaseModel):
    # 파일의 키(camelCase)로 읽고, 파이썬에서는 snake_case 로 쓴다. 응답도 파일과 같은 키로 내보낸다
    model_config = ConfigDict(frozen=True, populate_by_name=True)


class Eip712Domain(_Model):
    """EIP-712 도메인. 앱은 이 네 필드(+ 검산용 domainSeparator)를 그대로 서명 도메인으로 쓴다."""

    name: str = Field(..., description="컨트랙트명")
    version: str = Field(..., description='도메인 버전. 지금은 "1"')
    chain_id: int = Field(..., alias="chainId", **_CHAIN_ID)
    verifying_contract: str = Field(..., alias="verifyingContract", description="컨트랙트 주소 (EIP-55)")
    domain_separator: str = Field(
        ..., alias="domainSeparator", description="컨트랙트의 DOMAIN_SEPARATOR(). 앱이 계산한 도메인 해시와 비교해 검산한다"
    )

    @field_validator("verifying_contract")
    @classmethod
    def _address(cls, v: str) -> str:
        return abi.check_address(v)

    @field_validator("domain_separator")
    @classmethod
    def _bytes32(cls, v: str) -> str:
        if not _BYTES32.fullmatch(v):
            raise ValueError("domainSeparator 는 0x + hex 64자여야 한다")
        # 앱은 keccak 결과(소문자 hex)와 문자열로 비교한다. 대문자로 적힌 파일도 같은 값으로 내려주도록 소문자로 맞춘다
        return v.lower()


class DeployedContract(_Model):
    address: str
    deploy_block: int = Field(..., alias="deployBlock", description="이벤트를 이 블록부터 읽는다")
    abi: str = Field(..., description="ABI 파일 경로. 배포 기록 파일이 있는 폴더 기준")

    @field_validator("abi")
    @classmethod
    def _inside_deployments(cls, v: str) -> str:
        # 배포 기록 폴더 밖의 파일을 읽지 않는다. 절대 경로는 에러 메시지로 서버 경로를 드러내기도 한다
        parts = v.replace("\\", "/").split("/")
        if not v or parts[0] == "" or ":" in parts[0] or ".." in parts:
            raise ValueError("abi 는 배포 기록 폴더 안의 상대 경로여야 한다")
        return v


class Deployment(_Model):
    network: str
    chain_id: int = Field(..., alias="chainId", **_CHAIN_ID)
    contracts: dict[str, DeployedContract]
    eip712: dict[str, Eip712Domain]


def domain_separator(domain: Eip712Domain) -> str:
    """EIP-712 도메인 해시 (0x + 소문자 hex). 컨트랙트(OpenZeppelin EIP712)의 DOMAIN_SEPARATOR() 와 같은 식이다."""
    encoded = (
        _DOMAIN_TYPEHASH
        + keccak(text=domain.name)
        + keccak(text=domain.version)
        + abi.uint256(domain.chain_id)
        + abi.address(domain.verifying_contract)
    )
    return "0x" + keccak(encoded).hex()


def deployment_path() -> Path:
    override = os.environ.get("DEPLOYMENTS_FILE")
    return Path(override) if override else DEFAULT_PATH


def _read_json(path: Path, label: str, shown: str):
    """JSON 파일을 읽는다. 문제가 있으면 DeploymentError. 메시지에는 shown(파일 이름·상대 경로)만 넣는다."""
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise DeploymentError(f"{label}이 없습니다 ({shown}). 컨트랙트를 배포했는지 확인하세요")
    except OSError as e:
        # str(e) 에는 서버의 절대 경로가 들어간다. 응답으로 나가는 메시지라 원인만 남긴다
        raise DeploymentError(f"{label}을 읽을 수 없습니다 ({shown}): {e.strerror or type(e).__name__}")
    except UnicodeDecodeError:
        raise DeploymentError(f"{label}을 읽을 수 없습니다 ({shown}): UTF-8 이 아님")
    except json.JSONDecodeError as e:
        raise DeploymentError(f"{label}을 읽을 수 없습니다 ({shown}): JSON 형식 오류 ({e.msg}, {e.lineno}행)")


def load_deployment(path: Optional[Path] = None) -> Deployment:
    """배포 기록을 읽고 앞뒤가 맞는지 확인한다. 문제가 있으면 DeploymentError."""
    path = path or deployment_path()
    raw = _read_json(path, "배포 기록", path.name)
    try:
        deployment = Deployment.model_validate(raw)
    except ValidationError as e:
        first = e.errors()[0]
        where = ".".join(str(part) for part in first["loc"])  # 예: contracts.BudgetToken.deployBlock
        raise DeploymentError(f"배포 기록 형식이 맞지 않습니다 ({path.name}): {where} — {first['msg']}")
    _check_consistency(deployment, path.name)
    return deployment


def load_abi(contract: DeployedContract, path: Optional[Path] = None) -> list:
    """배포 기록의 abi 경로에서 ABI 를 읽는다. 경로는 배포 기록 파일(path)이 있는 폴더 기준이다. 릴레이어가 쓴다."""
    path = path or deployment_path()
    abi_list = _read_json(path.parent / contract.abi, "ABI 파일", contract.abi)
    problem = _abi_problem(abi_list)
    if problem:
        # 깨진 ABI 가 web3·해석기 안에서 KeyError 등으로 터지면 503 이 아니라 500 이 된다. 읽을 때 막는다
        raise DeploymentError(f"ABI 파일 형식이 맞지 않습니다 ({contract.abi}): {problem}")
    return abi_list


def _abi_problem(abi_list) -> Optional[str]:
    """릴레이어가 쓰는 만큼의 ABI 구조 검사. 문제가 있으면 설명, 없으면 None. 메시지에 파일 내용은 넣지 않는다."""
    if not isinstance(abi_list, list):
        return "배열이 아님"
    for n, item in enumerate(abi_list):
        if not isinstance(item, dict) or not isinstance(item.get("type"), str):
            return f"{n}번째 항목에 type 이 없음"
        if item["type"] in ("function", "event", "error") and (not isinstance(item.get("name"), str) or not item["name"]):
            return f"{n}번째 {item['type']} 에 name 이 없음"
        # inputs 는 호출·에러 인자를 만들 때, outputs 는 호출 결과를 해석할 때 쓴다
        for key in ("inputs", "outputs"):
            if not _params_ok(item.get(key, [])):
                return f"{n}번째 {item['type']} 의 {key} 형식이 맞지 않음"
    return None


def _params_ok(params) -> bool:
    """ABI 인자 목록. 튜플은 components 까지 본다."""
    return isinstance(params, list) and all(
        isinstance(p, dict)
        and isinstance(p.get("type"), str)
        and (not p["type"].startswith("tuple") or _params_ok(p.get("components")))
        for p in params
    )


def _check_consistency(d: Deployment, file_name: str) -> None:
    """반쯤 갱신된 배포 기록을 앱에 내려주지 않게, 도메인이 같은 파일의 체인·주소와 맞는지 본다."""
    missing = [name for name in REQUIRED_DOMAINS if name not in d.eip712]
    if missing:
        raise DeploymentError(f"배포 기록에 서명 도메인이 없습니다 ({file_name}): {', '.join(missing)}")
    for key, domain in d.eip712.items():
        problem = None
        if domain.name != key:
            problem = f"도메인 이름 {domain.name!r} 이 키와 다름"
        elif domain.chain_id != d.chain_id:
            problem = f"chainId {domain.chain_id} 가 파일의 chainId {d.chain_id} 와 다름"
        elif key not in d.contracts:
            problem = "contracts 에 같은 이름의 컨트랙트가 없음"
        elif domain.verifying_contract.lower() != d.contracts[key].address.lower():
            problem = "verifyingContract 가 contracts 의 주소와 다름"
        elif domain.domain_separator != domain_separator(domain):
            # 앱은 이 값으로 검산한다. 틀린 값을 내려주면 도메인이 맞아도 모든 서명이 앱에서 막힌다
            problem = "domainSeparator 가 네 필드로 계산한 값과 다름"
        if problem:
            raise DeploymentError(f"배포 기록의 {key} 도메인이 맞지 않습니다 ({file_name}): {problem}")
