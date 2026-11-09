"""회원권(MembershipSBT) 서명 대상·EIP-712·가짜 체인 릴레이.

MembershipSBT 구현이 아직 없어 기대값은 앱 PR #90(app/test/signing_sbt_test.dart)이 ethers v6 TypedDataEncoder 로
IMembershipSBT.sol 명세를 따라 계산한 벡터다. 서버(eth_account)와 앱(Dart)이 같은 바이트를 내는지 대조한다.
컨트랙트 구현이 나오면 contracts/scripts/eip712Vectors.ts 에도 넣어 세 쪽을 대조한다.
"""
import asyncio

import pytest
from eth_account import Account
from eth_utils import keccak
from pydantic import ValidationError

from app.chain import FakeChainClient, fake_signature
from app.chain import eip712
from app.chain.deployment import Eip712Domain
from app.chain.models import (
    BurnReason,
    BurnRequest,
    ChainRevert,
    ChainUnavailable,
    MembershipRevertReason,
    MintBatchRequest,
)

DOMAIN = Eip712Domain(
    name="MembershipSBT",
    version="1",
    chainId=31337,
    verifyingContract="0x5FbDB2315678afecb367f032d93F642f64180aa3",
    domainSeparator="0xd3c1b9a74f9f561108bd72b12aadd592342d9ca8407481a74fd0ed64526b6c9e",
)
A = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"  # Hardhat #1 — 회장
B = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"  # Hardhat #2
PRESIDENT_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
ZERO = "0x" + "0" * 40
TERM = 20262

# (이름, 요청, hashStruct, digest) — PR #90 의 ethers 벡터
VECTORS = [
    (
        "mint_two",
        MintBatchRequest(recipients=(A, B), term=20262, nonce=0, deadline=1800000000),
        "0x517da5df26741c52cf927a6c9248a2016926b513dd1807e53f03606589ea287d",
        "0x5bce7e4bd78a350f2b4e1526aee7f3035403fb899fb071e9e9871c486fa353fc",
    ),
    (
        "mint_one",
        MintBatchRequest(recipients=(A,), term=20262, nonce=5, deadline=1800000000),
        "0x63d4c6363292a95eb8483f3bbe5edb432a7e4ccdfebb31fb1781c259e72abc2c",
        "0x2da8f124f50058a816eec68a8bb2a93cb54a23345a769d3f7754bae90016de49",
    ),
    (
        "burn_withdrawal",
        BurnRequest(holder=A, term=20262, reason="WITHDRAWAL", nonce=3, deadline=1800000000),
        "0xc8f4c28e9c28be9f51f1b77b57b2749fb9525a2cc25ded1513ca4ac8a893891f",
        "0x756e037dad6ac5560efe40b25577ae41d6be9b6720ce12cd02b7864218b3f792",
    ),
    (
        "burn_refund",
        BurnRequest(holder=B, term=20261, reason="REFUND", nonce=0, deadline=1799999999),
        "0x5d2e48ed6a48f8a5588f7a41253c51c061f179b39bd171536f6ba71d9681ec4c",
        "0x604cabc5a635cc92044cbe4c4695d182f75c648d1867ab8d0f624c5c71b1a3b9",
    ),
]


# ---------------------------------------------------------------- EIP-712


def _encode_type(primary: str, fields: tuple) -> str:
    return f"{primary}(" + ",".join(f"{t} {n}" for n, t in fields) + ")"


def test_typehash_strings_match_the_interface():
    # IMembershipSBT.sol @dev typehash 원문 그대로. 필드 이름·순서·타입 중 하나라도 다르면 모든 서명이 다른 digest 가 된다
    assert _encode_type("MintBatchRequest", eip712.MINT_BATCH_REQUEST_FIELDS) == (
        "MintBatchRequest(address[] recipients,uint256 term,uint256 nonce,uint256 deadline)"
    )
    assert _encode_type("BurnRequest", eip712.BURN_REQUEST_FIELDS) == (
        "BurnRequest(address holder,uint256 term,uint8 reason,uint256 nonce,uint256 deadline)"
    )
    # PR #90 의 typeHash 와 같다
    assert "0x" + keccak(text=_encode_type("MintBatchRequest", eip712.MINT_BATCH_REQUEST_FIELDS)).hex() == (
        "0x620f04a17a5f2f8a289a03481dac82a7c3b175e44bca7a2570577d168d69b466"
    )
    assert "0x" + keccak(text=_encode_type("BurnRequest", eip712.BURN_REQUEST_FIELDS)).hex() == (
        "0x7299d54d04209a7e78c217caa5027b5c1349202ce875bbcec8c586812b8a2295"
    )


