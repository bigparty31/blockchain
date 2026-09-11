# CONTRACTS

인터페이스: `contracts/interfaces/`. 시그니처·이벤트·에러의 정본은 `.sol` 파일이고 이 문서는 요약이다.

## 컨트랙트 목록

| 컨트랙트 | 역할 |
| --- | --- |
| `RoleManager` | 임원 롤(TREASURER / AUDITOR / PRESIDENT). 키 교체는 회장·감사 2인 제안→승인 |
| `BudgetToken` | 학기+항목 1줄 단위 예산 잔량. `spend/refund`는 `AccountingLedger`만 호출 |
| `AccountingLedger` | 수입·지출 원장. 확정 항목 수정 불가, 정정은 `correctsId`로 원본을 가리키는 새 항목 |
| `MembershipSBT` | 학기 단위 학생 회원 증명. 전송 불가. 학번은 `keccak256(studentId, salt)` 커밋만 |
| `ObjectionRegistry` | 학생 이의 제기·답변. 해시만 온체인. entry 상태에 영향 없음 |

## 공통 규칙

- ID(`budgetId`, `entryId`, `objectionId`)는 백엔드 DB auto-increment 값을 파라미터로 받는다. 컨트랙트는 중복만 막는다. SBT `tokenId`만 온체인 카운터.
- 금액은 원 단위 정수. `amount`는 `int256`, `correctsId != 0`인 정정 항목만 음수 허용.
- 이벤트에 기록 시각을 넣지 않는다 (블록에 있음). 발생 시각 `occurredAt`은 파라미터.
- enum 온체인 순서 = `docs/enums.md` 표 순서. `ocr_status`는 온체인에 올리지 않는다.
- `recordPending` / `confirmEntry` / `rejectEntry` / `answer`는 릴레이어가 호출하되 EIP-712 서명자가 실제 행위자. `raise`만 릴레이어 신뢰.
- 예산 초과 검사는 등록 시점(초과면 revert 없이 `BLOCKED` 저장 + `EntryBlocked`), 예산 소모는 확정 시점(잔량 부족이면 revert).

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
| RoleManager | `grantRole`, `revokeRole`, `hasRole` | PRESIDENT |
| RoleManager | `proposeKeyRotation`, `approveKeyRotation` | PRESIDENT 또는 AUDITOR, 제안자 ≠ 승인자 |
| BudgetToken | `issue`, `increase`, `reclaim` | PRESIDENT |
| BudgetToken | `spend`, `refund` | AccountingLedger 컨트랙트만 |
| BudgetToken | `remaining`, `getBudget`, `exists` | view |
| AccountingLedger | `recordPending(RecordRequest, sig)` | 릴레이어 호출, 서명자 = TREASURER |
| AccountingLedger | `confirmEntry(ConfirmApproval, sig)` | 릴레이어 호출, 서명자 = 승인자 (≠ 등록자) |
| AccountingLedger | `rejectEntry(RejectDecision, sig)` | 릴레이어 호출, 서명자 = 반려자 |
| MembershipSBT | `mintBatch`, `burn` | PRESIDENT |
| MembershipSBT | `hasValidMembership`, `tokenOf`, `getMembership`, `nextTokenId` | view |
| ObjectionRegistry | `raise` | 릴레이어 호출, `raiser`는 SBT 보유자 (릴레이어 신뢰) |
| ObjectionRegistry | `answer(AnswerRequest, sig)` | 릴레이어 호출, 서명자 = 임원 |

## 이벤트

잔액 계산은 **`EntryConfirmed`만** 합산한다. `EntryPending` / `EntryRejected` / `EntryBlocked`는 잔액에 영향 없다.
`amount`는 `int256`이고 정정은 음수로 들어오므로 `budgetId`별로 그대로 더하면 된다.

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
