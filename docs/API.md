# API

> **문서 버전**: v0.2 (2주차 정본 규격 동기화)  
> **작성자**: 김경윤 (`feat/backend-core`)  
> **기본 Base URL**: `http://localhost:8000` (FastAPI Swagger UI: `/docs`)  
> **금액 규격**: 원 단위 정수 (`integer`, 스마트 컨트랙트 `int256` 대응)  
> **시간 규격**: 
> - `occurred_at`: 거래 사용일의 **KST 00:00:00 기준 Unix 초(정수, integer)** (`HASHING.md §1.3`, 시·분·초 제외 날짜 단위 잠금)
> - `ocr_paid_at`: 영수증 OCR로 판독한 **실제 결제 일시** (Unix 초 정수, 영수증의 시·분·초 보존)
> **해시 규격**: `0x` 접두사가 포함된 **66자리(0x + 64자리 소문자 hex, 256-bit)** 전체 문자열 (말줄임표 생략 금지)

---

## 인증

### 1. 로그인 (`POST /auth/login`)
- **설명**: 학번과 비밀번호로 로그인하고 세션 JWT 토큰과 역할(`role`)을 발급받습니다.

**Request**
```json
{
  "student_no": "20240002",
  "password": "userPassword123!"
}
```

**Response (`200 OK`)**
```json
{
  "access_token": "eyJhbGciOiJIUzI1Ni...",
  "token_type": "bearer",
  "role": "TREASURER",
  "name": "김총무",
  "wallet_address": "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
}
```
- `wallet_address`: 임원만 값이 있고 학생은 `null`
- 토큰 유효시간: 12시간

**로그인 실패 (`401 Unauthorized`)** — 학번이 없는지 비밀번호가 틀렸는지 구분하지 않습니다.
```json
{ "detail": "학번 또는 비밀번호가 올바르지 않습니다." }
```

### 2. 내 정보 조회 (`GET /auth/me`)
- **설명**: 현재 로그인한 사용자의 기본 프로필과 권한을 확인합니다.
- **권한**: 로그인한 사용자 누구나 (`Authorization` 헤더 필요)

**Response (`200 OK`)**
```json
{
  "id": 2,
  "student_no": "20240002",
  "name": "김총무",
  "role": "TREASURER"
}
```

### 3. 인증 헤더와 권한 오류 (공통)
- 로그인이 필요한 API는 `Authorization: Bearer <access_token>` 헤더를 붙여 호출합니다.
- 조회 API(`GET /entries`, `GET /balance`, `GET /budgets`)는 현재 토큰 없이 호출할 수 있습니다.

| 상황 | 응답 | `detail` |
| :--- | :--- | :--- |
| 헤더 없음 | `401` | `로그인이 필요합니다.` |
| 토큰 만료 | `401` | `세션이 만료되었습니다. 다시 로그인해 주세요.` |
| 위조·손상된 토큰, 없는 사용자 | `401` | `유효하지 않은 토큰입니다.` |
| 허용되지 않은 역할 | `403` | `이 작업을 할 권한이 없습니다.` |

`401` 응답에는 `WWW-Authenticate: Bearer` 헤더가 붙습니다. 앱은 `401`이면 로그인 화면으로, `403`이면 권한 없음 안내로 처리합니다.

### 4. 테스트 계정 (DB 도입 전 시드)
비밀번호는 모두 `userPassword123!` 입니다. id는 더미 데이터(`created_by=2`, `approved_by=3`)에 맞췄습니다.
임원 지갑은 로컬 배포의 임원 계정(`contracts/deployments/localhost.json`의 `accounts`, Hardhat 계정 1·2·3·5)과 같습니다. 체인의 등록자·승인자 주소를 사용자와 대조하는 기준이라, 재배포로 계정이 바뀌면 함께 바꿔야 합니다 (`backend/tests/test_seed_wallets.py`가 확인). 감사는 컨트랙트 규칙상 최소 2명입니다.

| id | 학번 | 이름 | role | wallet_address |
| :--- | :--- | :--- | :--- | :--- |
| 1 | 20240001 | 김학생 | `STUDENT` | `null` |
| 2 | 20240002 | 김총무 | `TREASURER` | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` |
| 3 | 20240003 | 이감사 | `AUDITOR` | `0x90F79bf6EB2c4f870365E785982E1f101E93b906` |
| 4 | 20240004 | 박회장 | `PRESIDENT` | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` |
| 5 | 20240005 | 최감사 | `AUDITOR` | `0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc` |

---

## 예산

### 1. 예산 현황 목록 (`GET /budgets`)
- **설명**: 카테고리별 예산 편성액, 실시간 잔여액, 집행률을 조회합니다. (앱 예산 카드 및 프로그레스 바 바인딩용, 쿼리 파라미터: `term_id`)
- **노출 및 잔량 반영 기준**:
  - 온체인(`BudgetToken.getBudget`)에 발행 확인된 예산만 반환하며, 미발행 초안(`DRAFT`), 온체인 미발행 시드 더미 행, 체인 응답 미확인(`NO_RESPONSE`) 대기 건은 목록에서 제외됩니다.
  - 잔량은 온체인 `ChainBudget.remaining` 기준(`CONFIRMED` 확정 건만 반영, `PENDING` 대기 건은 미차감)으로 계산합니다.
- **오류 응답**:
  - `503 Service Unavailable`: 블록체인 네트워크(`get_budget`) 또는 DB와 통신할 수 없을 때 (미검증 DB 추정치로 대체하지 않음)

**Response (`200 OK`)**
```json
[
  {
    "id": 1,
    "term_id": 1,
    "category": "행사비",
    "planned_amount": 2500000,
    "remaining_amount": 2470000,
    "execution_rate": 0.012,
    "version": 2,
    "expires_at": 1797260399,
    "revision_reason": "참가인원 증가"
  },
  {
    "id": 2,
    "term_id": 1,
    "category": "사업비",
    "planned_amount": 1500000,
    "remaining_amount": 1465000,
    "execution_rate": 0.023,
    "version": 1,
    "expires_at": 1797260399
  },
  {
    "id": 3,
    "term_id": 1,
    "category": "운영비",
    "planned_amount": 1000000,
    "remaining_amount": 1000000,
    "execution_rate": 0.0,
    "version": 1,
    "expires_at": 1797260399
  }
]
```