@pytest.mark.parametrize("name, request_, struct_hash, digest", VECTORS, ids=[v[0] for v in VECTORS])
def test_vectors_match_the_app(name, request_, struct_hash, digest):
    from eth_account.messages import encode_typed_data

    typed = eip712.typed_data_for(request_, DOMAIN)
    signable = encode_typed_data(full_message=typed)
    assert "0x" + signable.header.hex() == DOMAIN.domain_separator  # 앱이 검산하는 DOMAIN_SEPARATOR 와 같다
    assert "0x" + signable.body.hex() == struct_hash
    assert eip712.digest(typed) == digest


def test_recipient_order_is_part_of_what_is_signed():
    forward = eip712.digest(eip712.typed_data_for(MintBatchRequest(recipients=(A, B), term=TERM, nonce=0, deadline=1), DOMAIN))
    backward = eip712.digest(eip712.typed_data_for(MintBatchRequest(recipients=(B, A), term=TERM, nonce=0, deadline=1), DOMAIN))
    assert forward != backward


def test_signer_is_recovered_from_a_device_signature():
    request = VECTORS[0][1]
    typed = eip712.typed_data_for(request, DOMAIN)
    signed = Account.sign_typed_data(PRESIDENT_KEY, full_message=typed)
    assert eip712.recover_signer(typed, "0x" + signed.signature.hex()) == A
    # 다른 값(다른 nonce)에 대한 서명이면 다른 주소가 나온다 — 서비스가 기대 지갑과 비교해 400 으로 막는다
    other = eip712.typed_data_for(request.model_copy(update={"nonce": 1}), DOMAIN)
    assert eip712.recover_signer(other, "0x" + signed.signature.hex()) != A


def test_burn_reason_is_the_enum_order():
    for reason, code in ((BurnReason.REFUND, 0), (BurnReason.WITHDRAWAL, 1)):
        typed = eip712.typed_data_for(BurnRequest(holder=A, term=TERM, reason=reason, nonce=0, deadline=1), DOMAIN)
        assert typed["message"]["reason"] == code


# ---------------------------------------------------------------- 모델 (배치 전체 revert 값은 만들 때 막는다)


@pytest.mark.parametrize(
    "recipients",
    [
        (),  # EmptyBatch
        tuple("0x" + f"{i:040x}" for i in range(1, 102)),  # BatchTooLarge (101명)
        (A, ZERO),  # ZeroAddress — 하나라도 있으면 배치 전체 revert
        (A, A.lower()),  # 같은 주소 두 번
        ("0x1234",),
    ],
    ids=["empty", "101", "zero", "duplicate", "malformed"],
)
def test_mint_request_refuses_batches_the_contract_would_revert(recipients):
    with pytest.raises(ValidationError):
        MintBatchRequest(recipients=recipients, term=TERM, nonce=0, deadline=1)


def test_mint_request_accepts_100_and_checksums():
    hundred = tuple("0x" + f"{i:040x}" for i in range(1, 101))
    assert len(MintBatchRequest(recipients=hundred, term=TERM, nonce=0, deadline=1).recipients) == 100
    assert MintBatchRequest(recipients=(A.lower(),), term=TERM, nonce=0, deadline=1).recipients == (A,)


@pytest.mark.parametrize("term", [0, 2026, 20265])
def test_term_must_be_a_term_code(term):
    with pytest.raises(ValidationError):
        MintBatchRequest(recipients=(A,), term=term, nonce=0, deadline=1)
    with pytest.raises(ValidationError):
        BurnRequest(holder=A, term=term, reason="REFUND", nonce=0, deadline=1)


@pytest.mark.parametrize("reason", ["", "refund", "OTHER"])
def test_burn_reason_is_one_of_two(reason):
    with pytest.raises(ValidationError):
        BurnRequest(holder=A, term=TERM, reason=reason, nonce=0, deadline=1)


