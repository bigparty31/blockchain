"""시드 예산을 로컬 Hardhat 체인에도 발행한다. scripts.seed 는 DB 에만 넣기 때문이다.

    cd backend && python -m scripts.issue_seed_budgets

Hardhat 공개 키로 임원 서명을 대신하므로 chainId 31337 에서만 돈다. 이미 맞는 예산은 건너뛰어 다시 돌려도 안전하다.
"""
import os
import sys

from eth_utils import keccak
from web3 import Web3

from app.chain.deployment import deployment_path, load_abi, load_deployment
from app.utils.hashing import text_hash
from scripts.local_chain import (
    AUDITOR_INDEX,
    LOCAL_CHAIN_ID,
    LOCAL_RPC_URL,
    PRESIDENT_INDEX,
    RELAYER_INDEX,
    hardhat_key,
    sign_typed_data,
)
from scripts.seed import DEFAULT_BUDGET_EXPIRES_AT, DEFAULT_BUDGETS, DEFAULT_TERM_CODE

EIP712_DOMAIN = [
    {"name": "name", "type": "string"},
    {"name": "version", "type": "string"},
    {"name": "chainId", "type": "uint256"},
    {"name": "verifyingContract", "type": "address"},
]
ISSUE_FIELDS = [
    {"name": "budgetId", "type": "uint256"},
    {"name": "term", "type": "uint256"},
    {"name": "category", "type": "bytes32"},
    {"name": "amount", "type": "uint256"},
    {"name": "expiresAt", "type": "uint256"},
    {"name": "deadline", "type": "uint256"},
]
INCREASE_FIELDS = [
    {"name": "budgetId", "type": "uint256"},
    {"name": "amount", "type": "uint256"},
    {"name": "reasonHash", "type": "bytes32"},
    {"name": "version", "type": "uint256"},
    {"name": "deadline", "type": "uint256"},
]


def typed(domain, primary: str, fields: list, message: dict) -> dict:
    return {
        "types": {"EIP712Domain": EIP712_DOMAIN, primary: fields},
        "primaryType": primary,
        "domain": {
            "name": domain.name,
            "version": domain.version,
            "chainId": domain.chain_id,
            "verifyingContract": domain.verifying_contract,
        },
        "message": message,
    }


def main() -> int:
    deployment = load_deployment()
    info = deployment.contracts["BudgetToken"]
    w3 = Web3(Web3.HTTPProvider(os.environ.get("CHAIN_RPC_URL") or LOCAL_RPC_URL))
    if w3.eth.chain_id != LOCAL_CHAIN_ID:
        print(f"[issue] chainId {w3.eth.chain_id} 에서는 돌지 않습니다 (로컬 전용)", file=sys.stderr)
        return 1

    token = w3.eth.contract(address=Web3.to_checksum_address(info.address), abi=load_abi(info, deployment_path()))
    domain = deployment.eip712["BudgetToken"]
    relayer = w3.eth.account.from_key(hardhat_key(RELAYER_INDEX))
    president_key = hardhat_key(PRESIDENT_INDEX)
    auditor_key = hardhat_key(AUDITOR_INDEX)

    def send(call) -> None:
        tx = call.build_transaction({"from": relayer.address, "nonce": w3.eth.get_transaction_count(relayer.address)})
        tx_hash = w3.eth.send_raw_transaction(relayer.sign_transaction(tx).raw_transaction)
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=30)
        if receipt["status"] != 1:
            raise RuntimeError(f"트랜잭션 실패: {tx_hash.hex()}")

    expires_at = int(DEFAULT_BUDGET_EXPIRES_AT.timestamp())
    for budget_id, category, versions in DEFAULT_BUDGETS:
        ordered = sorted(versions, key=lambda v: v[0])
        # Budget 튜플의 version 은 6번째 필드다
        chain_version = (
            token.functions.getBudget(budget_id).call()[5] if token.functions.exists(budget_id).call() else 0
        )
        deadline = w3.eth.get_block("latest")["timestamp"] + 3600

        for index, (version, planned, reason, _approver, _request) in enumerate(ordered):
            if version <= chain_version:
                continue
            if version == 1:
                message = {
                    "budgetId": budget_id,
                    "term": DEFAULT_TERM_CODE,
                    "category": keccak(text=category),
                    "amount": planned,
                    "expiresAt": expires_at,
                    "deadline": deadline,
                }
                signature = sign_typed_data(typed(domain, "IssueRequest", ISSUE_FIELDS, message), president_key)
                send(token.functions.issue(tuple(message.values()), signature))
            else:
                # 증액 서명의 version 은 올리기 전 현재 버전이고, amount 는 늘어나는 양이다
                message = {
                    "budgetId": budget_id,
                    "amount": planned - ordered[index - 1][1],
                    "reasonHash": bytes.fromhex(text_hash(reason).removeprefix("0x")),
                    "version": version - 1,
                    "deadline": deadline,
                }
                payload = typed(domain, "IncreaseRequest", INCREASE_FIELDS, message)
                send(
                    token.functions.increase(
                        tuple(message.values()),
                        sign_typed_data(payload, president_key),
                        sign_typed_data(payload, auditor_key),
                    )
                )
            print(f"[issue] {category} v{version} = {planned:,}원")

    for budget_id, category, _versions in DEFAULT_BUDGETS:
        print(f"[issue] 확인 {budget_id} {category}: 잔량 {token.functions.remaining(budget_id).call():,}원")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