### 2. 예산 최초 편성 (`POST /budgets`, `POST /budgets/{id}/submit`)
- **설명**: 학기 초 회장이 항목별 예산을 최초 등록하고 EIP-712 `IssueRequest` 서명으로 온체인 발행(`relay_issue`)합니다. (`PRESIDENT` 전용, 지출 `EXPENSE` 8종 항목만 허용)
- **2단계 발행 흐름**:
  1. **1단계 (`POST /budgets`)**: `term_id`, `category`, `planned_amount`, `expires_at`을 보내 서명 대상 `id`, `term_code`, `category_hash` 초안(`status: "DRAFT"`, `201 Created`)을 발급받습니다.
  2. **2단계 (`POST /budgets/{id}/submit`)**: 앱에서 `IssueRequest`에 회장 기기 서명을 수행한 뒤 `planned_amount`, `expires_at`, `deadline`, `signature`를 제출해 온체인 발행(`200 OK`, `status: "ISSUED" | "ALREADY_ISSUED" | "REJECTED" | "NO_RESPONSE"`)을 완료합니다.

**Request (`POST /budgets` - 1단계 초안 ID 발급)**
```json
{
  "term_id": 1,
  "category": "행사비",
  "planned_amount": 2500000,
  "expires_at": 1797260399
}
```

**Response (`201 Created` - 1단계 초안)**
```json
{
  "id": 1,
  "term_id": 1,
  "term_code": 20262,
  "category": "행사비",
  "category_hash": "0x...",
  "planned_amount": 2500000,
  "expires_at": 1797260399,
  "version": 1,
  "status": "DRAFT",
  "issue_status": null,
  "tx_hash": null,
  "reason": null,
  "existing_id": null,
  "message": "예산 초안 ID가 준비되었습니다. 회장 기기 서명을 제출해 주세요."
}
```

**Request (`POST /budgets/{id}/submit` - 2단계 서명 제출)**
```json
{
  "planned_amount": 2500000,
  "expires_at": 1797260399,
  "deadline": 1797263999,
  "signature": "0x..."
}
```

**Response (`200 OK` - 2단계 온체인 발행 완료)**
```json
{
  "id": 1,
  "term_id": 1,
  "term_code": 20262,
  "category": "행사비",
  "category_hash": "0x...",
  "planned_amount": 2500000,
  "expires_at": 1797260399,
  "version": 1,
  "status": "ISSUED",
  "issue_status": "issued",
  "tx_hash": "0x...",
  "reason": null,
  "existing_id": null,
  "message": "예산 토큰이 온체인에 발행되었습니다."
}
```

| 코드 | 경우 (`POST /budgets`, `POST /budgets/{id}/submit`) |
| --- | --- |
| `201` / `200` | `POST /budgets` 초안 발급(`201`, `status: "DRAFT"` 또는 `"ALREADY_ISSUED"`), `POST /budgets/{id}/submit` 체인 처리 결과(`200`, `status: "ISSUED" \| "ALREADY_ISSUED" \| "REJECTED" \| "NO_RESPONSE"`) |
| `400` | 승인되지 않은 항목 또는 지출(`EXPENSE` 8종)이 아닌 수입 항목, 서명 형식 오류(`MalformedSignature`), 서명자 지갑 불일치 |
| `403` | 회장(`PRESIDENT`)이 아님 |
| `404` | 존재하지 않는 학기(`term_id`) 또는 예산(`id`) |
| `409` | 다른 발행 요청이 이미 `tx_issue`를 선점해 처리 중이거나, 온체인에 동일 학기·항목 예산이 DB와 다른 ID(`existing.id != id`)로 이미 발행된 경우 |
| `422` | 요청 본문 유효성 검증 실패 (카테고리 50자 초과, `planned_amount` 0 이하, `expires_at` 범위 초과/음수) |
| `503` | 릴레이어 전송 불가(`NOT_SENT`, `ChainSetupError`) 또는 DB 오류 |

---

### 3. 예산 증액 워크플로우 (`/budget-revisions`)
예산 증액은 **총무 요청(1단계) → 회장 EIP-712 서명(2단계) → 감사 EIP-712 서명 및 온체인 릴레이(3단계)** 순서로 진행됩니다 (`PENDING` → `PRESIDENT_SIGNED` → `APPROVED` / `REJECTED`).

#### 앱 서명 대상: EIP-712 `IncreaseRequest` (`BudgetToken` 도메인)
회장과 감사는 **동일한 `IncreaseRequest` 구조체 값**에 각각 EIP-712 서명합니다 (`docs/CONTRACTS.md` 참조).

| Solidity 필드 | 타입 | 백엔드 매핑 (`IncreaseRequest`) | 설명 |
| --- | --- | --- | --- |
| `budgetId` | `uint256` | `budget_id` | 증액 대상 온체인 예산 ID (`> 0`) |
| `amount` | `uint256` | `requested_amount` | **증액분** 원 단위 양의 정수 (`> 0`, 변경 후 총액이 아님) |
| `reasonHash` | `bytes32` | `text_hash(reason)` | 정규화된 증액 사유(`reason`) 원문의 UTF-8 SHA-256 해시 (`0x` + 64자 hex) |
| `version` | `uint256` | `signed_version` | **회장 서명 당시의 현재 온체인 예산 버전** (`>= 1`). 감사 승인 시에도 회장이 서명했던 `signed_version`을 그대로 사용 |
| `deadline` | `uint256` | `signature_deadline` | 회장이 지정한 서명 만료 시한 (Unix 초). 감사 승인 시에도 저장된 `signature_deadline`을 그대로 사용 |

---

#### 3.1 [1단계] 예산 증액 요청 등록 (`POST /budget-revisions`)
- **설명**: 총무가 기존 온체인 발행 예산에 대해 증액을 요청합니다 (`TREASURER` 전용).
- **사전 검증**: 대상 예산이 온체인에 발행되어 있고(`BudgetVersion` 및 `getBudget` 존재) 마감일(`expires_at`)이 지나지 않았는지 확인합니다. 온체인 미발행 초안·시드 예산이나 마감 경과 예산은 1단계에서 `400 Bad Request`로 차단됩니다.

**Request**
```json
{
  "term_id": 1,
  "category": "운영비",
  "requested_amount": 500000,
  "reason": "신학기 비품 구매로 인한 운영비 부족",
  "budget_id": 1,
  "blocked_entry_id": 10
}
```
- `budget_id` 생략 시 `term_id` + `category`로 대상 예산을 자동 매핑합니다.
- `blocked_entry_id`(선택)는 같은 학기·예산의 `EXPENSE`이면서 `BLOCKED` 또는 `PENDING` 상태인 지출만 연동할 수 있습니다.

