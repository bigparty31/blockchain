"""EIP-712 typed data 가 앱과 같은 digest 를 만들고 같은 서명자를 복구하는지 확인한다.

기대값은 tests/fixtures/eip712_vectors.json 이다. contracts/scripts/eip712Vectors.ts 가 ethers 로 서명해 만든다
(앱의 서명 구현이 아직 없어서 같은 표준 eth_signTypedData_v4 를 구현한 ethers 로 대신한다).
한 비트라도 다르면 모든 등록·승인 서명이 서버 검증에서 막히므로, 타입을 바꾸면 벡터도 ethers 로 다시 뽑는다.
"""
import json
from pathlib import Path

import pytest
from eth_keys.constants import SECPK1_N

from app.chain import ConfirmApproval, RecordRequest, RejectDecision, entry_commit
from app.chain.deployment import DEFAULT_PATH, Eip712Domain, load_abi, load_deployment
from app.chain.eip712 import (
    CONFIRM_APPROVAL_FIELDS,
    RECORD_REQUEST_FIELDS,
    REJECT_DECISION_FIELDS,
    digest,
    normalize_signature,
    recover_signer,
    typed_data_for,
)
from app.chain.models import KIND_ORDER
from chain_support import unchecked

FIXTURE = json.loads((Path(__file__).parent / "fixtures" / "eip712_vectors.json").read_text(encoding="utf-8"))
DOMAIN = Eip712Domain.model_validate(FIXTURE["domain"])
VECTORS = {v["name"]: v for v in FIXTURE["vectors"]}


def payload_of(vector: dict, **override):
    """벡터의 message 를 서버 모델로 옮긴다. 서버가 실제로 쓰는 경로와 같다."""
    m = {**vector["message"], **override}
    if vector["primaryType"] == "RecordRequest":
        return RecordRequest(
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
    if vector["primaryType"] == "ConfirmApproval":
        return ConfirmApproval(
            id=m["id"],
            hash=m["hash"],
            entry_commit=m["entryCommit"],
            had_warning=m["hadWarning"],
            warning_reason_hash=m["warningReasonHash"],
            deadline=m["deadline"],
        )
    return RejectDecision(id=m["id"], entry_commit=m["entryCommit"], reason_hash=m["reasonHash"], deadline=m["deadline"])


def typed_data_of(vector: dict) -> dict:
    return typed_data_for(payload_of(vector), DOMAIN)


def with_last_byte(signature: str, v: int) -> str:
    return signature[:-2] + f"{v:02x}"


@pytest.mark.parametrize("vector", VECTORS.values(), ids=VECTORS.keys())
def test_digest_matches_ethers(vector):
    assert digest(typed_data_of(vector)) == vector["digest"]


@pytest.mark.parametrize("vector", VECTORS.values(), ids=VECTORS.keys())
def test_recovers_the_signer(vector):
    assert recover_signer(typed_data_of(vector), vector["signature"]) == vector["signer"]


def test_vectors_match_the_repo_deployment():
    # 재배포로 원장 주소가 바뀌면 벡터의 도메인이 낡는다. 그때는 contracts 에서 node scripts/eip712Vectors.ts 를 다시 돌린다.
    # 셸의 DEPLOYMENTS_FILE 이 다른 네트워크를 가리켜도 저장소의 배포 기록과 비교한다
    assert load_deployment(DEFAULT_PATH).eip712["AccountingLedger"] == DOMAIN


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
        ("reject_expense", "message", "reasonHash", "0x" + "22" * 32),
        ("confirm_expense", "domain", "chainId", 80002),
        ("confirm_expense", "domain", "verifyingContract", "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"),
    ],
)
def test_any_changed_value_recovers_someone_else(name, part, field, value):
    # 다른 값에 대한 서명은 실패하지 않고 엉뚱한 주소가 나온다. 서버가 기대 지갑과 비교해야 하는 이유다
    vector = VECTORS[name]
    typed_data = typed_data_of(vector)
    typed_data[part][field] = value
    assert recover_signer(typed_data, vector["signature"]) != vector["signer"]


def test_changing_the_result_does_not_change_later_typed_data():
    vector = VECTORS["record_income"]
    typed_data = typed_data_of(vector)
    typed_data["types"]["RecordRequest"].append({"name": "extra", "type": "uint256"})
    typed_data["types"]["EIP712Domain"].pop()
    assert digest(typed_data_of(vector)) == vector["digest"]


