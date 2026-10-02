"""EIP-712 typed data 가 앱과 같은 digest 를 만들고 같은 서명자를 복구하는지 확인한다.

기대값은 tests/fixtures/eip712_vectors.json 이다. contracts/scripts/eip712Vectors.ts 가 ethers 로 서명해 만든다
(앱의 서명 구현이 아직 없어서 같은 표준 eth_signTypedData_v4 를 구현한 ethers 로 대신한다).
한 비트라도 다르면 모든 등록·승인 서명이 서버 검증에서 막히므로, 타입을 바꾸면 벡터도 ethers 로 다시 뽑는다.
"""
import copy
import json
from pathlib import Path

import pytest

from app.chain import ConfirmApproval, RecordRequest
from app.chain.deployment import Eip712Domain, load_deployment
from app.chain.eip712 import (
    CONFIRM_APPROVAL_FIELDS,
    RECORD_REQUEST_FIELDS,
    confirm_approval_typed_data,
    digest,
    normalize_signature,
    record_request_typed_data,
    recover_signer,
)
from app.chain.models import KIND_ORDER

FIXTURE = json.loads((Path(__file__).parent / "fixtures" / "eip712_vectors.json").read_text(encoding="utf-8"))
DOMAIN = Eip712Domain.model_validate(FIXTURE["domain"])
VECTORS = {v["name"]: v for v in FIXTURE["vectors"]}

SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141


def typed_data_of(vector: dict) -> dict:
    """벡터의 message 를 서버 모델로 옮겨 typed data 를 만든다. 서버가 실제로 쓰는 경로와 같다."""
    m = vector["message"]
    if vector["primaryType"] == "RecordRequest":
        request = RecordRequest(
            id=m["id"],
            hash=m["hash"],
            amount=m["amount"],
            kind=KIND_ORDER[m["kind"]],
            term=m["term"],
            occurred_at=m["occurredAt"],
            budget_id=m["budgetId"],
            corrects_id=m["correctsId"],
            deadline=m["deadline"],
        )
        return record_request_typed_data(request, DOMAIN)
    approval = ConfirmApproval(
        id=m["id"],
        hash=m["hash"],
        entry_commit=m["entryCommit"],
        had_warning=m["hadWarning"],
        warning_reason_hash=m["warningReasonHash"],
        deadline=m["deadline"],
    )
    return confirm_approval_typed_data(approval, DOMAIN)


def with_last_byte(signature: str, v: int) -> str:
    return signature[:-2] + f"{v:02x}"


@pytest.mark.parametrize("vector", VECTORS.values(), ids=VECTORS.keys())
def test_digest_matches_ethers(vector):
    assert digest(typed_data_of(vector)) == vector["digest"]


@pytest.mark.parametrize("vector", VECTORS.values(), ids=VECTORS.keys())
def test_recovers_the_signer(vector):
    assert recover_signer(typed_data_of(vector), vector["signature"]) == vector["signer"]


def test_vectors_match_current_deployment():
    # 재배포로 원장 주소가 바뀌면 벡터의 도메인이 낡는다. 그때는 contracts 에서 node scripts/eip712Vectors.ts 를 다시 돌린다
    assert load_deployment().eip712["AccountingLedger"] == DOMAIN


@pytest.mark.parametrize(
    "name, part, field, value",
    [
        ("record_expense", "message", "amount", 35001),
        ("record_expense", "message", "kind", 0),
        ("record_expense", "message", "term", 20261),
        ("record_expense", "message", "occurredAt", 1790694000 + 86400),
        ("record_expense", "message", "budgetId", 2),
        ("record_expense", "message", "deadline", 1790700001),
        ("record_negative_correction", "message", "amount", 20000),
        ("confirm_expense", "message", "entryCommit", "0x" + "11" * 32),
        ("confirm_expense", "message", "hadWarning", True),
        ("confirm_expense", "domain", "chainId", 80002),
        ("confirm_expense", "domain", "verifyingContract", "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"),
    ],
)
def test_any_changed_value_recovers_someone_else(name, part, field, value):
    # 다른 값에 대한 서명은 실패하지 않고 엉뚱한 주소가 나온다. 서버가 기대 지갑과 비교해야 하는 이유다
    vector = VECTORS[name]
    typed_data = copy.deepcopy(typed_data_of(vector))
    typed_data[part][field] = value
    assert recover_signer(typed_data, vector["signature"]) != vector["signer"]


def test_type_strings_match_contracts_doc():
    # docs/CONTRACTS.md EIP-712 표의 문자열 그대로. 컨트랙트 typehash 의 원문이다
    def type_string(name, fields):
        return f"{name}({','.join(f['type'] + ' ' + f['name'] for f in fields)})"

    assert type_string("RecordRequest", RECORD_REQUEST_FIELDS) == (
        "RecordRequest(uint256 id,bytes32 hash,int256 amount,uint8 kind,uint256 term,uint256 occurredAt,"
        "uint256 budgetId,uint256 correctsId,uint256 deadline)"
    )
    assert type_string("ConfirmApproval", CONFIRM_APPROVAL_FIELDS) == (
        "ConfirmApproval(uint256 id,bytes32 hash,bytes32 entryCommit,bool hadWarning,bytes32 warningReasonHash,uint256 deadline)"
    )


# ---------------------------------------------------------------- 서명 정규화


def test_v_zero_or_one_is_accepted_and_normalized():
    vector = VECTORS["record_income"]
    v = int(vector["signature"][-2:], 16)
    short_v = with_last_byte(vector["signature"], v - 27)
    assert normalize_signature(short_v) == vector["signature"].lower()
    assert recover_signer(typed_data_of(vector), short_v) == vector["signer"]


def test_upper_case_hex_is_the_same_signature():
    vector = VECTORS["record_income"]
    upper = "0x" + vector["signature"][2:].upper()
    assert normalize_signature(upper) == vector["signature"].lower()


def test_high_s_is_rejected():
    # 같은 서명자의 다른 표현이지만 컨트랙트(OpenZeppelin ECDSA)가 InvalidSignature 로 거부한다
    vector = VECTORS["record_income"]
    raw = bytes.fromhex(vector["signature"][2:])
    s = int.from_bytes(raw[32:64], "big")
    high_s = raw[:32] + (SECP256K1_N - s).to_bytes(32, "big") + bytes([55 - raw[64]])  # v 27 ↔ 28
    with pytest.raises(ValueError, match="high-s"):
        normalize_signature("0x" + high_s.hex())


@pytest.mark.parametrize("v", [2, 26, 29, 255])
def test_other_v_is_rejected(v):
    with pytest.raises(ValueError, match="v"):
        normalize_signature(with_last_byte(VECTORS["record_income"]["signature"], v))


@pytest.mark.parametrize("signature", ["0x1234", "0x" + "ab" * 64, "ab" * 65, "0x" + "zz" * 65])
def test_malformed_signature_is_rejected(signature):
    with pytest.raises(ValueError):
        normalize_signature(signature)


def test_unrecoverable_signature_raises_value_error():
    # r = s = 0 은 형식은 맞지만 복구할 수 없다. 컨트랙트에서는 InvalidSignature
    with pytest.raises(ValueError, match="복구"):
        recover_signer(typed_data_of(VECTORS["record_income"]), "0x" + "00" * 64 + "1b")