**Response (`201 Created`)**
```json
{
  "id": 2,
  "term_id": 1,
  "category": "운영비",
  "budget_id": 1,
  "blocked_entry_id": 10,
  "requested_amount": 500000,
  "reason": "신학기 비품 구매로 인한 운영비 부족",
  "requested_by": 2,
  "requested_at": "2026-09-05T09:00:00Z",
  "status": "PENDING",
  "president_signed_by": null,
  "president_signature": null,
  "president_signed_at": null,
  "signature_deadline": null,
  "signed_version": null,
  "tx_increase": null,
  "resolved_by": null,
  "resolved_at": null,
  "reject_reason": null,
  "created_at": "2026-09-05T09:00:00Z"
}
```

| 코드 | 경우 (`POST /budget-revisions`) |
| --- | --- |
| `201` | 증액 요청 생성 완료 (`status: "PENDING"`) |
| `400` | `requested_amount <= 0`, 사유 공백·제어문자 포함, 온체인 미발행(초안·시드) 예산, 마감일(`expires_at`) 경과 예산, `blocked_entry_id` 조건 불일치 |
| `403` | 총무(`TREASURER`)가 아님 |
| `404` | 학기(`term_id`), 대상 예산, 또는 `blocked_entry_id`를 찾을 수 없음 |
| `503` | 온체인 예산 조회(`get_budget`) 중 블록체인 통신 오류 |

---

#### 3.2 [2단계] 회장 EIP-712 서명 제출 (`POST /budget-revisions/{id}/sign`)
- **설명**: 회장이 `PENDING` 상태의 증액 요청에 대해 EIP-712 `IncreaseRequest` 서명값을 제출합니다 (`PRESIDENT` 전용, 요청 총무와 동일인 불가).
- **검증**: `signed_version`이 현재 예산 최신 버전과 일치하는지, `signature_deadline`이 현재 시각 이후인지, 복원된 서명자(`signer_of`)가 회장 본인의 `wallet_address`와 일치하는지 확인한 뒤 `PRESIDENT_SIGNED`로 전이합니다.

**Request**
```json
{
  "president_signature": "0x...",
  "signature_deadline": 1793548800,
  "signed_version": 1
}
```

**Response (`200 OK`)**
- `BudgetRevisionResponse` 반환 (`status: "PRESIDENT_SIGNED"`, `president_signed_by`, `president_signature`, `president_signed_at`, `signature_deadline`, `signed_version` 채워짐)

| 코드 | 경우 (`POST /budget-revisions/{id}/sign`) |
| --- | --- |
| `200` | 회장 서명 저장 및 `PRESIDENT_SIGNED` 전이 완료 |
| `400` | `PENDING` 상태가 아님, 마감일(`expires_at`) 경과 예산, 온체인 미발행 예산, `signature_deadline` 과거 시각, `signed_version` 불일치, 서명 형식 오류 또는 회장 지갑 주소 불일치, 요청 총무 본인 서명 시도 |
| `403` | 회장(`PRESIDENT`)이 아님 |
| `404` | 증액 요청(`id`) 또는 대상 예산을 찾을 수 없음 |
| `503` | 온체인 예산 조회 중 블록체인 통신 오류 |

---

#### 3.3 [3단계] 감사 최종 승인 및 온체인 증액 릴레이 (`POST /budget-revisions/{id}/approve`)
- **설명**: 감사가 `PRESIDENT_SIGNED` 상태의 요청에 대해 동일한 `IncreaseRequest`(`version = signed_version`, `deadline = signature_deadline`, `reasonHash = text_hash(reason)`)에 서명한 `auditor_signature`를 제출하면, 서버가 `BudgetToken.increase`를 릴레이하고 온체인 반영이 확인된 뒤에만 새 `BudgetVersion`을 생성하고 `APPROVED`로 확정합니다 (`AUDITOR` 전용, 요청 총무·서명 회장과 동일인 불가).
- **재시도 및 동시성 보장**:
  - 브로드캐스트 직전 `tx_increase`와 처리 감사(`resolved_by`)를 함께 조건부 선점합니다.
  - 응답 유실(`503`) 후 재시도할 때는 `tx_increase`가 있으면 예산 마감일 사전 검사를 건너뛰고 앞선 트랜잭션 결과를 먼저 확인하여 복구합니다.
  - 다른 감사가 진행 중이거나 이미 온체인에 반영된 건을 재시도하면 `409 Conflict`를 반환하며, 승인자(`resolved_by`, `BudgetVersion.approved_by`)는 실제 서명한 원래 감사로 보존됩니다.
  - `SignatureExpired` 또는 `VersionMismatch` 발생 시 회장 서명 필드를 초기화하고 `PENDING` 상태로 되돌린 뒤 `400 Bad Request`(재서명 안내)를 반환합니다.

**Request**
```json
{
  "auditor_signature": "0x..."
}
```

**Response (`200 OK`)**
- `BudgetRevisionResponse` 반환 (`status: "APPROVED"`, `tx_increase`, `resolved_by`, `resolved_at` 채워짐, 새 `BudgetVersion` 생성됨)

| 코드 | 경우 (`POST /budget-revisions/{id}/approve`) |
| --- | --- |
| `200` | 온체인 증액(`INCREASED`) 확인 및 `APPROVED` 확정 완료 |
| `400` | `PRESIDENT_SIGNED` 상태가 아님, 서명 시한 만료/`SignatureExpired`/`VersionMismatch`(`PENDING`으로 자동 롤백 후 재서명 안내), 예산 마감일 경과(`BudgetExpired`, 롤백 없음), 서명 형식 오류 또는 감사 지갑 불일치, 요청자·회장 서명자와 동일인 |
| `403` | 감사(`AUDITOR`)가 아님 |
| `404` | 증액 요청(`id`) 또는 대상 예산을 찾을 수 없음 |
| `409` | 동시에 다른 승인 요청이 처리 중이거나, 다른 감사가 선점·승인한 요청에 대한 재시도 |
| `503` | 블록체인 응답 미확인(`NO_RESPONSE`, `tx_increase` 선점 유지 — 재시도 시 앞선 결과 확인) 또는 릴레이어 미전송(`NOT_SENT`, 선점 해제) / DB 오류 |

---

