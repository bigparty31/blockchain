"""entryCommit — 승인·반려자가 서명하는 항목 값의 커밋.

meta_hash 에는 kind·term·budgetId·correctsId 가 없어서, 해시만 대조하면 다른 예산으로 등록된 항목도 승인이 통과한다.
그래서 ConfirmApproval·RejectDecision 은 등록된 값 전체를 묶은 이 커밋에도 서명한다 (IAccountingLedger, docs/CONTRACTS.md).

    entryCommit = keccak256(abi.encode(bytes32 hash, int256 amount, uint8 kind, uint256 term, uint256 occurredAt,
                                       uint256 budgetId, uint256 correctsId, address registrant))

모두 정적 타입이라 abi.encode 는 32바이트 칸 8개를 이어 붙인 것과 같다. 원장의 entryCommitOf(id) 와 같은 값이 나와야 한다.
"""
from eth_utils import keccak

from app.chain import abi
from app.chain.models import KIND_ORDER, ChainEntry, _bytes32
from app.schemas.entry import EntryKind


def entry_commit(
    *,
    hash: str,
    amount: int,
    kind: EntryKind,
    term: int,
    occurred_at: int,
    budget_id: int,
    corrects_id: int,
    registrant: str,
) -> str:
    """항목 값으로 entryCommit 을 계산한다. 결과는 0x + 소문자 hex 64자."""
    encoded = b"".join(
        (
            bytes.fromhex(_bytes32(hash)[2:]),
            abi.int256(amount),
            abi.uint256(KIND_ORDER.index(kind)),  # uint8 도 abi.encode 에서는 32바이트 칸 하나다
            abi.uint256(term),
            abi.uint256(occurred_at),
            abi.uint256(budget_id),
            abi.uint256(corrects_id),
            abi.address(registrant),
        )
    )
    return "0x" + keccak(encoded).hex()


def entry_commit_of(entry: ChainEntry) -> str:
    """getEntry 결과로 계산한 entryCommit. 원장의 entryCommitOf(id) 와 같다."""
    return entry_commit(
        hash=entry.hash,
        amount=entry.amount,
        kind=entry.kind,
        term=entry.term,
        occurred_at=entry.occurred_at,
        budget_id=entry.budget_id,
        corrects_id=entry.corrects_id,
        registrant=entry.registrant,
    )
