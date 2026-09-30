"""entryCommit 이 컨트랙트와 같은 값을 내는지 확인한다.

기대값은 contracts/test/helpers/fixture.ts 의 computeEntryCommit 과 같은 식을 ethers 6.17.0 으로 계산한 것이다:
    keccak256(AbiCoder.defaultAbiCoder().encode(
        ["bytes32","int256","uint8","uint256","uint256","uint256","uint256","address"], [...]))
한 비트라도 다르면 모든 승인·반려가 EntryCommitMismatch 로 막히므로, 식을 바꾸면 기대값도 ethers 로 다시 뽑는다.
"""
import pytest

from app.chain import ChainEntry, entry_commit, entry_commit_of
from app.schemas.entry import EntryKind, EntryStatus

TREASURER = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
AUDITOR2 = "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc"

VECTORS = [
    (
        "expense",
        dict(hash="0x" + "ab" * 32, amount=35000, kind=EntryKind.EXPENSE, term=20262, occurred_at=1788793200, budget_id=2, corrects_id=0, registrant=TREASURER),
        "0x36557711f16adf5fdaf3ff7f86b324196e4e4bc309605505f74dbe56fe4fdaef",
    ),
    (
        "income",
        dict(
            hash="0x74c9740556d857575586251e71fa24091ffaece5c01c4f889d7c1224ce7af3a9",
            amount=5000000, kind=EntryKind.INCOME, term=20262, occurred_at=1788620400, budget_id=0, corrects_id=0, registrant=TREASURER,
        ),
        "0x043124f7fd920fe92f2ea8e61ddac9f4165736d1a0aa9f2a42c9efeab0bc351f",
    ),
    (
        "negative_correction",
        dict(hash="0x" + "cd" * 32, amount=-30000, kind=EntryKind.EXPENSE, term=20262, occurred_at=1788793200, budget_id=2, corrects_id=1, registrant=TREASURER),
        "0xa2f7543952315363d73666147326812d0b0a84cc9d251f0f150d6a2e19e17926",
    ),
    (
        "max_amount_negative_and_uint64_max_budget",
        dict(
            hash="0x" + "01" * 32, amount=-(10**15), kind=EntryKind.EXPENSE, term=20261, occurred_at=1772636400,
            budget_id=2**64 - 1, corrects_id=7, registrant=AUDITOR2,
        ),
        "0x6c300f29700e52d1db4fa823bf32878c212fa52127757f6310a12cf81775a8fb",
    ),
]


@pytest.mark.parametrize("fields, expected", [(f, e) for _, f, e in VECTORS], ids=[n for n, _, _ in VECTORS])
def test_matches_ethers(fields, expected):
    assert entry_commit(**fields) == expected


def test_address_case_does_not_matter():
    fields = VECTORS[0][1]
    assert entry_commit(**{**fields, "registrant": fields["registrant"].lower()}) == VECTORS[0][2]


def test_entry_commit_of_uses_chain_entry_fields():
    fields = VECTORS[2][1]
    entry = ChainEntry(id=5, status=EntryStatus.PENDING, approver="0x" + "0" * 40, **fields)
    # id·status·approver 는 커밋에 들어가지 않는다
    assert entry_commit_of(entry) == VECTORS[2][2]


@pytest.mark.parametrize(
    "override",
    [{"amount": 2**255}, {"amount": -(2**255) - 1}, {"term": -1}, {"budget_id": 2**256}, {"registrant": "0x1234"}, {"hash": "0x12"}],
)
def test_rejects_values_that_do_not_fit_the_encoding(override):
    with pytest.raises(ValueError):
        entry_commit(**{**VECTORS[0][1], **override})