#### 3.4 예산 증액 반려 (`POST /budget-revisions/{id}/reject`)
- **설명**: 회장 또는 감사가 `PENDING` 또는 `PRESIDENT_SIGNED` 상태의 증액 요청을 반려합니다 (`PRESIDENT`, `AUDITOR` 전용, 요청 총무 본인 불가).

**Request**
```json
{
  "reject_reason": "기타 예비비 항목으로 대체 집행 가능하여 반려함"
}
```

**Response (`200 OK`)**
- `BudgetRevisionResponse` 반환 (`status: "REJECTED"`, `resolved_by`, `resolved_at`, `reject_reason` 채워짐)

| 코드 | 경우 (`POST /budget-revisions/{id}/reject`) |
| --- | --- |
| `200` | 반려(`REJECTED`) 처리 완료 |
| `400` | 반려 사유 공백·제어문자 포함, 이미 `APPROVED`/`REJECTED` 완료된 요청, 요청 총무 본인 반려 시도 |
| `403` | 회장(`PRESIDENT`) 또는 감사(`AUDITOR`)가 아님 |
| `404` | 증액 요청(`id`)을 찾을 수 없음 |
| `409` | 온체인 증액 릴레이(`tx_increase`)가 진행 중인 요청 |

---

#### 3.5 예산 증액 요청 목록 및 단건 조회 (`GET /budget-revisions`, `GET /budget-revisions/{id}`)
- **설명**: 학생회 임원(`TREASURER`, `PRESIDENT`, `AUDITOR`)이 예산 증액 요청 목록 또는 단건 상세를 조회합니다.
- **쿼리 파라미터 (`GET /budget-revisions`)**: `term_id`(선택), `status_filter`(선택: `PENDING`, `PRESIDENT_SIGNED`, `APPROVED`, `REJECTED`)
- **시한 만료 자동 정리**: 조회 시 `PRESIDENT_SIGNED` 상태이면서 `tx_increase`가 없고 `signature_deadline`이 경과한 건은 자동으로 `PENDING` 상태로 되돌린 뒤 결과를 반환합니다.

| 코드 | 경우 (`GET /budget-revisions`, `GET /budget-revisions/{id}`) |
| --- | --- |
| `200` | 목록(`List[BudgetRevisionResponse]`) 또는 단건(`BudgetRevisionResponse`) 반환 |
| `403` | 학생회 임원(`TREASURER`, `PRESIDENT`, `AUDITOR`)이 아님 |
| `404` | 단건 조회 시 존재하지 않는 증액 요청(`id`) |

---

## 회계 기록

### 1. 수입·지출 목록 조회 (`GET /entries`)
- **설명**: 장부 내역 목록을 최신순으로 조회합니다. (필터 쿼리: `kind`, `status`)
- **타임스탬프**: `occurred_at`은 사용일 KST 00:00:00 기준 Unix 초(정수)입니다.
- **등록자 지갑 주소**: `registrant` 필드에 온체인 등록자 지갑 주소(`0x...`)가 실려 내려옵니다 (체인을 못 읽으면 DB 등록자 지갑 주소로 대체). 승인·반려 서명(`entryCommit`) 생성 시 체인의 registrant로 사용됩니다.
- **블록 번호**: 목록 조회 시에는 블록체인 RPC 부하 및 호출 비용 절감을 위해 `block_number`가 항상 `null`로 반환됩니다. 확정·반려 트랜잭션의 블록 번호는 단건 상세 조회(`GET /entries/{id}`) 또는 온체인 원장 조회(`GET /entries/{id}/onchain`)에서 확인하실 수 있습니다.
- **조회 성능 및 RPC 보호**: 감사·회장 홈 폴링(15초) 및 앱 3초 타임아웃 방지를 위해, 목록 조회에서는 `PENDING` 건에 대해서만 최대 1.5초 이내로 온체인 조회를 시도하고 초과·실패 시 DB 값으로 즉시 응답합니다. (앱은 서명 직전 단건 상세 조회 `GET /entries/{id}`로 온체인 값을 최종 확인합니다)
- **초안(`DRAFT`) 제외 기준**:
  - 온체인 트랜잭션이 아직 발생하지 않은 미완성 초안(`status IS NULL`)은 **학생 앱과 총무 일반 장부 목록에서 모두 제외**됩니다.
  - **학생 앱**: 온체인에 등록 완료된 `CONFIRMED` 및 `PENDING` 건만 조회 가능합니다.
  - **총무 앱**: 정규 회계 장부 목록(`GET /entries`)에서는 초안이 노출되지 않으며, 기기 서명 대기 중인 임시 작성 건은 로컬 상태 또는 별도 초안 목록 뷰를 통해서만 접근합니다.

**Response (`200 OK`)**
```json
[
  {
    "id": 1,
    "term_id": 1,
    "term_code": 20261,
    "kind": "EXPENSE",
    "amount": 35000,
    "counterparty": "한결문구",
    "purpose": "신입생 환영회 명찰 및 필기구 구매",
    "occurred_at": 1788793200,
    "status": "CONFIRMED",
    "receipt_path": "/receipts/sample_01.jpg",
    "registrant": "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
    "block_number": null
  },
  {
    "id": 2,
    "term_id": 1,
    "term_code": 20261,
    "kind": "EXPENSE",
    "amount": 120000,
    "counterparty": "청년피자",
    "purpose": "개강총회 다과 주문",
    "occurred_at": 1788706800,
    "status": "PENDING",
    "receipt_path": "/receipts/sample_02.jpg",
    "registrant": "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
    "block_number": null
  }
]
```

### 1.1 수입·지출 내역 단건 상세 조회 (`GET /entries/{id}`)
- **설명**: 내역 ID로 특정 수입/지출 내역의 상세 정보를 조회합니다.
- **등록자 및 블록 번호**:
  - `registrant`: 온체인 등록자 지갑 주소(`0x...`)가 실려 내려옵니다 (미기록 또는 체인 단절 시 DB 등록자의 지갑 주소로 대체).
  - `block_number`: 확정/반려 트랜잭션이 안착된 블록 번호가 실려 내려옵니다 (`tx_confirm` 또는 `tx_pending` 기준 receipt 조회, 체인 미안착 시 `null`).

**Response (`200 OK`)**
```json
{
  "id": 1,
  "term_id": 1,
  "term_code": 20261,
  "kind": "EXPENSE",
  "amount": 35000,
  "counterparty": "한결문구",
  "purpose": "신입생 환영회 명찰 및 필기구 구매",
  "occurred_at": 1788793200,
  "status": "CONFIRMED",
  "receipt_path": "/receipts/sample_01.jpg",
  "registrant": "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
  "block_number": 102
}
```

