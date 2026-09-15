# HASHING — 해시 계산 규칙

작성 손종인 (`feat/backend-auth`) · 대상 백엔드·앱 전원 · 규칙 버전 **v1**

`docs/CONTRACTS.md`가 "구분자·인코딩 세부는 손종인이 확정 예정, 확정 전까지 각자 계산하지 말 것"이라고 미뤄둔 문서다. 이 문서의 값이 정본이며, **백엔드와 앱은 같은 입력에서 같은 해시가 나와야 한다.** 한 바이트만 달라도 학생 화면의 검증 배지가 전부 빨강으로 뜬다.

## 이 시스템의 해시 4종

함수가 두 가지(SHA-256 / keccak256)라 혼동하기 쉽다. 반드시 구분할 것.

| 대상 | 함수 | 규칙 |
| --- | --- | --- |
| `meta_hash` — 회계 항목 | **SHA-256** | §1 |
| 사유·이의 본문 등 텍스트 | **SHA-256** | §3 |
| 영수증·거래내역 파일 | **SHA-256** | §4 |
| `category` — 예산 항목명 | **keccak256** | `docs/CONTRACTS.md` |

`AccountingLedger.Entry.hash`는 SHA-256 출력 32바이트를 `bytes32`에 그대로 담는다. keccak이 아니다.

---

## 1. `meta_hash`

### 식

```
meta_hash = SHA256( amount ␟ counterparty ␟ purpose ␟ occurred_at ␟ receipt_hash )
```

`␟` 는 **U+001F (Unit Separator)** 한 글자다. 파이프(`|`)가 아니다.

> **왜 파이프가 아닌가** — 목적란은 자유 입력이라 총무가 `|`를 칠 수 있다. 그러면 서로 다른 거래가 같은 해시를 낸다. 실제로 재현된다.
> `상호="한결문구", 목적="명찰|필기구"` 와 `상호="한결문구|명찰", 목적="필기구"` 는 파이프 방식에서 preimage가 완전히 같아진다.
> U+001F는 키보드로 입력할 수 없는 제어문자라 이 충돌이 구조적으로 생기지 않는다.

### 필드 규칙

| 필드 | 형식 | 비고 |
| --- | --- | --- |
| `amount` | 10진수 문자열. `35000`, 음수는 `-20000` | 따옴표·천단위 쉼표·`+` 금지. 정정 항목만 음수 |
| `counterparty` | **정본 문자열 그대로** (§1.1) | 빈 문자열 불가 |
| `purpose` | **정본 문자열 그대로** (§1.1) | 빈 문자열 불가 |
| `occurred_at` | Unix 초 10진수 문자열. `1757300000` | ISO 문자열 아님. 컨트랙트 `occurredAt`과 동일 |
| `receipt_hash` | 소문자 hex, `0x` 접두사 포함 | **NULL이면 빈 문자열.** 구분자는 그대로 둔다 |

- 인코딩은 **UTF-8 고정**
- 결과는 소문자 hex 64자에 `0x` 접두사. 컨트랙트에 넘길 때는 `0x`를 떼고 32바이트로 변환한다
- 필드 순서는 위 표 그대로. 바꾸지 말 것
- `occurred_at`은 **초 단위로 절삭해 저장**한다. DB 컬럼이 `timestamptz`라 마이크로초까지 들어가면, 나중에 원본에서 해시를 재계산할 때 절삭이냐 반올림이냐에 따라 값이 갈린다 → 김경윤 ERD 반영 필요

> **`meta_hash`는 고유 식별자가 아니다.** 상호·금액·날짜·목적이 같으면 서로 다른 두 거래라도 같은 값이 나온다. DB 유니크 인덱스나 중복 판정 키로 쓰면 안 된다. 중복 탐지는 OCR 승인번호 조합(`ocr_approval_no` + `ocr_paid_at` + `amount`)이 담당한다 (PRD §6).

> **EIP-712 서명 해시(digest)와는 별개 값이다.** `RecordRequest.hash` / `ConfirmApproval.hash` 필드에 들어가는 것이 `meta_hash`이고, 기기가 실제로 서명하는 digest는 그 struct 전체를 EIP-712로 인코딩한 다른 값이다. 둘을 섞으면 `InvalidSignature`로 revert 된다.

### 1.1 정본 문자열 — 언제 누가 다듬는가

