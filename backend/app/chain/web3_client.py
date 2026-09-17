"""ChainClient 의 실제 구현 — AccountingLedger. 보내기·nonce·재전송은 relayer.Web3Relayer 가 한다.

임원 서명은 인자로 받은 것을 calldata 에 담을 뿐이다. 릴레이어 서명은 가스 지불용이고 행위자가 아니다 (PRD §9.2).

노드 없이 확인한 범위는 tests/test_web3_client.py (가짜 JSON-RPC 노드). 실제 컨트랙트 동작은 구현이 나온 뒤
Hardhat 로컬 노드로 확인한다.
"""
from typing import Any, Optional

from eth_utils import to_checksum_address
from hexbytes import HexBytes
from web3 import AsyncWeb3

from app.chain.models import (
    BLOCK_REASON_ORDER,
    KIND_ORDER,
    STATUS_ORDER,
    ChainConfigError,
    ChainEntry,
    ConfirmApproval,
    ConfirmedEntry,
    DecisionRecord,
    RecordRequest,
    RejectDecision,
    TxResult,
    check_signature,
)
from app.chain.relayer import Web3Relayer, bytes32, topic_uint, tx_hash_of
from app.chain.revert import LEDGER_ERRORS
from app.chain.settings import ChainSettings
from app.schemas.entry import EntryStatus


class Web3ChainClient:
    """ChainClient 와 LedgerEvents 를 구현한다."""

    def __init__(self, settings: ChainSettings, w3: Optional[AsyncWeb3] = None, relayer: Optional[Web3Relayer] = None):
        self._settings = settings
        self._relayer = relayer or Web3Relayer(settings, w3)
        self._ledger = self._relayer.contract(settings.ledger_address, "IAccountingLedger", LEDGER_ERRORS)

    @property
    def relayer(self) -> Web3Relayer:
        return self._relayer

    @property
    def relayer_address(self) -> str:
        return self._relayer.address

    async def check(self) -> list[str]:
        """서버 시작 때 부른다. 노드(chainId·잔고)와 원장(코드·DOMAIN_SEPARATOR)을 본다. 어긋나면 ChainConfigError."""
        warnings = await self._relayer.check()
        await self._relayer.check_contract(self._ledger, self._settings.domain)
        return warnings

    # ------------------------------------------------------------ ChainClient

    async def record_pending(self, request: RecordRequest, signature: str) -> TxResult:
        args = [_record_args(request), HexBytes(check_signature(signature))]
        receipt = await self._relayer.send(self._ledger, self._ledger.encode("recordPending", args))
        return _record_result(tx_hash_of(receipt), self._ledger.decode_logs(receipt["logs"], ("EntryBlocked", "EntryPending")))

    async def confirm_entry(self, approval: ConfirmApproval, signature: str) -> TxResult:
        args = [_confirm_args(approval), HexBytes(check_signature(signature))]
        receipt = await self._relayer.send(self._ledger, self._ledger.encode("confirmEntry", args))
        return self._decision_receipt(receipt, "EntryConfirmed", EntryStatus.CONFIRMED)

    async def reject_entry(self, decision: RejectDecision, signature: str) -> TxResult:
        args = [_reject_args(decision), HexBytes(check_signature(signature))]
        receipt = await self._relayer.send(self._ledger, self._ledger.encode("rejectEntry", args))
        return self._decision_receipt(receipt, "EntryRejected", EntryStatus.REJECTED)

    async def get_entry(self, entry_id: int) -> Optional[ChainEntry]:
        functions = self._ledger.web3.functions
        # getEntry 는 없는 id 에도 0 구조체(status PENDING)를 돌려주므로 exists 를 먼저 본다
        if not await self._relayer.rpc(functions.exists(entry_id).call(), LEDGER_ERRORS):
            return None
        raw = await self._relayer.rpc(functions.getEntry(entry_id).call(), LEDGER_ERRORS)
        return _entry(entry_id, raw)

    async def get_record_result(self, entry_id: int) -> Optional[TxResult]:
        events = await self._relayer.find_events(self._ledger, ("EntryBlocked", "EntryPending"), topic_uint(entry_id))
        return _record_result(tx_hash_of(events[0]), events) if events else None

    async def get_decision_result(self, entry_id: int) -> Optional[DecisionRecord]:
        events = await self._relayer.find_events(self._ledger, ("EntryConfirmed", "EntryRejected"), topic_uint(entry_id))
        return _decision_record(events[0]) if events else None

    # ------------------------------------------------------------ LedgerEvents

    async def safe_block(self) -> int:
        return await self._relayer.safe_block()

    async def confirmed_entries(self, from_block: int, to_block: int) -> list[ConfirmedEntry]:
        events = await self._relayer.events_between(self._ledger, ("EntryConfirmed",), from_block, to_block)
        return [
            ConfirmedEntry(
                id=e["args"]["id"],
                amount=e["args"]["amount"],
                kind=KIND_ORDER[e["args"]["kind"]],
                block_number=e["blockNumber"],
                tx_hash=tx_hash_of(e),
            )
            for e in events
        ]

    # ------------------------------------------------------------ 내부

    def _decision_receipt(self, receipt: Any, event: str, status: EntryStatus) -> DecisionRecord:
        events = self._ledger.decode_logs(receipt["logs"], (event,))
        if not events:
            raise ChainConfigError(f"영수증에 {event} 가 없다 — ABI 나 컨트랙트 주소를 확인")
        return _decision_record(events[0])


