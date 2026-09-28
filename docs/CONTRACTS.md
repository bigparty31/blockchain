# CONTRACTS

인터페이스: `contracts/interfaces/`. 시그니처·이벤트·에러의 정본은 `.sol` 파일이고 이 문서는 요약이다.

## 컨트랙트 목록

| 컨트랙트 | 역할 |
| --- | --- |
| `RoleManager` | 임원 롤(TREASURER / AUDITOR / PRESIDENT). 롤 식별자는 `keccak256("TREASURER")` 등 이름 해시(`bytes32`), enum 인덱스 아님. 부여·회수·교체 모두 임원 2인 제안→승인. 단독으로 롤을 바꾸는 함수는 없다 |
| `BudgetToken` | 학기+항목 1줄 단위 예산 한도·소모액. `spend/refund`는 `AccountingLedger`만 호출 |
| `AccountingLedger` | 수입·지출 원장. 확정 항목 수정 불가, 정정은 `correctsId`로 원본을 가리키는 새 항목 |
| `MembershipSBT` | 학기 단위 학생 회원 증명. 전송 불가. 학번은 `keccak256(studentId, salt)` 커밋만 |
| `ObjectionRegistry` | 학생 이의 제기·답변. 해시만 온체인. entry 상태에 영향 없음 |

거래내역 CSV 파일 해시를 남기는 `recordBankSnapshot`은 원장에 넣지 않는다. 별도 컨트랙트로 추후 설계한다 (문승준과 필드·서명 주체 확정 후).

## 공통 규칙

- ID(`budgetId`, `entryId`, `objectionId`)는 백엔드 DB auto-increment 값을 파라미터로 받는다. 컨트랙트는 중복만 막는다. SBT `tokenId`와 `changeId`(롤 변경 제안)만 온체인 카운터. ID는 1부터 시작한다 (`0`은 "없음").
- 금액은 원 단위 정수. `amount`는 `int256`, `correctsId != 0`인 정정 항목만 음수 허용.
- 이벤트에 기록 시각을 넣지 않는다 (블록에 있음). 발생 시각 `occurredAt`은 파라미터.
- enum 온체인 순서 = `docs/enums.md` 표 순서. `ocr_status`는 온체인에 올리지 않는다.
- 롤은 enum이 아니라 `bytes32 = keccak256(utf8("TREASURER"))` 등 이름 해시. `RoleManager`가 `TREASURER()` / `AUDITOR()` / `PRESIDENT()`로 노출하므로 백엔드는 하드코딩 대신 읽어가도 된다.
- `recordPending` / `confirmEntry` / `rejectEntry` / `answer`는 릴레이어가 호출하되 EIP-712 서명자가 실제 행위자. `raise`만 릴레이어 신뢰.
- **`term`(학기 식별자, 예 `20261`)은 모든 항목에 있고 서명 대상이다.** `0`은 금지(`TermRequired`). 지출은 등록 시점에 예산의 `term`과 대조해 다르면 revert(`TermMismatch`). BLOCKED로 저장하지 않는다. 수입은 대조할 예산이 없어 서명된 값을 그대로 저장한다.
- `INCOME` 항목은 `budgetId = 0`. `budgetId != 0`이면 revert(`BudgetIdNotAllowedForIncome`). 예산 검사·소모는 `EXPENSE`에만 적용된다.
- 예산 초과 검사는 등록 시점(초과·마감·미존재면 revert 없이 `BLOCKED` 저장 + `EntryBlocked`), 예산 소모는 확정 시점(잔량 부족·마감이면 revert). `budgetId = 0`인 지출은 `BUDGET_NOT_FOUND`로 `BLOCKED`.
- 등록 시점 검사는 잔량만 보고 대기 건을 예약하지 않는다. 대기 A(10만) + 대기 B(10만), 잔량 15만이면 둘 다 `PENDING`으로 들어가고, A 확정 후 B 확정은 `InsufficientBudget`으로 revert 한다. revert 시 온체인 상태는 `PENDING` 그대로이므로 앱은 "예산 부족 → 반려" 흐름으로 `rejectEntry`를 호출해야 한다.
- 승인자(확정·반려 서명자)는 `AUDITOR` 또는 `PRESIDENT`. 등록자 ≠ 승인자는 별도로 검사한다 (PRD §3: 회장은 감사와 동일 승인 권한). 앱 분기: `hasRole(AUDITOR) || hasRole(PRESIDENT)`.
- **사유 해시 규칙.** 반려는 `reasonHash != 0` 필수(`ReasonRequired`). 확정은 `hadWarning == (warningReasonHash != 0)`이어야 한다. 경고인데 사유 0이면 `ReasonRequired`, 경고 아닌데 사유가 있으면 `ReasonNotAllowed`. 해시 계산은 `docs/HASHING.md` §3.

