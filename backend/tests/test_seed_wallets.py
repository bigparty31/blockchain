"""시드 임원 지갑이 로컬 배포의 임원 계정과 같은지 확인한다.

체인의 registrant·approver(지갑 주소)를 사용자와 대조하는 기준이 시드의 wallet_address 다.
재배포로 계정 배치가 바뀌면 이 테스트가 먼저 깨져서 알려 준다.
"""
import json
from collections import defaultdict
from pathlib import Path

import pytest

from app.auth import users
from app.schemas.auth import Role

DEPLOYMENT = Path(__file__).resolve().parents[2] / "contracts" / "deployments" / "localhost.json"

# localhost.json "accounts" 의 키 → 역할. 감사는 컨트랙트 규칙상 최소 2명이다
ACCOUNT_ROLES = {
    "president": Role.PRESIDENT,
    "treasurer": Role.TREASURER,
    "auditor": Role.AUDITOR,
    "auditor2": Role.AUDITOR,
}


@pytest.fixture(scope="module")
def accounts():
    if not DEPLOYMENT.exists():
        pytest.skip(f"{DEPLOYMENT} 없음 — develop(PR #13)을 받아 온 뒤 실행된다")
    return json.loads(DEPLOYMENT.read_text())["accounts"]


def wallets_by_role(pairs):
    grouped = defaultdict(set)
    for role, address in pairs:
        grouped[role].add(address.lower())  # EIP-55 대소문자는 비교에서 뺀다 (CHAIN_CLIENT.md)
    return dict(grouped)


def test_officer_wallets_match_deployment(accounts):
    deployed = wallets_by_role((role, accounts[key]) for key, role in ACCOUNT_ROLES.items())
    seeded = wallets_by_role((u.role, u.wallet_address) for u in users.SEED_USERS if u.wallet_address)
    assert seeded == deployed


def test_deployer_and_relayer_are_not_users(accounts):
    # 배포자·릴레이어는 롤이 없는 계정이라 로그인 사용자와 겹치면 안 된다
    seeded = {u.wallet_address.lower() for u in users.SEED_USERS if u.wallet_address}
    assert accounts["deployer"].lower() not in seeded
    assert accounts["relayer"].lower() not in seeded
