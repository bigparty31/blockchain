"""PRD v0.15 §9.1 & §10: 2서버 아키텍처 (student_api vs council_api) 라우터 번들 정의.

"코드는 하나, 실행 단위는 둘" 원칙:
- student_api (학생용):
    - 조회 전용 엔드포인트만 마운트.
    - DB 읽기 전용 계정 사용 (Lazy commit이나 상태 변경 절대 금지).
    - 릴레이어 개인키 없음, FCM 발송 안 함.
- council_api (학생회용, 또는 기본 main.py):
    - 조회 + 기기 서명 제출, 온체인 릴레이, 수정 요청, 영수증 업로드 등 모든 명령(Command) 엔드포인트 마운트.
    - DB 읽기/쓰기 계정 사용.
"""
from typing import List
from fastapi import APIRouter

from app.routers.auth import query_router as auth_query_router
from app.routers.entries import (
    command_router as entries_command_router,
    query_router as entries_query_router,
)
from app.routers.balance import query_router as balance_query_router
from app.routers.budgets import (
    command_router as budgets_command_router,
    query_router as budgets_query_router,
)
from app.routers.terms import query_router as terms_query_router
from app.routers.memberships import query_router as memberships_query_router
# 회원권 일괄 발행은 회장·감사 전용이고 릴레이어 키로 체인에 쓴다. 학생 서버에는 붙이지 않는다 (PRD §9.1)
from app.routers.membership_mint import router as membership_mint_command_router
from app.routers.chain import query_router as chain_query_router
from app.routers.budget_revisions import command_router as budget_revisions_command_router
from app.routers.receipts import (
    command_router as receipts_command_router,
    query_router as receipts_query_router,
)
from app.routers.users import query_router as users_query_router
from app.routers.ocr import command_router as ocr_command_router
from app.routers.settlement import router as settlement_command_router
from app.routers.events import router as events_command_router
from app.routers.bank import router as bank_command_router
# 알림은 임원 전용이고 기기 토큰 등록·읽음 처리로 DB 에 쓴다. 학생 서버에는 붙이지 않는다 (PRD §9.1)
from app.routers.notifications import router as notifications_command_router


# 학생용 조회 전용 라우터 목록 (student_api)
# 주의: 이 목록의 라우터는 DB 쓰기(INSERT/UPDATE/DELETE/Lazy Commit)를 전혀 수행하지 않아야 합니다.
STUDENT_QUERY_ROUTERS: List[APIRouter] = [
    auth_query_router,
    entries_query_router,
    balance_query_router,
    budgets_query_router,
    terms_query_router,
    memberships_query_router,
    chain_query_router,
    receipts_query_router,
    users_query_router,
]

# 학생회용 쓰기/명령 전용 라우터 목록
COUNCIL_COMMAND_ROUTERS: List[APIRouter] = [
    entries_command_router,
    budgets_command_router,
    budget_revisions_command_router,
    membership_mint_command_router,
    receipts_command_router,
    ocr_command_router,
    settlement_command_router,
    events_command_router,
    bank_command_router,
    notifications_command_router,
]

# 학생회용 전체 라우터 (조회 + 쓰기)
# 주의: /entries/drafts 가 /entries/{id} 보다 먼저 라우팅 매칭되도록 command 라우터를 앞에 배치한다.
COUNCIL_ALL_ROUTERS: List[APIRouter] = [
    auth_query_router,
    entries_command_router,
    entries_query_router,
    balance_query_router,
    budgets_command_router,
    budgets_query_router,
    terms_query_router,
    memberships_query_router,
    membership_mint_command_router,
    chain_query_router,
    budget_revisions_command_router,
    receipts_command_router,
    receipts_query_router,
    users_query_router,
    ocr_command_router,
    settlement_command_router,
    events_command_router,
    bank_command_router,
    notifications_command_router,
]