### 정정

- 정정 항목은 `correctsId`로 원본을 가리키는 새 항목이다. 원본은 `CONFIRMED`여야 한다(`CorrectionTargetNotConfirmed`).
- **페어 필드는 없다.** `RECLASSIFY`는 양수 정정(새 예산 `spend`) + 음수 정정(원래 예산 `refund`) 2건으로 표현한다. 둘 다 `correctsId`는 원본.
- **순서는 서버 규칙: 양수 다음 음수.** `spend`는 잔량 부족·마감으로 실패할 수 있지만 `refund`는 원본 소모액 범위 안에서 항상 성공하기 때문이다.
- 음수 정정의 `budgetId`는 원본의 `budgetId`와 같아야 한다(`CorrectionBudgetMismatch`). `refund`가 엉뚱한 예산으로 가는 것을 막는다.
- 양수 정정도 일반 지출과 같이 등록 시 잔량 검사, 확정 시 `spend`를 거친다.
- **차액(`amount`)이 0인 정정은 등록 시 revert**(`ZeroAmount`). 일반 항목과 같은 검사에 걸린다. 새 에러를 두지 않는다.
- **음수 정정의 범위는 원본별 누적으로 검사한다.** 원본마다 순금액 `netAmountOf(원본 id)`를 저장한다. 원본 확정 시 원본 `amount`로 시작하고, 그 원본을 가리키는 정정이 확정될 때마다 정정 `amount`를 더한다(음수면 빠진다). **원본과 같은 `budgetId`로 가는 정정만 더한다.** 다른 예산으로 가는 양수 정정(재분류)은 더하지 않는다. 재분류 양수 정정이 원본 순금액을 부풀리면 원래 예산에 소모액 이상 refund가 가능해지기 때문이다. 음수 정정 확정으로 순금액이 0 아래로 가면 `CorrectionExceedsOriginal`. 등록 시에도 현재 순금액으로 같은 검사를 먼저 해 조기에 걸러내지만, 대기 중인 다른 정정은 예약하지 않으므로 확정 시 검사가 최종이다. 수입·지출 모두 적용.
- 예산 단위 상한(`RefundExceedsSpent`)과 원본 단위 상한(`CorrectionExceedsOriginal`)은 별개다. 둘 다 통과해야 refund가 실행된다.

### 예산 (BudgetToken)

- `issued`는 **현재 한도**다. `remaining() = issued − spent`. 불변식: 항상 `spent <= issued`.
- **개정은 증액만 가능.** `increase`는 `issued`에 더하고 `version`을 올리고 `BudgetIncreased`를 낸다. 덮어쓰기 없음. 감액은 향후 과제.
- `refund`는 `spent`만 줄인다. 마감·회수 여부를 보지 않는다. 원본이 소모한 금액을 넘는 refund는 `RefundExceedsSpent`.
- `reclaim`은 마감(`expiresAt`) 뒤에만 가능하고 `issued`를 `spent`까지 내린다. 재호출 가능. **`issued`는 회수 후 줄어든다. 최초 발행액·누적 증액은 이벤트(`Issued + Increased`)로 계산한다.** 회수된 예산에 refund가 오면 잔량이 다시 생기지만 마감이 지나 `spend`는 막히고, `reclaim`을 다시 부르면 된다.
- `spend` / `refund` 호출자는 `AccountingLedger` 하나로 제한한다. 원장 주소는 **배포자가 `setLedger`로 한 번만 설정하고 잠근다.** 두 번째 호출은 `LedgerAlreadySet`. 설정 시 `LedgerSet` 이벤트.
- `issue`의 `term == 0`은 `TermRequired`.

### 롤 (RoleManager)

