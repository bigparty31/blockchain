"""EIP-712 서명 대상(typed data) 구성과 서명자 복구.

릴레이하기 전에 서버가 저장한 값으로 앱과 같은 typed data 를 만들어 서명자를 복구해 본다 (CHAIN_CLIENT §7).
컨트랙트는 다른 값에 대한 서명도 형식만 맞으면 엉뚱한 주소를 복구해 NotRegistrant·NotApprover 로 revert 한다.
그래서 revert 만으로는 "앱이 다른 값에 서명함" 과 "권한 없는 사람" 을 구분할 수 없다. 체인에 보내기 전에
복구한 주소를 기대 지갑(등록은 created_by 의 지갑)과 비교하면 가스 없이 원인을 가를 수 있다.
비교는 DB 를 아는 서비스 계층이 ChainClient.signer_of 로 한다. 여기는 순수 함수만 둔다.

여기서 만든 typed data 를 앱에 서명할 값으로 내려주지 않는다. 앱은 화면에 보여준 값으로 직접 구성해 서명한다
(CHAIN_CLIENT §1·§5). 서버가 준 값에 서명하게 하면 서버가 장악됐을 때 화면과 다른 금액·예산에 임원 서명을
받아낼 수 있어, 임원 키를 기기에 둔 의미가 없어진다 (PRD §7.3·§9.2). 서버가 앱에 주는 것은 도메인(GET /chain/domains)뿐이다.

타입은 docs/CONTRACTS.md EIP-712 표, 도메인은 배포 기록(app/chain/deployment.py)에서 읽은 값을 받는다.
typed data 는 eth_signTypedData_v4 JSON 모양이다(types 에 EIP712Domain 포함). ethers 의 signTypedData 처럼
도메인 타입을 따로 받는 API 에 넘길 때는 types 에서 EIP712Domain 을 빼야 한다 — 넣으면 ethers 가 거부한다.
기대값은 tests/fixtures/eip712_vectors.json (contracts/scripts/eip712Vectors.ts 가 ethers 로 만든다).
"""
from typing import Union

from eth_abi.exceptions import EncodingError
from eth_account import Account
from eth_account.messages import SignableMessage, encode_typed_data
from eth_keys.constants import SECPK1_N
from eth_keys.exceptions import BadSignature
from eth_utils import keccak

from app.chain.deployment import Eip712Domain
from app.chain.models import KIND_ORDER, ConfirmApproval, RecordRequest, RejectDecision, check_signature

# (이름, 타입). 이름·순서·타입이 IAccountingLedger 의 typehash 와 같아야 한다 — 하나라도 다르면 모든 서명이 다른 digest 가 된다.
# 튜플이라 바꿀 수 없다. typed data 의 dict 는 부를 때마다 새로 만든다
_DOMAIN_FIELDS = (("name", "string"), ("version", "string"), ("chainId", "uint256"), ("verifyingContract", "address"))

RECORD_REQUEST_FIELDS = (
    ("id", "uint256"),
    ("hash", "bytes32"),
    ("amount", "int256"),
    ("kind", "uint8"),
    ("term", "uint256"),
    ("occurredAt", "uint256"),
    ("budgetId", "uint256"),
    ("correctsId", "uint256"),
    ("deadline", "uint256"),
)

CONFIRM_APPROVAL_FIELDS = (
    ("id", "uint256"),
    ("hash", "bytes32"),
    ("entryCommit", "bytes32"),
    ("hadWarning", "bool"),
    ("warningReasonHash", "bytes32"),
    ("deadline", "uint256"),
)

REJECT_DECISION_FIELDS = (
    ("id", "uint256"),
    ("entryCommit", "bytes32"),
    ("reasonHash", "bytes32"),
    ("deadline", "uint256"),
)

SignedPayload = Union[RecordRequest, ConfirmApproval, RejectDecision]


def _typed_data(primary_type: str, fields: tuple, domain: Eip712Domain, message: dict) -> dict:
    return {
        "types": {
            "EIP712Domain": [{"name": n, "type": t} for n, t in _DOMAIN_FIELDS],
            primary_type: [{"name": n, "type": t} for n, t in fields],
        },
        "primaryType": primary_type,
        "domain": {
            "name": domain.name,
            "version": domain.version,
            "chainId": domain.chain_id,
            "verifyingContract": domain.verifying_contract,
        },
        "message": message,
    }


def record_request_typed_data(request: RecordRequest, domain: Eip712Domain) -> dict:
    """총무가 서명하는 RecordRequest. domain 은 배포 기록의 eip712["AccountingLedger"]."""
    return _typed_data(
        "RecordRequest",
        RECORD_REQUEST_FIELDS,
        domain,
        {
            "id": request.id,
            "hash": request.hash,
            "amount": request.amount,
            "kind": KIND_ORDER.index(request.kind),  # EIP-712 타입 문자열에서는 uint8
            "term": request.term,
            "occurredAt": request.occurred_at,
            "budgetId": request.budget_id,
            "correctsId": request.corrects_id,
            "deadline": request.deadline,
        },
    )