### 2. 지출 및 수입 신규 등록 흐름 (2단계 등록 프로세스)
지출/수입 등록은 영수증 업로드 및 블록체인 EIP-712 기기 서명 검증을 위해 아래 절차로 진행됩니다:
1. **[사전 단계] 영수증 파일 업로드 (`POST /receipts`)**: 총무가 영수증 이미지를 업로드하고, 서버에서 바이트를 보존해 산출한 `receipt_hash`와 `receipt_path`를 획득합니다.
2. **1단계 (초안 등록 및 검증, `POST /entries`)**: 클라이언트가 영수증 해시와 거래 내역을 전송하여 서버에 초안을 생성하고 고유 id를 발급받습니다.
3. **2단계 (앱 서명 및 체인 제출, `POST /entries/{id}/submit`)**: 모바일 앱에서 기기 서명(EIP-712 `RecordRequest`)을 완료하여 서버/릴레이어에 제출하면 스마트 컨트랙트 트랜잭션이 발행되고 `PENDING` 상태로 전환됩니다.

---

#### 2.0 [사전] 영수증 파일 업로드 (`POST /receipts`, `GET /receipts/{filename}`)
- **설명**: 총무가 촬영하거나 선택한 영수증 이미지를 서버에 업로드합니다 (`multipart/form-data`). 서버는 파일의 원본 바이트를 보존하여 SHA-256 해시를 계산하고 파일명에 반영해 저장합니다.
- **권한**: 총무(`TREASURER`) 전용.
- **조회/열람**: 업로드된 파일은 `GET /receipts/{filename}`으로 언제든 원본 이미지를 다운로드하거나 모바일 앱 화면에서 열람(S3)할 수 있습니다.

**Request (`POST /receipts`)**
- Header: `Content-Type: multipart/form-data`
- Body: `file: <바이너리 이미지 파일>`

**Response (`201 Created`)**
```json
{
  "receipt_hash": "0xdef4567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
  "receipt_path": "/receipts/def4567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef.jpg",
  "filename": "receipt_20261106.jpg",
  "size": 245120
}
```

| 코드 | 경우 (`POST /receipts`, `GET /receipts/{filename}`) |
| --- | --- |
| `201` | 영수증 업로드 성공 및 해시 발급 완료 |
| `200` | `GET /receipts/{filename}` 파일 다운로드 성공 |
| `400` | 빈 파일이거나 파일 파라미터 누락 |
| `403` | 총무(`TREASURER`)가 아님 |
| `404` | `GET /receipts/{filename}` 파일 미존재 |

---

#### 2.1 [1단계] 초안 등록 및 검증 (`POST /entries`)
- **설명**: 총무가 영수증 해시와 거래 내역을 입력하여 초안을 생성합니다. 블록체인 기록 전이므로 온체인 상태가 아니며, 고유 `id`만 발급됩니다.
- **권한**: 총무(`TREASURER`)만. 컨트랙트도 등록자를 총무로 제한합니다(`NotRegistrant`). 학생·감사·회장은 `403`, 토큰이 없으면 `401` (인증 §3).
- **영수증 필수 및 검증 (PRD §4.3, B2, B3)**:
  - **지출(`EXPENSE`)**: 신규 일반 지출은 `receipt_hash`가 필수입니다 (누락 시 `400 Bad Request`). 단, 정정 지출(`corrects_entry_id`가 지정된 환불·정정 건)은 영수증이 선택값입니다 (`docs/HASHING.md` §2 샘플 3).
  - **수입(`INCOME`)**: `receipt_hash`는 선택값입니다.
  - **해시 형식 검증**: `receipt_hash`는 `0x`로 시작하는 64자리 소문자 16진수(`^0x[0-9a-f]{64}$`)여야 합니다 (대문자, 0x 누락, 길이 불일치 시 `400 Bad Request`).
  - **파일 존재 검증**: 사전에 `POST /receipts`로 업로드되지 않았거나 서버에 존재하지 않는 파일의 해시는 `400 Bad Request`로 거부됩니다.
- **영수증 중복 검증 (PRD §6, §8, B4)**:
  - 기존 승인번호+결제일시+금액 또는 영수증 해시가 이미 등록되어 있는 경우, `409 Conflict`로 차단하지 않고 **정상 등록하되 `ocr_status = "DUPLICATE"` 경고 상태로 등록**합니다. (감사 승인 시 소명 사유가 강제됩니다)
  - 단, 반려(`REJECTED`)되었거나 예산초과 차단(`BLOCKED`)된 내역은 장부에 유효하게 안착되지 않았으므로, 동일 영수증으로 재등록할 수 있도록 **중복 대조 대상에서 제외**됩니다.

**Request**
```json
{
  "term_id": 1,
  "kind": "EXPENSE",
  "amount": 120000,
  "counterparty": "청년피자",
  "purpose": "개강총회 다과 주문",
  "budget_id": 1,
  "occurred_at": 1788706800,
  "receipt_hash": "0xdef4567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
  "receipt_path": "/receipts/def4567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef.jpg"
}
```

**정상 응답 (`201 Created` - 초안 생성 및 서명 대기)**
- **상태 필드 규격 (`docs/enums.md`)**: `PENDING`, `CONFIRMED`, `REJECTED`, `BLOCKED` 4종은 전부 **온체인 상태**입니다. 1단계 초안은 블록체인에 기록되기 전이므로 `status`를 반환하지 않고 **고유 `id`만 발급**합니다.
- DB에서는 `status IS NULL` 여부로 초안 여부를 판별하며, 온체인 enum 순서 보존을 위해 `docs/enums.md`에 임의로 `DRAFT`를 추가하지 않습니다.

```json
{
  "id": 2,
  "message": "지출 초안이 등록되었으며, 기기 서명 제출 대기 상태입니다."
}
```

| 코드 | 경우 (`POST /entries`) |
| --- | --- |
| `201` | 초안 ID 채번 완료 |
| `400` | 지출 시 `receipt_hash` 누락, 해시 형식 불일치(대문자·길이 오류), 서버 미존재 영수증, 거래처/목적 제어문자 포함 또는 빈 문자열, `occurred_at` 자정 시각 불일치, 수입 내역에 예산 배정 시도 |
| `401` | 로그인 토큰 없음 |
| `403` | 총무(`TREASURER`)가 아님 |
| `422` | 요청 본문 유효성 검증 실패 (문자열 길이 초과 등) |
| `503` | 데이터베이스 오류 |

