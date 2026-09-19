# 백엔드 요청사항 — 학생 화면 파트

`feat/app-student` · 2026-09-18 (2차)

앱 쪽은 **아래가 오면 바로 받아 쓸 수 있게 이미 만들어 뒀습니다.** 엔드포인트가 생기거나
필드가 실려 오면 앱 코드를 고칠 필요 없이 자동으로 서버 값을 씁니다. 그때까지는 예시
데이터로 동작하며 화면에 「예시 데이터입니다」 배너가 뜹니다.

필드 이름은 앱이 파싱하는 키 그대로 적었습니다. **이름이 다르면 못 읽습니다.**

---

## 1. 새 엔드포인트

### 1-1. `GET /entries/{id}/onchain` — 검증 2단계

`AccountingLedger.getEntry(id)` 결과를 그대로 내려주면 됩니다.

```json
{
  "hash": "0x24ae7398...",
  "amount": 35000,
  "kind": "EXPENSE",
  "status": "CONFIRMED",
  "occurred_at": 1788793200,
  "budget_id": 2,
  "corrects_id": 0,
  "registrant": "0x71C7656EC7ab88b098defB751B7401B5f6d8976F",
  "approver": "0x2546BcD3c84621e976D8185a91A922aE77ECEc30"
}
```

- `budget_id` · `corrects_id` 는 **없을 때 `0`** (NULL 아님). 체인 표기를 그대로 씁니다
- `approver` 는 미승인 시 `0x0000...0000`
- `kind` · `status` 는 `docs/enums.md` 코드 문자열

**없으면**: `meta_hash` 에 들어가지 않는 `kind` · `budget_id` 를 대조할 수 없어
**모든 항목이 「부분 검증」(파랑)에 머뭅니다.** 수입↔지출 뒤바꾸기와 예산 항목
옮기기를 탐지하지 못합니다 (`HASHING.md` §2).

### 1-2. `GET /users/wallets` — 검증 2단계

```json
{ "2": "0x71C7...976F", "3": "0x2546...ec30", "4": "0xbDA5...197E" }
```

user id(문자열 키) → 지갑 주소.

**없으면**: 체인의 `registrant` · `approver` 는 지갑 주소인데 DB 의 `created_by` ·
`approved_by` 는 user id 라 값 자체가 달라 대조할 수 없습니다. **이 두 필드가
「누가 등록하고 누가 승인했는가」의 유일한 온체인 증거**입니다.

### 1-3. `GET /objections?entry_id=` · `POST /objections` — S8

```json
[{
  "id": 1,
  "entry_id": 2,
  "user_id": 3,
  "content": "영수증 미첨부 사유가 궁금합니다",
  "answer": null,
  "answered_by": null,
  "status": "OPEN",
  "raised_at": 1788879600,
  "answered_at": null,
  "tx_raise": "0xc3d4...",
  "tx_answer": null
}]
```

`POST` 요청 본문은 `{"entry_id": 2, "content": "..."}`, 응답은 위와 같은 객체 하나.

> **본문의 정본화·해시는 백엔드가 합니다** (`HASHING.md` §1.1, §3).
> 학생 앱은 쓰기 권한이 없어 직접 서명하지 않습니다 (PRD §9.2).
>
> **앱은 학생이 입력한 원문을 그대로 보냅니다.** 앞뒤 공백·개행도 다듬지 않습니다 —
> `CRLF`·`CR` 이 섞여 올 수 있으니 `HASHING.md` §3 의 처리 순서(개행 통일 → 제어문자
> 검사 → 앞뒤 trim → NFC)를 **서버에서 그대로 적용해 주세요.**
>
> 앱이 먼저 다듬지 않는 이유는 두 가지입니다. 다듬는 로직이 Dart·Python 두 곳에
> 생기면 한쪽만 바뀌는 순간 학생이 친 원문과 저장·해시되는 값이 조용히 갈립니다.
> 그리고 앱이 미리 세탁하면 §5 의 입력 검증(제어문자 400 거부)이 볼 입력 자체가
> 사라집니다. 화면의 최소 길이 검사만 `canonicalText` 로 재고, 전송값은 건드리지
> 않습니다.

### 1-4. `GET /memberships/me` — S5

```json
{
  "id": 1, "user_id": 3, "term_id": 1, "token_id": 128,
  "commit_hash": "0x7d3a9f1c...",
  "minted_at": 1788620400,
  "burned_at": null,
  "qr_payload": "SCA:2026-2:U000003"
}
```

