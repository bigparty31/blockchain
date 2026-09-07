# 블록체인 기반 학생회 회계 투명성 관리 시스템

예산을 벗어난 집행은 등록되지 않고, 등록된 기록은 수정할 수 없으며, 학생이 그것을 직접 검증한다.

## 폴더 구조

```
.
├── contracts/   # Solidity 컨트랙트
├── backend/     # FastAPI 서버
├── app/         # Flutter 앱
└── docs/        # 설계 문서
```

| 폴더 | 역할 |
|---|---|
| `contracts/` | 예산·집행 기록을 온체인에 올리는 Solidity 컨트랙트 |
| `backend/` | FastAPI 서버. DB, OCR, 오픈뱅킹, 릴레이어 연동 |
| `app/` | 학생·학생회가 사용하는 Flutter 앱 (로그인 후 role 분기) |
| `docs/` | enum, API, 컨트랙트 설계 문서 |

기능 구현은 각 파트 담당자가 담당 폴더에서 진행한다.

> **상태값·사유 유형은 `docs/enums.md`를 따른다.** 임의로 추가하거나 표기를 바꾸지 말 것. 여기가 어긋나면 백엔드와 앱이 조용히 안 맞는다.

## 폴더별 초기화

아래 명령은 골격만 잡힌 저장소에서 각 담당자가 직접 실행한다.

**contracts/**
```bash
cd contracts
npx hardhat init
```

**backend/**
```bash
cd backend
python -m venv .venv
pip install fastapi uvicorn
```

**app/**
```bash
cd app
flutter create .
```

## 브랜치 규칙

| 브랜치 | 용도 |
|---|---|
| `main` | 보호 브랜치. 직접 push 금지 |
| `develop` | 통합 개발 브랜치 |
| `feat/xxx` | 파트 단위 작업 브랜치 |

흐름: `feat/xxx` → `develop` → `main`

## 파트별 브랜치

| 파트 | 담당 | 폴더 | 브랜치 |
|---|---|---|---|
| 스마트 컨트랙트 | 장석연 | `contracts/` | `feat/contract` |
| 백엔드 — 인증·권한·서명 릴레이 | 손종인 | `backend/` | `feat/backend-auth` |
| 백엔드 — 회계·예산 API | 김경윤 | `backend/` | `feat/backend-core` |
| 앱 — 학생 화면 | 장정아 | `app/` | `feat/app-student` |
| 앱 — 총무·감사 화면 | 이승호 | `app/` | `feat/app-council` |
| 연동·결산 (OCR·오픈뱅킹) | 문승준 | `backend/`, `app/` | `feat/integration` |

## PR 규칙

- PR은 `develop`으로 보낸다
- 승인 최소 1명, 자기 PR은 자기가 승인하지 않는다
- 1차 리뷰는 아래 표의 인접 파트 담당자
- 24시간 내 반응이 없으면 다른 팀원이 대신 리뷰해도 된다
- PR 본문에 **왜 그렇게 했는지**를 쓴다

| PR | 작성 | 리뷰 |
|---|---|---|
| 컨트랙트 | 장석연 | 손종인 |
| 인증·서명 | 손종인 | 장석연 |
| 회계·예산 API | 김경윤 | 문승준 |
| 학생 앱 | 장정아 | 이승호 |
| 총무·감사 앱 | 이승호 | 장정아 |
| 연동·결산 | 문승준 | 김경윤 |

**팀장 승인이 필요한 경우** — 다른 파트에 영향이 가는 변경만

- `/contracts/` 변경
- `/docs/enums.md` 변경
- `develop` → `main` 머지

그 외에는 리뷰 1명으로 머지한다.

## 커밋 컨벤션

`feat:` 기능 추가 / `fix:` 버그 수정 / `chore:` 설정·잡무 / `docs:` 문서