**텍스트는 백엔드가 저장 시점에 한 번만 다듬고, 그 값이 정본이다. 해시할 때는 다시 가공하지 않는다.**

저장 시점 처리 순서:

1. 앞뒤의 **U+0020(공백)만** 제거한다
2. **NFC 정규화**한다
3. 그 결과를 DB에 저장한다. 이후 모든 해시 계산은 이 값을 그대로 쓴다

**방어는 두 겹이다.**

**1차 — 입력 거부.** 보이지 않는 문자가 들어오면 400으로 막는다.

| 거부 대상 | 이유 |
| --- | --- |
| 제어문자 U+0000 ~ U+001F (**탭 U+0009 포함**) | 구분자 U+001F 충돌 차단 |
| U+00A0 NBSP, U+200B ZWSP, U+3000 전각공백, U+FEFF BOM | 눈에 안 보이면서 해시를 바꾼다 |

**탭도 거부 대상이므로 trim 대상에 넣지 않는다.** 넣어봐야 입력 단계에서 이미 걸러져 도달하지 않는다.

**2차 — trim 범위를 좁게 고정.** 1차를 통과한 뒤에도 언어 기본 `trim`을 쓰면 값이 갈릴 수 있다. 실측 결과:

> | 문자 | Python `strip()` | Dart·JS `trim()` |
> | --- | --- | --- |
> | U+0020 공백 / U+0009 탭 / U+00A0 NBSP / U+3000 전각공백 | 지움 | 지움 |
> | U+200B ZWSP | 남김 | 남김 |
> | **U+FEFF BOM** | **남김** | **지움** |

BOM은 1차에서 이미 막는다. 그래도 언어 기본 `trim`은 이런 문자를 말없이 건드리므로, **지울 문자를 U+0020 하나로 못박아** 2차 안전망을 둔다. 1차 검증에 구멍이 나거나 나중에 규칙이 완화돼도 해시는 갈리지 않는다.

파트별로 이렇게 갈린다.

| 주체 | 하는 일 |
| --- | --- |
| 백엔드 | 저장 시점에 위 3단계 수행. 이후 정본 값으로 해시 |
| 총무·감사 앱 | 서명할 해시를 **직접 계산**해야 하므로 같은 3단계를 적용 |
| 학생 앱 | API가 내려준 정본 값을 **가공 없이 그대로** 해시 |

학생 앱이 다시 다듬으면 오히려 값이 갈린다. 받은 값을 그대로 쓴다.

### 1.2 NFC 정규화

같은 글자라도 정규화가 다르면 다른 바이트다.

```
NFC '한결문구'   4 글자,  sha=dde9ab2bfb3d8f5d…
NFD '한결문구'  11 글자,  sha=9c718897c7937b30…
```

macOS·iOS 경로나 일부 입력기에서 NFD(조합형)가 들어온다.

### 1.3 샘플

구분자가 눈에 보이지 않으므로 hex를 같이 싣는다. 구현 후 이 값이 그대로 나오는지 대조할 것.

**같은 값이 `docs/hashing_vectors.json`에 기계가 읽을 수 있는 형태로 들어 있다.** 백엔드 유닛테스트와 앱 테스트는 그 파일을 읽어서 검증한다. 문서에서 눈으로 옮겨 적으면 오타로 값이 갈린다. 파일에는 파이프 구분자 충돌과 BOM 처리까지 확인하는 부정 케이스도 함께 있다.

**샘플 1 — 지출, 영수증 있음**

```
amount        35000
counterparty  한결문구
purpose       신입생 환영회 명찰 및 필기구 구매
occurred_at   1757300000
receipt_hash  0xabc1234567890abcdef1234567890abcdef1234567890abcdef1234567890abc

preimage   35000␟한결문구␟신입생 환영회 명찰 및 필기구 구매␟1757300000␟0xabc1234...
hex        33353030301fed959ceab2b0ebacb8eab5ac1fec8ba0ec9e85ec839d20ed9998ec9881ed9a8c20ebaa85ecb0b020ebb08f20ed9584eab8b0eab5ac20eab5aceba7a41f313735373330303030301f307861626331323334353637383930616263646566313233343536373839306162636465663132333435363738393061626364656631323334353637383930616263

meta_hash  0x2e66f4be0afea4b6e81eb8cd981dddc2f357e72da0567782c946aa18cc39c05d
```