- **모든 롤 변경은 임원 2인 승인 경로로만 한다.** 단독으로 부여·회수하는 함수는 없다.
- 제안 `proposeRoleChange(role, from, to)`의 `from`·`to` 조합으로 세 가지를 표현한다: `from == 0` 신규 부여, `to == 0` 회수, 둘 다 있으면 교체. 둘 다 0이면 `ZeroAddress`.
- 제안자와 승인자는 서로 다른 임원(PRESIDENT·TREASURER·AUDITOR 중 하나 보유)이어야 한다. 같은 사람이면 `SelfApproval`, 임원이 아니면 `Unauthorized`.
- **보유 상태 검사는 전부 승인(실행) 시점에 한다.** 제안과 승인 사이에 상태가 바뀔 수 있기 때문이다. 순서: 제안이 존재·미실행인지 → 승인자가 임원인지 → 제안자 ≠ 승인자 → **제안자가 여전히 임원인지**(`ProposerNotOfficer`) → `from`이 롤 보유(`RoleNotGranted`) → `to`가 같은 롤 미보유(`RoleAlreadyGranted`) → `to`가 다른 임원 롤 미보유(`AlreadyOfficer`) → 회수면 실행 후 임원 수 ≥ 2(`TooFewOfficers`).
- **한 주소는 임원 롤을 하나만 가진다.** `roleOf(account)`로 조회한다. 교체는 임원 수를 바꾸지 않는다.
- **회수 결과 임원 수가 2명 미만이 되면 revert.** 2인 승인 경로가 막히는 것을 방지한다. `officerCount()`로 조회한다.
- 첫 회장·총무·감사는 **생성자 인자**로 받는다. 세 주소는 서로 다르고 0이 아니어야 한다. 배포자는 어떤 롤도 갖지 않는다. OpenZeppelin AccessControl을 쓰지 않으므로 `DEFAULT_ADMIN_ROLE` 같은 상위 권한도 없다.
- 실행 결과는 `RoleGranted` / `RoleRevoked`로 남기고 **제안자와 승인자를 둘 다 담는다.** 교체일 때만 `RoleReplaced`를 추가로 낸다. 같은 트랜잭션의 `RoleRevoked` + `RoleGranted`가 한 변경으로 묶인 것임을 인덱서가 알 수 있게 하기 위함이다.

### 생성자·배포 순서

| 컨트랙트 | 생성자 인자 |
| --- | --- |
| `RoleManager` | `(president, treasurer, auditor)` — 서로 다른 세 계정 |
| `BudgetToken` | `(roleManager)` |
| `AccountingLedger` | `(roleManager, budgetToken)` |

배포 순서: `RoleManager` → `BudgetToken` → `AccountingLedger` → `BudgetToken.setLedger(ledger)`. 릴레이어 계정은 롤이 없다. 배포 스크립트가 끝나면 배포자에게 남는 권한은 없다.

## entry.hash

`AccountingLedger`의 `Entry.hash` / `RecordRequest.hash` / `ConfirmApproval.hash` / `EntryPending.hash` / `EntryConfirmed.hash`는 모두 같은 값으로, PRD §8의 `meta_hash`다.

> **계산 규칙의 정본은 `docs/HASHING.md`다.** 구현할 때는 반드시 그 문서를 볼 것. 아래는 요약이며, 어긋나면 `docs/HASHING.md`가 맞다.

```
meta_hash = SHA256( amount ␟ counterparty ␟ purpose ␟ occurred_at ␟ receipt_hash )
```

