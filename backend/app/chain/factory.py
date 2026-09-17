"""환경변수로 체인 쪽 객체를 한꺼번에 만든다.

    CHAIN_CLIENT=fake   FakeChainClient 하나가 모든 역할을 한다. 서명자 확인도 가짜
    CHAIN_CLIENT=web3   Web3Relayer 하나를 원장·롤·이의·SBT 클라이언트가 나눠 쓴다 (nonce 공유). 설정은 ChainSettings.from_env

값이 없으면 실수로 가짜 체인이 운영에 붙지 않도록 에러를 낸다. main.py 에 붙이는 것은 API 합의 뒤다 (docs/RELAY.md §8).
만드는 것만으로는 네트워크를 쓰지 않는다. 서버 시작 때 check() 를 부른다.
"""
import os
import time
from collections.abc import Awaitable, Mapping
from dataclasses import dataclass, field
from functools import partial
from typing import Any, Callable, Optional

from app.chain.client import BudgetReader, ChainClient, LedgerEvents, MembershipReader, ObjectionClient, RoleReader
from app.chain.eip712 import RecoverSigner, recover_signer
from app.chain.fake import FakeChainClient, fake_recover_signer
from app.chain.relayer import Web3Relayer
from app.chain.settings import ChainSettings
from app.chain.web3_client import Web3ChainClient
from app.chain.web3_contracts import Web3BudgetReader, Web3MembershipReader, Web3ObjectionClient, Web3RoleReader

@dataclass(frozen=True)
class ChainServices:
    ledger: ChainClient
    events: LedgerEvents
    recover_signer: RecoverSigner  # AccountingLedger 도메인 (등록·확정·반려)
    roles: Optional[RoleReader] = None
    objections: Optional[ObjectionClient] = None
    recover_answer_signer: Optional[RecoverSigner] = None  # ObjectionRegistry 도메인 (답변)
    memberships: Optional[MembershipReader] = None
    budgets: Optional[BudgetReader] = None
    _checks: tuple[Callable[[], Awaitable[Any]], ...] = field(default=(), repr=False)

    async def check(self) -> list[str]:
        """서버 시작 때 부른다. 설정이 체인과 어긋나면 ChainConfigError, 막을 정도가 아닌 문제는 경고 문구로 모아 돌려준다."""
        warnings: list[str] = []
        for check in self._checks:
            result = await check()
            if result:
                warnings.extend(result)
        return warnings


def create_chain_services(env: Mapping[str, str] = os.environ, *, clock: Callable[[], float] = time.time) -> ChainServices:
    mode = env.get("CHAIN_CLIENT")
    if mode == "fake":
        fake = FakeChainClient(clock=clock)
        return ChainServices(
            ledger=fake,
            events=fake,
            recover_signer=fake_recover_signer,
            roles=fake,
            objections=fake,
            recover_answer_signer=fake_recover_signer,
            memberships=fake,
            budgets=fake,
        )
    if mode != "web3":
        raise ValueError(f"CHAIN_CLIENT 는 fake 또는 web3 여야 한다: {mode!r}")

    settings = ChainSettings.from_env(env)
    relayer = Web3Relayer(settings)
    ledger = Web3ChainClient(settings, relayer=relayer)
    checks: list[Callable[[], Awaitable[Any]]] = [ledger.check]

    roles = objections = memberships = budgets = None
    recover_answer = None
    if settings.role_manager_address:
        roles = Web3RoleReader(relayer, settings.role_manager_address)
        checks.append(roles.check)
    if settings.objection_address:
        objections = Web3ObjectionClient(relayer, settings.objection_address, settings.objection_domain)
        recover_answer = partial(recover_signer, settings.objection_domain)
        checks.append(objections.check)
    if settings.membership_address:
        memberships = Web3MembershipReader(relayer, settings.membership_address)
        checks.append(memberships.check)
    if settings.budget_address:
        budgets = Web3BudgetReader(relayer, settings.budget_address)
        checks.append(budgets.check)

    return ChainServices(
        ledger=ledger,
        events=ledger,
        recover_signer=partial(recover_signer, settings.domain),
        roles=roles,
        objections=objections,
        recover_answer_signer=recover_answer,
        memberships=memberships,
        budgets=budgets,
        _checks=tuple(checks),
    )
