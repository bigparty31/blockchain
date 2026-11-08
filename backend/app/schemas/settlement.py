from datetime import datetime
from typing import Dict, List, Optional

from pydantic import BaseModel, Field


class BudgetExecution(BaseModel):
    budget_id: int = Field(..., description="예산 ID (= 체인 budgetId)")
    category: str = Field(..., description="예산 항목명")
    initial_amount: int = Field(..., description="v1 편성액")
    planned_amount: int = Field(..., description="최신 버전 편성액 (개정 반영)")
    version: int = Field(..., description="최신 버전 번호 (1 = 개정 없음)")
    spent: int = Field(..., description="확정 지출 합계 (정정 포함)")
    remaining: int = Field(..., description="편성액 − 확정 지출 (DB 기준)")
    execution_rate: Optional[float] = Field(None, description="집행률 = 확정 지출 / 편성액 (편성액 0이면 null)")


class MetaMetrics(BaseModel):
    """PRD §4.7 메타지표. 이의 제기 건수는 v0.13에서 범위 밖이라 넣지 않는다."""

    ocr_warning_approved: int = Field(..., description="OCR 경고(MISMATCH·DUPLICATE·UNREADABLE) 상태로 확정된 건수")
    category_warning_approved: int = Field(..., description="용도 불일치 경고 상태로 확정된 건수")
    corrections: int = Field(..., description="확정된 정정 건수")
    corrections_by_reason: Dict[str, int] = Field(..., description="정정 사유별 건수 (5종 모두 포함, 없으면 0)")
    corrections_before_audit: int = Field(..., description="감사일 30일 전부터 감사일까지 등록된 확정 정정 건수")
    audit_at: datetime = Field(..., description="D-30 기준 감사일 (기본: 학기 종료일)")
    budget_revisions: int = Field(..., description="승인된 예산 증액 횟수")
    budget_revisions_after_block: int = Field(..., description="그중 차단(BLOCKED) 지출을 근거로 한 증액 횟수")
    revision_after_block_rate: Optional[float] = Field(None, description="초과 집행 이후 개정 비율 (개정 0회면 null)")


class SettlementResponse(BaseModel):
    term_id: int
    term_code: int = Field(..., description="온체인 학기 코드 (YYYYS)")
    term_name: str
    income: int = Field(..., description="확정 수입 합계 (정정 포함)")
    expense: int = Field(..., description="확정 지출 합계 (정정 포함)")
    ledger_balance: int = Field(..., description="장부잔액 = 확정 수입 − 확정 지출 (PRD §7.4)")
    bank_balance: Optional[int] = Field(None, description="가장 최근 계좌 스냅샷의 통장 잔액 (없으면 null)")
    bank_snapshot_at: Optional[datetime] = Field(None, description="그 스냅샷 시각")
    balance_gap: Optional[int] = Field(None, description="차액 = 장부잔액 − 통장 잔액 (PRD §7.4, 스냅샷 없으면 null)")
    budgets: List[BudgetExecution]
    metrics: MetaMetrics