- `␟`는 **U+001F (Unit Separator)** 한 글자다. **파이프(`|`)가 아니다.** 목적란이 자유 입력이라 파이프를 쓰면 서로 다른 거래가 같은 해시를 낸다 (`docs/HASHING.md` §1).
- SHA-256 출력이 32바이트라 `bytes32`에 그대로 넣는다 (keccak 아님).
- 영수증은 `receipt_hash`로 이미 포함되므로 영수증 파일·OCR 결과는 따로 올리지 않는다.
- `confirmEntry`는 저장된 `hash`와 `ConfirmApproval.hash`가 다르면 `HashMismatch`로 revert. 승인자가 본 내용이 등록된 내용과 같다는 보증.
- **EIP-712 서명 해시(digest)와는 별개 값**이다. `meta_hash`는 서명 대상 struct 안에 들어가는 필드이고, digest는 그 struct 전체를 EIP-712로 인코딩한 결과다.
- 필드 구분자·정수 표기·문자열 정규화·`receipt_hash` NULL 처리, 그리고 `reasonHash` 등 텍스트 해시와 파일 해시 규칙은 **`docs/HASHING.md`에서 확정됐다.** 샘플과 테스트 벡터는 `docs/hashing_vectors.json`에 있다.
- `term`은 `meta_hash`에 들어가지 않는다. 서명 대상 struct의 별도 필드다.

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
| RoleManager | `hasRole`, `roleOf`, `officerCount` | view. `role`은 `bytes32` 이름 해시 |
| RoleManager | `TREASURER()`, `AUDITOR()`, `PRESIDENT()` | view. 롤 식별자 상수 |
| RoleManager | `proposeRoleChange(role, from, to)`, `approveRoleChange(changeId)` | 임원. 제안자 ≠ 승인자. 부여·회수·교체 공통 |
| RoleManager | `getRoleChange` | view |
| BudgetToken | `setLedger` | 배포자, 1회만 |
| BudgetToken | `issue`, `increase`, `reclaim` | PRESIDENT |
| BudgetToken | `spend`, `refund` | AccountingLedger 컨트랙트만 |
| BudgetToken | `remaining`, `getBudget`, `exists`, `ledger` | view |
| AccountingLedger | `recordPending(RecordRequest, sig)` | 릴레이어 호출, 서명자 = TREASURER |
| AccountingLedger | `confirmEntry(ConfirmApproval, sig)` | 릴레이어 호출, 서명자 = AUDITOR 또는 PRESIDENT (≠ 등록자) |
| AccountingLedger | `rejectEntry(RejectDecision, sig)` | 릴레이어 호출, 서명자 = AUDITOR 또는 PRESIDENT (≠ 등록자) |
| AccountingLedger | `getEntry`, `statusOf`, `exists`, `netAmountOf`, `DOMAIN_SEPARATOR` | view |
| MembershipSBT | `mintBatch`, `burn` | PRESIDENT |
| MembershipSBT | `hasValidMembership`, `tokenOf`, `getMembership`, `nextTokenId` | view |
| ObjectionRegistry | `raise` | 릴레이어 호출, `raiser`는 SBT 보유자 (릴레이어 신뢰) |
| ObjectionRegistry | `answer(AnswerRequest, sig)` | 릴레이어 호출, 서명자 = 임원 |

확정된 항목을 수정하는 함수는 존재하지 않는다. `Entry`를 바꾸는 경로는 `PENDING → CONFIRMED / REJECTED` 상태 전이 하나뿐이다.

## 이벤트

**장부 잔액**과 **예산 잔량**은 다른 값이다. 둘 다 `CONFIRMED`만 반영하며 `EntryPending` / `EntryRejected` / `EntryBlocked`는 영향 없다.

- 장부 잔액 = Σ `EntryConfirmed.amount` (kind = INCOME) − Σ `EntryConfirmed.amount` (kind = EXPENSE). 수입·지출 모두 양수로 들어오므로 `kind`로 나눠 빼야 한다. `amount`를 그냥 더하면 안 된다. 학기별 합계는 `term`으로 나눈다.
- 예산 잔량: 구현은 `BudgetToken.remaining(budgetId)`를 호출한다. 이벤트 재계산은 검증용이며 식은 `budgetId`별로 `Σ BudgetIssued.amount + Σ BudgetIncreased.amount − Σ BudgetReclaimed.amount − Σ BudgetSpent.amount + Σ BudgetRefunded.amount`. `EntryConfirmed`로는 재계산하지 않는다.
- 정정 항목(`correctsId != 0`)은 `amount`가 음수로 들어오므로 위 합산에 그대로 포함하면 된다.

