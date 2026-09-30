# CONTRACTS

인터페이스: `contracts/interfaces/`. 시그니처·이벤트·에러의 정본은 `.sol` 파일이고 이 문서는 요약이다.

## 컨트랙트 목록

| 컨트랙트 | 역할 |
| --- | --- |
| `RoleManager` | 임원 롤(TREASURER / AUDITOR / PRESIDENT). 롤 식별자는 `keccak256("TREASURER")` 등 이름 해시(`bytes32`), enum 인덱스 아님. 일반 변경은 회장+감사 서명, 회장 키 분실은 감사 2명 + 72시간 대기로 복구 |
| `BudgetToken` | 학기+항목 1줄 단위 예산 한도·소모액. 발행·회수는 회장 서명, 증액은 회장+감사 서명. `spend/refund`는 `AccountingLedger`만 호출 |
| `AccountingLedger` | 수입·지출 원장. 확정 항목 수정 불가, 정정은 `correctsId`로 원본을 가리키는 새 항목 |
| `MembershipSBT` | 학기 단위 학생 회원 증명. 전송 불가. 학번은 `keccak256(studentId, salt)` 커밋만 |
| `ObjectionRegistry` | 학생 이의 제기·답변. 해시만 온체인. entry 상태에 영향 없음 |

거래내역 CSV 파일 해시를 남기는 `recordBankSnapshot`은 원장에 넣지 않는다. 별도 컨트랙트로 추후 설계한다 (문승준과 필드·서명 주체 확정 후).

## 공통 규칙

- **임원의 모든 쓰기는 기기 EIP-712 서명 + 서버 릴레이어 제출이다** (PRD §9.2). 임원 지갑이 직접 트랜잭션을 보내는 함수는 없다. 서명 없이 부를 수 있는 쓰기는 셋뿐이다: 배포자의 `setLedger` 1회, 릴레이어 신뢰인 `raise`, 대기가 끝난 회장 복구를 실행하는 `executePresidentRecovery`(누구나. 실행 조건은 저장된 감사 2명의 제안이 정한다).
- ID(`budgetId`, `entryId`, `objectionId`)는 백엔드 DB auto-increment 값을 파라미터로 받는다. 컨트랙트는 중복만 막는다. SBT `tokenId`와 RoleManager `nonce`만 온체인 카운터. ID는 1부터 시작한다 (`0`은 "없음"). `0`으로 등록·발행하면 `ReservedId`로 revert하며, 중복(`…AlreadyExists`)과 구분된다.
- 금액은 원 단위 정수. 요청의 `amount`는 `int256`, `correctsId != 0`인 정정 항목만 음수 허용. 상한 `MAX_AMOUNT = 10^15`원(`AmountOutOfRange`).
- 이벤트에 기록 시각을 넣지 않는다 (블록에 있음). 발생 시각 `occurredAt`은 파라미터.
- enum 온체인 순서 = `docs/enums.md` 표 순서. `ocr_status`는 온체인에 올리지 않는다.
- 롤은 enum이 아니라 `bytes32 = keccak256(utf8("TREASURER"))` 등 이름 해시. `RoleManager`가 `TREASURER()` / `AUDITOR()` / `PRESIDENT()`로 노출하므로 백엔드는 하드코딩 대신 읽어가도 된다.
- `INCOME` 항목은 `budgetId = 0`. `budgetId != 0`이면 revert(`BudgetIdNotAllowedForIncome`). 예산 검사·소모는 `EXPENSE`에만 적용된다.
- 예산 초과 검사는 등록 시점(초과·마감·미존재면 revert 없이 `BLOCKED` 저장 + `EntryBlocked`), 예산 소모는 확정 시점(잔량 부족·마감이면 revert). `budgetId = 0`인 지출은 `BUDGET_NOT_FOUND`로 `BLOCKED`.
- 등록 시점 검사는 잔량만 보고 대기 건을 예약하지 않는다. 대기 A(10만) + 대기 B(10만), 잔량 15만이면 둘 다 `PENDING`으로 들어가고, A 확정 후 B 확정은 `InsufficientBudget`으로 revert 한다. revert 시 온체인 상태는 `PENDING` 그대로이므로 앱은 "예산 부족 → 반려" 흐름으로 `rejectEntry`를 호출해야 한다.
- 승인자(확정·반려 서명자)는 `AUDITOR` 또는 `PRESIDENT`. 등록자 ≠ 승인자는 별도로 검사한다 (PRD §3: 회장은 감사와 동일 승인 권한). 앱 분기: `hasRole(AUDITOR) || hasRole(PRESIDENT)`.
- **승인자·반려자는 `entryCommit`에도 서명한다.** `meta_hash`에는 kind·term·budgetId·correctsId가 없어서, 해시만 대조하면 총무가 다른 예산으로 등록해도 승인이 통과한다. 아래 식으로 등록된 값 전체를 묶는다. 다르면 `EntryCommitMismatch`. 확정(`ConfirmApproval`)과 반려(`RejectDecision`) 둘 다 담는다.
  ```
  entryCommit = keccak256(abi.encode(bytes32 hash, int256 amount, uint8 kind, uint256 term, uint256 occurredAt,
                                     uint256 budgetId, uint256 correctsId, address registrant))
  ```
  ethers: `keccak256(AbiCoder.defaultAbiCoder().encode(["bytes32","int256","uint8","uint256","uint256","uint256","uint256","address"], [...]))`. 원장의 `entryCommitOf(id)`로 체인 값을 조회해 대조할 수 있다. `meta_hash` 공식(PRD §8)은 바꾸지 않는다.
- **`hash`는 0이 아니어야 한다**(`HashRequired`). 학생 앱은 0 해시를 "아직 기록 안 됨"으로 읽어서, 0이 올라가면 변조가 "알 수 없음"으로 가려진다.
- **`confirmEntry`의 revert는 BudgetToken 에러일 수 있다.** 잔량 부족(`InsufficientBudget`)·마감(`BudgetExpired`)은 BudgetToken이 내고 원장을 통과해 그대로 올라온다. 두 에러를 `IAccountingLedger`에도 같은 시그니처로 선언해 두었으므로 원장 ABI 하나로 해석하면 된다.
- **사유 해시 규칙.** 반려는 `reasonHash != 0` 필수(`ReasonRequired`). 확정은 `hadWarning == (warningReasonHash != 0)`이어야 한다. 경고인데 사유 0이면 `ReasonRequired`, 경고 아닌데 사유가 있으면 `ReasonNotAllowed`. 예산 증액도 사유 해시 필수. 해시 계산은 `docs/HASHING.md` §3.
- 요청의 `kind`가 0·1이 아니면 ABI 디코딩 단계에서 에러 데이터 없이 revert한다. 컨트랙트가 손쓸 수 없으니 백엔드가 먼저 막는다.