**샘플 2 — 수입, 영수증 없음** (`receipt_hash`가 NULL이라 마지막이 빈 값으로 끝난다)

```
amount        5000000
counterparty  컴퓨터공학과 학생회비 일괄 납부
purpose       2026-2학기 학과 학생회비 수납
occurred_at   1757100000
receipt_hash  (NULL)

preimage   5000000␟컴퓨터공학과 학생회비 일괄 납부␟2026-2학기 학과 학생회비 수납␟1757100000␟
hex        353030303030301fecbbb4ed93a8ed84b0eab3b5ed9599eab3bc20ed9599ec839ded9a8cebb98420ec9dbceab48420eb82a9ebb6801f323032362d32ed9599eab8b020ed9599eab3bc20ed9599ec839ded9a8cebb98420ec8898eb82a91f313735373130303030301f

meta_hash  0x70ad6e3e77e4041042c0056123de607d0b8c6184cc2a764b53578f06d46e531b
```

**샘플 3 — 정정, 금액 음수**

```
amount        -20000
counterparty  한결문구
purpose       입력 오류 정정
occurred_at   1757300000
receipt_hash  (NULL)

preimage   -20000␟한결문구␟입력 오류 정정␟1757300000␟
hex        2d32303030301fed959ceab2b0ebacb8eab5ac1fec9e85eba0a520ec98a4eba59820eca095eca0951f313735373330303030301f

meta_hash  0x13a26a42fc46ec3031d6e2437a00ac3273239a7a1582058b61574b70a5bf08ad
```

---

## 2. 검증 범위 — 해시만 비교하면 안 된다

**`meta_hash`는 항목의 절반만 덮는다.** 아래 필드는 해시에 들어가지 않는다.

| 해시가 덮는 것 | 해시가 덮지 않는 것 |
| --- | --- |
| `amount`, `counterparty`, `purpose`, `occurred_at`, `receipt_hash` | `kind`, `budget_id`, `corrects_entry_id`, `term_id`, `status` |

실측이다. 아래는 `amount=35000`, `counterparty=한결문구`, `purpose=명찰 구매`, `occurred_at=1757300000`, `receipt_hash=NULL` 인 항목이다. `kind`를 EXPENSE에서 INCOME으로 바꿔도, `budget_id`를 2에서 7로 바꿔도 `meta_hash`는 **한 글자도 변하지 않는다.**

```
지출 35000원, budget_id=2, kind=EXPENSE  -> dcb7f08be972d9e784f729d5…
kind=INCOME 으로 변조                     -> dcb7f08be972d9e784f729d5…  (불변)
budget_id=7 로 변조                      -> dcb7f08be972d9e784f729d5…  (불변)
```

그러므로 **검증 배지(S4)가 해시만 비교하면 수입·지출 뒤바꾸기와 예산 항목 옮기기를 탐지하지 못한다.**

다행히 이 값들은 **체인에서 직접 읽을 수 있다.** 읽는 방법이 둘이고 쓰임이 다르다.

| 방법 | 쓰는 곳 | 이유 |
| --- | --- | --- |
| **조회 함수** — `getEntry(id)` · `statusOf(id)` · `getBudget(budgetId)` | **단건 검증** (배지) | 호출 한 번으로 필요한 필드를 전부 얻는다 |
| **이벤트** — `EntryPending` · `EntryConfirmed` 등 | **집계** (잔액·집행률·결산) | 전체를 훑어야 하므로 로그가 맞다 (PRD §7.4) |

둘 다 체인 상태를 읽는 것이라 신뢰도는 같다. `eth_call`이냐 `eth_getLogs`냐의 차이일 뿐이다. **단건 검증에 이벤트를 쓸 이유는 없다.**

`getEntry(id)`가 돌려주는 `Entry`에 검증에 필요한 값이 모두 들어 있다.

```
Entry { hash, amount, kind, status, occurredAt, budgetId, correctsId, registrant, approver }
```

**검증 절차**

1. 원본 필드로 `meta_hash`를 재계산해 `getEntry(id).hash`와 비교
2. 아래 필드를 `getEntry(id)` 값과 **직접 비교**

