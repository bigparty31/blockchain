import asyncio
import logging

import pytest
from eth_account import Account
from eth_account.messages import encode_typed_data

from app.chain import (
    ChainServices,
    FakeChainClient,
    RecordRequest,
    Web3BudgetReader,
    Web3ChainClient,
    Web3MembershipReader,
    Web3ObjectionClient,
    Web3RoleReader,
    create_chain_services,
    typed_data,
)
from app.chain.settings import ChainSettings
from app.relay.runner import run_periodically
from app.schemas.entry import EntryKind

WEB3_ENV = {
    "CHAIN_CLIENT": "web3",
    "CHAIN_RPC_URL": "http://localhost:8545",
    "CHAIN_ID": "31337",
    "CHAIN_LEDGER_ADDRESS": "0x" + "33" * 20,
    "CHAIN_RELAYER_KEY": "0x" + "11" * 32,
}


def run(coro):
    return asyncio.run(coro)


# ---------------------------------------------------------------- 팩토리


def test_fake_services_share_one_fake_chain():
    services = create_chain_services({"CHAIN_CLIENT": "fake"})
    assert isinstance(services.ledger, FakeChainClient)
    assert services.events is services.roles is services.objections is services.memberships is services.budgets is services.ledger
    assert run(services.check()) == []


def test_web3_services_attach_only_configured_contracts():
    services = create_chain_services(WEB3_ENV)
    assert isinstance(services.ledger, Web3ChainClient)
    assert (services.roles, services.objections, services.memberships, services.budgets, services.recover_answer_signer) == (None,) * 5

    full = create_chain_services({
        **WEB3_ENV,
        "CHAIN_ROLE_MANAGER_ADDRESS": "0x" + "66" * 20,
        "CHAIN_OBJECTION_ADDRESS": "0x" + "77" * 20,
        "CHAIN_MEMBERSHIP_ADDRESS": "0x" + "88" * 20,
        "CHAIN_BUDGET_ADDRESS": "0x" + "aa" * 20,
    })
    assert isinstance(full.roles, Web3RoleReader)
    assert isinstance(full.objections, Web3ObjectionClient)
    assert isinstance(full.memberships, Web3MembershipReader)
    assert isinstance(full.budgets, Web3BudgetReader)


def test_web3_recover_signer_uses_ledger_domain():
    services = create_chain_services(WEB3_ENV)
    account = Account.create()
    request = RecordRequest(id=1, hash="0x" + "ab" * 32, amount=1, kind=EntryKind.INCOME,
                            occurred_at=1_790_000_000 // 86400 * 86400 + 54000, deadline=1_790_000_300)
    domain = ChainSettings.from_env(WEB3_ENV).domain
    signature = Account.sign_message(encode_typed_data(full_message=typed_data(domain, request)), account.key).signature.to_0x_hex()
    assert services.recover_signer(request, signature) == account.address


@pytest.mark.parametrize("env", [{}, {"CHAIN_CLIENT": "real"}])
def test_chain_client_mode_must_be_explicit(env):
    with pytest.raises(ValueError):
        create_chain_services(env)


def test_check_collects_warnings():
    async def warns():
        return ["잔고 적음"]

    async def silent():
        return None

    services = ChainServices(ledger=None, events=None, recover_signer=None, _checks=(warns, silent, warns))
    assert run(services.check()) == ["잔고 적음", "잔고 적음"]


# ---------------------------------------------------------------- 주기 작업


def test_runs_until_stopped_and_survives_failures(caplog):
    calls = {"ok": 0, "broken": 0}

    async def ok():
        calls["ok"] += 1

    async def broken():
        calls["broken"] += 1
        raise RuntimeError("DB 끊김")

    async def scenario():
        stop = asyncio.Event()
        task = asyncio.create_task(run_periodically([("깨짐", broken), ("정상", ok)], interval_seconds=0.01, stop=stop))

        async def three_rounds():
            while calls["ok"] < 3:
                if task.done():
                    task.result()  # 러너가 예외로 멈췄으면 여기서 올라온다
                await asyncio.sleep(0.005)

        try:
            await asyncio.wait_for(three_rounds(), timeout=2)  # 러너가 멈춰도 테스트가 끝없이 기다리지 않게 한다
        finally:
            stop.set()
        await asyncio.wait_for(task, timeout=1)

    with caplog.at_level(logging.ERROR):
        run(scenario())
    assert calls["broken"] >= 3  # 실패해도 다음 회차에 다시 부른다
    assert "깨짐" in caplog.text