### term

- **`term`은 학기 코드 `YYYYS`다.** 연도 4자리 + 학기 1자리. `20261` = 2026년 1학기, `20262` = 2학기. 계절학기가 필요하면 `3`(여름)·`4`(겨울)을 쓴다. **DB의 `Term.id`가 아니다.** 백엔드는 Term 테이블에 이 코드를 두고 체인에는 코드를 넘긴다.
- 모든 항목과 예산에 있고, 원장에서는 서명 대상(`RecordRequest`)이다. `0`은 금지(`TermRequired`). 저장 폭은 `uint32`.
- 지출은 등록 시점에 예산의 `term`과 대조해 다르면 revert(`TermMismatch`). BLOCKED로 저장하지 않는다.
- 정정은 원본의 `term`과 같아야 한다(`TermMismatch`). 재분류나 수입 정정으로 학기를 옮기지 못한다.
- 정정이 아닌 수입은 대조할 대상이 없어 서명된 값을 그대로 저장한다.

### 정정

- 정정 항목은 `correctsId`로 원본을 가리키는 새 항목이다. 원본은 `CONFIRMED`여야 한다(`CorrectionTargetNotConfirmed`).
- **페어 필드는 없다.** `RECLASSIFY`는 양수 정정(새 예산 `spend`) + 음수 정정(원래 예산 `refund`) 2건으로 표현한다. 둘 다 `correctsId`는 원본.
- **순서는 서버 규칙: 양수 다음 음수.** `spend`는 잔량 부족·마감으로 실패할 수 있지만 `refund`는 원본 소모액 범위 안에서 항상 성공하기 때문이다.
- 음수 정정의 `budgetId`는 원본의 `budgetId`와 같아야 한다(`CorrectionBudgetMismatch`). `refund`가 엉뚱한 예산으로 가는 것을 막는다.
- 양수 정정도 일반 지출과 같이 등록 시 잔량 검사, 확정 시 `spend`를 거친다. 음수 정정은 등록 시 예산 판정을 건너뛴다(refund는 마감·잔량과 무관).
- **차액(`amount`)이 0인 정정은 등록 시 revert**(`ZeroAmount`). 일반 항목과 같은 검사에 걸린다. 새 에러를 두지 않는다.
- **정정의 `kind`·`term`은 원본과 같아야 한다**(`CorrectionKindMismatch` / `TermMismatch`).
- **정정 대상은 "정정 가능 항목"이어야 한다.** 원본(정정이 아닌 항목)이거나, 원본과 다른 `budgetId`로 간 양수 정정(재분류)이다. 같은 예산 양수 정정이나 음수 정정을 대상으로 하면 `InvalidCorrectionTarget`. 같은 금액이 원본과 정정 양쪽의 순금액에 잡혀 소모액보다 많이 refund되는 것을 막는다 (원본 35,000 → 같은 예산 +10,000 → 원본 대상 −45,000 → 정정 대상 −10,000이 모두 통과하던 구멍).
- **음수 정정의 범위는 대상별 누적으로 검사한다.** 정정 가능 항목마다 순금액 `netAmountOf(id)`를 둔다. 확정 시 자기 `amount`로 시작하고, 그 항목을 대상으로 하는 정정이 확정될 때마다 정정 `amount`를 더한다(음수면 빠진다). 재분류 양수 정정은 원본 순금액에 더하지 않고 자기 순금액을 새로 가진다. 같은 예산 양수 정정은 순금액을 갖지 않는다(대상의 순금액에 흡수). 음수 정정 확정으로 대상 순금액이 0 아래로 가면 `CorrectionExceedsOriginal`. 등록 시에도 현재 순금액으로 같은 검사를 먼저 해 조기에 걸러내지만, 대기 중인 다른 정정은 예약하지 않으므로 확정 시 검사가 최종이다. 수입·지출 모두 적용.
- 이 규칙들로 **예산별 누적 refund ≤ 누적 spend**가 항상 성립한다. 각 spend 금액은 정확히 하나의 정정 가능 항목의 순금액에 속하고, refund는 그 순금액 안에서만 나가기 때문이다.
- 예산 단위 상한(`RefundExceedsSpent`)과 원본 단위 상한(`CorrectionExceedsOriginal`)은 별개다. 둘 다 통과해야 refund가 실행된다.

### 예산 (BudgetToken)

- **한 학기·한 항목에 예산은 하나다.** 같은 `(term, category)`로 두 번째 발행은 `BudgetAlreadyIssued`. 한도를 늘리려면 증액을 쓴다. 회수된 뒤에도 같은 조합은 다시 발행할 수 없다. `budgetIdOf(term, category)`로 조회한다.
- `issued`는 **현재 한도**다. `remaining() = issued − spent`. 불변식: 항상 `spent <= issued`.
- **발행은 회장 서명 1개** (PRD §3 "예산 편성"은 회장 권한). `IssueRequest`에 서명하고 릴레이어가 제출한다.
- **개정은 증액만, 회장 요청 + 감사 승인 2개 서명** (PRD §4.1 "개정 사유 입력과 감사 승인이 필수"). 같은 `IncreaseRequest`에 회장과 감사가 서명한다. 사유 해시 0 금지(`ReasonRequired`). 요청의 `version`은 증액 전 현재 version이어야 하고(`VersionMismatch`), 증액마다 1 오르므로 한 서명은 한 번만 쓰인다. 마감이 지난 예산은 증액할 수 없다(`BudgetExpired`). `BudgetIncreased`에 요청자·승인자를 남긴다. 덮어쓰기 없음. 감액은 향후 과제.
- `refund`는 `spent`만 줄인다. 마감·회수 여부를 보지 않는다. 원본이 소모한 금액을 넘는 refund는 `RefundExceedsSpent`.
- **회수는 회장 서명 1개.** 마감(`expiresAt`) 뒤에만 가능하고 `issued`를 `spent`까지 내린다. 요청의 `amount`는 현재 잔량과 같아야 하고(`ReclaimAmountMismatch`), `reclaimCount`는 현재 회수 횟수여야 한다(`ReclaimCountMismatch`). 회수마다 횟수가 1 오르므로 한 서명은 한 번만 쓰인다. 금액 대조만으로는 같은 금액의 환불 뒤에 옛 서명을 다시 제출할 수 있어서 횟수를 따로 둔다. 회수 횟수는 `version`(개정 번호)과 별개다. 회수가 개정 번호를 올리면 학생 화면의 "v2" 표시와 결산의 개정 횟수 지표가 틀어진다. 재호출 가능. **`issued`는 회수 후 줄어든다. 최초 발행액·누적 증액은 이벤트(`Issued + Increased`)로 계산한다.** 회수된 예산에 refund가 오면 잔량이 다시 생기지만 마감이 지나 `spend`는 막히고, 회수를 다시 하면 된다.
- PRD §7.2의 `reclaim(uint256 term)`(학기 단위)과 달리 예산 단위로 회수한다. 학기 전환 시 회수·이월은 PRD §14 미결이라 더 세밀한 단위를 두었고, 학기 단위 회수는 서버가 그 학기 예산마다 호출하면 된다.
- `spend` / `refund` 호출자는 `AccountingLedger` 하나로 제한한다. 원장 주소는 **배포자가 `setLedger`로 한 번만 설정하고 잠근다.** 두 번째 호출은 `LedgerAlreadySet`. 원장의 `roleManager()`·`budgetToken()`이 맞지 않으면 `LedgerMismatch`. 설정 시 `LedgerSet` 이벤트.
- `issue`의 `term == 0`은 `TermRequired`, `category == 0`은 `CategoryRequired`. 해시 0은 시스템 전체에서 "없음"이라 예산 키로 쓸 수 없다.

