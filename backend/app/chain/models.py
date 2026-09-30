"""ChainClient 가 주고받는 값.

온체인 구조체·에러를 그대로 옮긴다. 정본은 contracts/interfaces/IAccountingLedger.sol 과
docs/CONTRACTS.md 이고, enum 의 온체인 숫자 순서는 docs/enums.md 표 순서를 따른다.
서명 대상 구조체의 필드 순서는 EIP-712 typehash 의 순서와 같다 (도메인 name = "AccountingLedger", version = "1").
"""
import re
from enum import Enum
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.schemas.entry import EntryKind, EntryStatus

# docs/enums.md 표 순서 = 온체인 uint8 값. 튜플의 인덱스가 곧 그 값이다.
# 다음 주 실제 구현에서 enum 과 uint8 을 옮길 때 쓴다 (KIND_ORDER.index(kind) → 0·1, STATUS_ORDER[v] → enum).
KIND_ORDER = (EntryKind.INCOME, EntryKind.EXPENSE)
STATUS_ORDER = (EntryStatus.PENDING, EntryStatus.CONFIRMED, EntryStatus.REJECTED, EntryStatus.BLOCKED)

ZERO_BYTES32 = "0x" + "0" * 64
ZERO_ADDRESS = "0x" + "0" * 40

_BYTES32 = re.compile(r"0x[0-9a-f]{64}")
_SIGNATURE = re.compile(r"0x[0-9a-fA-F]{130}")
_KST_MIDNIGHT_REMAINDER = 54000  # KST 00:00 = UTC 15:00 → Unix 초 % 86400

# 원장의 저장 필드 폭과 금액 상한 (IAccountingLedger "저장 필드 폭", MAX_AMOUNT). 넘으면 체인이 revert 한다
MAX_AMOUNT = 10**15
UINT64_MAX = 2**64 - 1
UINT32_MAX = 2**32 - 1
# 학기 코드 YYYYS 의 학기 자리: 1·2 정규, 3 여름, 4 겨울 (docs/CONTRACTS.md "공통 규칙")
_TERM_SEMESTERS = (1, 2, 3, 4)


class BlockReason(str, Enum):
    """EntryBlocked.reason. docs/enums.md block_reason 순서."""

    BUDGET_EXCEEDED = "BUDGET_EXCEEDED"
    BUDGET_EXPIRED = "BUDGET_EXPIRED"
    BUDGET_NOT_FOUND = "BUDGET_NOT_FOUND"


# EntryBlocked 이벤트의 reason uint8 매핑. 쓰임은 KIND_ORDER 와 같다
BLOCK_REASON_ORDER = (BlockReason.BUDGET_EXCEEDED, BlockReason.BUDGET_EXPIRED, BlockReason.BUDGET_NOT_FOUND)


def _bytes32(value: str) -> str:
    if not _BYTES32.fullmatch(value):
        raise ValueError("0x + 소문자 hex 64자여야 한다 (docs/HASHING.md §5)")
    return value


def _term(value: int) -> int:
    """학기 코드 YYYYS (예: 20261). DB 의 Term.id 가 아니다 — 체인에는 이 코드를 넘긴다."""
    if not (10000 <= value <= 99999) or value % 10 not in _TERM_SEMESTERS:
        raise ValueError("term 은 학기 코드 YYYYS 여야 한다 (예: 20261). DB 의 Term.id 가 아니다")
    return value


def check_signature(signature: str) -> str:
    """EIP-712 서명 형식(0x + 65바이트)만 보고 소문자로 맞춰 돌려준다. 서명자 검증은 컨트랙트가 한다.

    서명은 모델 필드가 아니어서 모델 생성 때가 아니라 ChainClient 메서드를 부를 때 검사된다.
    대소문자가 달라도 같은 바이트라 둘 다 받는다 (해시는 HASHING §5 대로 소문자만 받는다).
    """
    if not _SIGNATURE.fullmatch(signature):
        raise ValueError("서명은 0x + hex 130자여야 한다")
    return signature.lower()


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
    term: int = Field(..., description="학기 코드 YYYYS. 지출은 예산의 term, 정정은 원본의 term 과 같아야 한다")
    occurred_at: int = Field(..., ge=0, description="사용일 KST 00:00:00 Unix 초 (docs/HASHING.md §1.3)")
    budget_id: int = Field(0, ge=0, description="INCOME 은 0")
    corrects_id: int = Field(0, ge=0, description="정정 대상 entryId. 정정이 아니면 0")
    deadline: int = Field(..., ge=0, description="서명 유효 시한 (Unix 초)")

    @field_validator("hash")
    @classmethod
    def _hash(cls, v: str) -> str:
        return _bytes32(v)

    @field_validator("term")
    @classmethod
    def _term(cls, v: int) -> int:
        return _term(v)

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
    entry_commit: str = Field(..., description="승인자가 본 항목 값의 커밋 (app.chain.commit). 다르면 EntryCommitMismatch")
    had_warning: bool = False
    warning_reason_hash: str = Field(ZERO_BYTES32, description="경고가 없으면 bytes32(0). 경고면 사유 해시 필수")
    deadline: int = Field(..., ge=0)

    @field_validator("hash", "entry_commit", "warning_reason_hash")
    @classmethod
    def _hash(cls, v: str) -> str:
        return _bytes32(v)


