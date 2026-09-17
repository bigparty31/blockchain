"""등록 릴레이가 다루는 값. 흐름은 docs/RELAY.md."""
from enum import Enum
from typing import Optional, Union

from pydantic import BaseModel, ConfigDict, Field

from app.chain.models import ZERO_BYTES32, BlockReason, ConfirmApproval, RecordRequest, RejectDecision
from app.schemas.entry import EntryKind, EntryStatus


class DraftStatus(str, Enum):
    DRAFT = "DRAFT"  # 서명 대기
    SUBMITTING = "SUBMITTING"  # 체인에 보냈고 결과를 아직 모른다. 다시 보내지 않는다
    FAILED = "FAILED"  # 체인에 없는 것이 확정됐다 (revert·보내지 못함·시한 경과). 다시 서명할 수 있다
    RECORDED = "RECORDED"  # 체인에 들어갔고 Entry 행이 생겼다
    DISCARDED = "DISCARDED"  # 총무가 버렸다. 예약한 id 는 다시 쓰지 않는다


OPEN_STATUSES = (DraftStatus.DRAFT, DraftStatus.SUBMITTING, DraftStatus.FAILED)

# fail_reason 에는 RevertReason 값이 들어가고, 체인이 아닌 릴레이가 판정한 경우 아래 셋이 들어간다
NOT_RECORDED_BY_DEADLINE = "NotRecordedByDeadline"  # 서명 시한이 지나도록 체인에 없다. 이제 들어갈 수도 없다
NOT_SENT = "NotSent"  # 보내지 못했다 (잔고 부족·연결 실패 등). 체인에 없는 것이 확정이라 바로 다시 제출할 수 있다
ENTRY_ID_TAKEN = "EntryIdTaken"  # 체인에 같은 id 가 다른 내용으로 있다 (DB 만 초기화한 경우 등). 새 초안으로 다시 등록한다


class Draft(BaseModel):
    """초안 중 체인 등록에 필요한 부분.

    초안 테이블에는 이 밖에 Entry 입력 칼럼(거래처·목적·영수증·OCR 결과 등)이 함께 있고,
    RECORDED 가 될 때 그 값으로 Entry 행을 만든다 (DraftStore.record).
    """

    model_config = ConfigDict(frozen=True)

    id: int = Field(..., ge=1, description="Entry id 시퀀스에서 예약한 entryId. RECORDED 가 되면 그대로 Entry.id")
    created_by: int = Field(..., description="초안을 만든 총무 User id")
    registrant: str = Field(..., description="서명해야 하는 총무의 wallet_address")
    hash: str = Field(..., description="서버가 계산한 meta_hash")
    amount: int
    kind: EntryKind
    occurred_at: int
    budget_id: int = 0
    corrects_id: int = 0

    status: DraftStatus = DraftStatus.DRAFT
    deadline: Optional[int] = Field(None, description="마지막으로 보낸 서명의 시한")
    signature: Optional[str] = Field(None, description="마지막으로 보낸 서명")
    fail_reason: Optional[str] = Field(None, description="FAILED 일 때만")
    entry_status: Optional[EntryStatus] = Field(None, description="RECORDED 일 때 PENDING 또는 BLOCKED")
    block_reason: Optional[BlockReason] = None
    tx_hash: Optional[str] = Field(None, description="RECORDED 일 때 등록 트랜잭션. Entry.tx_pending 에 들어간다")

    def record_request(self, deadline: int) -> RecordRequest:
        return RecordRequest(
            id=self.id,
            hash=self.hash,
            amount=self.amount,
            kind=self.kind,
            occurred_at=self.occurred_at,
            budget_id=self.budget_id,
            corrects_id=self.corrects_id,
            deadline=deadline,
        )


class DecisionKind(str, Enum):
    CONFIRM = "CONFIRM"
    REJECT = "REJECT"


class DecisionStatus(str, Enum):
    SUBMITTING = "SUBMITTING"  # 체인에 보냈고 결과를 아직 모른다. 이 항목에 다른 결정을 보내지 않는다
    FAILED = "FAILED"  # 체인에 반영되지 않은 것이 확정됐다. 새 결정을 낼 수 있다
    RECORDED = "RECORDED"  # 체인에 들어갔고 Entry 가 CONFIRMED·REJECTED 로 바뀌었다


