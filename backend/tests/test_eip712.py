import re
from pathlib import Path

import pytest
from eth_account import Account
from eth_account.messages import encode_typed_data

from app.chain import ConfirmApproval, Eip712Domain, RecordRequest, RejectDecision, recover_signer, typed_data
from app.chain.models import AnswerRequest
from app.chain.eip712 import TYPES
from app.schemas.entry import EntryKind

INTERFACES = Path(__file__).resolve().parents[2] / "contracts" / "interfaces"
SIGNED_SOL = ("IAccountingLedger.sol", "IObjectionRegistry.sol")

DOMAIN = Eip712Domain(chain_id=31337, verifying_contract="0x" + "33" * 20)
DAY = 1_790_000_000 // 86400 * 86400 + 54000
HASH = "0x" + "ab" * 32

STRUCTS = [
    RecordRequest(id=7, hash=HASH, amount=-500, kind=EntryKind.EXPENSE, occurred_at=DAY, budget_id=2, corrects_id=3, deadline=1_790_000_300),
    ConfirmApproval(id=7, hash=HASH, had_warning=True, warning_reason_hash="0x" + "cd" * 32, deadline=1_790_000_300),
    RejectDecision(id=7, reason_hash="0x" + "ef" * 32, deadline=1_790_000_300),
    AnswerRequest(objection_id=3, answer_hash="0x" + "12" * 32, deadline=1_790_000_300),
]


def sign(struct, key, domain=DOMAIN):
    return Account.sign_message(encode_typed_data(full_message=typed_data(domain, struct)), key).signature.to_0x_hex()


def test_types_match_typehash_strings_in_interface():
    declared = [s for f in SIGNED_SOL for s in re.findall(r'keccak256\("([^"]+)"\)', (INTERFACES / f).read_text())]
    ours = [name + "(" + ",".join(f["type"] + " " + f["name"] for f in fields) + ")" for name, fields in TYPES.items()]
    assert sorted(ours) == sorted(declared)


@pytest.mark.parametrize("struct", STRUCTS, ids=lambda s: type(s).__name__)
def test_recovers_signer(struct):
    account = Account.create()
    assert recover_signer(DOMAIN, struct, sign(struct, account.key)) == account.address


def test_signature_over_other_data_recovers_other_address():
    account = Account.create()
    request = STRUCTS[0]
    tampered = request.model_copy(update={"budget_id": 9})

    recovered = recover_signer(DOMAIN, request, sign(tampered, account.key))
    assert recovered != account.address

    other_deploy = Eip712Domain(chain_id=80002, verifying_contract=DOMAIN.verifying_contract)
    assert recover_signer(DOMAIN, request, sign(request, account.key, other_deploy)) != account.address


@pytest.mark.parametrize("signature", ["0x" + "00" * 65, "0x" + "ab" * 64, "not-a-signature"])
def test_broken_signature_raises_value_error(signature):
    with pytest.raises(ValueError):
        recover_signer(DOMAIN, STRUCTS[0], signature)


def test_domain_separator_matches_eth_account():
    from app.chain.eip712 import domain_separator

    header = encode_typed_data(full_message=typed_data(DOMAIN, STRUCTS[0])).header
    assert domain_separator(DOMAIN) == "0x" + bytes(header).hex()
    assert domain_separator(DOMAIN) != domain_separator(Eip712Domain(chain_id=80002, verifying_contract=DOMAIN.verifying_contract))


def test_kind_is_sent_as_enum_index():
    message = typed_data(DOMAIN, STRUCTS[0])["message"]
    assert message["kind"] == 1
    assert message["occurredAt"] == DAY


@pytest.mark.parametrize("signature", ["0x" + "ff" * 64 + "1b", "0x" + "11" * 64 + "05", "0x" + "11" * 32 + "ff" * 32 + "1c"])
def test_out_of_range_signatures_raise_value_error(signature):
    from app.chain.eip712 import recover_personal_signer

    with pytest.raises(ValueError):
        recover_signer(DOMAIN, STRUCTS[0], signature)
    with pytest.raises(ValueError):
        recover_personal_signer("hi", signature)


def test_validation_error_from_older_eth_keys_becomes_value_error(monkeypatch):
    """eth-keys 버전에 따라 r·s 범위 초과가 eth_utils.ValidationError(ValueError 아님)로 온다."""
    from eth_utils import ValidationError

    def raise_validation(*args, **kwargs):
        raise ValidationError("r is out of range")

    monkeypatch.setattr(Account, "recover_message", raise_validation)
    with pytest.raises(ValueError):
        recover_signer(DOMAIN, STRUCTS[0], "0x" + "ff" * 64 + "1b")