### 롤 (RoleManager)

- **보유 규칙.** 회장 정확히 1명, 총무 정확히 1명, **감사 2명 이상**. 한 주소는 임원 롤을 하나만 가진다(`AlreadyOfficer`).
- **감사가 2명인 이유는 키 분실 복구다.** 키는 각자 휴대폰에 있어 기기 분실·교체가 반드시 생긴다(PRD §7.2). 감사가 2명이면 회장 키를 잃어도 감사 둘이 복구하고, 감사 한 명의 키를 잃어도 회장 + 다른 감사가 교체한다.

**일반 변경 — `changeRole`**

- 같은 `RoleChange(role, from, to, nonce, deadline)`에 **회장 1명 + 감사 1명**이 서명하고 릴레이어가 한 트랜잭션으로 제출한다(PRD §7.2·§9.2 "회장+감사 2인 서명"). 서명 순서는 자유다.
- **감사 둘만의 서명은 거부한다**(`PresidentRequired`). 감사가 여럿이면 회장 없이 감사끼리 회장·총무를 바꾸거나 감사를 늘릴 수 있기 때문이다.
- **총무는 서명 자격이 없다**(`NotGovernor`). 총무가 자기 두 번째 키를 감사로 올리는 경로를 막고, 감사 대상이 감사 교체에 관여하지 못하게 한다.
- `from`·`to` 조합: `from == 0` 신규 부여, `to == 0` 회수, 둘 다 있으면 교체. 둘 다 0이면 `ZeroAddress`.
- **회장·총무는 교체만 가능하다.** 보유자가 있는데 부여하면 `RoleCapacityExceeded`, 회수하면 `RoleMinimumViolated`. **감사는 부여 가능, 2명 이하일 때 회수 불가**(`RoleMinimumViolated`).
- **제안은 체인에 저장되지 않는다.** 서명은 `deadline`이 지나면 무효(`SignatureExpired`)이고, 전역 `nonce`가 변경마다 1 오르므로 한 변경이 실행되면 그 전에 받아 둔 다른 서명은 전부 무효(`InvalidNonce`)가 된다.
- 검사 순서: `SignatureExpired` → `InvalidNonce` → `UnknownRole` → `ZeroAddress` → `InvalidSignature` → `NotGovernor`(제안자, 승인자) → `SameSigner` → `PresidentRequired` → `RoleNotGranted` → `RoleAlreadyGranted` / `AlreadyOfficer` → `RoleCapacityExceeded` / `RoleMinimumViolated`.

**회장 복구 — 회장 키 분실 대비**

| 단계 | 함수 | 서명자 | 하는 일 |
| --- | --- | --- | --- |
| 제안 | `proposePresidentRecovery(PresidentRecovery, sigA, sigB)` | 감사 2명 | "현재 회장 → 새 회장" 제안을 저장. 실행 가능 시각 = 지금 + 72시간 |
| 취소 | `cancelPresidentRecovery(RecoveryCancel, sig)` | 현재 회장 | 대기 중 취소. 회장 키가 살아 있으면 여기서 끝난다 |
| 실행 | `executePresidentRecovery()` | 없음 (누구나) | 대기가 끝나면 교체 실행 |

- 대기 중인 복구는 한 건뿐이다. 새 제안은 이전 제안을 덮어쓴다. 조건이 깨진 옛 제안 때문에 복구가 잠기지 않게 하기 위함이다.
- **회장이 바뀌면 대기 중인 복구는 지워진다.** 일반 교체든 복구 실행이든 같다. 옛 회장을 겨냥한 제안이 그 사람이 나중에 다시 회장이 됐을 때 되살아나는 경로를 막는다.
- 실행 시점에 다시 검사한다: `from`이 여전히 회장인지(`RoleNotGranted`, 위 규칙의 안전망), 두 제안자가 여전히 감사인지(`NotAuditor`), `to`에 롤이 없는지(`AlreadyOfficer`). 대기가 안 끝났으면 `RecoveryNotReady`, 대기 중인 복구가 없으면 `NoPendingRecovery`.
- 제안은 전역 `nonce`를 소비하고(그 값이 `recoveryId`), 실행도 `nonce`를 1 올린다. 그 사이 받아 둔 일반 변경 서명은 무효가 된다.
- 실행 결과는 일반 변경과 같은 `RoleRevoked` / `RoleGranted` / `RoleChangeExecuted`로 남고, proposer·approver 자리에 두 감사가 들어간다.

**공통**

- 첫 회장·총무·감사 2명은 **생성자 인자**로 받는다. 네 주소는 서로 다르고 0이 아니어야 한다. 배포자는 어떤 롤도 갖지 않는다. OpenZeppelin AccessControl을 쓰지 않으므로 `DEFAULT_ADMIN_ROLE` 같은 상위 권한도 없다.
- 실행 결과는 `RoleGranted` / `RoleRevoked`로 남기고 **제안자와 승인자를 둘 다 담는다.** 변경 한 번마다 `RoleChangeExecuted(nonce, …)`를 하나 낸다. 교체일 때 같은 트랜잭션의 `RoleRevoked` + `RoleGranted`가 한 변경이라는 것을 이 이벤트로 묶는다. **생성자 부여는 `RoleGranted`의 proposer·approver가 0**이고, 그 값이 최초 부여의 표시다.

