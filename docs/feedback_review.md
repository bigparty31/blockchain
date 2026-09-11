# PR 피드백 반영 보고서

- **작업 브랜치**: `feat/backend-core`
- **담당자**: 김경윤
- **작업 일자**: 2026-09-11
- **관련 PR**: 1주차 모바일 앱 연동용 Mock API 구현

---

## 1. 수신된 피드백 내용

> "경윤님 balance랑 expense에 PENDING 건이 포함돼 있어요 PENDING은 대기상태라 지출에 포함되면 안돼요 expense 35,000 / balance 4,965,000이 맞고, 행사비 예산도 120,000 차감 전 상태여야 해요  
> message 필드는 그대로 두셔도 됩니다 앱은 id/status만 읽으면 돼요 venv 이름은 .venv로 통일하고 .gitignore에 들어있는지 확인 부탁드려요 수정해서 같은 브랜치에 커밋하시면 pr 업데이트되니깐 수정한번 부탁드려요"

---

## 2. 세부 검토 및 수정 사항

### 2.1 Balance 및 Expense 산출식 수정 (PENDING 건 제외)
- **원인**: 초기 더미 데이터 중 PENDING 상태인 지출 1건(청년피자 개강총회 다과 주문: 120,000원)이 총 지출(expense) 및 장부 잔액(balance)에 선반영되어 있었음.
- **규격 검토**: PRD §7.4 산출식에 따르면 장부 잔액은 `확정 수입 - 확정 지출`이며, PENDING(대기) 상태 건은 지출 합계에 포함되지 않아야 함.
  - 확정 수입: 5,000,000원 (컴퓨터공학과 학생회비 수납, CONFIRMED)
  - 확정 지출: 35,000원 (한결문구 신입생 환영회 물품 구매, CONFIRMED)
  - 대기 지출: 120,000원 (청년피자, PENDING) -> **지출 합계에서 제외**
  - 계산된 잔액: 5,000,000 - 35,000 = **4,965,000원**
- **수정 파일**:
  - `backend/app/routers/balance.py`: `balance=4965000`, `expense=35000`으로 수정
  - `backend/README.md`: API 표 내 응답 예시 동기화

### 2.2 행사비 예산 잔여액 및 집행률 롤백 (120,000원 차감 전 상태)
- **원인**: 행사비 예산(ID: 1)에서 PENDING 상태인 120,000원이 사전 차감되어 `remaining_amount=2380000`, `execution_rate=0.048`로 기재되어 있었음.
- **수정 내용**: PENDING 상태이므로 예산 집행 차감 전 상태로 복구.
  - 총 편성액(`planned_amount`): 2,500,000원
  - 잔여 예산(`remaining_amount`): 2,380,000원 -> **2,500,000원**
  - 집행률(`execution_rate`): 0.048 -> **0.0**
- **수정 파일**:
  - `backend/app/routers/budgets.py`

### 2.3 POST /entries 응답 스키마 (`message` 필드) 확인
- **피드백 내용**: 앱은 `id`와 `status`만 읽으므로 `message` 필드는 그대로 유지해도 됨.
- **확인 결과**: `EntryCreateResponse` 스키마 및 라우터에 `id`, `status`, `message` 필드가 기존대로 유지되어 있어 별도 변경 없이 규격 충족.
  - 관련 파일: `backend/app/schemas/entry.py`, `backend/app/routers/entries.py`

### 2.4 가상환경 명칭 `.venv` 통일 및 `.gitignore` 확인
- **`.gitignore` 확인**: 루트 `.gitignore` 30~33행에 `.venv/`, `venv/`가 모두 포함되어 있어 Git 추적 대상에서 정상 제외됨 확인.
- **가상환경 가이드 통일**:
  - 루트 `README.md`는 이미 `python -m venv .venv`로 안내되어 있음.
  - `backend/README.md`의 가상환경 생성 명령어(`python -m venv venv` -> `python -m venv .venv`) 및 활성화 스크립트 경로(`.\venv\Scripts\Activate.ps1` -> `.\.venv\Scripts\Activate.ps1`)를 `.venv`로 통일 수정.

---

## 3. 변경 파일 목록 및 Git 상태

| 구분 | 파일 경로 | 변경 내용 요약 |
| :--- | :--- | :--- |
| **수정** | `backend/app/routers/balance.py` | `balance` 4,965,000 / `expense` 35,000 수정 (PENDING 제외) |
| **수정** | `backend/app/routers/budgets.py` | 행사비 예산 `remaining_amount` 2,500,000 / `execution_rate` 0.0 복구 |
| **수정** | `backend/README.md` | 가상환경 명칭 `.venv` 통일 및 balance 예시값 갱신 |
| **신규** | `docs/feedback_review.md` | 피드백 검토 및 수정 내역 기록 (본 문서) |

> **안내**: 사용자 요청에 따라 커밋은 진행하지 않았으며, 작업 디렉터리에 수정 사항이 반영된 상태입니다. 검토 후 아래 명령어로 커밋 및 푸시하시면 PR이 자동으로 업데이트됩니다:
> ```bash
> git add backend/app/routers/balance.py backend/app/routers/budgets.py backend/README.md docs/feedback_review.md
> git commit -m "fix(backend): exclude pending entries from balance and restore event budget"
> git push origin feat/backend-core
> ```