| 이벤트 | indexed |
| --- | --- |
| `EntryPending(id, hash, amount, kind, term, budgetId, correctsId, actor)` | id, budgetId, actor |
| `EntryConfirmed(id, hash, amount, kind, term, budgetId, hadWarning, warningReasonHash, actor)` | id, budgetId, actor |
| `EntryRejected(id, reasonHash, actor)` | id, actor |
| `EntryBlocked(id, budgetId, attempted, reason)` | id, budgetId |
| `BudgetIssued(budgetId, term, category, amount, expiresAt)` | budgetId, term |
| `BudgetIncreased(budgetId, amount, version, reasonHash)` | budgetId |
| `BudgetSpent(budgetId, amount, entryId)` / `BudgetRefunded(...)` | budgetId |
| `BudgetReclaimed(budgetId, amount, actor)` | budgetId, actor |
| `LedgerSet(ledger)` | ledger |
| `MembershipMinted(tokenId, to, term, commitment)` / `MembershipBurned(tokenId, from, term)` | tokenId, to/from, term |
| `ObjectionRaised(objectionId, entryId, contentHash, raiser)` / `ObjectionAnswered(objectionId, answerHash, responder)` | objectionId, entryId/responder |
| `RoleGranted(role, account, proposer, approver)` / `RoleRevoked(role, account, proposer, approver)` | role, account, approver |
| `RoleReplaced(role, from, to, proposer, approver)` | role, from, to. 교체일 때만 |
| `RoleChangeProposed(changeId, role, from, to, proposer)` / `RoleChangeApproved(changeId, approver)` | changeId, role/approver, proposer |

## 에러

기존 에러는 `.sol` 파일 참고. 이번 구현에서 새로 정한 이름과, 백엔드 `RevertReason`에 추가해야 할 목록이다. 백엔드 코드 수정은 손종인 담당.

| 에러 | 컨트랙트 | 조건 |
| --- | --- | --- |
| `TermRequired` | AccountingLedger, BudgetToken | `term == 0` |
| `TermMismatch` | AccountingLedger | EXPENSE의 `term`이 예산 `term`과 다름 (등록 시점 revert) |
| `BudgetIdNotAllowedForIncome` | AccountingLedger | INCOME인데 `budgetId != 0` |
| `ReasonRequired` | AccountingLedger | 반려 사유 0, 또는 `hadWarning`인데 사유 0 |
| `ReasonNotAllowed` | AccountingLedger | `hadWarning` 아닌데 사유 != 0 |
| `CorrectionBudgetMismatch` | AccountingLedger | 음수 정정의 `budgetId`가 원본과 다름 |
| `CorrectionExceedsOriginal` | AccountingLedger | 음수 정정 누적이 원본 순금액을 넘음 (등록 시 선검사, 확정 시 최종) |
| `ZeroAmount` (기존) | AccountingLedger | 차액 0인 정정도 여기에 걸린다. 새 이름 없음 |
| `AlreadyOfficer` | RoleManager | `to`가 이미 다른 임원 롤 보유 (한 주소 한 롤). 생성자 인자 중복도 같은 에러 |
| `TooFewOfficers` | RoleManager | 회수 실행 후 임원 수 < 2 |
| `ProposerNotOfficer` | RoleManager | 승인 시점에 제안자가 더는 임원이 아님 |
| `ChangeNotFound` / `ChangeAlreadyExecuted` | RoleManager | 옛 `RotationNotFound` / `RotationAlreadyExecuted`의 새 이름 |
| `BudgetExpired` | BudgetToken (기존) | 확정 시 `spend`에서 마감 경과. `confirmEntry`를 통과해 그대로 올라온다. 백엔드 enum에만 추가 |
| `LedgerAlreadySet` | BudgetToken | `setLedger` 두 번째 호출 |

## EIP-712

도메인: `name = 컨트랙트명`, `version = "1"`, `chainId`, `verifyingContract`. 각 컨트랙트가 `DOMAIN_SEPARATOR()`를 노출한다.

| struct | typehash 문자열 |
| --- | --- |
| `RecordRequest` | `RecordRequest(uint256 id,bytes32 hash,int256 amount,uint8 kind,uint256 term,uint256 occurredAt,uint256 budgetId,uint256 correctsId,uint256 deadline)` |
| `ConfirmApproval` | `ConfirmApproval(uint256 id,bytes32 hash,bool hadWarning,bytes32 warningReasonHash,uint256 deadline)` |
| `RejectDecision` | `RejectDecision(uint256 id,bytes32 reasonHash,uint256 deadline)` |
| `AnswerRequest` | `AnswerRequest(uint256 objectionId,bytes32 answerHash,uint256 deadline)` |

`deadline`은 서명 유효 시한. 각 id는 한 번만 상태 전이하므로 nonce는 두지 않는다.

nonce가 없으므로 같은 id에 `ConfirmApproval`과 `RejectDecision` 서명이 둘 다 존재하면 릴레이어가 먼저 올리는 쪽이 이긴다. **서버 규칙: 한 id에 확정·반려 서명을 동시에 발급하지 않는다.** 하나를 발급했으면 그 서명이 제출되거나 `deadline`이 지나기 전에는 다른 쪽을 발급하지 않는다.