### 생성자·배포 순서

| 컨트랙트 | 생성자 인자 |
| --- | --- |
| `RoleManager` | `(president, treasurer, auditor1, auditor2)` — 서로 다른 네 계정 |
| `BudgetToken` | `(roleManager)` |
| `AccountingLedger` | `(roleManager, budgetToken)` — 0 이면 `ZeroAddress` |

배포 순서: `RoleManager` → `BudgetToken` → `AccountingLedger` → `BudgetToken.setLedger(ledger)`. 릴레이어 계정은 롤이 없다. 배포 스크립트가 끝나면 배포자에게 남는 권한은 없다.

### 저장 배치

배포 뒤에는 struct를 바꿀 수 없어 이번에 묶었다. 요청 struct(EIP-712 서명 대상)는 `uint256` 그대로 두고, 저장할 때만 좁힌다. 폭을 넘는 값은 `FieldOutOfRange` / `AmountOutOfRange`.

| struct | 슬롯 | 배치 |
| --- | --- | --- |
| `Entry` | 4 (이전 9) | `[hash] [amount int128 · budgetId u64 · correctsId u64] [registrant · occurredAt u64 · term u32] [approver · kind · status]` |
| `Budget` | 3 (이전 6) | `[category] [issued u128 · spent u128] [term u32 · expiresAt u64 · version u16 · reclaimCount u16]` |

`getEntry` / `getBudget`의 반환 튜플 순서가 위 필드 순서로 바뀌었다. 이름으로 읽으면 영향 없다. 항목 존재는 `registrant != 0`, 예산 존재는 `version != 0`으로 판정한다.

## entry.hash

`AccountingLedger`의 `Entry.hash` / `RecordRequest.hash` / `ConfirmApproval.hash` / `EntryPending.hash` / `EntryConfirmed.hash` / `EntryBlocked.hash`는 모두 같은 값으로, PRD §8의 `meta_hash`다.

> **계산 규칙의 정본은 `docs/HASHING.md`다.** 구현할 때는 반드시 그 문서를 볼 것. 아래는 요약이며, 어긋나면 `docs/HASHING.md`가 맞다.

```
meta_hash = SHA256( amount ␟ counterparty ␟ purpose ␟ occurred_at ␟ receipt_hash )
```

- `␟`는 **U+001F (Unit Separator)** 한 글자다. **파이프(`|`)가 아니다.** 목적란이 자유 입력이라 파이프를 쓰면 서로 다른 거래가 같은 해시를 낸다 (`docs/HASHING.md` §1).
- SHA-256 출력이 32바이트라 `bytes32`에 그대로 넣는다 (keccak 아님).
- 영수증은 `receipt_hash`로 이미 포함되므로 영수증 파일·OCR 결과는 따로 올리지 않는다.
- `confirmEntry`는 저장된 `hash`와 `ConfirmApproval.hash`가 다르면 `HashMismatch`로 revert. 승인자가 본 내용이 등록된 내용과 같다는 보증. 나머지 필드는 `entryCommit`이 보증한다.
- **EIP-712 서명 해시(digest)와는 별개 값**이다. `meta_hash`는 서명 대상 struct 안에 들어가는 필드이고, digest는 그 struct 전체를 EIP-712로 인코딩한 결과다.
- 필드 구분자·정수 표기·문자열 정규화·`receipt_hash` NULL 처리, 그리고 `reasonHash` 등 텍스트 해시와 파일 해시 규칙은 **`docs/HASHING.md`에서 확정됐다.** 샘플과 테스트 벡터는 `docs/hashing_vectors.json`에 있다.
- `term`·`kind`·`budgetId`는 `meta_hash`에 들어가지 않는다. 학생 앱 검증기는 이 필드들을 이벤트 값과 따로 비교해야 한다.

## category

`bytes32`. 백엔드가 `keccak256(utf8(name))`으로 만들어 넘긴다. 사람이 읽는 이름은 오프체인.

인코딩 규칙 — 어긋나면 같은 항목이 다른 예산으로 갈라진다:
- UTF-8, **NFC 정규화** (macOS 파일명 등에서 오는 NFD 조합형 금지)
- 앞뒤 공백 없음, 내부 공백 없음
- 아래 표의 문자열 그대로. 표에 없는 항목은 이 문서에 먼저 추가한 뒤 사용 (팀장 승인)

| kind | name | keccak256 |
| --- | --- | --- |
| INCOME | `학생회비` | `0x30196e0702394f886c610dd63afe744491e2280bc4cb254069b0f6bb4e673015` |
| INCOME | `지원금` | `0xc1f4cada6ae364d09f9fdc632a1c0d18e62e6052ada22798dc68eabdaa499068` |
| INCOME | `후원금` | `0xbd66760e2bca6f5a7157ad451da7b8ca350885207c7d905bca10eb981b4e3f60` |
| INCOME | `이자수입` | `0x52c162681bc81ae825905c23946c57727418da571123f7e53da0ed44d0affdd1` |
| EXPENSE | `행사비` | `0x813d3904998cb03bb83478bc9ef8d8773f1ea9f2eefdb23e69b21648ce468b32` |
| EXPENSE | `사업비` | `0x36f858ef3e10cb7c78dd328a3cfd4769e88665c15cab429d22ab28c5673f5aec` |
| EXPENSE | `운영비` | `0xe39a5129036c8d0d89c73a5a8de3b5413ee1e49f293fed41b1c13b59021f3fed` |
| EXPENSE | `홍보비` | `0xb175d782e82e1c65b459c5b5467c16e3345e97eb956ce5baeb8e3154a019c242` |
| EXPENSE | `복지비` | `0xad2641bd76a79e69a398d17e88b02219d8a19770df5c464efef4df97a3dbeaa5` |
| EXPENSE | `회의비` | `0x2432130db18b07c25bfee01014b43d019cfe7499c62b20cda021c3ea58f549ef` |
| EXPENSE | `비품비` | `0x372720e4f1ed05731d7cf07f23395e04ebc9618999cd47ae91487f3b9e47d646` |
| EXPENSE | `예비비` | `0xd9de0fb4fc1856737fa6b81fa4e42eb6d2a91948c82ad0f8e61eabc0818ac00d` |

> 항목 이름은 초안이다. 실제 학생회 예산서 항목에 맞춰 김경윤(회계·예산 API)과 확정할 것. 해시는 `ethers.keccak256(ethers.toUtf8Bytes(name))`로 재계산 가능.

## 함수

