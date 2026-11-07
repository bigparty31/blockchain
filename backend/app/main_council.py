"""PRD v0.15 §9.1 & §10: 학생회용 풀 기능 FastAPI 엔트리포인트 (council_api).

특징:
1. 읽기/쓰기 DB 연결 (`db_council`).
2. 릴레이어 개인키(`RELAYER_PRIVATE_KEY`) 및 FCM 발송 서버 키 탑재.
3. 기기 서명 검증 후 온체인 릴레이, 수정 요청, 영수증 파일 저장 등 모든 쓰기/관리 기능 포함.
4. 모든 조회(Query) 및 명령(Command) 라우터 마운트.
"""
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.chain import ChainSetupError
from app.chain.provider import check_chain_config, close_chain_client
from app.routers.bundles import COUNCIL_ALL_ROUTERS


@asynccontextmanager
async def lifespan(app: FastAPI):
    check_chain_config()
    yield
    await close_chain_client()


app = FastAPI(
    lifespan=lifespan,
    title="학생회비 투명성 관리 시스템 - 학생회용 API (council_api)",
    version="0.1.0",
    description="""
### 역할 B (백엔드 회계 도메인) - 학생회용 풀 기능 API (PRD v0.15 §9.1 & §10)

- **원칙**: "코드는 하나, 실행 단위는 둘"
- **권한 및 보안**:
  - 읽기/쓰기 DB 계정 연결
  - 릴레이어 개인키 보유 (온체인 트랜잭션 릴레이)
  - FCM 푸시 발송 키 보유
- **제공 엔드포인트**:
  - 학생용 모든 조회 API 포함
  - `POST /entries`: 수입·지출 초안 등록 (총무)
  - `POST /entries/{id}/submit`: 기기 서명 제출 및 온체인 등록 (총무)
  - `POST /entries/{id}/confirm`: 승인 및 온체인 확정 (감사/회장)
  - `POST /entries/{id}/reject`: 반려 및 온체인 기록 (감사/회장)
  - `POST /entries/{id}/request-revision`: 수정 요청 (T4)
  - `GET /entries/drafts`: 미제출 초안 목록 (총무 본인)
  - `POST /budgets`: 예산 발행 초안 및 서명 제출 (회장)
  - `POST /budget-revisions`: 증액 신청 (총무)
  - `POST /budget-revisions/{id}/sign`: 증액 회장 서명 (회장)
  - `POST /budget-revisions/{id}/approve`: 증액 감사 승인 (감사)
  - `POST /receipts`: 영수증 파일 업로드
  - `GET /users/wallets`: 임원 지갑 매핑 조회
    """,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(ChainSetupError)
async def chain_setup_error(request: Request, exc: ChainSetupError):
    return JSONResponse(status_code=503, content={"detail": str(exc)})


# 학생회용 전체 라우터 (조회 + 쓰기) 등록
for router in COUNCIL_ALL_ROUTERS:
    app.include_router(router)


@app.get("/", tags=["Health"])
def health_check():
    return {
        "status": "ok",
        "service": "Student Council Fee Transparency System - Council API (Read/Write)",
        "docs_url": "/docs",
        "version": "0.1.0",
    }
