# 학생회비 투명성 관리 시스템 — Backend (Mock API)

> **담당**: 역할 B (김경윤 — 백엔드 회계 도메인)  
> **브랜치**: `feat/backend-core`  
> **목적**: 1주차 최우선 과제로서 모바일 앱(C, D) 개발자가 화면을 연결할 수 있도록 PRD 규격에 맞춘 4개 목업 API 제공

---

## 1. 가상환경 설정 및 실행 방법

### 1.1 가상환경 생성 및 패키지 설치
```powershell
# backend 디렉터리로 이동
cd backend

# 가상환경 생성 (최초 1회)
python -m venv .venv

# 가상환경 활성화 (Windows PowerShell)
.\.venv\Scripts\Activate.ps1

# (참고) macOS / Linux 활성화
# source .venv/bin/activate

# 패키지 설치
pip install -r requirements.txt
```

### 1.2 서버 실행
```powershell
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```
- `--host 0.0.0.0`: 같은 로컬 네트워크 내 모바일 실기기 및 에뮬레이터에서 접근 가능
- `--reload`: 코드 수정 시 서버 자동 재시작

---

## 2. API 문서 및 엔드포인트

서버 실행 후 브라우저에서 아래 주소로 접속하면 대화형 API 문서를 확인하고 직접 호출해 볼 수 있습니다:
- **Swagger UI**: `http://localhost:8000/docs`
- **ReDoc**: `http://localhost:8000/redoc`

| Method | Endpoint | 설명 | 반환 데이터 |
| :--- | :--- | :--- | :--- |
| `GET` | `/` | 헬스체크 및 서비스 상태 | `{ "status": "ok", ... }` |
| `POST` | `/auth/login` | 학번·비밀번호 로그인 | `{ "access_token": "...", "role": "TREASURER", ... }` |
| `GET` | `/auth/me` | 내 정보 (토큰 필요) | `{ "id": 2, "role": "TREASURER", ... }` |
| `GET` | `/entries` | 수입·지출 내역 목록 | 더미 3건 (확정 지출, 대기 지출, 확정 수입) |
| `POST` | `/entries` | 지출/수입 초안 등록 (**총무 토큰 필요**) | `{ "id": 4, "message": "..." }` |
| `POST` | `/entries/{id}/submit` | 초안 서명 제출 (**등록한 총무 본인 토큰 필요**) | `{ "id": 4, "status": "PENDING", ... }` |
| `GET` | `/balance` | 장부 잔액 요약 | `{ "balance": 4965000, "income": 5000000, "expense": 35000 }` |
| `GET` | `/budgets` | 카테고리별 예산 현황 | 행사비, 사업비, 운영비 편성액 및 잔량 |
| `GET` | `/chain/domains` | 앱이 서명할 EIP-712 도메인 (컨트랙트별) | `{ "chainId": 31337, "domains": { ... } }` |
| `GET` | `/users/wallets` | 지갑 주소 → user id 매핑 (현·전 임원, 검증용) | `{ "0x3c44…93bc": 2, ... }` |

### 2.1 인증
- `POST /auth/login` 으로 받은 `access_token` 을 `Authorization: Bearer <token>` 헤더로 보냅니다. Swagger UI 에서는 우측 상단 **Authorize** 에 토큰을 넣으면 됩니다.
- 테스트 계정: `20240001`(학생) · `20240002`(총무) · `20240003`(감사) · `20240004`(회장) · `20240005`(감사 2), 비밀번호는 모두 `userPassword123!` (자세한 내용은 `docs/API.md` 「인증」)
- 설정은 환경변수로 줍니다. 저장소 루트의 `.env.example` 을 `.env` 로 복사해 채우면 서버가 시작할 때 읽습니다 (`app/env.py`). 이미 설정된 실제 환경변수가 우선합니다.
- 배포 기록 위치는 환경변수 `DEPLOYMENTS_FILE` 로 바꿀 수 있습니다. 없으면 저장소의 `contracts/deployments/localhost.json` 을 읽습니다 (`GET /chain/domains`, 릴레이어가 사용).
- 토큰 서명 키는 환경변수 `JWT_SECRET` 으로 설정합니다. **없으면 서버가 시작하지 않습니다.** 로컬 개발에서는 `JWT_DEV_SECRET=1` 로 저장소에 공개된 개발용 키를 쓸 수 있습니다 (시작 로그에 경고). 배포 환경에서는 `JWT_DEV_SECRET` 을 넣지 마세요.
- 체인도 둘 중 하나를 명시해야 서버가 시작합니다. 노드 없이 개발할 때는 `CHAIN_FAKE=1`(가짜 체인 — 서명을 검사하지 않고 아무것도 기록하지 않음), 로컬 노드를 쓸 때는 `CHAIN_RPC_URL`·`RELAYER_PRIVATE_KEY` 입니다 (`docs/CHAIN_CLIENT.md` §8).
- 노드 없이 로컬에서 띄우는 가장 간단한 `.env`: `JWT_DEV_SECRET=1`, `CHAIN_FAKE=1`

---

## 3. Flutter 모바일 앱 연동 가이드

- **Android 에뮬레이터**: `http://10.0.2.2:8000`
- **iOS 시뮬레이터**: `http://localhost:8000`
- **실기기(Wi-Fi)**: `http://<PC_로컬_IP>:8000`
