"""GET /chain/domains — 앱이 서명할 때 쓸 EIP-712 도메인 (docs/CONTRACTS.md "EIP-712")."""
import json

import pytest
from eth_utils import keccak
from fastapi.testclient import TestClient

from app.chain.deployment import DEFAULT_PATH
from app.main import app

client = TestClient(app)

SIGNING_CONTRACTS = {"AccountingLedger", "BudgetToken", "RoleManager"}
_DOMAIN_TYPEHASH = keccak(text="EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")


def domain_separator(domain: dict) -> str:
    """EIP-712 표준 도메인 해시. 컨트랙트(OpenZeppelin EIP712)의 DOMAIN_SEPARATOR() 와 같은 식이다."""
    encoded = (
        _DOMAIN_TYPEHASH
        + keccak(text=domain["name"])
        + keccak(text=domain["version"])
        + domain["chainId"].to_bytes(32, "big")
        + bytes(12) + bytes.fromhex(domain["verifyingContract"][2:])
    )
    return "0x" + keccak(encoded).hex()


@pytest.fixture
def deployment_file(tmp_path, monkeypatch):
    """저장소 배포 기록을 복사해 고칠 수 있게 하고, API 가 그 파일을 읽게 한다."""
    data = json.loads(DEFAULT_PATH.read_text())
    path = tmp_path / "localhost.json"

    def write(mutate=None):
        copy = json.loads(json.dumps(data))
        if mutate:
            mutate(copy)
        path.write_text(json.dumps(copy))
        return copy

    monkeypatch.setenv("DEPLOYMENTS_FILE", str(path))
    return write


def test_returns_domains_from_deployment_file():
    res = client.get("/chain/domains")  # 토큰 없이 부른다
    assert res.status_code == 200
    data = json.loads(DEFAULT_PATH.read_text())
    assert res.json() == {"chainId": data["chainId"], "domains": data["eip712"]}
    assert set(res.json()["domains"]) == SIGNING_CONTRACTS


def test_domains_have_the_fields_the_app_signs_with():
    # 키 이름은 EIP-712 도메인 필드 그대로라 앱이 서명 라이브러리에 바로 넘길 수 있다
    for name, domain in client.get("/chain/domains").json()["domains"].items():
        assert domain["name"] == name
        assert domain["version"] == "1"
        assert set(domain) == {"name", "version", "chainId", "verifyingContract", "domainSeparator"}


@pytest.mark.parametrize("name", sorted(SIGNING_CONTRACTS))
def test_domain_separator_matches_eip712_formula(name):
    # 배포 기록의 domainSeparator 가 네 필드로 계산한 값과 같아야 앱이 검산에 쓸 수 있다
    domain = client.get("/chain/domains").json()["domains"][name]
    assert domain["domainSeparator"] == domain_separator(domain)


def test_follows_redeploy_without_restart(deployment_file):
    # 부를 때마다 파일을 읽어서, 재배포로 주소가 바뀌면 서버를 다시 띄우지 않아도 반영된다
    new_address = "0x" + "12" * 20

    def redeploy(d):
        d["contracts"]["AccountingLedger"]["address"] = new_address
        domain = d["eip712"]["AccountingLedger"]
        domain["verifyingContract"] = new_address
        domain["domainSeparator"] = domain_separator(domain)  # 배포 스크립트처럼 새 주소로 다시 계산한 값

    deployment_file(redeploy)
    assert client.get("/chain/domains").json()["domains"]["AccountingLedger"]["verifyingContract"] == new_address


def test_new_signing_contract_is_included_automatically(deployment_file):
    # ObjectionRegistry 처럼 서명을 받는 컨트랙트가 배포 기록에 추가되면 코드 수정 없이 내려간다
    address = "0x" + "34" * 20

    def add(d):
        d["contracts"]["ObjectionRegistry"] = {"address": address, "deployBlock": 5, "abi": "abi/ObjectionRegistry.json"}
        domain = {"name": "ObjectionRegistry", "version": "1", "chainId": d["chainId"], "verifyingContract": address}
        d["eip712"]["ObjectionRegistry"] = {**domain, "domainSeparator": domain_separator(domain)}

    deployment_file(add)
    assert "ObjectionRegistry" in client.get("/chain/domains").json()["domains"]


def test_missing_file_is_503(monkeypatch, tmp_path):
    monkeypatch.setenv("DEPLOYMENTS_FILE", str(tmp_path / "nothing.json"))
    res = client.get("/chain/domains")
    assert res.status_code == 503
    assert "배포 기록이 없습니다" in res.json()["detail"]
    assert str(tmp_path) not in res.json()["detail"]  # 서버의 절대 경로는 응답에 내보내지 않는다


def test_read_error_does_not_leak_server_path(monkeypatch, tmp_path):
    # 파일 없음 말고 다른 읽기 오류(폴더를 가리킴, 권한 없음)도 파이썬 오류 문구에 절대 경로가 들어간다
    folder = tmp_path / "localhost.json"
    folder.mkdir()
    monkeypatch.setenv("DEPLOYMENTS_FILE", str(folder))
    res = client.get("/chain/domains")
    assert res.status_code == 503
    assert "배포 기록을 읽을 수 없습니다" in res.json()["detail"]
    assert str(tmp_path) not in res.json()["detail"]


def test_broken_json_is_503(monkeypatch, tmp_path):
    path = tmp_path / "localhost.json"
    path.write_text("{ not json")
    monkeypatch.setenv("DEPLOYMENTS_FILE", str(path))
    assert client.get("/chain/domains").status_code == 503


@pytest.mark.parametrize(
    "mutate, reason",
    [
        (lambda d: d["eip712"]["AccountingLedger"].update(verifyingContract="0x" + "99" * 20), "verifyingContract"),
        (lambda d: d["eip712"]["BudgetToken"].update(chainId=1), "chainId"),
        (lambda d: d["eip712"]["RoleManager"].update(name="Other"), "도메인 이름"),
        (lambda d: d["contracts"].pop("BudgetToken"), "contracts"),
        (lambda d: d["eip712"]["AccountingLedger"].update(domainSeparator="0x12"), "형식"),
        # 다른 필드는 그대로 두고 도메인 해시만 틀린 경우. 앱의 검산이 모든 서명을 막게 된다
        (lambda d: d["eip712"]["AccountingLedger"].update(domainSeparator="0x" + "11" * 32), "domainSeparator"),
    ],
    ids=["address-mismatch", "chain-mismatch", "name-mismatch", "contract-missing", "bad-separator", "separator-mismatch"],
)
def test_inconsistent_file_is_503(deployment_file, mutate, reason):
    # 반쯤 갱신된 배포 기록을 앱에 내려주면 모든 서명이 체인에서 거부된다. 내려주지 않고 503 으로 알린다
    deployment_file(mutate)
    res = client.get("/chain/domains")
    assert res.status_code == 503
    assert reason in res.json()["detail"]