> `qr_payload` 에 **「납부함」 같은 자격 정보를 담지 마세요.** 담으면 캡처를 전달하는
> 것만으로 대리 입장이 됩니다. 식별자만 담고 자격 판단은 스캐너가 조회해서 합니다.

### 1-5. `GET /snapshots/latest` — S11

```json
{
  "id": 1, "term_id": 1,
  "bank_balance": 4834000,
  "snapshot_at": 1789052400,
  "tx_hash": "0xa1b2c3...",
  "unrecorded": [
    { "amount": 28000, "counterparty": "카페베네 후문점", "occurred_at": 1789052400 }
  ]
}
```

---

## 2. 기존 응답에 추가가 필요한 필드

| 필드 | 위치 | 쓰는 곳 | 앱 상태 |
|:---|:---|:---|:---|
| `block_number` | `EntryResponse` | S10 트랜잭션 표시 | **파싱 코드 작성 완료.** 실려 오면 즉시 표시됨 |
| `had_warning` | `EntryResponse` | S7 「경고 무시 승인」 뱃지 판정 (PRD §293) | 현재 `warning_ack_reason` 유무로 추정 중 |
| `rejected_by` | `Entry` (DB) | 반려 항목의 서명자 대조 | 컬럼이 없어 `REJECTED` 는 승인자 비교를 건너뜀 |
| 이전 버전 금액 | `BudgetResponse` | S6 `200만 → 250만` 의 **앞** 금액 | 현재 뒤 금액만 표시 |
| 학기 이름 | `GET /terms/{id}` 또는 `EntryResponse` | 대시보드 헤더·SBT 화면 | `term_id` 만 있고 이름이 없어 **앱에 문자열을 고정해 둔 상태** (`core/term_info.dart`) |

`block_number` 는 앱에 `EntryModel.blockNumber` 로 이미 자리를 만들어 뒀습니다.
응답에 키만 실리면 앱 수정 없이 화면에 나옵니다.

### 2-1. `/budgets` 목업에 개정된 예산을 한 건 넣어 주세요

현재 `DUMMY_BUDGETS` 3건이 모두 `version=1` · `revision_reason=null` 입니다.
앱은 `version > 1` 일 때만 `v2` 뱃지와 개정 사유를 그리기 때문에, **서버에 붙이면
S6 예산 개정 이력 표시가 화면에서 통째로 사라집니다.** 서버를 끄고 예시 데이터로 볼
때만 보이는 기능이 되어 버립니다.

행사비 한 건만 아래처럼 바꿔 주시면 충분합니다.

```json
{ "id": 1, "category": "행사비", "planned_amount": 2500000,
  "remaining_amount": 2470000, "execution_rate": 0.012,
  "version": 2, "revision_reason": "참가인원 증가", "expires_at": 1798729200 }
```

> `expires_at` 도 함께 봐주세요. 현재 목업은 `1767196799` 인데 이는
> **2026-01-01 00:59:59 KST** 로, UTC 기준 값을 그대로 쓴 것으로 보입니다.
> 2026-2학기 예산이 학기 시작 전에 만료되는 셈입니다. 기간 만료는
> `BudgetToken.spend` 가 revert 하는 **하드 게이트**라(PRD §7 규칙 4) 실제 연동 전에
> 맞춰야 합니다. 지금 화면에 이 값을 렌더링하지 않아 눈에는 안 보입니다.

---

## 3. 영수증 파일 — 바이트를 그대로 주세요

검증 3단계가 **내려받은 파일의 바이트로 `SHA-256` 을 다시 계산해** `receipt_hash` 와
비교합니다. 그래서 서버나 CDN 이 아래를 하면 **정상 영수증이 위조로 판정됩니다.**

- 재인코딩 (JPEG 품질 변경, 포맷 변환)
- EXIF 회전 보정
- 메타데이터 제거
- 썸네일로 대체

썸네일이 필요하면 **별도 경로에 따로** 만들고 원본 경로는 손대지 마세요 (`HASHING.md` §4).

`receipt_path` 는 상대 경로(`/receipts/x.jpg`)든 절대 URL(`https://...`)이든
앱이 둘 다 처리합니다.

---

## 4. 목업 해시 — 해결됨, 머지 대기

