"""Web3ChainClient 의 회원권 조회 (MembershipSBT.hasValidMembership·tokenOf). 노드 없이 확인한다.

MembershipSBT 는 아직 배포 기록에 없을 수 있다. 없으면 연결은 되고 회원권 조회만 ChainSetupError 다.
"""
import asyncio
from types import SimpleNamespace

import aiohttp
import pytest
from eth_account import Account

from app.chain import ChainSetupError, ChainUnavailable
from app.chain.deployment import DEFAULT_PATH, DeployedContract, load_abi, load_deployment
from app.chain.web3_client import CONTRACTS, MEMBERSHIP_SBT, Web3ChainClient
from chain_support import RELAYER_KEY

DEPLOYMENT = load_deployment(DEFAULT_PATH)
STUDENT = "0x" + "ab" * 20
SBT_ADDRESS = "0x" + "cd" * 20


class _Call:
    def __init__(self, result):
        self._result = result

    async def call(self):
        if isinstance(self._result, BaseException):
            raise self._result
        return self._result


def _sbt(valid, token, seen):
    def has_valid(account, term):
        seen.append(("hasValidMembership", account, term))
        return _Call(valid)

    def token_of(account, term):
        seen.append(("tokenOf", account, term))
        return _Call(token)

    return SimpleNamespace(
        address=SBT_ADDRESS, abi=[], functions=SimpleNamespace(hasValidMembership=has_valid, tokenOf=token_of)
    )


def _client(sbt=None) -> Web3ChainClient:
    contracts = {
        name: SimpleNamespace(abi=load_abi(DEPLOYMENT.contracts[name], DEFAULT_PATH), address=DEPLOYMENT.contracts[name].address)
        for name in CONTRACTS
    }
    deployment = DEPLOYMENT
    if sbt is not None:
        contracts[MEMBERSHIP_SBT] = sbt
        sbt_record = DeployedContract(address=SBT_ADDRESS, deployBlock=0, abi="abi/MembershipSBT.json")
        deployment = DEPLOYMENT.model_copy(update={"contracts": {**DEPLOYMENT.contracts, MEMBERSHIP_SBT: sbt_record}})
    return Web3ChainClient(None, Account.from_key(RELAYER_KEY), deployment, contracts, DEFAULT_PATH)


def test_without_sbt_in_deployment_membership_reads_are_setup_errors():
    client = _client()
    with pytest.raises(ChainSetupError):
        asyncio.run(client.has_valid_membership(STUDENT, 20262))
    with pytest.raises(ChainSetupError):
        asyncio.run(client.membership_token_of(STUDENT, 20262))


def test_reads_call_the_contract_with_checksum_address_and_term_code():
    seen = []
    client = _client(_sbt(True, 42, seen))
    assert asyncio.run(client.has_valid_membership(STUDENT, 20262)) is True
    assert asyncio.run(client.membership_token_of(STUDENT, 20262)) == 42
    checksum = "0xABaBaBaBABabABabAbAbABAbABabababaBaBABaB"
    assert seen == [("hasValidMembership", checksum, 20262), ("tokenOf", checksum, 20262)]


def test_unreachable_node_is_unavailable_not_false():
    client = _client(_sbt(aiohttp.ClientConnectionError("down"), aiohttp.ClientConnectionError("down"), []))
    with pytest.raises(ChainUnavailable):
        asyncio.run(client.has_valid_membership(STUDENT, 20262))
    with pytest.raises(ChainUnavailable):
        asyncio.run(client.membership_token_of(STUDENT, 20262))


# ---------------------------------------------------------------- 발행·소각 쓰기 (인터페이스 ABI 로, 노드 없이)

import json  # noqa: E402
from pathlib import Path  # noqa: E402

from eth_abi import encode  # noqa: E402
from eth_utils import keccak, to_checksum_address  # noqa: E402
from web3 import AsyncWeb3  # noqa: E402

from app.chain import eip712 as eip712_module  # noqa: E402
from app.chain.deployment import Eip712Domain, domain_separator  # noqa: E402
from app.chain.models import BurnRequest, MembershipRevertReason, MintBatchRequest  # noqa: E402
from app.chain.revert import membership_revert_decoder  # noqa: E402

# IMembershipSBT.sol 을 컴파일한 ABI. 구현이 배포되면 배포 기록의 abi/MembershipSBT.json 이 정본이 된다
SBT_ABI = json.loads((Path(__file__).parent / "fixtures" / "IMembershipSBT.abi.json").read_text(encoding="utf-8"))
SIGNER = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
OTHER = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"


def _sbt_domain() -> Eip712Domain:
    fields = dict(name="MembershipSBT", version="1", chainId=DEPLOYMENT.chain_id, verifyingContract=to_checksum_address(SBT_ADDRESS))
    return Eip712Domain(**fields, domainSeparator=domain_separator(Eip712Domain(**fields, domainSeparator="0x" + "00" * 32)))