def test_burn_holder_cannot_be_zero():
    with pytest.raises(ValidationError):
        BurnRequest(holder=ZERO, term=TERM, reason="REFUND", nonce=0, deadline=1)


# ---------------------------------------------------------------- 가짜 체인


def _mint(chain, recipients, nonce=0, signer=A, deadline=4_000_000_000, before_broadcast=None):
    request = MintBatchRequest(recipients=tuple(recipients), term=TERM, nonce=nonce, deadline=deadline)
    return asyncio.run(chain.mint_memberships(request, fake_signature(signer), before_broadcast))


def _burn(chain, holder, nonce, signer=A, reason="REFUND"):
    request = BurnRequest(holder=holder, term=TERM, reason=reason, nonce=nonce, deadline=4_000_000_000)
    return asyncio.run(chain.burn_membership_relayed(request, fake_signature(signer)))


def test_fake_mints_skips_valid_holders_and_spends_the_nonce():
    chain = FakeChainClient()
    existing = chain.grant_membership(B, TERM)
    result = _mint(chain, [A, B])
    assert [(m.address, m.token_id) for m in result.minted] == [(A, existing + 1)]
    assert result.skipped == (B,)
    assert result.signer == A
    assert asyncio.run(chain.has_valid_membership(A, TERM))
    assert asyncio.run(chain.membership_nonce(A)) == 1
    # 전부 건너뛰어도 성공이고 nonce 는 오른다
    again = _mint(chain, [A, B], nonce=1)
    assert again.minted == () and again.skipped == (A, B)
    assert asyncio.run(chain.membership_nonce(A)) == 2
    assert asyncio.run(chain.membership_nonce(B)) == 0  # 서명자마다 따로다


def test_fake_refuses_a_stale_nonce_and_an_expired_signature():
    chain = FakeChainClient()
    _mint(chain, [A])
    with pytest.raises(ChainRevert) as e:
        _mint(chain, [B], nonce=0)  # 같은 서명 재사용·다른 발행이 먼저 들어감
    assert e.value.reason is MembershipRevertReason.INVALID_NONCE
    with pytest.raises(ChainRevert) as e:
        _mint(chain, [B], nonce=1, deadline=1)
    assert e.value.reason is MembershipRevertReason.SIGNATURE_EXPIRED
    assert not asyncio.run(chain.has_valid_membership(B, TERM))


def test_fake_not_approver_comes_from_fail_next():
    chain = FakeChainClient()
    chain.fail_next("mint_memberships", MembershipRevertReason.NOT_APPROVER)
    with pytest.raises(ChainRevert) as e:
        _mint(chain, [A])
    assert e.value.reason is MembershipRevertReason.NOT_APPROVER
    assert asyncio.run(chain.membership_nonce(A)) == 0


def test_fake_result_can_be_read_back_by_hash():
    chain = FakeChainClient()
    hashes = []

    async def remember(tx_hash):
        hashes.append(tx_hash)

    chain.unavailable_next("mint_memberships", landed=True)
    with pytest.raises(ChainUnavailable):
        _mint(chain, [A], before_broadcast=remember)
    result = asyncio.run(chain.mint_tx_result(hashes[0]))
    assert result.minted[0].address == A
    # 닿지 않은 트랜잭션은 None (모름)
    chain.unavailable_next("mint_memberships", landed=False)
    with pytest.raises(ChainUnavailable):
        _mint(chain, [B], nonce=1, before_broadcast=remember)
    assert asyncio.run(chain.mint_tx_result(hashes[1])) is None


def test_fake_burn_shares_the_nonce_and_allows_reissue():
    chain = FakeChainClient()
    first = _mint(chain, [A]).minted[0].token_id
    burned = _burn(chain, A, nonce=1, reason="WITHDRAWAL")
    assert (burned.token_id, burned.reason, burned.holder) == (first, BurnReason.WITHDRAWAL, A)
    assert not asyncio.run(chain.has_valid_membership(A, TERM))
    assert asyncio.run(chain.membership_nonce(A)) == 2
    second = _mint(chain, [A], nonce=2).minted[0].token_id
    assert second != first  # 같은 학기 재발행은 새 tokenId
    with pytest.raises(ChainRevert) as e:
        _burn(chain, B, nonce=3)
    assert e.value.reason is MembershipRevertReason.NO_MEMBERSHIP