| 컨트랙트 | 함수 | 호출자 / 서명자 |
| --- | --- | --- |
| RoleManager | `changeRole(RoleChange, proposerSig, approverSig)` | 릴레이어 호출, 서명자 = 회장 1 + 감사 1 |
| RoleManager | `proposePresidentRecovery(PresidentRecovery, sigA, sigB)` | 릴레이어 호출, 서명자 = 감사 2명 |
| RoleManager | `cancelPresidentRecovery(RecoveryCancel, sig)` | 릴레이어 호출, 서명자 = 현재 회장 |
| RoleManager | `executePresidentRecovery()` | 누구나 (대기 72시간 뒤) |
| RoleManager | `hasRole`, `roleOf`, `holderCount`, `isGovernor`, `nonce`, `pendingRecovery`, `RECOVERY_DELAY`, `MIN_AUDITORS`, `DOMAIN_SEPARATOR` | view. `role`은 `bytes32` 이름 해시 |
| RoleManager | `TREASURER()`, `AUDITOR()`, `PRESIDENT()` | view. 롤 식별자 상수 |
| BudgetToken | `setLedger` | 배포자, 1회만 |
| BudgetToken | `issue(IssueRequest, sig)` | 릴레이어 호출, 서명자 = PRESIDENT |
| BudgetToken | `increase(IncreaseRequest, requesterSig, approverSig)` | 릴레이어 호출, 서명자 = PRESIDENT + AUDITOR |
| BudgetToken | `reclaim(ReclaimRequest, sig)` | 릴레이어 호출, 서명자 = PRESIDENT |
| BudgetToken | `spend`, `refund` | AccountingLedger 컨트랙트만 |
| BudgetToken | `remaining`, `getBudget`, `exists`, `budgetIdOf`, `ledger`, `roleManager`, `MAX_AMOUNT`, `DOMAIN_SEPARATOR` | view |
| AccountingLedger | `recordPending(RecordRequest, sig)` | 릴레이어 호출, 서명자 = TREASURER |
| AccountingLedger | `confirmEntry(ConfirmApproval, sig)` | 릴레이어 호출, 서명자 = AUDITOR 또는 PRESIDENT (≠ 등록자) |
| AccountingLedger | `rejectEntry(RejectDecision, sig)` | 릴레이어 호출, 서명자 = AUDITOR 또는 PRESIDENT (≠ 등록자) |
| AccountingLedger | `getEntry`, `statusOf`, `exists`, `entryCommitOf`, `netAmountOf`, `roleManager`, `budgetToken`, `MAX_AMOUNT`, `DOMAIN_SEPARATOR` | view. `statusOf`는 없는 id면 `EntryNotFound` |
| MembershipSBT | `mintBatch`, `burn` | PRESIDENT |
| MembershipSBT | `hasValidMembership`, `tokenOf`, `getMembership`, `nextTokenId` | view |
| ObjectionRegistry | `raise` | 릴레이어 호출, `raiser`는 SBT 보유자 (릴레이어 신뢰) |
| ObjectionRegistry | `answer(AnswerRequest, sig)` | 릴레이어 호출, 서명자 = 임원 |

확정된 항목을 수정하는 함수는 존재하지 않는다. `Entry`를 바꾸는 경로는 `PENDING → CONFIRMED / REJECTED` 상태 전이 하나뿐이다.

## 이벤트

**장부 잔액**과 **예산 잔량**은 다른 값이다. 둘 다 `CONFIRMED`만 반영하며 `EntryPending` / `EntryRejected` / `EntryBlocked`는 영향 없다.

- 장부 잔액 = Σ `EntryConfirmed.amount` (kind = INCOME) − Σ `EntryConfirmed.amount` (kind = EXPENSE). 원본 수입·지출은 양수로 들어오므로 `kind`로 나눠 빼야 한다. `amount`를 그냥 더하면 안 된다. 학기별 합계는 `term`으로 나눈다.
- **음수 정정은 `EntryConfirmed.amount`가 음수로 온다.** 위 식에 그대로 넣으면 해당 kind 합계에서 빠진다.
- 예산 잔량: 구현은 `BudgetToken.remaining(budgetId)`를 호출한다. 이벤트 재계산은 검증용이며 식은 `budgetId`별로 `Σ BudgetIssued.amount + Σ BudgetIncreased.amount − Σ BudgetReclaimed.amount − Σ BudgetSpent.amount + Σ BudgetRefunded.amount`. `EntryConfirmed`로는 재계산하지 않는다.
- 집계 시작 블록은 `deployments/<network>.json`의 `deployBlock`이다.

| 이벤트 | indexed |
| --- | --- |
| `EntryPending(id, hash, amount, kind, term, budgetId, correctsId, actor)` | id, budgetId, actor |
| `EntryConfirmed(id, hash, amount, kind, term, budgetId, hadWarning, warningReasonHash, actor)` | id, budgetId, actor |
| `EntryRejected(id, reasonHash, actor)` | id, actor |
| `EntryBlocked(id, hash, attempted, term, budgetId, correctsId, reason, actor)` | id, budgetId, actor. 학기별 초과 시도 지표·정정 쌍 대조용 |
| `BudgetIssued(budgetId, term, category, amount, expiresAt, actor)` | budgetId, term, actor |
| `BudgetIncreased(budgetId, amount, version, reasonHash, requester, approver)` | budgetId, requester, approver |
| `BudgetSpent(budgetId, amount, entryId)` / `BudgetRefunded(...)` | budgetId |
| `BudgetReclaimed(budgetId, amount, actor)` | budgetId, actor |
| `LedgerSet(ledger)` | ledger |
| `MembershipMinted(tokenId, to, term, commitment)` / `MembershipBurned(tokenId, from, term)` | tokenId, to/from, term |
| `ObjectionRaised(objectionId, entryId, contentHash, raiser)` / `ObjectionAnswered(objectionId, answerHash, responder)` | objectionId, entryId/responder |
| `RoleGranted(role, account, proposer, approver)` / `RoleRevoked(role, account, proposer, approver)` | role, account, approver. proposer·approver 0 = 생성자 최초 부여 |
| `RoleChangeExecuted(nonce, role, from, to, proposer, approver)` | nonce, role. 일반 변경·회장 복구 실행 모두 |
| `PresidentRecoveryProposed(recoveryId, from, to, auditorA, auditorB, executableAt)` | recoveryId, from, to |
| `PresidentRecoveryCancelled(recoveryId, president)` | recoveryId, president |

## 에러

