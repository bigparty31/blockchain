from typing import List, Optional

from pydantic import BaseModel, Field


class MembershipResponse(BaseModel):
    """GET /memberships/me. 보유 중일 때만 이 모양이고, 미보유는 본문 null 이다 (docs/backend_requests.md §1-4)."""

    id: Optional[int] = Field(None, description="DB 회원권 ID. 체인에는 있는데 DB 기록이 없으면 null")
    user_id: int = Field(..., description="학생 ID")
    term_id: int = Field(..., description="학기 ID (terms.id)")
    token_id: int = Field(..., description="온체인 SBT tokenId")
    minted_at: Optional[int] = Field(None, description="발급 시각 (Unix 초). DB 기록이 없으면 null")
    burned_at: Optional[int] = Field(None, description="소각 시각. 보유 중인 회원권만 내려가므로 항상 null")
    qr_payload: str = Field(..., description='입장 QR 문자열. 예: "SCA:2026-2:U000001". 자격 정보는 담지 않는다')


# ---------------------------------------------------------------- 회원권 일괄 발행 (docs/API.md 「회원권 2」)

INT64_MAX = 2**63 - 1  # deadline 저장 폭 (membership_mint_batches.deadline BIGINT)


class MintBatchPrepareRequest(BaseModel):
    """POST /memberships/mint-batches. 납부자 명단의 학번 1~100개."""

    term_id: int = Field(..., ge=1, description="발행 학기 ID (terms.id)")
    student_nos: List[str] = Field(..., min_length=1, max_length=100, description="학번 목록. 앞뒤 공백은 지운다")


class MintBatchSubmitRequest(BaseModel):
    """POST /memberships/mint-batches/{id}/submit. 준비 응답의 값으로 만든 MintBatchRequest 에 대한 서명."""

    deadline: int = Field(..., ge=0, le=INT64_MAX, description="서명 유효 시한 (Unix 초)")
    signature: str = Field(..., description="EIP-712 서명 (0x + hex 130자)")


class MintTargetResponse(BaseModel):
    student_no: str
    user_id: int
    name: str
    address: str = Field(..., description="서명할 학생 지갑 주소 (EIP-55)")
    status: str = Field(..., description="PENDING | MINTED | SKIPPED")
    token_id: Optional[int] = Field(None, description="MINTED 면 새 tokenId, SKIPPED 면 이미 있던 tokenId(읽지 못하면 null)")
    membership_id: Optional[int] = Field(None, description="DB 회원권 기록 ID. 기록을 만들지 못했으면 null")


class MintExcludedResponse(BaseModel):
    student_no: str
    user_id: Optional[int] = None
    name: Optional[str] = None
    status: str = Field(..., description="ALREADY_MEMBER | NOT_FOUND | NOT_STUDENT | DUPLICATE | DB_MISMATCH")


class MintBatchResponse(BaseModel):
    id: int
    term_id: int
    term_code: int = Field(..., description="체인 학기 코드 YYYYS. 서명할 MintBatchRequest.term")
    status: str = Field(..., description="PREPARED | SUBMITTING | MINTED | REJECTED | NO_RESPONSE")
    signer_address: str = Field(..., description="이 지갑으로 서명해야 한다")
    nonce: int = Field(..., description="서명할 MintBatchRequest.nonce")
    recipients: List[str] = Field(..., description="서명할 MintBatchRequest.recipients. 이 순서 그대로 쓴다")
    deadline: Optional[int] = None
    tx_hash: Optional[str] = None
    reason: Optional[str] = Field(None, description="REJECTED 사유 (Solidity 에러 이름 또는 Unknown)")
    targets: List[MintTargetResponse]
    excluded: List[MintExcludedResponse] = Field(default_factory=list, description="준비 응답에만 있다")
    created_at: int
    message: str