class RejectDecision(_Frozen):
    """감사·회장 기기가 서명한 반려 요청."""

    id: int = Field(..., ge=1)
    entry_commit: str = Field(..., description="반려자가 본 항목 값의 커밋. ConfirmApproval 과 같은 식")
    reason_hash: str = Field(..., description="반려 사유 text_hash (docs/HASHING.md §3). 0 이면 ReasonRequired")
    deadline: int = Field(..., ge=0)

    @field_validator("entry_commit", "reason_hash")
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
    term: int = Field(..., description="학기 코드 YYYYS. meta_hash 에 없어서 단건 검증이 따로 대조한다")
    occurred_at: int
    budget_id: int
    corrects_id: int
    registrant: str = Field(..., description="등록 서명자 주소. EIP-55 체크섬 형식이라 DB 와 비교할 땐 양쪽을 소문자로 맞춘다")
    approver: str = Field(..., description="확정·반려 서명자 주소. 미처리면 address(0). 형식은 registrant 와 같다")


# ---------------------------------------------------------------- 에러


class RevertReason(str, Enum):
    """값은 Solidity 에러 이름 그대로다. 실제 구현에서 revert 데이터를 이 값으로 옮긴다.

    범위는 AccountingLedger ABI 의 에러다 (ChainClient 가 원장만 부른다). confirmEntry 안에서 BudgetToken 이 내는
    InsufficientBudget·BudgetExpired 도 원장 ABI 에 같은 시그니처로 선언돼 있어 원장 ABI 하나로 해석된다.
    BudgetToken·RoleManager 를 직접 부르게 되면 TermRequired·ReservedId 처럼 이름이 같은 에러가 있으니
    이름만이 아니라 어느 컨트랙트에서 났는지까지 보고 분류한다. 순서는 IAccountingLedger 의 검사 순서다.
    """

    # 서명·시한
    SIGNATURE_EXPIRED = "SignatureExpired"
    INVALID_SIGNATURE = "InvalidSignature"  # 서명 바이트가 깨졌을 때만. 다른 데이터에 서명하면 아래 둘로 온다
    NOT_REGISTRANT = "NotRegistrant"  # 등록 서명자가 총무가 아님. 앱이 다른 값에 서명해도 이것
    NOT_APPROVER = "NotApprover"  # 확정·반려 서명자가 감사·회장이 아님. 앱이 다른 값에 서명해도 이것
    SELF_APPROVAL = "SelfApproval"  # 등록자 == 승인자. 한 주소 한 롤이라 등록 뒤 롤이 바뀐 경우에만 난다
    # 항목 존재·상태
    RESERVED_ID = "ReservedId"  # id == 0. 중복과 구분한다 — 재시도 판정에 쓰지 않는다
    ENTRY_ALREADY_EXISTS = "EntryAlreadyExists"
    ENTRY_NOT_FOUND = "EntryNotFound"
    INVALID_STATUS = "InvalidStatus"  # PENDING 이 아닌 항목(BLOCKED 포함)의 확정·반려
    # 입력 값
    HASH_REQUIRED = "HashRequired"
    TERM_REQUIRED = "TermRequired"
    ZERO_AMOUNT = "ZeroAmount"
    AMOUNT_OUT_OF_RANGE = "AmountOutOfRange"  # |amount| > MAX_AMOUNT
    FIELD_OUT_OF_RANGE = "FieldOutOfRange"  # id·term·occurredAt·budgetId·correctsId 가 저장 폭을 넘음
    NEGATIVE_AMOUNT_WITHOUT_CORRECTION = "NegativeAmountWithoutCorrection"
    BUDGET_ID_NOT_ALLOWED_FOR_INCOME = "BudgetIdNotAllowedForIncome"
    TERM_MISMATCH = "TermMismatch"  # 지출 term ≠ 예산 term, 또는 정정 term ≠ 원본 term
    # 정정
    CORRECTION_TARGET_NOT_FOUND = "CorrectionTargetNotFound"
    CORRECTION_TARGET_NOT_CONFIRMED = "CorrectionTargetNotConfirmed"
    CORRECTION_KIND_MISMATCH = "CorrectionKindMismatch"
    INVALID_CORRECTION_TARGET = "InvalidCorrectionTarget"  # 대상이 원본도 재분류 양수 정정도 아님
    CORRECTION_BUDGET_MISMATCH = "CorrectionBudgetMismatch"  # 음수 정정의 예산 ≠ 원본 예산
    CORRECTION_EXCEEDS_ORIGINAL = "CorrectionExceedsOriginal"  # 음수 정정 누적이 대상 순금액을 넘음
    # 확정·반려 내용
    HASH_MISMATCH = "HashMismatch"
    ENTRY_COMMIT_MISMATCH = "EntryCommitMismatch"  # 승인·반려자가 본 값과 등록된 값이 다름
    REASON_REQUIRED = "ReasonRequired"  # 반려 사유 0, 또는 경고 승인에 사유 0
    REASON_NOT_ALLOWED = "ReasonNotAllowed"  # 경고 아닌 확정에 사유
    # BudgetToken 이 confirmEntry 안에서 내는 것. 항목은 PENDING 그대로라 반려 흐름으로 넘긴다
    INSUFFICIENT_BUDGET = "InsufficientBudget"
    BUDGET_EXPIRED = "BudgetExpired"


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