이번 작업(구현 전 결정 ~ PR #13 리뷰 반영)에서 새로 생긴 이름이다. 백엔드 `RevertReason`에 추가해야 할 목록이며, 값은 Solidity 에러 이름 그대로다. **같은 이름이 여러 컨트랙트에 있으면 revert를 낸 컨트랙트 주소로 구분한다** (`TermRequired`, `ReservedId`, `ZeroAmount`, `ReasonRequired`, `AmountOutOfRange`, `FieldOutOfRange`, `InvalidSignature`, `SignatureExpired`, `ZeroAddress`). 백엔드 코드 수정은 손종인 담당.

| 에러 | 컨트랙트 | 조건 |
| --- | --- | --- |
| `TermRequired` | AccountingLedger, BudgetToken | `term == 0` |
| `CategoryRequired` | BudgetToken | 발행의 `category == 0` |
| `TermMismatch` | AccountingLedger | 지출 `term`이 예산 `term`과 다름, 또는 정정 `term`이 원본과 다름 (등록 시점 revert) |
| `BudgetIdNotAllowedForIncome` | AccountingLedger | INCOME인데 `budgetId != 0` |
| `ReasonRequired` | AccountingLedger, BudgetToken | 반려 사유 0, `hadWarning`인데 사유 0, 증액 사유 0 |
| `ReasonNotAllowed` | AccountingLedger | `hadWarning` 아닌데 사유 != 0 |
| `CorrectionBudgetMismatch` | AccountingLedger | 음수 정정의 `budgetId`가 원본과 다름 |
| `CorrectionExceedsOriginal` | AccountingLedger | 음수 정정 누적이 대상 순금액을 넘음 (등록 시 선검사, 확정 시 최종) |
| `CorrectionKindMismatch` | AccountingLedger | 정정의 `kind`가 원본과 다름 |
| `InvalidCorrectionTarget` | AccountingLedger | 정정 대상이 원본도 재분류 양수 정정도 아님 |
| `EntryCommitMismatch` | AccountingLedger | 승인·반려자가 서명한 `entryCommit`이 저장된 항목과 다름 |
| `HashRequired` | AccountingLedger | `hash == 0` |
| `ReservedId` | AccountingLedger, BudgetToken | `id == 0` / `budgetId == 0`. 중복이 아니라 예약값 위반 |
| `AmountOutOfRange` | AccountingLedger, BudgetToken | 금액이 `MAX_AMOUNT`를 넘음 |
| `FieldOutOfRange` | AccountingLedger, BudgetToken | id·term·시각이 저장 폭을 넘음 |
| `ZeroAddress` | AccountingLedger (신규), BudgetToken·RoleManager (기존) | 생성자 인자 0 |
| `ZeroAmount` (기존) | AccountingLedger | 차액 0인 정정도 여기에 걸린다. 새 이름 없음 |
| `BudgetAlreadyIssued` | BudgetToken | 같은 `(term, category)`에 두 번째 발행 |
| `VersionMismatch` | BudgetToken | 증액 요청의 `version`이 현재 version과 다름 (서명 재사용·경합) |
| `ReclaimAmountMismatch` | BudgetToken | 회수 요청 금액이 현재 잔량과 다름 |
| `ReclaimCountMismatch` | BudgetToken | 회수 요청의 `reclaimCount`가 현재 회수 횟수와 다름 (서명 재사용) |
| `NotPresident` | BudgetToken, RoleManager | 발행·회수 서명자, 증액 요청 서명자, 회장 복구 취소 서명자가 회장이 아님 |
| `NotAuditor` | BudgetToken, RoleManager | 증액 승인 서명자, 회장 복구 제안자가 감사가 아님 |
| `InvalidSignature` / `SignatureExpired` | BudgetToken, RoleManager (신규), AccountingLedger (기존) | 서명 바이트 깨짐 / deadline 경과 |
| `BudgetExpired` | BudgetToken (기존), AccountingLedger ABI | 확정 시 `spend`에서 마감 경과(`confirmEntry`를 통과해 그대로 올라옴), 마감 뒤 증액. 원장 ABI에도 선언 |
| `InsufficientBudget` | BudgetToken (기존), AccountingLedger ABI | 확정 시 잔량 부족. 원장 ABI에도 선언 |
| `LedgerAlreadySet` | BudgetToken | `setLedger` 두 번째 호출 |
| `LedgerMismatch` | BudgetToken | `setLedger` 대상 원장이 이 BudgetToken·RoleManager를 가리키지 않음 |
| `AlreadyOfficer` | RoleManager | `to`가 이미 다른 임원 롤 보유 (한 주소 한 롤). 생성자 인자 중복도 같은 에러 |
| `RoleCapacityExceeded` | RoleManager | 보유자가 있는 회장·총무에 신규 부여 |
| `RoleMinimumViolated` | RoleManager | 회장·총무 회수, 감사가 2명 이하일 때 감사 회수 |
| `NotGovernor` | RoleManager | 롤 변경 서명자가 회장·감사가 아님 |
| `PresidentRequired` | RoleManager | 일반 롤 변경 서명자 둘 다 감사 (회장 없음) |
| `NoPendingRecovery` | RoleManager | 대기 중인 회장 복구가 없거나 id가 다름 |
| `RecoveryNotReady` | RoleManager | 회장 복구 대기 72시간이 안 지남 |
| `SameSigner` | RoleManager | 롤 변경 제안자 == 승인자. 원장의 `SelfApproval`과 이름을 나눴다 |
| `InvalidNonce` | RoleManager | 롤 변경 요청의 nonce가 현재 값과 다름 (이미 실행됐거나 다른 변경이 먼저 실행됨) |

이름이 바뀌거나 없어진 것: RoleManager의 `Unauthorized`·`SelfApproval`·`RotationNotFound`·`RotationAlreadyExecuted`는 새 구조에서 쓰지 않는다. 원장의 `Unauthorized`는 쓰이지 않아 뺐다.

## EIP-712

서명을 받는 컨트랙트마다 도메인이 따로 있다: `name = 컨트랙트명`, `version = "1"`, `chainId`, `verifyingContract`. `DOMAIN_SEPARATOR()`를 노출하는 것은 AccountingLedger·BudgetToken·RoleManager·ObjectionRegistry이고, MembershipSBT는 서명을 받지 않아 없다. 앱은 서명 대상에 맞는 도메인을 골라야 한다.

| 컨트랙트 | struct | typehash 문자열 |
| --- | --- | --- |
| AccountingLedger | `RecordRequest` | `RecordRequest(uint256 id,bytes32 hash,int256 amount,uint8 kind,uint256 term,uint256 occurredAt,uint256 budgetId,uint256 correctsId,uint256 deadline)` |
| AccountingLedger | `ConfirmApproval` | `ConfirmApproval(uint256 id,bytes32 hash,bytes32 entryCommit,bool hadWarning,bytes32 warningReasonHash,uint256 deadline)` |
| AccountingLedger | `RejectDecision` | `RejectDecision(uint256 id,bytes32 entryCommit,bytes32 reasonHash,uint256 deadline)` |
| BudgetToken | `IssueRequest` | `IssueRequest(uint256 budgetId,uint256 term,bytes32 category,uint256 amount,uint256 expiresAt,uint256 deadline)` |
| BudgetToken | `IncreaseRequest` | `IncreaseRequest(uint256 budgetId,uint256 amount,bytes32 reasonHash,uint256 version,uint256 deadline)` |
| BudgetToken | `ReclaimRequest` | `ReclaimRequest(uint256 budgetId,uint256 amount,uint256 reclaimCount,uint256 deadline)` |
| RoleManager | `RoleChange` | `RoleChange(bytes32 role,address from,address to,uint256 nonce,uint256 deadline)` |
| RoleManager | `PresidentRecovery` | `PresidentRecovery(address from,address to,uint256 nonce,uint256 deadline)` |
| RoleManager | `RecoveryCancel` | `RecoveryCancel(uint256 recoveryId,uint256 deadline)` |
| ObjectionRegistry | `AnswerRequest` | `AnswerRequest(uint256 objectionId,bytes32 answerHash,uint256 deadline)` |

`deadline`은 서명 유효 시한. 원장의 각 id는 한 번만 상태 전이하므로 nonce는 두지 않는다. 재사용 방지: 예산 발행은 `budgetId` 유일성, 증액은 `version`, 회수는 `reclaimCount`, 롤 변경·회장 복구 제안은 `nonce`, 복구 취소는 `recoveryId`(취소되면 대기 복구가 사라짐).

nonce가 없으므로 같은 id에 `ConfirmApproval`과 `RejectDecision` 서명이 둘 다 존재하면 릴레이어가 먼저 올리는 쪽이 이긴다. **서버 규칙: 한 id에 확정·반려 서명을 동시에 발급하지 않는다.** 하나를 발급했으면 그 서명이 제출되거나 `deadline`이 지나기 전에는 다른 쪽을 발급하지 않는다.

## 한계

- **정정 쌍 중 한쪽만 확정된 상태가 존재할 수 있다** (사람이 한쪽만 승인하는 경우). 그 사이 장부 잔액과 예산 잔량은 이중으로 빠져 보인다. 완화는 앱·서버 몫: 짝이 미확정인 정정은 "재분류 진행 중"으로 표시하고, 음수 정정을 반려할 때 서버가 경고를 띄운다.
- **회장과 감사 한 명이 담합하면 롤을 바꿀 수 있다.** 모든 변경은 제안자·승인자와 함께 이벤트로 남는다. 롤별 하한은 경로가 막히는 것만 방지하고 담합을 막지는 못한다.
- **감사 두 명이 담합하면 회장을 바꿀 수 있다.** 단 72시간 대기 중에 회장이 취소하지 않을 때만이다. 컨트랙트는 회장이 정말 키를 잃었는지 구분할 수 없어서, 키 분실 복구 경로를 두는 대가로 받아들인다. 제안·취소·실행이 모두 이벤트로 남는다. 감사 둘이 취소당해도 다시 제안해 회장을 번거롭게 할 수는 있다.
- **회장과 감사 한 명이 동시에 키를 잃으면(감사가 2명뿐일 때) 복구할 수 없다.** 남은 감사 한 명으로는 어떤 서명 쌍도 만들 수 없다. 재배포가 필요하다.
- **회장과 감사 한 명이 담합하면 증액할 수 있다.** 증액 이벤트에 두 사람이 남고, 결산의 "예산 개정 N회, 그중 초과 집행 이후 M회" 지표(PRD §4.1)가 이를 드러낸다.
- **재분류 금액은 재분류 양수 정정을 대상으로 한 음수 정정으로만 되돌린다.** 원본을 대상으로 한 음수 정정으로는 되돌릴 수 없다. 원본 순금액에 재분류 양수 정정을 더하지 않기 때문이다.
- 정정이 아닌 수입 항목의 `term`은 총무가 서명한 값일 뿐 체인이 대조하지 못한다. 지출은 예산 `term`, 정정은 원본 `term`과 대조한다.
- 파일 해시는 "그 뒤로 파일이 안 바뀌었다"만 증명하고 CSV가 진짜인지는 증명하지 못한다 (추후 별도 컨트랙트).

## 필수 테스트

이번 범위(RoleManager·BudgetToken·AccountingLedger)에서 통과해야 하는 목록이다. SBT는 이번 범위가 아니라 목록에만 둔다.

| # | 항목 | 이번 범위 |
| --- | --- | --- |
| 1 | 등록자 == 승인자이면 revert (`SelfApproval`) | O |
| 2 | 예산 초과·만료: 등록 시점은 `BLOCKED` 저장, 확정 시점은 revert (`InsufficientBudget` / `BudgetExpired`) | O |
| 3 | 확정 항목을 수정하는 함수가 존재하지 않음 (ABI에 상태 변경 경로가 `recordPending`·`confirmEntry`·`rejectEntry`뿐) | O |
| 4 | 정정 대상이 `CONFIRMED`가 아니면 revert (`CorrectionTargetNotConfirmed`) | O |
| 5 | 증액 정정(양수 정정)도 잔량 검사 (등록 시 `BLOCKED`, 확정 시 `InsufficientBudget`) | O |
| 6 | SBT 전송 revert (`Soulbound`) | X (다음 범위) |
| 7 | 릴레이어 키로 승인 불가 (릴레이어 서명은 `NotApprover`) | O |
| 8 | `BudgetToken.spend`를 `AccountingLedger` 외 계정이 호출하면 revert (`Unauthorized`). PRD §7.2 | O |
| 9 | 롤 변경(부여·회수·교체)은 회장과 감사 두 사람의 서명 없이는 실행되지 않음 (회장 키 분실 시에만 감사 2명 + 72시간 대기). PRD §7.2·§9.2 | O |

> 8·9번은 요구사항명세서 확인 후 번호가 바뀔 수 있다.

추가 테스트:

- 새 에러 전부: 위 에러 표의 각 에러마다 revert 1건 이상
- RECLASSIFY: 양수 정정 확정 후 음수 정정 확정 → 두 예산의 `spent`·원장 잔액이 기대값과 일치
- refund: 원래 예산 마감 뒤, 회수 뒤에도 성공 / 소모액 초과 refund는 revert
- 증액: 회장+감사 서명으로 `version` 증가·이벤트에 요청자·승인자 / 감사 서명 없이(회장 둘, 총무, 외부인) revert / 같은 서명 재사용은 `VersionMismatch` / 마감 뒤 증액 revert / 증액 후 refund → `remaining`이 `issued`를 넘지 않음 / 감액 함수 이름이 ABI에 하나도 없음 (이름마다 따로 검사)
- 발행: 같은 `(term, category)` 두 번째 발행 revert / 회장 아닌 서명 revert
- 회수 → refund → spend 시도 → revert (`BudgetExpired`) / 회수 금액 불일치 revert
- `spend`·`refund`를 원장 외 계정이 호출 → revert
- `setLedger` 두 번째 호출 → revert / 다른 BudgetToken을 가리키는 원장 → `LedgerMismatch`
- 롤: 같은 사람이 두 서명 → `SameSigner` / 총무·외부인 서명 → `NotGovernor` / 부여·회수·교체 각각 2인 서명으로 성공, 이벤트에 제안자·승인자 포함 / 배포 후 배포자 롤 없음, 세 임원 롤 보유, 생성자 부여 이벤트의 proposer·approver 0
- 롤 (보유 규칙): 회장·총무 추가 부여 → `RoleCapacityExceeded` / 회장·총무 회수, 마지막 감사 회수 → `RoleMinimumViolated` / 감사 둘에서 하나 회수는 성공 / 이미 다른 롤을 가진 주소에 부여 → `AlreadyOfficer` / 교체는 보유자 수 불변 / 생성자 인자 중복·0 주소 → revert
- 롤 (서명 수명): deadline 지난 서명 → `SignatureExpired` / 한 변경 실행 후 먼저 받아 둔 다른 서명 → `InvalidNonce` / 같은 서명 재제출 → `InvalidNonce`
- 롤 (회장 필수): 감사 둘만의 서명으로 회장·총무 교체, 감사 추가 → `PresidentRequired` / 감사 3명에서 1명 회수는 성공, 2명에서 회수는 `RoleMinimumViolated`
- 키 분실 (잃은 키의 서명 없이): 감사 한 명 분실 → 회장 + 다른 감사로 교체 성공 / 회장 분실 → 감사 2명 복구 제안, 72시간 전 실행 `RecoveryNotReady`, 뒤 실행 성공, 새 회장이 예산 발행 가능
- 회장 복구: 살아 있는 회장이 취소 → 실행 `NoPendingRecovery` / 회장 아닌 취소 `NotPresident` / 감사 아닌 제안 `NotAuditor` / 같은 감사 두 서명 `SameSigner` / 제안 서명 재사용 `InvalidNonce` / 대기 중 제안 감사가 교체되면 실행 `NotAuditor` / 대기 중 회장이 바뀌면 `RoleNotGranted` / 대기 중 `to`가 임원이 되면 `AlreadyOfficer` / 새 제안이 옛 제안을 덮어씀
- 회수 서명 재사용: 같은 금액 환불 뒤 옛 회수 서명 재제출 → `ReclaimCountMismatch` / 회수는 `version`을 바꾸지 않음
- 해시: `hash == 0` 등록 → `HashRequired`
- 반려 범위: 등록과 다른 값으로 계산한 `entryCommit`의 반려 → `EntryCommitMismatch` / 날짜(`occurredAt`)만 다른 `entryCommit`도 확정 거부
- 에러 해석: `confirmEntry`의 `InsufficientBudget`·`BudgetExpired`를 원장 ABI로 해석 가능
- 승인 범위: 등록과 다른 budgetId·kind·term·registrant로 계산한 `entryCommit` → `EntryCommitMismatch` / `entryCommitOf`가 문서의 식과 일치
- 정정 (term): 원본과 `term`이 다른 정정 → `TermMismatch`
- 정정 (원본별 누적): 원본 10만에 음수 정정 −6만 확정 후 −5만 등록 → revert (`CorrectionExceedsOriginal`) / 이어서 같은 예산 양수 정정 +3만 확정 → 순금액 7만, −7만은 허용, −8만은 revert / 대기 중 음수 정정 두 건이 순금액을 나눠 쓰면 나중 확정은 revert (확정 시 최종 검사) / 차액 0인 정정 등록 → revert (`ZeroAmount`) / `netAmountOf`가 원본 확정·정정 확정마다 기대값과 일치
- 정정 (재분류는 순금액에 안 더함): 원본(예산 A) → 재분류 양수(예산 B) 확정 → 재분류 음수(예산 A) 확정 → 추가 음수 정정(예산 A) 등록은 `CorrectionExceedsOriginal`로 revert. `netAmountOf(원본)`은 재분류 양수 확정 뒤에도 원본 금액 그대로
- 정정 (대상 제한): 원본 35,000 → 같은 예산 +10,000 확정 → 원본 대상 −45,000 확정 → 그 +10,000 정정을 대상으로 한 −10,000 등록은 `InvalidCorrectionTarget`로 revert. 같은 예산 양수 정정의 `netAmountOf`는 0 / 음수 정정을 대상으로 한 정정도 `InvalidCorrectionTarget` / 수입 양수 정정(재분류가 될 수 없음)을 대상으로 한 정정도 `InvalidCorrectionTarget`
- 정정 (재분류 되돌림): 재분류 양수 정정(B)을 대상으로 한 음수 정정(B)은 그 정정 금액 범위 안에서 성공, 초과는 `CorrectionExceedsOriginal`
- 정정 (kind): 원본과 `kind`가 다른 정정 등록은 `CorrectionKindMismatch`
- 예산 불변식: **환불이 일어나는 모든 정정 시나리오** 끝에 예산별 Σ `BudgetRefunded` ≤ Σ `BudgetSpent`
- 예약 id·범위: `recordPending(id = 0)`·`issue(budgetId = 0)`은 `ReservedId` / `int256` 최솟값·상한 초과 금액은 `AmountOutOfRange` / `uint64`를 넘는 id는 `FieldOutOfRange`
- 조회: 없는 id의 `statusOf`는 `EntryNotFound` / `EntryBlocked`에 hash·term·correctsId·등록자 (차단된 양수 정정은 correctsId != 0)
- 회장 복구 소멸: 제안 뒤 회장이 일반 교체되면 대기 복구가 지워지고, 옛 회장이 돌아온 뒤 72시간이 지나도 실행은 `NoPendingRecovery`
- 발행: `category == 0` → `CategoryRequired`