---

#### 2.2 [2단계] 모바일 앱 서명 및 체인 등록 (`POST /entries/{id}/submit`)
- **설명**: 1단계에서 발급받은 `id`에 대해 총무의 모바일 기기 서명값(`RecordRequest` EIP-712 signature)을 백엔드로 전달하여 블록체인에 등록합니다. 등록 완료 시 `tx_pending` 해시가 부여되며 이 시점부터 온체인 **`PENDING`** 상태가 부여됩니다.
- **권한**: 초안을 등록한 총무 본인만. 다른 역할은 `403` "이 작업을 할 권한이 없습니다.", 다른 총무는 `403` "본인이 등록한 초안만 제출할 수 있습니다.", 토큰이 없으면 `401`.
  - 다른 사람이 서명하면 체인의 등록자(서명자)와 DB의 `created_by`가 달라져 학생 앱 검증에서 불일치로 표시되기 때문입니다.
- **예산 검증 및 차단 (`BLOCKED`)**: 
  - 잔여 예산 초과, 집행 마감 경과 등의 사유 발생 시 단순 `400 Bad Request`로 요청을 버리지 않고, **감사 및 추적을 위해 장부에 `status: BLOCKED`로 기록**하며 사유(`block_reason`)를 반환합니다.

**Request**
```json
{
  "signature": "0x5a1b2c3d4e5f60718293a4b5c6d7e8f901a2b3c4d5e6f708192a3b4c5d6e7f801b",
  "deadline": 1788796800
}
```

**정상 등록 응답 (`200 OK` - 온체인 PENDING 등록)**
```json
{
  "id": 2,
  "status": "PENDING",
  "tx_pending": "0x3333333333333333333333333333333333333333333333333333333333333333",
  "message": "온체인에 성공적으로 기록되어 감사 승인 대기(PENDING) 상태가 되었습니다."
}
```

**예산 초과 시 차단 응답 (`200 OK` 또는 `422 Unprocessable` - BLOCKED 기록 및 사유 반환)**
```json
{
  "id": 4,
  "status": "BLOCKED",
  "tx_pending": "0x4444444444444444444444444444444444444444444444444444444444444444",
  "block_reason": "BUDGET_EXCEEDED",
  "message": "해당 예산 카테고리의 잔량이 부족하여 지출 등록이 차단(BLOCKED)되었습니다."
}
```

---

#### 2.3 초안 수명주기 및 예외 처리 정책 (모바일 앱 등록 화면 가이드)
총무가 1단계로 ID를 발급받은 뒤 모바일 앱 기기 서명(2단계) 단계에서 이탈하거나 오류가 발생한 경우의 처리 정책입니다:

1. **서명 실패/이탈 시 재시도 (`Retry`) 허용**:
   - 1단계 ID 발급 후 생체인증 창 취소, 일시적 네트워크 오류, 앱 백그라운드 전환 등으로 서명 제출이 지연된 경우, 서명 유효 시한(`deadline`, 기본 발급 시점 + 10분) 이내에는 **동일한 `id`로 `POST /entries/{id}/submit` 재서명 제출이 가능**합니다.
   - 모바일 앱은 작성 중이던 내역 화면에서 "다시 서명하기" 버튼을 노출하여 잔여 시간 동안 재시도를 유도합니다.

2. **유효 시한(`deadline`) 만료 시 자동 폐기 (`Discard`)**:
   - `deadline`이 경과할 때까지 2단계 서명이 제출되지 않은 초안은 만료되어 더 이상 온체인에 등록할 수 없습니다 (`410 Gone` 또는 `400 Bad Request`).
   - 만료된 초안은 서버 백그라운드 정리 작업(스케줄러)을 통해 자동 폐기되며, 총무는 영수증 촬영부터 신규 등록을 다시 진행해야 합니다.

---

### 3. 감사 기기 서명 승인 (`POST /entries/{id}/approve`)
- **설명**: 감사가 기기 생체인증 서명(`ConfirmApproval`)을 제출하여 지출을 `CONFIRMED`로 최종 확정하고 연계 예산을 차감합니다.
- **제약 (Maker-Checker)**: 작성자(`created_by`)와 승인자(`approved_by`)가 동일할 경우 `403 Forbidden`으로 즉시 거부됩니다.
  - `detail`: `본인이 등록한 항목은 승인·반려할 수 없습니다.` — 역할 오류(`이 작업을 할 권한이 없습니다.`)와 구분됩니다.
  - **반려에도 똑같이 적용**됩니다. 컨트랙트가 확정·반려 서명자 모두 등록자와 같으면 revert(`SelfApproval`)하기 때문입니다.
  - 서버 검사는 서명이 담긴 요청이 온 뒤에 돌기 때문에, 서명 전에 막으려면 **화면에서 먼저** 거릅니다. 승인 목록에서 `GET /auth/me`의 `id`와 항목의 `created_by`가 같으면 승인·반려 버튼을 비활성화합니다.
  - 서버 구현: `app/auth/approval.py`의 `ensure_not_self_approval(entry.created_by, user)`를 승인·반려 API에서 항목을 불러온 뒤 호출합니다.

**Request**
```json
{
  "device_signature": "0x6f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a1b"
}
```

**Response (`200 OK`)**
```json
{
  "id": 2,
  "status": "CONFIRMED",
  "approved_by": 3,
  "tx_confirm": "0x2222222222222222222222222222222222222222222222222222222222222222",
  "remaining_budget": 2380000
}
```

### 4. 반려 (`POST /entries/{id}/reject`)
- **설명**: 감사·회장이 기기 서명(`RejectDecision`)과 사유를 제출해 `PENDING` 항목을 `REJECTED`로 끝냅니다. 확정과 같은 `tx_confirm` 칸을 선점하므로 한 항목에 확정과 반려가 함께 나가지 않습니다.
- **처리 중 응답 값**: 체인에서 끝나기 전에는 목록·단건 응답의 `rejected_by`·`reject_reason`이 `null`입니다. 확정도 같아서 `approved_by`·`warning_ack_reason`은 `CONFIRMED`일 때만 값이 있습니다. `tx_confirm`은 처리 중에도 채워집니다.

**Request**
```json
{
  "deadline": 1790700000,
  "signature": "0x6f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a1b",
  "reject_reason": "영수증 식별 불가"
}
```

