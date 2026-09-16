"""ChainClient 가 주고받는 값.

온체인 구조체·에러를 그대로 옮긴다. 정본은 contracts/interfaces/IAccountingLedger.sol 과
docs/CONTRACTS.md 이고, enum 의 온체인 숫자 순서는 docs/enums.md 표 순서를 따른다.
"""
import re
from enum import Enum
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.schemas.entry import EntryKind, EntryStatus

# docs/enums.md 표 순서 = 온체인 uint8 값
KIND_ORDER = (EntryKind.INCOME, EntryKind.EXPENSE)
STATUS_ORDER = (EntryStatus.PENDING, EntryStatus.CONFIRMED, EntryStatus.REJECTED, EntryStatus.BLOCKED)

ZERO_BYTES32 = "0x" + "0" * 64
ZERO_ADDRESS = "0x" + "0" * 40

_BYTES32 = re.compile(r"0x[0-9a-f]{64}")
_SIGNATURE = re.compile(r"0x[0-9a-f]{130}")
_KST_MIDNIGHT_REMAINDER = 54000  # KST 00:00 = UTC 15:00 → Unix 초 % 86400


class BlockReason(str, Enum):
    """EntryBlocked.reason. docs/enums.md block_reason 순서."""

    BUDGET_EXCEEDED = "BUDGET_EXCEEDED"
    BUDGET_EXPIRED = "BUDGET_EXPIRED"
    BUDGET_NOT_FOUND = "BUDGET_NOT_FOUND"


BLOCK_REASON_ORDER = (BlockReason.BUDGET_EXCEEDED, BlockReason.BUDGET_EXPIRED, BlockReason.BUDGET_NOT_FOUND)


def _bytes32(value: str) -> str:
    if not _BYTES32.fullmatch(value):
        raise ValueError("0x + 소문자 hex 64자여야 한다 (docs/HASHING.md §5)")
    return value


def check_signature(signature: str) -> str:
    """EIP-712 서명 형식(0x + 65바이트)만 본다. 서명자 검증은 컨트랙트가 한다."""
    if not _SIGNATURE.fullmatch(signature):
        raise ValueError("서명은 0x + 소문자 hex 130자여야 한다")
    return signature


class _Frozen(BaseModel):
    model_config = ConfigDict(frozen=True)


# ---------------------------------------------------------------- 서명 대상 구조체
# 필드 이름·순서가 IAccountingLedger 의 EIP-712 struct 와 같다. 앱이 서명한 값을 그대로 담는다.


class RecordRequest(_Frozen):
    """총무 기기가 서명한 등록 요청."""

    id: int = Field(..., ge=1, description="DB 에서 채번한 entryId. 1부터 (0 은 없음)")
    hash: str = Field(..., description="meta_hash (docs/HASHING.md §1)")
    amount: int = Field(..., description="원 단위. 정정 항목만 음수")
    kind: EntryKind
    occurred_at: int = Field(..., description="사용일 KST 00:00:00 Unix 초 (docs/HASHING.md §1.3)")
    budget_id: int = Field(0, ge=0, description="INCOME 은 0")
    corrects_id: int = Field(0, ge=0, description="정정 대상 entryId. 정정이 아니면 0")
    deadline: int = Field(..., ge=0, description="서명 유효 시한 (Unix 초)")

    @field_validator("hash")
    @classmethod
    def _hash(cls, v: str) -> str:
        return _bytes32(v)

    @field_validator("occurred_at")
    @classmethod
    def _kst_midnight(cls, v: int) -> int:
        if v % 86400 != _KST_MIDNIGHT_REMAINDER:
            raise ValueError("사용일의 KST 자정이어야 한다 (docs/HASHING.md §1.3)")
        return v


class ConfirmApproval(_Frozen):
    """감사·회장 기기가 서명한 확정 요청."""

    id: int = Field(..., ge=1)
    hash: str = Field(..., description="등록 때와 같은 meta_hash. 다르면 HashMismatch")
    had_warning: bool = False
    warning_reason_hash: str = Field(ZERO_BYTES32, description="경고가 없으면 bytes32(0)")
    deadline: int = Field(..., ge=0)

    @field_validator("hash", "warning_reason_hash")
    @classmethod
    def _hash(cls, v: str) -> str:
        return _bytes32(v)


class RejectDecision(_Frozen):
    """감사·회장 기기가 서명한 반려 요청."""

    id: int = Field(..., ge=1)
    reason_hash: str = Field(..., description="반려 사유 text_hash (docs/HASHING.md §3)")
    deadline: int = Field(..., ge=0)

    @field_validator("reason_hash")
    @classmethod
    def _hash(cls, v: str) -> str:
        return _bytes32(v)


# ---------------------------------------------------------------- 결과


class TxResult(_Frozen):
    """트랜잭션이 블록에 들어간 뒤의 결과. revert 는 여기로 오지 않고 ChainRevert 로 올라간다."""

    tx_hash: str
    status: EntryStatus = Field(..., description="record_pending 은 PENDING·BLOCKED, 확정은 CONFIRMED, 반려는 REJECTED")
    block_reason: Optional[BlockReason] = Field(None, description="status 가 BLOCKED 일 때만")


class ChainEntry(_Frozen):
    """getEntry(id) 결과. 단건 검증(docs/HASHING.md §2)이 읽는 값."""

    id: int
    hash: str
    amount: int
    kind: EntryKind
    status: EntryStatus
    occurred_at: int
    budget_id: int
    corrects_id: int
    registrant: str = Field(..., description="등록 서명자 주소")
    approver: str = Field(..., description="확정·반려 서명자 주소. 미처리면 address(0)")


# ---------------------------------------------------------------- 에러


class RevertReason(str, Enum):
    """값은 Solidity 에러 이름 그대로다. 실제 구현에서 revert 데이터를 이 값으로 옮긴다."""

    UNAUTHORIZED = "Unauthorized"
    INVALID_SIGNATURE = "InvalidSignature"
    SIGNATURE_EXPIRED = "SignatureExpired"
    NOT_REGISTRANT = "NotRegistrant"
    NOT_APPROVER = "NotApprover"
    SELF_APPROVAL = "SelfApproval"
    HASH_MISMATCH = "HashMismatch"
    INVALID_STATUS = "InvalidStatus"
    ENTRY_ALREADY_EXISTS = "EntryAlreadyExists"
    ENTRY_NOT_FOUND = "EntryNotFound"
    ZERO_AMOUNT = "ZeroAmount"
    NEGATIVE_AMOUNT_WITHOUT_CORRECTION = "NegativeAmountWithoutCorrection"
    CORRECTION_TARGET_NOT_FOUND = "CorrectionTargetNotFound"
    CORRECTION_TARGET_NOT_CONFIRMED = "CorrectionTargetNotConfirmed"
    INSUFFICIENT_BUDGET = "InsufficientBudget"  # BudgetToken. confirmEntry 안에서 발생


class ChainError(Exception):
    """체인 호출 실패의 공통 부모."""


class ChainRevert(ChainError):
    """트랜잭션이 revert 됐다. 온체인 상태는 바뀌지 않는다."""

    def __init__(self, reason: RevertReason, detail: str = ""):
        self.reason = reason
        self.detail = detail
        super().__init__(f"{reason.value}: {detail}" if detail else reason.value)


class ChainUnavailable(ChainError):
    """RPC 연결 실패·타임아웃. revert 와 달리 트랜잭션이 들어갔는지 알 수 없다."""
