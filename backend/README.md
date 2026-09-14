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
| `GET` | `/entries` | 수입·지출 내역 목록 | 더미 3건 (확정 지출, 대기 지출, 확정 수입) |
| `POST` | `/entries` | 지출/수입 신규 등록 | `{ "id": 4, "status": "PENDING", ... }` |
| `GET` | `/balance` | 장부 잔액 요약 | `{ "balance": 4965000, "income": 5000000, "expense": 35000 }` |
| `GET` | `/budgets` | 카테고리별 예산 현황 | 행사비, 사업비, 운영비 편성액 및 잔량 |

---

## 3. Flutter 모바일 앱 연동 가이드

- **Android 에뮬레이터**: `http://10.0.2.2:8000`
- **iOS 시뮬레이터**: `http://localhost:8000`
- **실기기(Wi-Fi)**: `http://<PC_로컬_IP>:8000`
