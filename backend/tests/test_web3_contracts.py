"""Web3RoleReader·Web3ObjectionClient·Web3MembershipReader 를 가짜 JSON-RPC 노드에 붙여 확인한다."""
import asyncio

import pytest
from eth_utils import keccak, to_checksum_address
from web3 import AsyncWeb3

from app.chain import AnswerRequest, ChainRevert, ObjectionStatus, RecordRequest, RevertReason, Role
from app.chain.eip712 import domain_separator
from app.chain.models import ChainConfigError
from app.chain.relayer import Web3Relayer, bytes32
from app.chain.revert import decode_revert
from app.chain.web3_client import Web3ChainClient
from app.chain.web3_contracts import Web3BudgetReader, Web3MembershipReader, Web3ObjectionClient, Web3RoleReader
from app.schemas.entry import EntryKind
from fake_node import (
    LEDGER,
    OBJECTION_ABI,
    OBJECTIONS,
    ROLES,
    BUDGET,
    SBT,
    FakeNode,
    contract_log,
    encoded,
    error_data,
    event_log,
    run,
    settings,
)

STUDENT = to_checksum_address("0x" + "99" * 20)
AUDITOR = to_checksum_address("0x" + "55" * 20)
CONTENT = "0x" + "c1" * 32
ANSWER = "0x" + "a1" * 32
SIG = "0x" + "cd" * 65


@pytest.fixture
def node():
    return FakeNode()


def relayer(node, **overrides):
    return Web3Relayer(settings(**overrides), AsyncWeb3(node))


# ---------------------------------------------------------------- 롤


def test_role_reader_checks_role_ids(node):
    for role in Role:
        node.calls[role.value] = encoded(["bytes32"], [bytes32(role.id)])
    roles = Web3RoleReader(relayer(node), ROLES)
    run(roles.check())

    node.calls["AUDITOR"] = encoded(["bytes32"], [b"\1" * 32])
    with pytest.raises(ChainConfigError):
        run(roles.check())


def test_has_role_sends_name_hash(node):
    node.calls["hasRole"] = encoded(["bool"], [True])
    assert run(Web3RoleReader(relayer(node), ROLES).has_role(Role.PRESIDENT, AUDITOR.lower())) is True
    [(name, args)] = node.call_args
    assert name == "hasRole"
    assert (args["role"], args["account"]) == (bytes32(Role.PRESIDENT.id), AUDITOR)
    assert Role.TREASURER.id == "0x" + keccak(text="TREASURER").hex()


# ---------------------------------------------------------------- 이의


def objections(node, **overrides):
    s = settings(**overrides)
    return Web3ObjectionClient(Web3Relayer(s, AsyncWeb3(node)), OBJECTIONS, s.objection_domain)


def test_objection_check_uses_its_own_domain(node):
    node.calls["DOMAIN_SEPARATOR"] = domain_separator(settings().objection_domain)
    run(objections(node).check())

    node.calls["DOMAIN_SEPARATOR"] = domain_separator(settings().domain)  # 원장 도메인이면 틀리다
    with pytest.raises(ChainConfigError):
        run(objections(node).check())


def test_raise_objection(node):
    node.outcome["logs"] = lambda tx_hash, block: [
        contract_log(OBJECTIONS, "ObjectionRaised", block, tx_hash, objectionId=3, entryId=1, contentHash=bytes32(CONTENT), raiser=STUDENT)
    ]
    result = run(objections(node).raise_objection(3, 1, CONTENT, STUDENT.lower()))

    [sent] = node.sent
    fn, args = node.decode_input(sent)
    assert fn.fn_name == "raise"
    assert (args["objectionId"], args["entryId"], args["contentHash"], args["raiser"]) == (3, 1, bytes32(CONTENT), STUDENT)
    assert (result.status, result.tx_hash) == (ObjectionStatus.OPEN, sent["hash"])


def test_answer_objection(node):
    node.outcome["logs"] = lambda tx_hash, block: [
        contract_log(OBJECTIONS, "ObjectionAnswered", block, tx_hash, objectionId=3, answerHash=bytes32(ANSWER), responder=AUDITOR)
    ]
    result = run(objections(node).answer_objection(AnswerRequest(objection_id=3, answer_hash=ANSWER, deadline=1_790_000_300), SIG))

    fn, args = node.decode_input(node.sent[0])
    assert fn.fn_name == "answer"
    assert args["request"] == {"objectionId": 3, "answerHash": bytes32(ANSWER), "deadline": 1_790_000_300}
    assert result.status == ObjectionStatus.ANSWERED


@pytest.mark.parametrize(
    "error, reason",
    [
        (("ObjectionAlreadyExists", 3), RevertReason.OBJECTION_ALREADY_EXISTS),
        (("NotMember", STUDENT), RevertReason.NOT_MEMBER),
        (("EntryNotFound", 1), RevertReason.ENTRY_NOT_FOUND),
    ],
)
def test_objection_reverts_are_read_with_objection_abi(node, error, reason):
    data = error_data(OBJECTION_ABI, *error)
    node.estimate = {"revert": data}
    with pytest.raises(ChainRevert) as e:
        run(objections(node).raise_objection(3, 1, CONTENT, STUDENT))
    assert e.value.reason == reason
    assert node.sent == []