def confirm_approval_typed_data(approval: ConfirmApproval, domain: Eip712Domain) -> dict:
    """감사·회장이 서명하는 ConfirmApproval. domain 은 배포 기록의 eip712["AccountingLedger"]."""
    return _typed_data(
        "ConfirmApproval",
        CONFIRM_APPROVAL_FIELDS,
        domain,
        {
            "id": approval.id,
            "hash": approval.hash,
            "entryCommit": approval.entry_commit,
            "hadWarning": approval.had_warning,
            "warningReasonHash": approval.warning_reason_hash,
            "deadline": approval.deadline,
        },
    )


def reject_decision_typed_data(decision: RejectDecision, domain: Eip712Domain) -> dict:
    """감사·회장이 서명하는 RejectDecision. domain 은 배포 기록의 eip712["AccountingLedger"]."""
    return _typed_data(
        "RejectDecision",
        REJECT_DECISION_FIELDS,
        domain,
        {
            "id": decision.id,
            "entryCommit": decision.entry_commit,
            "reasonHash": decision.reason_hash,
            "deadline": decision.deadline,
        },
    )


def typed_data_for(payload: SignedPayload, domain: Eip712Domain) -> dict:
    """서명 대상 모델에 맞는 typed data. ChainClient.signer_of 구현이 쓴다."""
    if isinstance(payload, RecordRequest):
        return record_request_typed_data(payload, domain)
    if isinstance(payload, ConfirmApproval):
        return confirm_approval_typed_data(payload, domain)
    if isinstance(payload, RejectDecision):
        return reject_decision_typed_data(payload, domain)
    raise TypeError(f"서명 대상이 아니다: {type(payload).__name__}")


def _encode(typed_data: dict) -> SignableMessage:
    # 모델은 uint256·int256 상한을 보지 않는다 (저장 폭 검사는 체인의 FieldOutOfRange). 넘는 값은 인코딩에서 막힌다
    try:
        return encode_typed_data(full_message=typed_data)
    except EncodingError as e:
        raise ValueError(f"서명 대상 값이 EIP-712 타입 범위를 벗어났다: {e}") from e


def digest(typed_data: dict) -> str:
    """서명되는 32바이트 = keccak256(0x19 0x01 ‖ domainSeparator ‖ structHash). 0x + 소문자 hex 64자."""
    signable = _encode(typed_data)
    return "0x" + keccak(b"\x19" + signable.version + signable.header + signable.body).hex()


def normalize_signature(signature: str) -> str:
    """컨트랙트(OpenZeppelin ECDSA.tryRecover)가 받는 모양으로 맞춘다. 릴레이할 때도 이 결과를 보낸다.

    - v 가 0·1 이면 27·28 로 바꾼다. 서명 라이브러리에 따라 0·1 로 내는데, 컨트랙트는 27·28 만 받는다
    - 그 밖의 v, high-s 서명은 ValueError. 컨트랙트가 InvalidSignature 로 거부하는 모양이라 체인에 보내기 전에 막는다
      (high-s 는 서명자가 같은 다른 표현이지만, 한 서명에 두 표현을 허용하지 않는다)
    결과는 0x + 소문자 hex 130자. 형식이 틀리면 check_signature 와 같은 ValueError.
    """
    raw = bytes.fromhex(check_signature(signature)[2:])
    r, s, v = raw[:32], raw[32:64], raw[64]
    if v in (0, 1):
        v += 27
    if v not in (27, 28):
        raise ValueError("서명의 v 는 27·28 (또는 0·1) 이어야 한다")
    if int.from_bytes(s, "big") > SECPK1_N // 2:
        raise ValueError("s 가 곡선 위수의 절반을 넘는 서명(high-s)은 컨트랙트가 받지 않는다")
    return "0x" + (r + s + bytes([v])).hex()


def recover_signer(typed_data: dict, signature: str) -> str:
    """서명자 주소 (EIP-55 체크섬). DB 의 wallet_address 와 비교할 때는 양쪽을 소문자로 맞춘다.

    다른 값에 대한 서명이어도 실패하지 않고 다른 주소가 나온다 — 기대 지갑과 비교하는 것은 호출하는 쪽이다.
    서명 형식이 틀렸거나, 복구할 수 없는 서명(r·s 가 0 등)이거나, 값이 타입 범위를 벗어나면 ValueError.
    """
    signable = _encode(typed_data)
    try:
        return Account.recover_message(signable, signature=normalize_signature(signature))
    except BadSignature as e:
        raise ValueError("서명에서 서명자를 복구할 수 없다") from e