def _record_args(r: RecordRequest) -> tuple:
    kind = KIND_ORDER.index(r.kind)
    return (r.id, bytes32(r.hash), r.amount, kind, r.occurred_at, r.budget_id, r.corrects_id, r.deadline)


def _confirm_args(a: ConfirmApproval) -> tuple:
    return (a.id, bytes32(a.hash), a.had_warning, bytes32(a.warning_reason_hash), a.deadline)


def _reject_args(d: RejectDecision) -> tuple:
    return (d.id, bytes32(d.reason_hash), d.deadline)


def _entry(entry_id: int, raw: Any) -> ChainEntry:
    hash_, amount, kind, status, occurred_at, budget_id, corrects_id, registrant, approver = raw
    return ChainEntry(
        id=entry_id,
        hash=HexBytes(hash_).to_0x_hex(),
        amount=amount,
        kind=KIND_ORDER[kind],
        status=STATUS_ORDER[status],
        occurred_at=occurred_at,
        budget_id=budget_id,
        corrects_id=corrects_id,
        registrant=to_checksum_address(registrant),
        approver=to_checksum_address(approver),
    )


def _decision_record(event: Any) -> DecisionRecord:
    args = event["args"]
    if event["event"] == "EntryConfirmed":
        details = {
            "status": EntryStatus.CONFIRMED,
            "had_warning": args["hadWarning"],
            "warning_reason_hash": HexBytes(args["warningReasonHash"]).to_0x_hex(),
        }
    else:
        details = {"status": EntryStatus.REJECTED, "reason_hash": HexBytes(args["reasonHash"]).to_0x_hex()}
    return DecisionRecord(
        tx_hash=tx_hash_of(event), approver=to_checksum_address(args["actor"]), block_number=event["blockNumber"], **details
    )


def _record_result(tx_hash: str, events: list) -> TxResult:
    if not events:
        raise ChainConfigError("영수증에 EntryPending·EntryBlocked 가 없다 — ABI 나 컨트랙트 주소를 확인")
    first = events[0]
    if first["event"] == "EntryBlocked":
        return TxResult(tx_hash=tx_hash, status=EntryStatus.BLOCKED, block_reason=BLOCK_REASON_ORDER[first["args"]["reason"]])
    return TxResult(tx_hash=tx_hash, status=EntryStatus.PENDING)