| 비교할 필드 | DB / API 쪽 | 비고 |
| --- | --- | --- |
| `amount` | `amount` | |
| `kind` | `kind` | enum 순서는 `docs/enums.md` |
| `budgetId` | `budget_id` | **NULL → 0** (§2.1) |
| `correctsId` | `corrects_entry_id` | **NULL → 0** (§2.1) |
| `status` | `status` | |
| `registrant` | `created_by` | **주소 ↔ user id 매핑 필요** (아래) |
| `approver` | `approved_by` | 주소 ↔ user id 매핑. 미처리면 `address(0)` ↔ `NULL` |
| `occurredAt` | `occurred_at` | 해시에도 들어가지만 따로 봐도 된다 |

`term_id`는 이 목록에 없다. 지출은 `budgetId`를 거쳐 확인하고, 수입은 확인할 방법이 없다 (§2.3).

2번을 빠뜨리면 반쪽짜리 검증이다. 해시 식은 PRD §8이 고정한 것이라 바꾸지 않고, 비교 대상을 늘려서 메운다.

> **`registrant` / `approver`는 지갑 주소이고 DB의 `created_by` / `approved_by`는 user id다.** 값 자체가 달라서 그냥 비교하면 안 되고, `User.wallet_address`로 옮긴 뒤 대조해야 한다. **이 두 필드가 "누가 등록하고 누가 승인했는가"의 유일한 온체인 증거**이므로 빠뜨리면 안 된다. 주소 매핑은 인증 파트(손종인)가 API로 내려준다.

### 2.1 NULL과 0 — 비교 전에 맞춰야 한다

**DB는 값이 없을 때 `NULL`을 쓰고 체인은 `0`을 쓴다.** 이 변환을 빼먹으면 정상 항목이 위조로 판정된다.

| DB / API | 체인 | 해당하는 항목 |
| --- | --- | --- |
| `budget_id = NULL` | `budgetId = 0` | **모든 수입 항목** |
| `corrects_entry_id = NULL` | `correctsId = 0` | **정정이 아닌 모든 항목** |
| `approved_by = NULL` | `approver = address(0)` | **승인 대기 중인 모든 항목** |
| `reject_reason = NULL` | `reasonHash = bytes32(0)` | 반려되지 않은 항목 |

원장의 대부분이 여기 걸린다. 그냥 비교하면 `None != 0`이라 배지가 거의 전부 빨강이 된다. **비교 전에 `NULL`을 `0`으로 맞춘 뒤 대조한다.**

이게 성립하려면 **ID를 1부터 채번해야 한다.** `0`을 "없음"의 뜻으로 예약하므로 `budget_id = 0`인 실제 예산이 존재하면 안 된다. → 김경윤 확인 필요

### 2.2 상태별 검증 범위

확정 항목만 검증 대상이 아니다. PRD §4.3은 등록 즉시 Pending을 온체인에 올려 학생 앱에 "승인대기"로 노출한다.

| 항목 상태 | 해시 검증 | 비고 |
| --- | --- | --- |
| `PENDING` | 가능 | |
| `CONFIRMED` | 가능 | |
| `REJECTED` | 가능 | 반려는 `PENDING`에서만 가능하므로 `Entry`가 남아 있다 |
| `BLOCKED` | 가능 | 예산 검사에 걸려도 `Entry`는 저장된다 (`IAccountingLedger`: "revert 하지 않고 BLOCKED 로 저장") |

이벤트만 보면 `EntryRejected`·`EntryBlocked`에 `hash`가 없어 검증이 안 되는 것처럼 보인다. **`getEntry(id)`를 쓰면 네 상태 모두 검증된다.**

**승인 전 수정은 새 id로 다시 등록된다.** 같은 내용의 항목이 여러 건 남을 수 있으므로, 각 항목은 **자기 id의 체인 값과만** 비교한다. 이전 id의 기록이 체인에 남아 있는 것은 정상이다 (PRD T4 "이전 기록 잔존").

### 2.3 `term` — 지출만 검증된다

`term`은 `Entry`에도 이벤트에도 없다. 다만 지출은 예산을 거쳐 도달할 수 있다.

```
EXPENSE   entry.budgetId → getBudget(budgetId).term      검증 가능
INCOME    budgetId = 0 이라 거쳐 갈 예산이 없다            검증 불가
```

**수입 항목의 학기만 DB 값을 믿는 수밖에 없다.** 학기별 총수입(S1)이 여기 걸린다. 컨트랙트에 `term` 추가를 요청해 둔 상태다 (§8).

---

## 3. 텍스트 해시

컨트랙트가 `bytes32`로 받는 본문 해시들이다. 필드가 하나뿐이라 구분자가 없다.

