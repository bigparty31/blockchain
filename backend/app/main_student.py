"""PRD v0.15 §9.1 & §10: 학생용 조회 전용 FastAPI 엔트리포인트 (student_api).

특징:
1. 읽기 전용 DB 연결 (`db_student` 또는 읽기 전용 세션).
2. 릴레이어 개인키(`RELAYER_PRIVATE_KEY`) 및 FCM 발송 키를 탑재하지 않음.
3. 기기 서명 제출, 온체인 릴레이, 수정 요청, 영수증 업로드 등 모든 명령(Command) 엔드포인트 배제.
4. GET 요청 시 DB에 변경을 가하는 Lazy Update 배제.
"""
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.chain import ChainSetupError
from app.chain.provider import check_chain_config, close_chain_client
from app.routers.bundles import STUDENT_QUERY_ROUTERS


@asynccontextmanager
async def lifespan(app: FastAPI):
    # 체인 설정 확인 (학생 서버는 릴레이어 키 없이 RPC 조회만 사용)
    check_chain_config()
    # 재알림 작업·푸시 전송(app.services.notification_worker)은 띄우지 않는다. DB 에 쓰고 FCM 키가 필요하다 — 학생회 서버만 한다
    yield
    await close_chain_client()


app = FastAPI(
    lifespan=lifespan,
    title="학생회비 투명성 관리 시스템 - 학생용 조회 API (student_api)",
    version="0.1.0",
    description="""
### 학생용 조회 전용 API (PRD v0.15 §9.1 & §10)

- **원칙**: "코드는 하나, 실행 단위는 둘"
- **권한 및 보안**:
  - 읽기 전용 DB 계정 연결
  - 릴레이어 개인키 미보유 (트랜잭션 릴레이 불가)
  - 푸시 발송 미수행
- **제공 엔드포인트**:
  - `POST /auth/login`: 학번·비밀번호 로그인, 세션 JWT 발급
  - `GET /auth/me`: 로그인한 사용자 정보
  - `GET /entries`: 체인에 기록된 수입·지출 내역 목록
  - `GET /entries/{id}`: 특정 내역 상세 정보
  - `GET /entries/{id}/onchain`: 온체인 원장 항목 원본 조회
  - `GET /balance`: 장부 잔액 및 총 수입·지출 요약
  - `GET /budgets`: 카테고리별 예산 편성액, 잔여액, 집행률
  - `GET /terms`: 학기 목록 조회
  - `GET /memberships/me`: 본인 학기 회원권(SBT) 및 입장 QR
  - `GET /chain/domains`: EIP-712 서명 도메인 정보
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


# 학생용 조회 전용 라우터만 등록
for router in STUDENT_QUERY_ROUTERS:
    app.include_router(router)


@app.get("/", tags=["Health"])
def health_check():
    return {
        "status": "ok",
        "service": "Student Council Fee Transparency System - Student API (Read-Only)",
        "docs_url": "/docs",
        "version": "0.1.0",
    }