**Response (`200 OK`)**
```json
{
  "id": 2,
  "status": "REJECTED",
  "message": "온체인에 성공적으로 반려(REJECTED) 기록되었습니다."
}
```

| 코드 | 경우 |
| --- | --- |
| `400` | `PENDING`이 아님, 사유 없음, 서명 형식 오류, 서명자 불일치, 체인이 거부함 (`fail_reason` 코드 동봉) |
| `403` | 감사·회장이 아님, 본인이 등록한 항목 |
| `404` | 없는 항목 |
| `409` | 확정이 처리 중, 다른 요청이 먼저 처리함 또는 처리 중. 잠시 뒤 다시 조회합니다 |
| `503` | 노드·DB 오류. 트랜잭션이 들어갔는지 모르면 같은 요청을 다시 보내 결과를 확인합니다 |

확정(`POST /entries/{id}/confirm`)도 반려가 처리 중이면 같은 방식으로 `409`입니다.

#### 온체인 거부 시 `fail_reason` 코드 (400 Bad Request)
체인이 확정(`confirm`)·반려(`reject`)·등록(`submit`)을 거부(`ChainRevert`)하면, `detail` 문구와 함께 최상위에 기계 판독용 `fail_reason` 코드가 함께 반환됩니다.
앱은 문자열 파싱 없이 `fail_reason` 코드로 분기할 수 있습니다.
- 예산 관련 거부 코드: `InsufficientBudget`(예산 잔량 부족), `BudgetExpired`(집행 기간 만료), `BudgetNotFound`(예산 미존재)
- 서명/상태 거부 코드: `InvalidStatus`(이미 처리됨), `SignatureExpired`(서명 유효시한 만료), `SelfApproval`(자기 승인/반려), `EntryCommitMismatch` 등

**온체인 승인 거부 응답 예시 (`400 Bad Request`)**
```json
{
  "detail": "온체인 승인이 거부되었습니다 (InsufficientBudget).",
  "fail_reason": "InsufficientBudget"
}
```

---

### 5. 온체인 원장 항목 조회 (`GET /entries/{id}/onchain`)
- **설명**: 스마트 컨트랙트 원장(`getEntry`) 및 블록체인 트랜잭션 기록(`entry_tx_detail`)을 직접 조회합니다. 모바일 앱의 1단계/2단계 검증(등록자 지갑 주소 대조, 해시 대조, 블록 번호 대조)에 사용됩니다.
- **체인 미등록 항목**: 체인에 아직 올라가지 않았거나 없는 건은 `404 Not Found`를 반환합니다.

**Response (`200 OK`)**
```json
{
  "id": 1,
  "hash": "0x3b8d...",
  "amount": 35000,
  "kind": "EXPENSE",
  "status": "CONFIRMED",
  "term": 20261,
  "occurred_at": 1788793200,
  "budget_id": 1,
  "corrects_id": 0,
  "registrant": "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
  "approver": "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
  "had_warning": false,
  "reason_hash": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "block_number": 102,
  "block_reason": null,
  "tx_hash": "0x2222222222222222222222222222222222222222222222222222222222222222"
}
```

---

## 검증

### 1. 장부 잔액 요약 (`GET /balance`)
- **설명**: 대시보드 상단 카드에 표시되는 계좌/장부 잔액 요약입니다. (`entries` 테이블의 `CONFIRMED` 확정 건만 실시간 DB 합산, 쿼리 파라미터: `term_id`)
- **산출식**: `balance = income - expense` (`PENDING`, `BLOCKED`, `REJECTED` 및 미제출 초안 건 제외, 확정된 음수 정정 `amount < 0` 자동 반영)
- **오류 응답**: `503 Service Unavailable` (DB 오류)

**Response (`200 OK`)**
```json
{
  "balance": 4965000,
  "income": 5000000,
  "expense": 35000
}
```

### 2. 온체인 독립 검증 (`GET /entries/{id}/verify`)
- **설명**: 모바일 앱이 내장 SHA-256 로직으로 `meta_hash`를 직접 계산하여 DB 및 블록체인 상의 데이터와 대조합니다.
- **해시 계산**: `SHA256( amount ␟ counterparty ␟ purpose ␟ occurred_at ␟ receipt_hash )` (`U+001F` 구분자)

**Response (`200 OK`)**
```json
{
  "entry_id": 1,
  "hash_inputs": {
    "amount": "35000",
    "counterparty": "한결문구",
    "purpose": "신입생 환영회 명찰 및 필기구 구매",
    "occurred_at": "1788793200",
    "receipt_hash": "0xabc1234567890abcdef1234567890abcdef1234567890abcdef1234567890abc"
  },
  "db_meta_hash": "0x24ae73988d927fb39f45eb6024e9ff8ffa19e8501603565bd82710ea8df4b937",
  "onchain_meta_hash": "0x24ae73988d927fb39f45eb6024e9ff8ffa19e8501603565bd82710ea8df4b937",
  "is_tampered": false
}
```

### 3. 사용자 지갑 매핑 (`GET /users/wallets`)
- **설명**: 체인의 `registrant`·`approver`(지갑 주소)를 DB의 `created_by`·`approved_by`(user id)와 대조할 때 쓰는 매핑입니다. 학생 앱 단건 검증 2단계가 읽습니다 (HASHING.md §2, `docs/backend_requests.md` 1-2).
- **권한**: 토큰 없이 호출할 수 있습니다 (다른 조회 API와 같음). 임원 주소는 체인에 이미 공개된 값입니다.
- **범위**: 지갑이 등록된 사용자(현·전 임원)가 모두 들어 있습니다. 역할이 아니라 지갑 유무로 고르므로, 임기가 끝난 사람이 등록·승인한 과거 항목도 검증할 수 있습니다. 지갑이 없는 학생은 체인에 서명자로 나오지 않아 빠집니다.
- **형식**: 키는 **소문자** 지갑 주소, 값은 user id(숫자)입니다. 앱은 체인의 `registrant`·`approver`를 소문자로 바꿔 그대로 찾습니다. 주소는 로컬 배포의 임원 계정(`contracts/deployments/localhost.json`)과 같습니다.
- **주소가 키인 이유**: 한 사람이 주소를 여러 개 가질 수 있습니다. 임원이 기기를 바꿔 새 주소로 롤을 옮겨도(`RoleManager.changeRole`, 회장은 키 분실 때 `proposePresidentRecovery` → `executePresidentRecovery`) 옛 주소로 등록·승인한 과거 항목은 체인에 옛 주소로 남아 있어서, 사람마다 현재 주소 하나만 주면 그 항목이 모두 "등록자 불일치"로 판정됩니다. 지금은 사용자마다 현재 주소 하나만 들어 있고, 옛 주소는 롤 변경·회장 복구 릴레이를 붙일 때 같은 응답에 더해집니다 (형식은 그대로입니다).
- **찾지 못하면**: 매핑에 없는 주소는 이 시스템의 사용자가 아닙니다. 대조 결과는 불일치입니다.