def test_objection_errors_are_unknown_to_ledger_decoding():
    """컨트랙트마다 에러 표를 따로 본다. 원장 호출에서 이의 에러가 나오면 이름을 지어내지 않는다."""
    assert decode_revert(error_data(OBJECTION_ABI, "NotMember", STUDENT)).reason == RevertReason.UNKNOWN


def test_get_objection(node):
    client = objections(node)
    node.calls["exists"] = encoded(["bool"], [False])
    assert run(client.get_objection(3)) is None

    node.calls["exists"] = encoded(["bool"], [True])
    node.calls["getObjection"] = encoded(
        ["(uint256,bytes32,bytes32,uint8,address,address)"],
        [(1, bytes32(CONTENT), bytes32(ANSWER), 1, STUDENT, AUDITOR)],
    )
    objection = run(client.get_objection(3))
    assert (objection.entry_id, objection.content_hash, objection.answer_hash) == (1, CONTENT, ANSWER)
    assert (objection.status, objection.raiser, objection.responder) == (ObjectionStatus.ANSWERED, STUDENT, AUDITOR)


def test_ledger_and_objection_clients_share_nonces(node):
    """같은 릴레이어 계정이라 한 Web3Relayer 를 나눠 써야 nonce 가 겹치지 않는다."""
    node.outcome["logs"] = lambda tx_hash, block: [
        event_log("EntryPending", block, tx_hash, id=1, hash=b"\1" * 32, amount=1, kind=0, budgetId=0, correctsId=0, actor=STUDENT),
        contract_log(OBJECTIONS, "ObjectionRaised", block, tx_hash, objectionId=3, entryId=1, contentHash=bytes32(CONTENT), raiser=STUDENT),
    ]
    s = settings()
    shared = Web3Relayer(s, AsyncWeb3(node))
    ledger = Web3ChainClient(s, relayer=shared)
    registry = Web3ObjectionClient(shared, OBJECTIONS, s.objection_domain)
    request = RecordRequest(id=1, hash="0x" + "01" * 32, amount=1, kind=EntryKind.INCOME,
                            occurred_at=1_790_000_000 // 86400 * 86400 + 54000, deadline=1_790_000_300)

    async def both():
        await asyncio.gather(
            ledger.record_pending(request, SIG), registry.raise_objection(3, 1, CONTENT, STUDENT),
            ledger.record_pending(request, SIG), registry.raise_objection(4, 1, CONTENT, STUDENT),
        )

    run(both())
    assert sorted(tx["nonce"] for tx in node.sent) == [7, 8, 9, 10]
    assert {to_checksum_address(tx["to"]) for tx in node.sent} == {LEDGER, OBJECTIONS}


# ---------------------------------------------------------------- SBT 조회


def test_membership_reader(node):
    sbt = Web3MembershipReader(relayer(node), SBT)

    node.calls["hasValidMembership"] = encoded(["bool"], [True])
    assert run(sbt.has_valid_membership(STUDENT, 20262)) is True

    node.calls["tokenOf"] = encoded(["uint256"], [0])
    assert run(sbt.token_of(STUDENT, 20262)) is None
    node.calls["tokenOf"] = encoded(["uint256"], [5])
    assert run(sbt.token_of(STUDENT, 20262)) == 5

    node.calls["ownerOf"] = {"revert": "0x7e273289" + "00" * 31 + "09"}  # ERC721NonexistentToken(9) — 인터페이스 ABI 에 없는 에러
    node.call_args.clear()
    assert run(sbt.get_membership(9)) is None
    assert [name for name, _ in node.call_args] == ["ownerOf"]  # 없는 토큰이면 getMembership 을 부르지 않는다

    node.calls["ownerOf"] = encoded(["address"], [STUDENT])
    node.calls["getMembership"] = encoded(["(uint256,bytes32)"], [(20262, b"\7" * 32)])
    membership = run(sbt.get_membership(5))
    assert (membership.token_id, membership.term, membership.commitment) == (5, 20262, "0x" + "07" * 32)


# ---------------------------------------------------------------- 예산 조회


def test_budget_reader(node):
    budgets = Web3BudgetReader(relayer(node), BUDGET)
    node.calls["exists"] = encoded(["bool"], [False])
    assert run(budgets.get_budget(2)) is None
    assert run(budgets.remaining(2)) is None
    assert [name for name, _ in node.call_args] == ["exists", "exists"]  # 없으면 getBudget·remaining 을 부르지 않는다

    node.calls["exists"] = encoded(["bool"], [True])
    node.calls["getBudget"] = encoded(["(uint256,bytes32,uint256,uint256,uint256,uint16)"], [(20262, b"\xc3" * 32, 2_000_000, 500_000, 1_790_086_400, 2)])
    node.calls["remaining"] = encoded(["uint256"], [1_400_000])
    budget = run(budgets.get_budget(2))
    assert (budget.term, budget.category, budget.issued, budget.spent, budget.version) == (20262, "0x" + "c3" * 32, 2_000_000, 500_000, 2)
    assert run(budgets.remaining(2)) == 1_400_000
