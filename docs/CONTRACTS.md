# CONTRACTS

인터페이스: `contracts/interfaces/`. 시그니처·이벤트·에러의 정본은 `.sol` 파일이고 이 문서는 요약이다.

## 컨트랙트 목록

| 컨트랙트 | 역할 |
| --- | --- |
| `RoleManager` | 임원 롤(TREASURER / AUDITOR / PRESIDENT). 롤 식별자는 `keccak256("TREASURER")` 등 이름 해시(`bytes32`), enum 인덱스 아님. 키 교체는 회장·감사 2인 제안→승인 |
| `BudgetToken` | 학기+항목 1줄 단위 예산 잔량. `spend/refund`는 `AccountingLedger`만 호출 |
| `AccountingLedger` | 수입·지출 원장. 확정 항목 수정 불가, 정정은 `correctsId`로 원본을 가리키는 새 항목 |
| `MembershipSBT` | 학기 단위 학생 회원 증명. 전송 불가. 학번은 `keccak256(studentId, salt)` 커밋만 |
| `ObjectionRegistry` | 학생 이의 제기·답변. 해시만 온체인. entry 상태에 영향 없음 |

## 공통 규칙

- ID(`budgetId`, `entryId`, `objectionId`)는 백엔드 DB auto-increment 값을 파라미터로 받는다. 컨트랙트는 중복만 막는다. SBT `tokenId`만 온체인 카운터.
- 금액은 원 단위 정수. `amount`는 `int256`, `correctsId != 0`인 정정 항목만 음수 허용.
- 이벤트에 기록 시각을 넣지 않는다 (블록에 있음). 발생 시각 `occurredAt`은 파라미터.
- enum 온체인 순서 = `docs/enums.md` 표 순서. `ocr_status`는 온체인에 올리지 않는다.
- 롤은 enum이 아니라 `bytes32 = keccak256(utf8("TREASURER"))` 등 이름 해시. `RoleManager`가 `TREASURER()` / `AUDITOR()` / `PRESIDENT()`로 노출하므로 백엔드는 하드코딩 대신 읽어가도 된다.
- `recordPending` / `confirmEntry` / `rejectEntry` / `answer`는 릴레이어가 호출하되 EIP-712 서명자가 실제 행위자. `raise`만 릴레이어 신뢰.
- `INCOME` 항목은 `budgetId = 0`. 예산 검사·소모는 `EXPENSE`에만 적용된다.
- 예산 초과 검사는 등록 시점(초과면 revert 없이 `BLOCKED` 저장 + `EntryBlocked`), 예산 소모는 확정 시점(잔량 부족이면 revert).
- 등록 시점 검사는 잔량만 보고 대기 건을 예약하지 않는다. 대기 A(10만) + 대기 B(10만), 잔량 15만이면 둘 다 `PENDING`으로 들어가고, A 확정 후 B 확정은 `InsufficientBudget`으로 revert 한다. revert 시 온체인 상태는 `PENDING` 그대로이므로 앱은 "예산 부족 → 반려" 흐름으로 `rejectEntry`를 호출해야 한다.
- 승인자(확정·반려 서명자)는 `AUDITOR` 또는 `PRESIDENT`. 등록자 ≠ 승인자는 별도로 검사한다 (PRD §3: 회장은 감사와 동일 승인 권한). 앱 분기: `hasRole(AUDITOR) || hasRole(PRESIDENT)`.

## entry.hash

`AccountingLedger`의 `Entry.hash` / `RecordRequest.hash` / `ConfirmApproval.hash` / `EntryPending.hash` / `EntryConfirmed.hash`는 모두 같은 값으로, PRD §8의 `meta_hash`다.

```
meta_hash = SHA256(amount | counterparty | purpose | occurred_at | receipt_hash)
```

- SHA-256 출력이 32바이트라 `bytes32`에 그대로 넣는다 (keccak 아님).
- 영수증은 `receipt_hash`로 이미 포함되므로 영수증 파일·OCR 결과는 따로 올리지 않는다.
- `confirmEntry`는 저장된 `hash`와 `ConfirmApproval.hash`가 다르면 `HashMismatch`로 revert. 승인자가 본 내용이 등록된 내용과 같다는 보증.
- **EIP-712 서명 해시(digest)와는 별개 값**이다. `meta_hash`는 서명 대상 struct 안에 들어가는 필드이고, digest는 그 struct 전체를 EIP-712로 인코딩한 결과다.
- 필드 구분자·인코딩(정수 표기, 문자열 정규화, `receipt_hash` 없을 때 처리 등) 세부는 손종인이 확정 예정 (2026-09 2주차). 확정 전까지 백엔드·앱이 각자 계산하지 말 것.

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
| RoleManager | `grantRole`, `revokeRole`, `hasRole` | PRESIDENT. `role`은 `bytes32` 이름 해시 |
| RoleManager | `TREASURER()`, `AUDITOR()`, `PRESIDENT()` | view. 롤 식별자 상수 |
| RoleManager | `proposeKeyRotation`, `approveKeyRotation` | PRESIDENT 또는 AUDITOR, 제안자 ≠ 승인자 |
| BudgetToken | `issue`, `increase`, `reclaim` | PRESIDENT |
| BudgetToken | `spend`, `refund` | AccountingLedger 컨트랙트만 |
| BudgetToken | `remaining`, `getBudget`, `exists` | view |
| AccountingLedger | `recordPending(RecordRequest, sig)` | 릴레이어 호출, 서명자 = TREASURER |
| AccountingLedger | `confirmEntry(ConfirmApproval, sig)` | 릴레이어 호출, 서명자 = AUDITOR 또는 PRESIDENT (≠ 등록자) |
| AccountingLedger | `rejectEntry(RejectDecision, sig)` | 릴레이어 호출, 서명자 = AUDITOR 또는 PRESIDENT (≠ 등록자) |
| MembershipSBT | `mintBatch`, `burn` | PRESIDENT |
| MembershipSBT | `hasValidMembership`, `tokenOf`, `getMembership`, `nextTokenId` | view |
| ObjectionRegistry | `raise` | 릴레이어 호출, `raiser`는 SBT 보유자 (릴레이어 신뢰) |
| ObjectionRegistry | `answer(AnswerRequest, sig)` | 릴레이어 호출, 서명자 = 임원 |

