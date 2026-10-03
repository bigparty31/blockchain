from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.chain import ChainSetupError
from app.chain.provider import close_chain_client
from app.routers.auth import router as auth_router
from app.routers.entries import router as entries_router
from app.routers.balance import router as balance_router
from app.routers.budgets import router as budgets_router
from app.routers.users import router as users_router
from app.routers.chain import router as chain_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    await close_chain_client()  # 릴레이어의 RPC 연결을 닫는다


app = FastAPI(
    lifespan=lifespan,
    title="학생회비 투명성 관리 시스템 - Mock API",
    version="0.1.0",
    description="""
### 역할 B (백엔드 회계 도메인) - 모바일 앱(C, D) 연동용 목업 API

- **목적**: DB 및 블록체인 연동 전, PRD §8 데이터 모델 규격을 준수하는 응답 형태로 앱 화면 개발 지원
- **산출물 대상**:
  - `POST /auth/login`: 학번·비밀번호 로그인, 세션 JWT·role 발급
  - `GET /auth/me`: 로그인한 사용자 정보
  - `GET /users/wallets`: user id ↔ 지갑 주소 매핑, 현·전 임원 (체인의 등록자·승인자 대조용)
  - `GET /chain/domains`: 앱이 서명할 때 쓸 EIP-712 도메인 (컨트랙트별, 배포 기록에서 읽음)
  - `GET /entries`: 수입·지출 내역 목록 (더미 3건: 확정 지출, 승인 대기 지출, 확정 수입)
  - `GET /balance`: 장부 잔액, 총 수입, 총 지출 요약
  - `GET /budgets`: 카테고리별 예산 편성액, 잔여액, 집행률
  - `POST /entries`: 지출/수입 초안 등록 (총무 토큰 필요)
  - `POST /entries/{id}/submit`: 초안 기기 서명 제출 (초안을 등록한 총무 본인 토큰 필요)
- **인증**: `POST /auth/login` 으로 받은 토큰을 `Authorization: Bearer <token>` 헤더로 보낸다 (Swagger 우측 상단 Authorize)
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



@app.exception_handler(ChainSetupError)
async def chain_setup_error(request: Request, exc: ChainSetupError):
    # 노드·배포 기록·릴레이어 키가 릴레이할 수 없는 상태 (배포 기록 문제 DeploymentError 포함).
    # 요청이 아니라 서버 설정 문제라 503 이다. 메시지에는 키·절대 경로가 들어가지 않는다
    return JSONResponse(status_code=503, content={"detail": str(exc)})


# 라우터 등록
app.include_router(auth_router)
app.include_router(entries_router)
app.include_router(balance_router)
app.include_router(budgets_router)
app.include_router(users_router)
app.include_router(chain_router)


@app.get("/", tags=["Health"])
def health_check():
    return {
        "status": "ok",
        "service": "Student Council Fee Transparency System - Mock API",
        "docs_url": "/docs",
        "version": "0.1.0",
    }
