from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.routers.entries import router as entries_router
from app.routers.balance import router as balance_router
from app.routers.budgets import router as budgets_router

app = FastAPI(
    title="학생회비 투명성 관리 시스템 - Mock API",
    version="0.1.0",
    description="""
### 역할 B (백엔드 회계 도메인) - 모바일 앱(C, D) 연동용 목업 API

- **목적**: DB 및 블록체인 연동 전, PRD §8 데이터 모델 규격을 준수하는 응답 형태로 앱 화면 개발 지원
- **산출물 대상**:
  - `GET /entries`: 수입·지출 내역 목록 (더미 3건: 확정 지출, 승인 대기 지출, 확정 수입)
  - `GET /balance`: 장부 잔액, 총 수입, 총 지출 요약
  - `GET /budgets`: 카테고리별 예산 편성액, 잔여액, 집행률
  - `POST /entries`: 지출/수입 등록 요청 시 PENDING 상태 생성 응답
    """,
)

# Flutter 모바일 앱(웹, Android 에뮬레이터, 실기기)과의 원활한 통신을 위한 CORS 설정
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 라우터 등록
app.include_router(entries_router)
app.include_router(balance_router)
app.include_router(budgets_router)


@app.get("/", tags=["Health"])
def health_check():
    return {
        "status": "ok",
        "service": "Student Council Fee Transparency System - Mock API",
        "docs_url": "/docs",
        "version": "0.1.0",
    }