def _real_sbt_client(with_domain: bool = True) -> Web3ChainClient:
    contracts = {
        name: SimpleNamespace(abi=load_abi(DEPLOYMENT.contracts[name], DEFAULT_PATH), address=DEPLOYMENT.contracts[name].address)
        for name in CONTRACTS
    }
    contracts[MEMBERSHIP_SBT] = AsyncWeb3().eth.contract(address=to_checksum_address(SBT_ADDRESS), abi=SBT_ABI)
    record = DeployedContract(address=SBT_ADDRESS, deployBlock=0, abi="abi/MembershipSBT.json")
    update = {"contracts": {**DEPLOYMENT.contracts, MEMBERSHIP_SBT: record}}
    if with_domain:
        update["eip712"] = {**DEPLOYMENT.eip712, MEMBERSHIP_SBT: _sbt_domain()}
    return Web3ChainClient(None, Account.from_key(RELAYER_KEY), DEPLOYMENT.model_copy(update=update), contracts, DEFAULT_PATH)


def _topic(value) -> bytes:
    if isinstance(value, str):
        return bytes(12) + bytes.fromhex(value[2:])
    return value.to_bytes(32, "big")


def _log(signature: str, indexed: list, data_types: list, data_values: list, address: str = SBT_ADDRESS) -> dict:
    return {
        "address": to_checksum_address(address),
        "topics": [keccak(text=signature)] + [_topic(v) for v in indexed],
        "data": encode(data_types, data_values),
        "logIndex": 0,
        "transactionIndex": 0,
        "transactionHash": b"\x11" * 32,
        "blockHash": b"\x22" * 32,
        "blockNumber": 1,
    }


def _minted(token_id, to, term=20262, actor=SIGNER, address=SBT_ADDRESS):
    return _log("MembershipMinted(uint256,address,uint256,address)", [token_id, to, actor], ["uint256"], [term], address)


def _skipped(to, term=20262, actor=SIGNER):
    return _log("MembershipSkipped(address,uint256,address)", [to, term, actor], [], [])


def test_mint_result_reads_minted_and_skipped_events():
    client = _real_sbt_client()
    receipt = {"status": 1, "logs": [_minted(7, STUDENT), _skipped(OTHER), _minted(99, OTHER, address="0x" + "ee" * 20)]}
    result = client._mint_result("0x" + "ab" * 32, receipt)
    assert [(m.address, m.token_id) for m in result.minted] == [(to_checksum_address(STUDENT), 7)]  # 다른 컨트랙트 로그는 무시
    assert result.skipped == (OTHER,)
    assert result.signer == SIGNER


def test_mint_result_without_events_is_unknown_not_success():
    client = _real_sbt_client()
    with pytest.raises(ChainUnavailable):
        client._mint_result("0x" + "ab" * 32, {"status": 1, "logs": []})


def test_mint_signer_is_recovered_with_the_sbt_domain():
    client = _real_sbt_client()
    request = MintBatchRequest(recipients=(STUDENT,), term=20262, nonce=0, deadline=1800000000)
    key = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"  # Hardhat #1
    signed = Account.sign_typed_data(key, full_message=eip712_module.typed_data_for(request, _sbt_domain()))
    assert client.signer_of(request, "0x" + signed.signature.hex()) == SIGNER


def test_without_sbt_domain_signatures_cannot_be_checked():
    client = _real_sbt_client(with_domain=False)
    request = MintBatchRequest(recipients=(STUDENT,), term=20262, nonce=0, deadline=1)
    with pytest.raises(ChainSetupError):
        client.signer_of(request, "0x" + "11" * 65)


def test_without_sbt_in_deployment_writes_are_setup_errors_and_not_sent():
    client = _client()
    request = MintBatchRequest(recipients=(STUDENT,), term=20262, nonce=0, deadline=1)
    burn = BurnRequest(holder=STUDENT, term=20262, reason="REFUND", nonce=0, deadline=1)
    sent = []

    async def claim(tx_hash):
        sent.append(tx_hash)

    for call in (
        lambda: client.mint_memberships(request, "0x" + "11" * 65, claim),
        lambda: client.burn_membership_relayed(burn, "0x" + "11" * 65, claim),
        lambda: client.mint_tx_result("0x" + "ab" * 32),
        lambda: client.membership_nonce(SIGNER),
    ):
        with pytest.raises(ChainSetupError):
            asyncio.run(call())
    assert sent == []


def test_nonce_read_calls_the_contract():
    seen = []

    def nonces(signer):
        seen.append(signer)
        return _Call(4)

    sbt = SimpleNamespace(address=SBT_ADDRESS, abi=[], functions=SimpleNamespace(nonces=nonces))
    assert asyncio.run(_client(sbt).membership_nonce(STUDENT.lower())) == 4
    assert seen == ["0xABaBaBaBABabABabAbAbABAbABabababaBaBABaB"]


@pytest.mark.parametrize(
    "signature, args, types, reason",
    [
        ("InvalidNonce(uint256,uint256)", [3, 2], ["uint256", "uint256"], MembershipRevertReason.INVALID_NONCE),
        ("NotApprover(address)", [OTHER], ["address"], MembershipRevertReason.NOT_APPROVER),
        ("SignatureExpired(uint256)", [1], ["uint256"], MembershipRevertReason.SIGNATURE_EXPIRED),
        ("NoMembership(address,uint256)", [OTHER, 20262], ["address", "uint256"], MembershipRevertReason.NO_MEMBERSHIP),
        ("ZeroAddress()", [], [], MembershipRevertReason.ZERO_ADDRESS),
    ],
)
def test_sbt_reverts_are_named(signature, args, types, reason):
    decoder = membership_revert_decoder(SBT_ABI)
    assert decoder.missing_reasons() == []
    data = keccak(text=signature)[:4] + encode(types, args)
    assert decoder.decode(data).reason is reason