## 한계

- **정정 쌍 중 한쪽만 확정된 상태가 존재할 수 있다** (사람이 한쪽만 승인하는 경우). 그 사이 장부 잔액과 예산 잔량은 이중으로 빠져 보인다. 완화는 앱·서버 몫: 짝이 미확정인 정정은 "재분류 진행 중"으로 표시하고, 음수 정정을 반려할 때 서버가 경고를 띄운다.
- **서로 다른 두 임원이 담합하면 롤을 바꿀 수 있다.** 모든 변경은 제안자·승인자와 함께 이벤트로 남는다. 임원 수 하한(2명)은 경로가 막히는 것만 방지하고 담합을 막지는 못한다.
- **총무가 참여한 2인 승인으로 감사를 교체할 수 있다.** 감사 대상인 총무가 감사 교체에 관여할 수 있다는 뜻이다. 모든 롤 변경은 제안자·승인자와 함께 이벤트로 남는다.
- **재분류로 다른 예산에 들어간 금액은 음수 정정으로 되돌릴 수 없다.** 원본 순금액에 재분류 양수 정정을 더하지 않기 때문이다. 되돌리려면 재분류 양수 정정 항목을 원본으로 하는 음수 정정을 새로 등록한다.
- 수입 항목의 `term`은 총무가 서명한 값일 뿐 체인이 대조하지 못한다. 지출은 예산 `term`과 대조한다.
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
| 9 | 롤 변경(부여·회수·교체)은 서로 다른 두 임원의 승인 없이는 실행되지 않음. PRD §9.2 | O |

> 8·9번은 요구사항명세서 확인 후 번호가 바뀔 수 있다.

이번 결정으로 추가된 테스트:

- 새 에러 전부: 각 에러마다 revert 1건 이상 (`TermRequired`, `TermMismatch`, `BudgetIdNotAllowedForIncome`, `ReasonRequired` ×2, `ReasonNotAllowed`, `CorrectionBudgetMismatch`, `LedgerAlreadySet`)
- RECLASSIFY: 양수 정정 확정 후 음수 정정 확정 → 두 예산의 `spent`·원장 잔액이 기대값과 일치
- refund: 원래 예산 마감 뒤, 회수 뒤에도 성공 / 소모액 초과 refund는 revert
- 증액: `version` 증가·이벤트 확인 / 증액 후 refund → `remaining`이 `issued`를 넘지 않음
- 회수 → refund → spend 시도 → revert (`BudgetExpired`)
- `spend`·`refund`를 원장 외 계정이 호출 → revert
- `setLedger` 두 번째 호출 → revert
- 롤: 한 사람이 제안하고 같은 사람이 승인 → revert / 임원 아닌 계정의 제안·승인 → revert / 부여·회수·교체 각각 2인 승인으로 성공, 이벤트에 제안자·승인자 포함 / 배포 후 배포자 롤 없음, 생성자로 넣은 세 임원 롤 보유
- 롤 (승인 시점 검사): 제안 후 제안자가 회수되면 승인 → revert (`ProposerNotOfficer`) / 이미 다른 롤을 가진 주소에 부여 → revert (`AlreadyOfficer`) / 임원 3명에서 1명 회수는 성공, 2명에서 1명 회수는 revert (`TooFewOfficers`) / 교체는 임원 수 불변 / 생성자 인자 중복·0 주소 → revert
- 정정 (원본별 누적): 원본 10만에 음수 정정 −6만 확정 후 −5만 등록 → revert (`CorrectionExceedsOriginal`) / 같은 예산 양수 정정 +3만 확정 후에는 −8만까지 허용 / 차액 0인 정정 등록 → revert (`ZeroAmount`) / `netAmountOf`가 원본 확정·정정 확정마다 기대값과 일치
- 정정 (재분류는 순금액에 안 더함): 원본(예산 A) → 재분류 양수(예산 B) 확정 → 재분류 음수(예산 A) 확정 → 추가 음수 정정(예산 A) 등록은 `CorrectionExceedsOriginal`로 revert. `netAmountOf(원본)`은 재분류 양수 확정 뒤에도 원본 금액 그대로
