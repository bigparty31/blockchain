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
