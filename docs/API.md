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
- **설명**: 카테고리별 예산 편성액, 실시간 잔여액, 집행률을 조회합니다. (앱 예산 카드 및 프로그레스 바 바인딩용)
- **잔량 반영 기준**: `CONFIRMED` 확정 건만 잔량 차감에 반영되며, `PENDING`(대기) 상태 건은 예산 잔량에서 차감되지 않습니다.

**Response (`200 OK`)**
```json
[
  {
    "id": 1,
    "term_id": 1,
    "category": "행사비",
    "planned_amount": 2500000,
    "remaining_amount": 2500000,
    "execution_rate": 0.0,
    "version": 1,
    "expires_at": 1767196799
  },
  {
    "id": 2,
    "term_id": 1,
    "category": "사업비",
    "planned_amount": 1500000,
    "remaining_amount": 1465000,
    "execution_rate": 0.023,
    "version": 1,
    "expires_at": 1767196799
  },
  {
    "id": 3,
    "term_id": 1,
    "category": "운영비",
    "planned_amount": 1000000,
    "remaining_amount": 1000000,
    "execution_rate": 0.0,
    "version": 1,
    "expires_at": 1767196799
  }
]
```

### 2. 예산 최초 편성 (`POST /budgets`)
- **설명**: 학기 초 회장이 항목별 예산을 최초 등록합니다. (`PRESIDENT` 전용)

**Request**
```json
{
  "term_id": 1,
  "category": "행사비",
  "planned_amount": 2500000,
  "expires_at": 1767196799
}
```

**Response (`201 Created`)**
```json
{
  "id": 1,
  "category": "행사비",
  "planned_amount": 2500000,
  "version": 1,
  "status": "ISSUED"
}
```

---

## 회계 기록

### 1. 수입·지출 목록 조회 (`GET /entries`)
- **설명**: 장부 내역 목록을 최신순으로 조회합니다. (필터 쿼리: `kind`, `status`)
- **타임스탬프**: `occurred_at`은 사용일 KST 00:00:00 기준 Unix 초(정수)입니다.
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
    "kind": "EXPENSE",
    "amount": 35000,
    "counterparty": "한결문구",
    "purpose": "신입생 환영회 명찰 및 필기구 구매",
    "occurred_at": 1788793200,
    "status": "CONFIRMED",
    "receipt_path": "/receipts/sample_01.jpg"
  },
  {
    "id": 2,
    "term_id": 1,
    "kind": "EXPENSE",
    "amount": 120000,
    "counterparty": "청년피자",
    "purpose": "개강총회 다과 주문",
    "occurred_at": 1788706800,
    "status": "PENDING",
    "receipt_path": "/receipts/sample_02.jpg"
  },
  {
    "id": 3,
    "term_id": 1,
    "kind": "INCOME",
    "amount": 5000000,
    "counterparty": "컴퓨터공학과 학생회비 일괄 납부",
    "purpose": "2026-2학기 학과 학생회비 수납",
    "occurred_at": 1788620400,
    "status": "CONFIRMED",
    "receipt_path": null
  }
]
```

### 2. 지출 및 수입 신규 등록 흐름 (2단계 등록 프로세스)
지출/수입 등록은 블록체인 EIP-712 기기 서명 검증을 위해 **2단계**로 진행됩니다:
1. **1단계 (초안 등록 및 검증)**: 클라이언트가 거래 내역을 전송하여 서버에 초안을 생성하고 고유 id를 발급받습니다.
2. **2단계 (앱 서명 및 체인 제출)**: 모바일 앱에서 기기 서명(EIP-712 `RecordRequest`)을 완료하여 서버/릴레이어에 제출하면 스마트 컨트랙트 트랜잭션이 발행되고 `PENDING` 상태로 전환됩니다.

---

#### 2.1 [1단계] 초안 등록 및 검증 (`POST /entries`)
- **설명**: 총무가 영수증 해시와 거래 내역을 입력하여 초안을 생성합니다. 블록체인 기록 전이므로 온체인 상태가 아니며, 고유 `id`만 발급됩니다.
- **권한**: 총무(`TREASURER`)만. 컨트랙트도 등록자를 총무로 제한합니다(`NotRegistrant`). 학생·감사·회장은 `403`, 토큰이 없으면 `401` (인증 §3).
- **등록자**: `created_by`에는 토큰의 사용자 id가 기록됩니다.

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
  "receipt_hash": "0xdef4567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
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

---

## 검증

### 1. 장부 잔액 요약 (`GET /balance`)
- **설명**: 대시보드 상단 카드에 표시되는 계좌/장부 잔액 요약입니다. (`CONFIRMED` 확정 건만 반영)
- **산출식**: `balance = income - expense` (`PENDING`, `BLOCKED`, `REJECTED` 건 제외)

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
