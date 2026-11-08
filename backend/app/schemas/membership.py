from typing import Optional

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