**`feat/backend-core` 에서 고쳐졌고, 앱 계산값과 한 바이트도 안 틀립니다.**
`app/test/backend_dummy_hash_test.dart` 가 목업 3건을 그대로 재계산해 대조하며 통과합니다.
영수증이 없는 수입 건(#3)도 `receipt_hash` 자리를 빈 문자열로 두고 구분자를 남기는
규칙까지 맞습니다.

| | 이전 (`develop` 현재) | 수정 후 (`feat/backend-core`) |
|:---|:---|:---|
| `meta_hash` | `0x456def1234…` 자리표시자 | `0x24ae7398…` 실제 SHA-256 |
| `occurred_at` | `1757300000` (`% 86400 = 10400`) | `1788793200` (`% 86400 = 54000`) |

> ⚠️ **아직 `develop` 에 머지되지 않았습니다** (`origin/feat/backend-core` `a6bdf90`).
> `develop` 의 목업은 여전히 자리표시자라, **머지 전 서버에 붙이면 세 건 모두
> 「변조 감지」(빨강)로 뜹니다.** 머지가 되어야 목업만으로 검증 화면을 확인할 수 있습니다.

참고로 계산식은 아래와 같습니다 (구분자는 파이프가 아니라 **U+001F**).
`receipt_hash` 가 NULL 이면 빈 문자열로 넣되 **구분자는 그대로 두어** preimage 가 `␟` 로 끝납니다.

```
meta_hash = SHA256( amount ␟ counterparty ␟ purpose ␟ occurred_at ␟ receipt_hash )
```

---

## 5. 제안 — SBT 발행 수로 수입을 대조할 수 있게 해주세요

**지금 수입 항목에는 진실성을 확인할 근거가 하나도 없습니다.** 지출은 영수증 파일·OCR 금액
대조·예산 하드 게이트가 받쳐주는데, 수입은 셋 다 없습니다. `budget_id` 가 NULL 이라 예산을
거치지 않고, 학기조차 검증 경로가 없습니다 (`HASHING.md` §2.3). 처음부터 부풀려 적은 금액은
2인 서명만 통과하면 그대로 온체인에 확정되고, 이후 「검증됨」으로 표시됩니다.

PRD §4.2 가 **학생회비 납부자에게 SBT 를 발급**한다고 하므로, 이 등식이 성립합니다.

```
SBT 발행 수 × 1인당 회비  ≈  학생회비 수입 총액
```

200명에게 SBT 가 나갔는데 원장의 학생회비 수입이 500만원이면 1인당 25,000원입니다.
공지된 회비와 맞는지 **학생 누구나 직접 확인할 수 있습니다.** 수입에 대해 현재 설계에서
얻을 수 있는 유일한 독립 근거입니다.

필요한 것 두 가지입니다.

| 필요한 것 | 어디 |
|:---|:---|
| `totalSupply()` 또는 학기별 발행 수 조회 | `MembershipSBT` 컨트랙트 |
| `GET /memberships/count?term_id=` → `{"count": 200}` | 백엔드 |

> **컨트랙트가 배포된 뒤에는 추가할 수 없습니다.** 구현은 이번 PR 범위 밖이지만
> 배포 전에 인터페이스에 자리를 잡아두어야 합니다.

---

## 6. 확답이 필요한 것

**① 정정 항목의 `amount` 는 증감분입니까, 새 총액입니까?**

앱은 **증감분**으로 구현했습니다. 50,000원을 30,000원으로 바로잡을 때 정정 항목의
금액은 `-20,000` 입니다. 근거는 `HASHING.md` §5("음수는 `corrects_entry_id` 가 있을
때만 허용")와 샘플 3 입니다.

**새 총액 방식이라면 앱의 합계 산출 로직(`EntryChain.finalAmount`,
`EntryMerge._sumOf`)을 바꿔야 합니다.** 확인 부탁드립니다.

**② ID 를 1부터 채번합니까?**

`0` 을 "없음"의 뜻으로 예약합니다 (`HASHING.md` §2.1). `budget_id = 0` 인 실제 예산이
있으면 NULL↔0 변환이 깨집니다.

---

## 참고

- 해시 규칙 정본: `docs/HASHING.md` · 테스트 벡터: `docs/hashing_vectors.json`
- 앱 쪽 구현 메모: `docs/student_screens.md` §3(검증) · §5(연동 현황)
- 앱은 `GET /balance` 를 호출하지 않습니다. 장부 잔액은 항목에서 직접 계산합니다
  (PRD §7.4 「체인 이벤트로 산출, DB 불신뢰」). 서버 값과 대조해 불일치를 보여주는
  기능은 후속으로 추가할 예정입니다.
