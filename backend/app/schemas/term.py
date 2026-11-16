from datetime import datetime
from typing import Optional
from pydantic import BaseModel, ConfigDict, Field


class TermResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int = Field(..., description="학기 고유 ID (1부터 시작)")
    term_code: int = Field(..., description="온체인 학기 코드 (YYYYS 형식, 예: 20262)")
    name: str = Field(..., description="학기 명칭 (예: 2026학년도 2학기 또는 2026-2학기)")
    started_at: datetime = Field(..., description="학기 시작 일시")
    ended_at: datetime = Field(..., description="학기 종료 일시")

