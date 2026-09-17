"""ChainClient 가 주고받는 값.

온체인 구조체·에러를 그대로 옮긴다. 정본은 contracts/interfaces/*.sol 과 docs/CONTRACTS.md 이고,
enum 의 온체인 숫자 순서는 docs/enums.md 표 순서를 따른다.
"""
import re
from enum import Enum
from typing import Optional

from eth_utils import keccak
from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.hashing import ZERO_BYTES32, check_bytes32, check_occurred_at
from app.schemas.entry import EntryKind, EntryStatus

# docs/enums.md 표 순서 = 온체인 uint8 값
KIND_ORDER = (EntryKind.INCOME, EntryKind.EXPENSE)
STATUS_ORDER = (EntryStatus.PENDING, EntryStatus.CONFIRMED, EntryStatus.REJECTED, EntryStatus.BLOCKED)

ZERO_ADDRESS = "0x" + "0" * 40

_SIGNATURE = re.compile(r"0x[0-9a-fA-F]{130}")
_ADDRESS = re.compile(r"0x[0-9a-fA-F]{40}")


class BlockReason(str, Enum):
    """EntryBlocked.reason. docs/enums.md block_reason 순서."""

    BUDGET_EXCEEDED = "BUDGET_EXCEEDED"
    BUDGET_EXPIRED = "BUDGET_EXPIRED"
    BUDGET_NOT_FOUND = "BUDGET_NOT_FOUND"


BLOCK_REASON_ORDER = (BlockReason.BUDGET_EXCEEDED, BlockReason.BUDGET_EXPIRED, BlockReason.BUDGET_NOT_FOUND)


class Role(str, Enum):
    """온체인 임원 롤. 식별자는 이름의 keccak256 이고 enum 숫자가 아니다 (docs/enums.md role). STUDENT 는 온체인 롤이 아니다."""

    TREASURER = "TREASURER"
    AUDITOR = "AUDITOR"
    PRESIDENT = "PRESIDENT"

    @property
    def id(self) -> str:
        return "0x" + keccak(text=self.value).hex()


APPROVER_ROLES = (Role.AUDITOR, Role.PRESIDENT)  # 확정·반려 서명자
RESPONDER_ROLES = (Role.TREASURER, Role.AUDITOR, Role.PRESIDENT)  # 이의 답변 서명자 — "임원" (docs/CONTRACTS.md 함수 표)


class ObjectionStatus(str, Enum):
    """docs/enums.md objection status 순서."""

    OPEN = "OPEN"
    ANSWERED = "ANSWERED"


OBJECTION_STATUS_ORDER = (ObjectionStatus.OPEN, ObjectionStatus.ANSWERED)


def check_signature(signature: str) -> str:
    """EIP-712 서명 형식(0x + 65바이트)만 보고 소문자로 맞춰 돌려준다. 서명자 검증은 컨트랙트가 한다.

    서명은 모델 필드가 아니어서 모델 생성 때가 아니라 ChainClient 메서드를 부를 때 검사된다.
    대소문자가 달라도 같은 바이트라 둘 다 받는다 (해시는 HASHING §5 대로 소문자만 받는다).
    """
    if not _SIGNATURE.fullmatch(signature):
        raise ValueError("서명은 0x + hex 130자여야 한다")
    return signature.lower()


def check_address(address: str) -> str:
    """주소 형식(0x + 20바이트)만 본다. 대소문자는 그대로 두고, 비교할 때 소문자로 맞춘다."""
    if not _ADDRESS.fullmatch(address):
        raise ValueError("주소는 0x + hex 40자여야 한다")
    return address


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
    occurred_at: int = Field(..., ge=0, description="사용일 KST 00:00:00 Unix 초 (docs/HASHING.md §1.3)")
    budget_id: int = Field(0, ge=0, description="INCOME 은 0")
    corrects_id: int = Field(0, ge=0, description="정정 대상 entryId. 정정이 아니면 0")
    deadline: int = Field(..., ge=0, description="서명 유효 시한 (Unix 초)")

    @field_validator("hash")
    @classmethod
    def _hash(cls, v: str) -> str:
        return check_bytes32(v)

    @field_validator("occurred_at")
    @classmethod
    def _kst_midnight(cls, v: int) -> int:
        return check_occurred_at(v)


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
        return check_bytes32(v)