DECIDED_ELSEWHERE = "DecidedElsewhere"  # 체인에서 이 결정이 아닌 다른 결정(반대 결정·다른 승인자)으로 끝났다


class Decision(BaseModel):
    """확정·반려 제출 한 번. 실패한 뒤 다시 내는 결정은 새 Decision 이다."""

    model_config = ConfigDict(frozen=True)

    id: int = Field(..., ge=0, description="저장소가 매긴다. 넣기 전에는 0")
    entry_id: int = Field(..., ge=1)
    kind: DecisionKind
    decided_by: int = Field(..., description="결정한 감사·회장 User id")
    approver: str = Field(..., description="서명해야 하는 승인자의 wallet_address")
    hash: str = Field(ZERO_BYTES32, description="확정만. 등록 때와 같은 meta_hash")
    had_warning: bool = False
    warning_reason_hash: str = ZERO_BYTES32
    reason_hash: str = Field(ZERO_BYTES32, description="반려만. 반려 사유 text_hash")
    deadline: int
    signature: str

    status: DecisionStatus = DecisionStatus.SUBMITTING
    fail_reason: Optional[str] = Field(None, description="RevertReason 값, NotSent, NotRecordedByDeadline, DecidedElsewhere")
    tx_hash: Optional[str] = Field(None, description="RECORDED 일 때. Entry.tx_confirm 에 들어간다")

    @property
    def target_status(self) -> EntryStatus:
        return EntryStatus.CONFIRMED if self.kind == DecisionKind.CONFIRM else EntryStatus.REJECTED

    def struct(self) -> Union[ConfirmApproval, RejectDecision]:
        if self.kind == DecisionKind.CONFIRM:
            return ConfirmApproval(
                id=self.entry_id,
                hash=self.hash,
                had_warning=self.had_warning,
                warning_reason_hash=self.warning_reason_hash,
                deadline=self.deadline,
            )
        return RejectDecision(id=self.entry_id, reason_hash=self.reason_hash, deadline=self.deadline)


class RelayErrorCode(str, Enum):
    DRAFT_NOT_FOUND = "DRAFT_NOT_FOUND"
    NOT_OWNER = "NOT_OWNER"  # 다른 총무의 초안
    INVALID_DRAFT = "INVALID_DRAFT"  # 체인에 올리면 revert 되거나 막힐 입력
    DRAFT_DISCARDED = "DRAFT_DISCARDED"
    CANNOT_DISCARD = "CANNOT_DISCARD"  # SUBMITTING·RECORDED 는 버릴 수 없다
    HASH_MISMATCH = "HASH_MISMATCH"  # 앱이 계산한 meta_hash 가 서버 값과 다르다. 정규화 차이일 가능성이 크다
    INVALID_DEADLINE = "INVALID_DEADLINE"
    INVALID_SIGNATURE = "INVALID_SIGNATURE"  # 서명 형식이 틀렸거나 주소를 복구할 수 없다
    SIGNER_MISMATCH = "SIGNER_MISMATCH"  # 서명자가 기대한 임원이 아니다. 다른 값에 서명했거나 다른 키로 서명했다
    ROLE_MISSING = "ROLE_MISSING"  # 서명자는 맞는데 체인의 RoleManager 에 그 역할이 없다 (롤 조회를 붙였을 때만)
    # 확정·반려
    INVALID_DECISION = "INVALID_DECISION"  # 주소·해시 형식
    ENTRY_NOT_FOUND = "ENTRY_NOT_FOUND"  # 체인에 없는 항목
    ENTRY_NOT_PENDING = "ENTRY_NOT_PENDING"  # 체인에서 이미 PENDING 이 아니다 (BLOCKED 포함)
    SELF_APPROVAL = "SELF_APPROVAL"  # 승인자가 등록자다
    INVALID_REASON = "INVALID_REASON"  # 경고 승인·반려에 사유가 없거나, 경고가 없는데 사유가 있다
    DECISION_IN_PROGRESS = "DECISION_IN_PROGRESS"  # 반대 결정이 제출 중이다
    ALREADY_DECIDED = "ALREADY_DECIDED"  # 반대 결정이 이미 체인에 들어갔다


class RelayError(Exception):
    """체인에 보내기 전에 막힌 요청. 온체인에는 아무 일도 없었다."""

    def __init__(self, code: RelayErrorCode, detail: str = ""):
        self.code = code
        self.detail = detail
        super().__init__(f"{code.value}: {detail}" if detail else code.value)
