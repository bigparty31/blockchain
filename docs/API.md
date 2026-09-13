# API

> **문서 버전**: v0.1 (1주차 초안)  
> **작성자**: 김경윤 (`feat/backend-core`)  
> **기본 Base URL**: `http://localhost:8000` (FastAPI Swagger UI: `/docs`)  
> **금액 규격**: 원 단위 정수 (`integer`, 스마트 컨트랙트 `int256` 대응)

---

## 인증

### 1. 로그인 (`POST /auth/login`)
- **설명**: 학번과 비밀번호로 로그인하고 세션 JWT 토큰과 역할(`role`)을 발급받습니다.

**Request**
```json
{
  "student_no": "20240001",
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
  "wallet_address": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
}
```

### 2. 내 정보 조회 (`GET /auth/me`)
- **설명**: 현재 로그인한 사용자의 기본 프로필과 권한을 확인합니다.

**Response (`200 OK`)**
```json
{
  "id": 1,
  "student_no": "20240001",
  "name": "김총무",
  "role": "TREASURER"
}
```

---

## 예산

### 1. 예산 현황 목록 (`GET /budgets`)
- **설명**: 카테고리별 예산 편성액, 실시간 잔여액, 집행률을 조회합니다. (앱 예산 카드 및 프로그레스 바 바인딩용)

**Response (`200 OK`)**
```json
[
  {
    "id": 1,
    "term_id": 1,
    "category": "행사비",
    "planned_amount": 2500000,
    "remaining_amount": 2380000,
    "execution_rate": 0.048,
    "version": 1
  },
  {
    "id": 2,
    "term_id": 1,
    "category": "운영비",
    "planned_amount": 1000000,
    "remaining_amount": 1000000,
    "execution_rate": 0.0,
    "version": 1
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
  "expires_at": "2026-12-31T23:59:59Z"
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

**Response (`200 OK`)**
```json
[
  {
    "id": 1,
    "term_id": 1,
    "kind": "EXPENSE",
    "amount": 35000,
    "counterparty": "한결문구",
    "purpose": "신입생 환영회 명찰 구매",
    "occurred_at": "2026-09-10T15:30:00Z",
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
    "occurred_at": "2026-09-11T19:00:00Z",
    "status": "PENDING",
    "receipt_path": "/receipts/sample_02.jpg"
  }
]
```

### 2. 수입·지출 단건 상세 조회 (`GET /entries/{id}`)
- **설명**: 특정 내역의 영수증 경로, 해시, 온체인 트랜잭션 정보 등 상세 내용을 조회합니다.

**Response (`200 OK`)**
```json
{
  "id": 1,
  "term_id": 1,
  "kind": "EXPENSE",
  "amount": 35000,
  "counterparty": "한결문구",
  "purpose": "신입생 환영회 명찰 구매",
  "budget_id": 1,
  "occurred_at": "2026-09-10T15:30:00Z",
  "status": "CONFIRMED",
  "receipt_path": "/receipts/sample_01.jpg",
  "receipt_hash": "a1b2c3d4e5f6...7890",
  "meta_hash": "f0e1d2c3b4a5...6789",
  "created_by": 1,
  "approved_by": 2,
  "tx_confirm": "0x33334444...bbbb"
}
```

### 3. 지출 및 수입 신규 등록 (`POST /entries`)
- **설명**: 총무가 영수증 해시와 지출 내역을 입력하여 신규 등록합니다. 등록 직후 `PENDING` 상태가 됩니다.
- **예산 초과 시**: 잔량 초과 시 등록이 거부됩니다. (`400 Bad Request`)

**Request**
```json
{
  "term_id": 1,
  "kind": "EXPENSE",
  "amount": 120000,
  "counterparty": "청년피자",
  "purpose": "개강총회 다과 주문",
  "budget_id": 1,
  "occurred_at": "2026-09-11T19:00:00Z",
  "receipt_hash": "7f83b165...e9b"
}
```

**Response (`201 Created`)**
```json
{
  "id": 2,
  "status": "PENDING",
  "message": "지출 등록이 완료되었으며 감사 승인 대기 상태입니다."
}
```

### 4. 감사 기기 서명 승인 (`POST /entries/{id}/approve`)
- **설명**: 감사가 기기 생체인증 서명을 전달하여 지출을 `CONFIRMED`로 최종 확정하고 예산을 소모합니다.
- **제약 (Maker-Checker)**: 작성자(`created_by`)와 승인자(`approved_by`)가 동일하면 `403 Forbidden`으로 거부됩니다.

**Request**
```json
{
  "device_signature": "0x6f9a...3c21"
}
```

**Response (`200 OK`)**
```json
{
  "id": 2,
  "status": "CONFIRMED",
  "approved_by": 2,
  "remaining_budget": 2380000
}
```

---

## 검증

### 1. 장부 잔액 요약 (`GET /balance`)
- **설명**: 대시보드 상단 카드에 표시되는 계좌/장부 잔액 요약입니다. (확정 건만 반영)
- **산출식**: `balance = income - expense`

**Response (`200 OK`)**
```json
{
  "balance": 4965000,
  "income": 5000000,
  "expense": 35000
}
```

### 2. 온체인 독립 검증 (`GET /entries/{id}/verify`)
- **설명**: 모바일 앱이 내장 SHA-256 로직으로 해시를 직접 계산하여 블록체인 상의 데이터와 대조합니다.

**Response (`200 OK`)**
```json
{
  "entry_id": 1,
  "hash_inputs": {
    "amount": "35000",
    "counterparty": "한결문구",
    "purpose": "신입생 환영회 명찰 구매",
    "occurred_at": "2026-09-10T15:30:00Z",
    "receipt_hash": "a1b2c3d4e5f6...7890"
  },
  "db_meta_hash": "f0e1d2c3b4a5...6789",
  "onchain_meta_hash": "0xf0e1d2c3b4a5...6789",
  "is_tampered": false
}
```