class RejectDecision(_Frozen):
    """감사·회장 기기가 서명한 반려 요청."""

    id: int = Field(..., ge=1)
    reason_hash: str = Field(..., description="반려 사유 text_hash (docs/HASHING.md §3)")
    deadline: int = Field(..., ge=0)

    @field_validator("reason_hash")
    @classmethod
    def _hash(cls, v: str) -> str:
        return check_bytes32(v)


class AnswerRequest(_Frozen):
    """임원 기기가 서명한 이의 답변. ObjectionRegistry 도메인으로 서명한다."""

    objection_id: int = Field(..., ge=1)
    answer_hash: str = Field(..., description="답변 본문 text_hash (docs/HASHING.md §3)")
    deadline: int = Field(..., ge=0)

    @field_validator("answer_hash")
    @classmethod
    def _hash(cls, v: str) -> str:
        return check_bytes32(v)


# ---------------------------------------------------------------- 결과


class TxResult(_Frozen):
    """트랜잭션이 블록에 들어간 뒤의 결과. revert 는 여기로 오지 않고 ChainRevert 로 올라간다."""

    tx_hash: str
    status: EntryStatus = Field(..., description="record_pending 은 PENDING·BLOCKED, 확정은 CONFIRMED, 반려는 REJECTED")
    block_reason: Optional[BlockReason] = Field(None, description="status 가 BLOCKED 일 때만")


class DecisionRecord(TxResult):
    """확정·반려 결과. EntryConfirmed·EntryRejected 이벤트에만 있는 값을 함께 담는다.

    단건 검증(docs/HASHING.md §2)은 경고 무시 승인 사유와 반려 사유를 getEntry 가 아니라 이 이벤트에서 읽는다.
    """

    approver: str = Field(..., description="확정·반려 서명자 (이벤트의 actor)")
    had_warning: bool = False
    warning_reason_hash: str = Field(ZERO_BYTES32, description="확정만. 경고 없이 확정했으면 bytes32(0)")
    reason_hash: str = Field(ZERO_BYTES32, description="반려만")
    block_number: int


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
    registrant: str = Field(..., description="등록 서명자 주소. EIP-55 체크섬 형식이라 DB 와 비교할 땐 양쪽을 소문자로 맞춘다")
    approver: str = Field(..., description="확정·반려 서명자 주소. 미처리면 address(0). 형식은 registrant 와 같다")


class ConfirmedEntry(_Frozen):
    """EntryConfirmed 이벤트 하나. 장부 잔액 집계가 읽는다 (docs/CONTRACTS.md 이벤트)."""

    id: int
    amount: int = Field(..., description="원. 정정 항목은 음수")
    kind: EntryKind
    block_number: int
    tx_hash: str


class ObjectionTx(_Frozen):
    """이의 제기·답변 트랜잭션이 블록에 들어간 뒤의 결과."""

    tx_hash: str
    status: ObjectionStatus


class ChainObjection(_Frozen):
    """getObjection(id) 결과."""

    id: int
    entry_id: int
    content_hash: str
    answer_hash: str = Field(..., description="ANSWERED 전에는 bytes32(0)")
    status: ObjectionStatus
    raiser: str
    responder: str = Field(..., description="ANSWERED 전에는 address(0)")


class ChainMembership(_Frozen):
    """getMembership(tokenId) 결과."""

    token_id: int
    term: int
    commitment: str


class ChainBudget(_Frozen):
    """BudgetToken.getBudget(budgetId) 결과. 잔량은 여기서 계산하지 않고 remaining() 을 쓴다 (회수분이 구조체에 없다)."""

    id: int
    term: int = Field(..., description="학기 식별자 (예: 20261)")
    category: str = Field(..., description="keccak256(항목 이름). 이름은 오프체인 (docs/CONTRACTS.md category)")
    issued: int = Field(..., description="누적 배정액 (원)")
    spent: int = Field(..., description="누적 소모액 (원)")
    expires_at: int
    version: int = Field(..., description="issue 때 1, increase 마다 +1")


# ---------------------------------------------------------------- 에러