**Response (`200 OK`)**
```json
{
  "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc": 2,
  "0x90f79bf6eb2c4f870365e785982e1f101e93b906": 3,
  "0x70997970c51812dc3a010c7d01b50e0d17dc79c8": 4,
  "0x9965507d1a55bcc2695c58ba16fb37d819b0a4dc": 5
}
```

---

## 회원권

### 1. 내 회원권과 입장 QR (`GET /memberships/me`)
- **설명**: 학생 화면 S5의 SBT 보유 표시와 입장 QR입니다. 보유 여부는 **체인의 `MembershipSBT.hasValidMembership`으로 확인**합니다. DB 기록만 있고 체인에 없으면 미보유입니다 (PRD §13).
- **권한**: 로그인이 필요합니다(토큰 없으면 `401`). 임원 계정은 회원권을 가질 수 없어 항상 `null`입니다.
- **학기**: `term_id` 쿼리로 고릅니다. 없으면 진행 중인 학기, 진행 중인 학기가 없으면 가장 최근에 시작한 학기입니다.
- **학생 주소**: 서버가 `wallet_index`로 파생한 주소(`m/44'/60'/0'/0/{index}`)로 조회합니다. 학번은 체인에 올라가지 않습니다.
- **QR**: `SCA:<학기>:U<학생 ID 6자리 이상>` (예: `SCA:2026-2:U000001`). 자격 정보는 담지 않습니다. 스캐너가 매번 조회합니다 (`docs/backend_requests.md` §1-4).

**Response (`200 OK`, 보유 중)**
```json
{
  "id": 1,
  "user_id": 1,
  "term_id": 2,
  "token_id": 128,
  "minted_at": 1788620400,
  "burned_at": null,
  "qr_payload": "SCA:2026-2:U000001"
}
```
- `id`·`minted_at`은 DB 기록입니다. 체인에는 있는데 DB 기록이 없거나 tokenId가 다르면 `null`이고, `token_id`는 체인 값입니다.

| 코드 | 경우 |
| --- | --- |
| `200` + 본문 | 그 학기 회원권 보유 중 |
| `200` + `null` | 미보유, 임원 계정, 진행 중이거나 시작한 학기가 없음 |
| `401` | 토큰 없음·만료 |
| `404` | `term_id`의 학기가 없음 |
| `503` | 보유 여부를 확인하지 못함 (체인 장애, `MembershipSBT` 미배포, `STUDENT_WALLET_MNEMONIC` 미설정, DB 오류). **미보유가 아니므로 「납부 확인 필요」로 안내하지 않습니다** |

---

## 체인

### 1. EIP-712 서명 도메인 (`GET /chain/domains`)
- **설명**: 앱이 서명할 때 쓸 EIP-712 도메인을 배포 기록(`contracts/deployments/localhost.json`)에서 읽어 내려줍니다. 재배포하면 주소와 도메인이 바뀌므로 **앱은 값을 하드코딩하지 말고 이 API를 씁니다.**
- **권한**: 토큰 없이 호출할 수 있습니다.
- **도메인 고르기**: 서명을 받는 컨트랙트마다 도메인이 따로 있습니다 (`docs/CONTRACTS.md` 「EIP-712」).

| 서명 | 도메인 |
| :--- | :--- |
| 등록 `RecordRequest`, 승인 `ConfirmApproval`, 반려 `RejectDecision` | `AccountingLedger` |
| 예산 발행 `IssueRequest`, 증액 `IncreaseRequest`, 회수 `ReclaimRequest` | `BudgetToken` |
| 롤 변경 `RoleChange`, 회장 복구 `PresidentRecovery`·`RecoveryCancel` | `RoleManager` |

- **검산**: `domainSeparator`는 컨트랙트의 `DOMAIN_SEPARATOR()`입니다. 앱이 나머지 네 필드로 계산한 도메인 해시와 비교하면, 체인 id나 주소를 잘못 쓴 것을 서명 전에 잡을 수 있습니다.
- 키 이름은 EIP-712 도메인 필드 그대로(`chainId`, `verifyingContract`)라 서명 라이브러리에 바로 넘길 수 있습니다. `domainSeparator`는 도메인 필드가 아니니 넘기기 전에 뺍니다.

**Response (`200 OK`)**
```json
{
  "chainId": 31337,
  "domains": {
    "RoleManager": {
      "name": "RoleManager",
      "version": "1",
      "chainId": 31337,
      "verifyingContract": "0x5FbDB2315678afecb367f032d93F642f64180aa3",
      "domainSeparator": "0xebbd14b2ace84e519e5d9866354eabd2160af1a8a8675bb913e187e94c7a2a0c"
    },
    "BudgetToken": {
      "name": "BudgetToken",
      "version": "1",
      "chainId": 31337,
      "verifyingContract": "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
      "domainSeparator": "0x1f2905a02b6b82de113d21bf22f98674232314b3d02d77ab6f4bdf7e0c252699"
    },
    "AccountingLedger": {
      "name": "AccountingLedger",
      "version": "1",
      "chainId": 31337,
      "verifyingContract": "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0",
      "domainSeparator": "0x7887f5ba6910ea3e84a905c6e45288e1cd7b0f62a455182c7bc12b4208109294"
    }
  }
}
```

**배포 기록이 없거나 앞뒤가 맞지 않을 때 (`503 Service Unavailable`)** — 서명 도메인(`AccountingLedger`·`BudgetToken`·`RoleManager`) 중 하나라도 없거나, 도메인의 `chainId`·`verifyingContract`가 같은 파일의 체인·주소와 다르거나, `domainSeparator`가 네 필드로 계산한 값과 다르면 반쯤 갱신되거나 잘못된 기록으로 보고 내려주지 않습니다. 틀린 `domainSeparator`를 내려주면 앱의 검산이 모든 서명을 막기 때문입니다.
```json
{ "detail": "배포 기록이 없습니다 (localhost.json). 컨트랙트를 배포했는지 확인하세요" }
```