@pytest.mark.parametrize("name", ["confirm_expense", "confirm_with_warning", "reject_expense"])
def test_vectors_use_the_backend_entry_commit(name):
    # 벡터의 entryCommit 은 ethers 로 계산했다. 서버가 승인 전에 대조하는 app/chain/commit.py 와 같은 값이어야 한다
    registered = VECTORS["record_expense"]
    m = registered["message"]
    expected = entry_commit(
        hash=m["hash"],
        amount=m["amount"],
        kind=KIND_ORDER[m["kind"]],
        term=m["term"],
        occurred_at=m["occurredAt"],
        budget_id=m["budgetId"],
        corrects_id=m["correctsId"],
        registrant=registered["signer"],
    )
    assert VECTORS[name]["message"]["entryCommit"] == expected


def test_type_strings_match_contracts_doc():
    # docs/CONTRACTS.md EIP-712 표의 문자열 그대로. 컨트랙트 typehash 의 원문이다
    def type_string(name, fields):
        return f"{name}({','.join(f'{t} {n}' for n, t in fields)})"

    assert type_string("RecordRequest", RECORD_REQUEST_FIELDS) == (
        "RecordRequest(uint256 id,bytes32 hash,int256 amount,uint8 kind,uint256 term,uint256 occurredAt,"
        "uint256 budgetId,uint256 correctsId,uint256 deadline)"
    )
    assert type_string("ConfirmApproval", CONFIRM_APPROVAL_FIELDS) == (
        "ConfirmApproval(uint256 id,bytes32 hash,bytes32 entryCommit,bool hadWarning,bytes32 warningReasonHash,uint256 deadline)"
    )
    assert type_string("RejectDecision", REJECT_DECISION_FIELDS) == (
        "RejectDecision(uint256 id,bytes32 entryCommit,bytes32 reasonHash,uint256 deadline)"
    )


@pytest.mark.parametrize(
    "struct, fields, function",
    [
        ("RecordRequest", RECORD_REQUEST_FIELDS, "recordPending"),
        ("ConfirmApproval", CONFIRM_APPROVAL_FIELDS, "confirmEntry"),
        ("RejectDecision", REJECT_DECISION_FIELDS, "rejectEntry"),
    ],
)
def test_field_order_matches_the_ledger_abi(struct, fields, function):
    # 서명 대상의 필드 이름·타입·순서가 배포된 원장 ABI 의 인자 tuple 과 같은지 노드 없이 본다 (PR #20 2차 리뷰).
    # 순서가 어긋나면 typehash 가 달라 모든 서명이 다른 사람의 것으로 복구된다. 지금까지는 노드 테스트에서만 드러났다
    deployment = load_deployment()
    abi = load_abi(deployment.contracts["AccountingLedger"])
    (item,) = [f for f in abi if f.get("type") == "function" and f["name"] == function]
    arg = item["inputs"][0]
    assert arg["internalType"] == f"struct IAccountingLedger.{struct}"
    assert [(c["name"], c["type"]) for c in arg["components"]] == list(fields)


@pytest.mark.parametrize(
    "name, field, value",
    [
        ("record_income", "deadline", 2**256),
        ("record_income", "id", 2**256),
        ("record_negative_correction", "amount", -(2**255) - 1),
        ("record_income", "amount", 2**255),
    ],
)
def test_values_outside_the_eip712_types_raise_value_error(name, field, value):
    # 모델이 먼저 막지만(app/chain/models.py), 인코딩 층도 스스로 막는다. eth_abi 예외가 아니라 ValueError 여야 한다
    typed_data = typed_data_for(unchecked(payload_of(VECTORS[name]), **{field: value}), DOMAIN)
    with pytest.raises(ValueError, match="범위"):
        digest(typed_data)
    with pytest.raises(ValueError, match="범위"):
        recover_signer(typed_data, VECTORS[name]["signature"])


def test_typed_data_for_rejects_other_models():
    with pytest.raises(TypeError):
        typed_data_for(DOMAIN, DOMAIN)


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
    high_s = raw[:32] + (SECPK1_N - s).to_bytes(32, "big") + bytes([55 - raw[64]])  # v 27 ↔ 28
    with pytest.raises(ValueError, match="high-s"):
        normalize_signature("0x" + high_s.hex())


@pytest.mark.parametrize("v", [2, 26, 29, 255])
def test_other_v_is_rejected(v):
    with pytest.raises(ValueError, match="v 는"):
        normalize_signature(with_last_byte(VECTORS["record_income"]["signature"], v))


@pytest.mark.parametrize("signature", ["0x1234", "0x" + "ab" * 64, "ab" * 65, "0x" + "zz" * 65])
def test_malformed_signature_is_rejected(signature):
    with pytest.raises(ValueError):
        normalize_signature(signature)


def test_unrecoverable_signature_raises_value_error():
    # r = s = 0 은 형식은 맞지만 복구할 수 없다. 컨트랙트에서는 InvalidSignature
    with pytest.raises(ValueError, match="복구"):
        recover_signer(typed_data_of(VECTORS["record_income"]), "0x" + "00" * 64 + "1b")
