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

DEFAULT_PATH = Path(__file__).resolve().parents[3] / "contracts" / "deployments" / "localhost.json"

_DOMAIN_TYPEHASH = keccak(text="EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")

_ADDRESS = re.compile(r"0x[0-9a-fA-F]{40}")
_BYTES32 = re.compile(r"0x[0-9a-fA-F]{64}")


class DeploymentError(Exception):
    """배포 기록이 없거나 깨졌거나 앞뒤가 맞지 않는다."""


class _Model(BaseModel):
    # 파일의 키(camelCase)로 읽고, 파이썬에서는 snake_case 로 쓴다. 응답도 파일과 같은 키로 내보낸다
    model_config = ConfigDict(frozen=True, populate_by_name=True)


class Eip712Domain(_Model):
    """EIP-712 도메인. 앱은 이 네 필드(+ 검산용 domainSeparator)를 그대로 서명 도메인으로 쓴다."""

    name: str = Field(..., description="컨트랙트명")
    version: str = Field(..., description='도메인 버전. 지금은 "1"')
    chain_id: int = Field(..., alias="chainId")
    verifying_contract: str = Field(..., alias="verifyingContract", description="컨트랙트 주소 (EIP-55)")
    domain_separator: str = Field(
        ..., alias="domainSeparator", description="컨트랙트의 DOMAIN_SEPARATOR(). 앱이 계산한 도메인 해시와 비교해 검산한다"
    )

    @field_validator("verifying_contract")
    @classmethod
    def _address(cls, v: str) -> str:
        if not _ADDRESS.fullmatch(v):
            raise ValueError("verifyingContract 는 0x + hex 40자여야 한다")
        return v

    @field_validator("domain_separator")
    @classmethod
    def _bytes32(cls, v: str) -> str:
        if not _BYTES32.fullmatch(v):
            raise ValueError("domainSeparator 는 0x + hex 64자여야 한다")
        return v


class DeployedContract(_Model):
    address: str
    deploy_block: int = Field(..., alias="deployBlock", description="이벤트를 이 블록부터 읽는다")
    abi: str = Field(..., description="ABI 파일 경로. 배포 기록 파일이 있는 폴더 기준")


class Deployment(_Model):
    network: str
    chain_id: int = Field(..., alias="chainId")
    contracts: dict[str, DeployedContract]
    eip712: dict[str, Eip712Domain]


def domain_separator(domain: Eip712Domain) -> str:
    """EIP-712 도메인 해시 (0x + 소문자 hex). 컨트랙트(OpenZeppelin EIP712)의 DOMAIN_SEPARATOR() 와 같은 식이다."""
    encoded = (
        _DOMAIN_TYPEHASH
        + keccak(text=domain.name)
        + keccak(text=domain.version)
        + domain.chain_id.to_bytes(32, "big")
        + bytes(12)
        + bytes.fromhex(domain.verifying_contract[2:])
    )
    return "0x" + keccak(encoded).hex()


def deployment_path() -> Path:
    override = os.environ.get("DEPLOYMENTS_FILE")
    return Path(override) if override else DEFAULT_PATH


def load_deployment(path: Optional[Path] = None) -> Deployment:
    """배포 기록을 읽고 앞뒤가 맞는지 확인한다. 문제가 있으면 DeploymentError."""
    path = path or deployment_path()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise DeploymentError(f"배포 기록이 없습니다 ({path.name}). 컨트랙트를 배포했는지 확인하세요")
    except OSError as e:
        # str(e) 에는 서버의 절대 경로가 들어간다. 응답으로 나가는 메시지라 원인만 남긴다
        raise DeploymentError(f"배포 기록을 읽을 수 없습니다 ({path.name}): {e.strerror or type(e).__name__}")
    except json.JSONDecodeError as e:
        raise DeploymentError(f"배포 기록을 읽을 수 없습니다 ({path.name}): JSON 형식 오류 ({e.msg}, {e.lineno}행)")
    try:
        deployment = Deployment.model_validate(raw)
    except ValidationError as e:
        raise DeploymentError(f"배포 기록 형식이 맞지 않습니다 ({path.name}): {e.errors()[0]['msg']}")
    _check_consistency(deployment, path.name)
    return deployment


def _check_consistency(d: Deployment, file_name: str) -> None:
    """반쯤 갱신된 배포 기록을 앱에 내려주지 않게, 도메인이 같은 파일의 체인·주소와 맞는지 본다."""
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
        elif domain.domain_separator.lower() != domain_separator(domain):
            # 앱은 이 값으로 검산한다. 틀린 값을 내려주면 도메인이 맞아도 모든 서명이 앱에서 막힌다
            problem = "domainSeparator 가 네 필드로 계산한 값과 다름"
        if problem:
            raise DeploymentError(f"배포 기록의 {key} 도메인이 맞지 않습니다 ({file_name}): {problem}")