```
SHA256( 정본 문자열 )   — 아래 「여러 줄 텍스트 규칙」으로 다듬은 값, UTF-8
```

> `meta_hash` 필드(§1.1)와 **다듬는 규칙이 다르다.** 여기는 여러 줄을 허용하므로 개행 처리가 추가된다.

| 값 | 쓰이는 곳 |
| --- | --- |
| `warningReasonHash` | 경고 무시 승인 사유 (`confirmEntry`) |
| `reasonHash` | 반려 사유 (`rejectEntry`), 예산 개정 사유 (`increase`) |
| `contentHash` | 이의 본문 (`raise`) |
| `answerHash` | 이의 답변 (`answer`) |

값이 없으면 `bytes32(0)`을 넘긴다. 빈 문자열을 해시하지 않는다.

**여러 줄 텍스트 규칙** — 이의 본문과 반려 사유는 여러 줄일 수 있다. `meta_hash` 필드와 달리 **줄바꿈을 허용한다.** 필드가 하나뿐이라 구분자 충돌이 없기 때문이다.

- 제어문자 중 **허용하는 것은 `U+0009`(탭)와 `U+000A`(LF) 둘뿐이다.** 나머지(`U+000B` VT, `U+000C` FF, `U+001F` 등)는 400으로 거부한다. 보이지 않는 공백류 금지는 `meta_hash` 필드와 같다(§1.1)
- **개행은 LF로 통일한다.** 입력의 `CRLF`·`CR`은 저장 전에 `LF`로 바꾼다. 웹(Windows)과 모바일이 서로 다른 개행을 보내면 같은 글인데 해시가 갈린다
- **앞뒤에서 제거할 문자는 `U+0020`·`U+0009`·`U+000A` 셋으로 고정한다.** 사용자가 끝에 엔터나 탭을 치면 값이 달라지기 때문이다

> **여기서도 언어 기본 `trim`을 쓰면 안 된다.** `meta_hash` 필드와 같은 이유다(§1.1). 탭을 제거 대상에 넣은 것도 그래서다 — 탭은 이 필드에서 합법인데 Dart·JS의 `trim()`은 지우고 Python의 `strip(" \n")`은 남긴다. 제거 문자를 셋으로 못박아 양쪽을 맞춘다.

```
"OCR 금액 불일치, 영수증 원본 확인함"  -> 0x41357b2c4497cfd0b66c43ad57242c82c8850c666e229aea0ca7ded5052e54fb
"영수증 미첨부 사유가 궁금합니다"        -> 0x2a737959edd39d9f96fc6015c21127aae8882ebf3a18230dab18a4f9e1093597
```

---

## 4. 파일 해시

**파일은 바이트 그대로 해시한다. 정규화·트림을 하지 않는다.** 텍스트 규칙을 적용하면 안 된다.

```
SHA256( 파일 원본 바이트 )
```

| 대상 | 비고 |
| --- | --- |
| `receipt_hash` | 영수증 이미지 원본. `meta_hash`의 입력이 된다 |
| 거래내역 CSV 해시 | PRD v0.7 §4.6 — 업로드 파일 해시를 온체인 기록 |

```
CSV 예시 -> 0xed6a74f157c79bec09aec2b1f9b8dde80ac22e46fe31fda31928fa13eedf5bd2
```

### 누가 계산하고 누가 검증하는가

**파일을 먼저 올리고, 항목 등록은 그 뒤에 한다.** 순서가 바뀌면 서버가 대조할 대상이 없다.

1. **앱이 파일을 업로드한다.** 이때 **전송할 바이트 그대로**를 해시한 `receipt_hash`를 함께 보낸다. **hex는 생성 시점부터 소문자로 만든다** — 대문자로 보내면 서버가 400으로 거부한다(§5). 서버가 말없이 소문자로 고치면 앱이 서명용으로 계산한 `meta_hash`와 값이 갈려 승인 시점에 `HashMismatch`로 revert 되기 때문에, 등록 단계에서 막는다
2. 서버는 받은 바이트를 **가공 없이 저장**하고, **저장한 바이트로 해시를 재계산해 대조**한다. 불일치면 400
3. **항목 등록(`POST /entries`)은 이미 저장된 `receipt_hash`만 참조한다.** 대응하는 파일이 없는 `receipt_hash`가 오면 400

