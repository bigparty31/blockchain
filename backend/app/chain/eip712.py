"""EIP-712 서명 대상과 서명자 복구.

도메인은 docs/CONTRACTS.md "EIP-712" 절을 따른다 — name 은 컨트랙트명, version 은 "1",
chainId·verifyingContract 는 배포값. 구조체의 필드 이름·순서·타입은 IAccountingLedger 의 typehash 주석과 같다.

서명은 앱이 한다. 서버는 앱이 서명할 typed data 를 내려주고, 받은 서명의 서명자를 체인에 보내기 전에 확인한다.
"""
from typing import Any, Callable, Union

from eth_abi import encode
from eth_account import Account
from eth_account.messages import encode_defunct, encode_typed_data
from eth_keys.exceptions import BadSignature
from eth_utils import ValidationError, keccak, to_checksum_address
from pydantic import BaseModel, ConfigDict

from app.chain.models import (
    KIND_ORDER,
    AnswerRequest,
    ConfirmApproval,
    RecordRequest,
    RejectDecision,
    check_address,
    check_signature,
)

Struct = Union[RecordRequest, ConfirmApproval, RejectDecision, AnswerRequest]

# (서명 대상 struct, 서명) → 서명자 주소. 실제로는 functools.partial(recover_signer, domain), 테스트는 fake.fake_recover_signer
RecoverSigner = Callable[[Any, str], str]

DOMAIN_TYPE = [
    {"name": "name", "type": "string"},
    {"name": "version", "type": "string"},
    {"name": "chainId", "type": "uint256"},
    {"name": "verifyingContract", "type": "address"},
]

TYPES = {
    "RecordRequest": [
        {"name": "id", "type": "uint256"},
        {"name": "hash", "type": "bytes32"},
        {"name": "amount", "type": "int256"},
        {"name": "kind", "type": "uint8"},
        {"name": "occurredAt", "type": "uint256"},
        {"name": "budgetId", "type": "uint256"},
        {"name": "correctsId", "type": "uint256"},
        {"name": "deadline", "type": "uint256"},
    ],
    "ConfirmApproval": [
        {"name": "id", "type": "uint256"},
        {"name": "hash", "type": "bytes32"},
        {"name": "hadWarning", "type": "bool"},
        {"name": "warningReasonHash", "type": "bytes32"},
        {"name": "deadline", "type": "uint256"},
    ],
    "RejectDecision": [
        {"name": "id", "type": "uint256"},
        {"name": "reasonHash", "type": "bytes32"},
        {"name": "deadline", "type": "uint256"},
    ],
    "AnswerRequest": [  # ObjectionRegistry 도메인
        {"name": "objectionId", "type": "uint256"},
        {"name": "answerHash", "type": "bytes32"},
        {"name": "deadline", "type": "uint256"},
    ],
}


class Eip712Domain(BaseModel):
    model_config = ConfigDict(frozen=True)

    name: str = "AccountingLedger"
    version: str = "1"
    chain_id: int
    verifying_contract: str

    def as_dict(self) -> dict:
        return {
            "name": self.name,
            "version": self.version,
            "chainId": self.chain_id,
            "verifyingContract": check_address(self.verifying_contract),
        }


def domain_separator(domain: Eip712Domain) -> str:
    """컨트랙트의 DOMAIN_SEPARATOR() 와 같아야 하는 값. 시작 점검에서 비교한다."""
    type_hash = keccak(text="EIP712Domain(" + ",".join(f"{t['type']} {t['name']}" for t in DOMAIN_TYPE) + ")")
    encoded = encode(
        ["bytes32", "bytes32", "bytes32", "uint256", "address"],
        [
            type_hash,
            keccak(text=domain.name),
            keccak(text=domain.version),
            domain.chain_id,
            to_checksum_address(check_address(domain.verifying_contract)),
        ],
    )
    return "0x" + keccak(encoded).hex()


def _message(struct: Struct) -> tuple[str, dict]:
    if isinstance(struct, RecordRequest):
        return "RecordRequest", {
            "id": struct.id,
            "hash": struct.hash,
            "amount": struct.amount,
            "kind": KIND_ORDER.index(struct.kind),
            "occurredAt": struct.occurred_at,
            "budgetId": struct.budget_id,
            "correctsId": struct.corrects_id,
            "deadline": struct.deadline,
        }
    if isinstance(struct, ConfirmApproval):
        return "ConfirmApproval", {
            "id": struct.id,
            "hash": struct.hash,
            "hadWarning": struct.had_warning,
            "warningReasonHash": struct.warning_reason_hash,
            "deadline": struct.deadline,
        }
    if isinstance(struct, AnswerRequest):
        return "AnswerRequest", {
            "objectionId": struct.objection_id,
            "answerHash": struct.answer_hash,
            "deadline": struct.deadline,
        }
    return "RejectDecision", {"id": struct.id, "reasonHash": struct.reason_hash, "deadline": struct.deadline}


def typed_data(domain: Eip712Domain, struct: Struct) -> dict:
    """앱이 서명할 typed data. eth_signTypedData_v4 에 그대로 넘기는 JSON 모양이다."""
    primary, message = _message(struct)
    return {
        "types": {"EIP712Domain": DOMAIN_TYPE, primary: TYPES[primary]},
        "primaryType": primary,
        "domain": domain.as_dict(),
        "message": message,
    }


def recover_signer(domain: Eip712Domain, struct: Struct, signature: str) -> str:
    """서명자 주소를 EIP-55 체크섬 형식으로 돌려준다.

    다른 데이터에 대한 서명이어도 실패하지 않고 다른 주소가 나온다. 그래서 결과를 기대한 주소와 비교해야 한다.

    Raises:
        ValueError: 서명 형식이 틀렸거나 바이트가 깨져 주소를 복구할 수 없다.
    """
    return _recover(encode_typed_data(full_message=typed_data(domain, struct)), signature)


def recover_personal_signer(message: str, signature: str) -> str:
    """personal_sign(EIP-191) 한 문장의 서명자 주소. 임원 지갑 등록 확인에 쓴다. 예외는 recover_signer 와 같다."""
    return _recover(encode_defunct(text=message), signature)


def _recover(signable, signature: str) -> str:
    try:
        return Account.recover_message(signable, signature=check_signature(signature))
    except (BadSignature, ValidationError) as e:
        # eth-keys 버전에 따라 r·s 가 범위를 넘는 서명이 BadSignature 대신 ValidationError(ValueError 아님)로 온다
        raise ValueError(f"서명에서 주소를 복구할 수 없다: {e}") from e