class RevertReason(str, Enum):
    """값은 Solidity 에러 이름 그대로다. 실제 구현에서 revert 데이터를 이 값으로 옮긴다.

    confirmEntry 는 BudgetToken 을 부르므로 AccountingLedger 와 BudgetToken 의 에러를 함께 디코딩한다.
    이름이 같아도 인자가 달라 selector 가 다른 에러가 있다 — ZeroAmount(uint256) 와 ZeroAmount() 는 둘 다 ZERO_AMOUNT.
    """

    UNAUTHORIZED = "Unauthorized"
    INVALID_SIGNATURE = "InvalidSignature"  # 서명 바이트가 깨졌을 때만. 다른 데이터에 서명하면 아래 둘로 온다
    SIGNATURE_EXPIRED = "SignatureExpired"
    NOT_REGISTRANT = "NotRegistrant"  # 등록 서명자가 총무가 아님. 앱이 다른 값에 서명해도 이것
    NOT_APPROVER = "NotApprover"  # 확정·반려 서명자가 감사·회장이 아님. 앱이 다른 값에 서명해도 이것
    SELF_APPROVAL = "SelfApproval"
    HASH_MISMATCH = "HashMismatch"
    INVALID_STATUS = "InvalidStatus"
    ENTRY_ALREADY_EXISTS = "EntryAlreadyExists"
    ENTRY_NOT_FOUND = "EntryNotFound"
    ZERO_AMOUNT = "ZeroAmount"
    NEGATIVE_AMOUNT_WITHOUT_CORRECTION = "NegativeAmountWithoutCorrection"
    CORRECTION_TARGET_NOT_FOUND = "CorrectionTargetNotFound"
    CORRECTION_TARGET_NOT_CONFIRMED = "CorrectionTargetNotConfirmed"
    # 여기부터 BudgetToken. confirmEntry 안의 spend / refund 에서 발생하고, 항목은 PENDING 그대로다
    INSUFFICIENT_BUDGET = "InsufficientBudget"
    BUDGET_EXPIRED = "BudgetExpired"  # 등록 뒤 확정 전에 예산 마감이 지남
    BUDGET_NOT_FOUND = "BudgetNotFound"
    REFUND_EXCEEDS_SPENT = "RefundExceedsSpent"  # 감액 정정이 소모액보다 큼
    # 여기부터 ObjectionRegistry. EntryNotFound·InvalidSignature·SignatureExpired·Unauthorized 는 위와 같은 값
    OBJECTION_ALREADY_EXISTS = "ObjectionAlreadyExists"
    OBJECTION_NOT_FOUND = "ObjectionNotFound"
    OBJECTION_ALREADY_ANSWERED = "ObjectionAlreadyAnswered"
    NOT_MEMBER = "NotMember"  # raiser 가 그 학기 SBT 를 갖고 있지 않다
    NOT_RESPONDER = "NotResponder"  # 답변 서명자가 임원이 아니다. 앱이 다른 값에 서명해도 이것

    UNKNOWN = "Unknown"  # 위에 없는 에러·require 문자열·panic. 원본은 ChainRevert.data 와 detail 에 남는다


class ChainError(Exception):
    """체인 호출 실패의 공통 부모."""


class ChainRevert(ChainError):
    """트랜잭션이 revert 됐다. 온체인 상태는 바뀌지 않는다."""

    def __init__(self, reason: RevertReason, detail: str = "", data: Optional[str] = None):
        self.reason = reason
        self.detail = detail
        self.data = data  # revert 데이터 원본 (0x hex). 실제 구현에서만 채운다
        super().__init__(f"{reason.value}: {detail}" if detail else reason.value)


class ChainUnavailable(ChainError):
    """RPC 연결 실패·타임아웃. revert 와 달리 트랜잭션이 들어갔는지 알 수 없다."""

    def __init__(self, message: str = "", tx_hash: Optional[str] = None):
        self.tx_hash = tx_hash  # 이미 보낸 뒤라면 그 트랜잭션. 보내기 전에 실패했으면 None
        super().__init__(f"{message} (tx={tx_hash})" if tx_hash else message)


class ChainNotSent(ChainError):
    """트랜잭션을 보내지 못했다 — 보내기 전에 실패했거나 노드가 받지 않았다(잔고 부족·nonce 어긋남 등).

    ChainUnavailable 과 달리 체인에 들어가지 않은 것이 확정이다. 같은 서명으로 다시 보내도 된다.
    """

    def __init__(self, message: str = "", tx_hash: Optional[str] = None):
        self.tx_hash = tx_hash  # 서명까지 했다면 그 해시 (참고용). 체인에는 없다
        super().__init__(message)


class ChainConfigError(Exception):
    """설정이 체인과 맞지 않는다 (chainId·주소·도메인·ABI). 재시도로 풀리지 않으므로 ChainError 가 아니다."""