> **왜 순서를 고정하는가** — 등록 요청에 해시만 오고 파일이 나중에 올라오면, 서버는 재계산할 대상이 없는 채로 `meta_hash`를 만들어 온체인에 올리게 된다. 그러면 **`receipt_hash`는 있는데 파일은 없는(또는 다른 파일인) 항목**이 생기고, 해시는 서로 맞으니 검증 배지는 초록으로 뜬다. 존재하지 않는 영수증이 검증을 통과하는 셈이다.

**앱이 촬영 후 압축·리사이즈를 하려면 그 결과 바이트를 해시해야 한다.** 원본을 해시하고 리사이즈본을 올리면 서버 재계산에서 걸린다. 서버도 썸네일 생성 등으로 원본을 덮어쓰면 안 된다.

CSV는 은행에서 받은 파일을 **그대로** 해시한다. 인코딩(CP949 등)을 변환하면 해시가 달라진다.

---

## 5. 입력 검증 (백엔드)

해시 규칙이 성립하려면 입력이 제한돼야 한다.

- **`meta_hash`에 들어가는 텍스트**(`counterparty`, `purpose`) — 제어문자(U+0000 ~ U+001F) **전면 금지** -> 400. 한 줄 입력이라 개행이 필요 없다. 구분자 충돌을 막는 것은 이 중 U+001F 금지이고, 나머지는 보이지 않는 문자를 함께 걸러내기 위한 것이다
- **텍스트 해시 대상**(반려 사유·개정 사유·이의 본문·답변) — `U+001F`만 금지하고 **개행은 허용**한다 (§3)
- **보이지 않는 공백류 금지** — U+00A0, U+200B, U+3000, U+FEFF -> 400 (§1.1). 두 종류 모두에 적용
- `counterparty`, `purpose`는 다듬은 뒤 **빈 문자열이면 400**
- `amount`는 정수. 0 금지. 음수는 `corrects_entry_id`가 있을 때만 허용
- `occurred_at`은 Unix 초 정수
- `receipt_hash`는 `0x` + **소문자** hex 64자 또는 NULL. **대문자가 오면 400.** 서버가 소문자로 고쳐 저장하면 앱이 서명한 `meta_hash`와 값이 갈린다 (§4)

---

## 6. 구현

**Python (백엔드)**

```python
import hashlib, unicodedata

US = "\x1f"
TRIM = " "            # U+0020 만. 탭은 입력 단계에서 거부된다 (§1.1)

def canonical(s: str) -> str:
    """저장 시점에 한 번만 호출. 결과가 정본."""
    return unicodedata.normalize("NFC", s.strip(TRIM))

def meta_hash(amount: int, counterparty: str, purpose: str,
              occurred_at: int, receipt_hash: str | None) -> str:
    # counterparty, purpose 는 이미 canonical 을 거친 정본 값
    pre = US.join([str(amount), counterparty, purpose,
                   str(occurred_at), receipt_hash or ""])
    return "0x" + hashlib.sha256(pre.encode("utf-8")).hexdigest()

TRIM_TEXT = " \t\n"   # U+0020, U+0009, U+000A (§3)

def canonical_text(s: str) -> str:
    """여러 줄 텍스트용 (§3). 개행을 LF 로 통일하고 앞뒤 공백·탭·개행을 제거한다."""
    s = s.replace("\r\n", "\n").replace("\r", "\n")
    return unicodedata.normalize("NFC", s.strip(TRIM_TEXT))

def text_hash(text: str) -> str:
    # text 는 canonical_text 를 거친 정본 값이어야 한다
    return "0x" + hashlib.sha256(text.encode("utf-8")).hexdigest()

def file_hash(data: bytes) -> str:
    return "0x" + hashlib.sha256(data).hexdigest()
```

**Dart (앱)**