## 이벤트

**장부 잔액**과 **예산 잔량**은 다른 값이다. 둘 다 `CONFIRMED`만 반영하며 `EntryPending` / `EntryRejected` / `EntryBlocked`는 영향 없다.

- 장부 잔액 = Σ `EntryConfirmed.amount` (kind = INCOME) − Σ `EntryConfirmed.amount` (kind = EXPENSE). 수입·지출 모두 양수로 들어오므로 `kind`로 나눠 빼야 한다. `amount`를 그냥 더하면 안 된다.
- 예산 잔량: 구현은 `BudgetToken.remaining(budgetId)`를 호출한다. 이벤트 재계산은 검증용이며 식은 `budgetId`별로 `Σ BudgetIssued.amount + Σ BudgetIncreased.amount − Σ BudgetReclaimed.amount − Σ BudgetSpent.amount + Σ BudgetRefunded.amount`. `EntryConfirmed`로는 재계산하지 않는다.
- 정정 항목(`correctsId != 0`)은 `amount`가 음수로 들어오므로 위 합산에 그대로 포함하면 된다.

| 이벤트 | indexed |
| --- | --- |
| `EntryPending(id, hash, amount, kind, budgetId, correctsId, actor)` | id, budgetId, actor |
| `EntryConfirmed(id, hash, amount, kind, budgetId, hadWarning, warningReasonHash, actor)` | id, budgetId, actor |
| `EntryRejected(id, reasonHash, actor)` | id, actor |
| `EntryBlocked(id, budgetId, attempted, reason)` | id, budgetId |
| `BudgetIssued(budgetId, term, category, amount, expiresAt)` | budgetId, term |
| `BudgetIncreased(budgetId, amount, version, reasonHash)` | budgetId |
| `BudgetSpent(budgetId, amount, entryId)` / `BudgetRefunded(...)` | budgetId |
| `BudgetReclaimed(budgetId, amount, actor)` | budgetId, actor |
| `MembershipMinted(tokenId, to, term, commitment)` / `MembershipBurned(tokenId, from, term)` | tokenId, to/from, term |
| `ObjectionRaised(objectionId, entryId, contentHash, raiser)` / `ObjectionAnswered(objectionId, answerHash, responder)` | objectionId, entryId/responder |
| `RoleGranted` / `RoleRevoked` / `KeyRotationProposed` / `KeyRotationApproved` / `KeyRotated` | RoleManager 참고 |

## EIP-712

도메인: `name = 컨트랙트명`, `version = "1"`, `chainId`, `verifyingContract`. 각 컨트랙트가 `DOMAIN_SEPARATOR()`를 노출한다.

| struct | typehash 문자열 |
| --- | --- |
| `RecordRequest` | `RecordRequest(uint256 id,bytes32 hash,int256 amount,uint8 kind,uint256 occurredAt,uint256 budgetId,uint256 correctsId,uint256 deadline)` |
| `ConfirmApproval` | `ConfirmApproval(uint256 id,bytes32 hash,bool hadWarning,bytes32 warningReasonHash,uint256 deadline)` |
| `RejectDecision` | `RejectDecision(uint256 id,bytes32 reasonHash,uint256 deadline)` |
| `AnswerRequest` | `AnswerRequest(uint256 objectionId,bytes32 answerHash,uint256 deadline)` |

`deadline`은 서명 유효 시한. 각 id는 한 번만 상태 전이하므로 nonce는 두지 않는다.

nonce가 없으므로 같은 id에 `ConfirmApproval`과 `RejectDecision` 서명이 둘 다 존재하면 릴레이어가 먼저 올리는 쪽이 이긴다. **서버 규칙: 한 id에 확정·반려 서명을 동시에 발급하지 않는다.** 하나를 발급했으면 그 서명이 제출되거나 `deadline`이 지나기 전에는 다른 쪽을 발급하지 않는다.