```dart
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

const _us = '\u001F';

/// 총무·감사 앱에서 서명용 해시를 직접 만들 때만 사용.
/// 학생 앱은 API 가 준 값을 그대로 쓰고 이 함수를 호출하지 않는다.
String canonical(String s) {
  var t = s;
  while (t.startsWith(' ')) { t = t.substring(1); }              // U+0020 만
  while (t.endsWith(' '))   { t = t.substring(0, t.length - 1); }
  return unorm.nfc(t);
}

String metaHash({
  required int amount,
  required String counterparty,
  required String purpose,
  required int occurredAt,
  String? receiptHash,
}) {
  final pre = [
    '$amount', counterparty, purpose, '$occurredAt', receiptHash ?? '',
  ].join(_us);
  return '0x${sha256.convert(utf8.encode(pre))}';
}

/// §3 여러 줄 텍스트용. 개행을 LF 로 통일하고 앞뒤 공백·탭·개행을 제거한다.
/// 감사 앱이 warningReasonHash / reasonHash 를 서명 전에 직접 만들 때 쓴다.
String canonicalText(String s) {
  var t = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  bool edge(String c) => c == ' ' || c == '\t' || c == '\n';
  while (t.isNotEmpty && edge(t[0])) { t = t.substring(1); }
  while (t.isNotEmpty && edge(t[t.length - 1])) { t = t.substring(0, t.length - 1); }
  return unorm.nfc(t);
}

/// 인자는 canonicalText 를 거친 정본 값이어야 한다.
String textHash(String text) => '0x${sha256.convert(utf8.encode(text))}';

/// 파일은 바이트 그대로 (§4). 정규화·트림을 하지 않는다.
String fileHash(List<int> bytes) => '0x${sha256.convert(bytes)}';
```

> **Dart 주의** — 표준 라이브러리에 유니코드 정규화가 없다. `crypto`만으로는 NFC를 못 한다. `unorm_dart` 같은 패키지를 `pubspec.yaml`에 추가해야 한다.
> `String.trim()`은 쓰지 말 것. BOM 처리가 Python과 다르다 (§1.1).

Python과 Node로 독립 구현해 위 샘플 3건이 동일하게 나오는 것을 확인했다. Dart 구현 후에도 같은 값이 나오는지 대조할 것.

---

## 7. 규칙이 바뀌면

규칙을 한 번이라도 고치면 **이미 확정된 항목의 배지가 전부 깨진다.** 온체인 해시는 옛 규칙으로 계산된 값이기 때문이다.

그래서 `Entry`에 `hash_version` 컬럼(기본값 `1`)을 두기를 제안한다. 규칙이 바뀌면 새 항목만 `2`로 쌓고, 검증할 때 버전에 맞는 계산식을 쓴다. 나중에 추가하려면 이미 늦다. -> 김경윤 ERD 반영 요청

**이 문서와 `docs/hashing_vectors.json`은 `.github/CODEOWNERS` 대상이다.** `docs/enums.md`를 보호하는 이유("상태값이 어긋나면 백엔드와 앱이 조용히 안 맞는다")가 여기에도 그대로 적용되며, 결과는 더 크다. 값이 어긋나면 이미 확정된 항목의 배지까지 전부 깨진다. 규칙을 바꾸는 PR은 손종인 승인을 거친다.

---

## 8. 열린 항목

- **거래내역 CSV 해시를 온체인에 남길 함수가 없다.** PRD v0.7 §4.6이 "파일 해시를 온체인 기록"을 요구하는데, 병합된 `IAccountingLedger`에는 PRD §7.2의 `recordBankSnapshot`조차 빠져 있다. 장석연·문승준과 확인 필요
- `Snapshot` 테이블(PRD §8)에 업로드 파일 해시를 담을 컬럼이 없다
- **`0x` 접두사 표기가 팀 안에서 엇갈린다.** 병합된 목업 스키마(`backend/app/schemas/entry.py`)는 `0x` 포함인데, 닫힌 PR #5의 API 명세 초안은 `0x` 없이 적혀 있었다. 이 문서 기준(`0x` 포함)으로 김경윤과 정렬 필요
- 검증용 원본 필드를 내려주는 API(`GET /entries/{id}/verify` 등)가 아직 없다. §2의 이벤트 필드 비교까지 가능한 응답 형태가 필요하다
- **수입 항목의 `term`을 검증할 방법이 없다.** 지출은 `budgetId → getBudget().term`으로 도달하지만 수입은 `budgetId = 0`이라 거쳐 갈 예산이 없다(§2.3). `Entry`나 이벤트에 `term`을 넣어달라고 장석연에게 요청한다. 이벤트는 배포 후 바꿀 수 없으므로 구현 착수 전에 정리돼야 한다 (PR #3 리뷰로 이미 요청)
- **ID 채번을 1부터 시작해야 한다.** `0`을 "없음"으로 예약하기 때문이다(§2.1). 김경윤과 확인
