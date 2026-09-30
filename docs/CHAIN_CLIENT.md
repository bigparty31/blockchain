# CHAIN_CLIENT — 백엔드가 체인을 부르는 입구

작성 손종인 · 대상 김경윤(등록 API), 이승호(등록·승인 화면) · 코드 `backend/app/chain/`

지금은 **모양만** 정한다. 김경윤은 `FakeChainClient`로 등록 API를 끝까지 만들고, 나중에 실제 릴레이어로 갈아끼운다. 호출하는 쪽 코드는 바꾸지 않는다. 형식의 정본은 PR #13으로 머지된 `contracts/interfaces/IAccountingLedger.sol`이다.

| 지금 | 다음 |
| --- | --- |
| `AccountingLedger` 등록·확정·반려, `getEntry` 조회 | 예산(`BudgetToken`)·롤(`RoleManager`) 릴레이 — 둘 다 서명 + 릴레이어 방식이 됐다. 실제 릴레이어, 배포 정보(`contracts/deployments/localhost.json`) 읽기, deadline 정책, 중복 릴레이 방지. 이의·SBT는 컨트랙트가 아직 없다 |

서명은 ChainClient가 만들지 않는다. 임원 기기가 서명한 값을 받아 릴레이만 한다 (PRD §9.2).

---

## 1. 등록은 두 단계다

총무가 서명하는 `RecordRequest` 안에 `id`가 들어 있고, `id`는 DB auto-increment다 (`docs/CONTRACTS.md` 공통 규칙). **서명하려면 id를 먼저 알아야 하는데, id는 저장해야 생긴다.** 서명은 기기 생체인증이라 서버 요청 중간에 끼워 넣을 수 없고, 서버가 대신 서명할 수도 없다. 그래서 한 번에 끝나지 않는다.

```
① 앱 → 서버   입력값          서버: 검증 · 정규화(HASHING §1.1) · DB 저장 · id 채번  →  id 반환
② 앱          id·term(학기 코드) 을 넣은 RecordRequest 구성, meta_hash 직접 계산, 생체인증 서명
③ 앱 → 서버   서명 + deadline  서버: 앱이 보낸 hash == 서버가 계산한 hash 확인
                              →  record_pending  →  PENDING 또는 BLOCKED 저장
```

③에서 해시를 먼저 대조하는 이유 — 어긋나면 체인에 올리기 전에 400으로 끝낼 수 있다. 가스도 안 쓰고, 원인도 등록 시점에 드러난다. API 이름·경로는 김경윤이 정한다.

## 2. 아직 제출 안 된 항목의 status는 NULL

`PENDING`은 **온체인에 기록됐다**는 뜻이다 (PRD §4.3). ①에서 저장만 된 초안에 `PENDING`을 쓰면 학생 앱에 체인에 없는 "승인대기"가 뜬다.

- ① 직후 `status = NULL`, ③이 성공하면 `PENDING` 또는 `BLOCKED`로 채운다
- `docs/enums.md`는 바꾸지 않는다
- 학생 앱·목록 API는 `status IS NULL`인 항목을 내려주지 않는다

## 3. 메서드

| 메서드 | 컨트랙트 | 돌려주는 status |
| --- | --- | --- |
| `record_pending(request, signature)` | `recordPending` | `PENDING` · `BLOCKED` |
| `confirm_entry(approval, signature)` | `confirmEntry` | `CONFIRMED` |
| `reject_entry(decision, signature)` | `rejectEntry` | `REJECTED` |
| `get_entry(entry_id)` | `getEntry` | 없으면 `None` |

`getEntry`는 없는 id에도 0으로 채운 구조체(`registrant == 0`)를 돌려주고, status 0은 `PENDING`이다. 그대로 옮기면 없는 항목이 `PENDING`으로 보이므로 실제 구현은 `exists(id)`를 먼저 확인해 없으면 `None`을 돌려준다. (`statusOf`는 없는 id면 `EntryNotFound`로 revert한다.) 반환 튜플 순서는 저장 배치를 따르므로 **위치가 아니라 필드 이름으로 읽는다** (HASHING §2).

`ChainEntry.term`은 학기 코드 `YYYYS`다. **DB의 `Term.id`가 아니다** — 체인에 넘길 때와 비교할 때 `Term`의 학기 코드로 바꾼다.

`registrant`·`approver`는 web3.py가 돌려주는 EIP-55 체크섬 주소(대소문자 섞임)다. DB의 `wallet_address`와 비교할 때는 **양쪽을 소문자로 맞춘다.** Fake도 같은 형식으로 돌려준다.

쓰기 메서드는 **트랜잭션이 블록에 들어갈 때까지 기다린 뒤** 최종 상태를 돌려준다. `recordPending`은 반환값이 없어 `PENDING`/`BLOCKED`를 이벤트로만 알 수 있기 때문이다. 파이썬에서는 `async`로 기다린다.

## 4. 결과와 실패

| 종류 | 모양 | 온체인 |
| --- | --- | --- |
| 정상 | `TxResult(tx_hash, status, block_reason)` | 기록됨 |
| revert | `ChainRevert(reason, detail)` | **바뀌지 않음** |
| 연결 실패 | `ChainUnavailable` | **들어갔는지 모름** |
| 입력 형식 오류 | `ValueError` — 모델 생성 시, 서명은 메서드 호출 시 | 체인에 보내기 전에 막힘 |

**`BLOCKED`는 예외가 아니다.** 트랜잭션은 성공했고 예산 조건 위반이 기록된 것이다. 에러 처리 분기에 넣지 말 것.

**`ChainUnavailable`이면 바로 재시도하지 않는다.** 먼저 `get_entry(id)`로 들어갔는지 확인한다. 확정·반려 때는 항목이 원래 있으므로 `None`인지가 아니라 `status`로 판단한다.

| 메서드 | 이미 들어간 것으로 보는 조건 | 확인 없이 다시 보내면 |
| --- | --- | --- |
| `record_pending` | `get_entry(id)`가 `None`이 아님 | `ENTRY_ALREADY_EXISTS`로 revert |
| `confirm_entry` | `status`가 `CONFIRMED` | `INVALID_STATUS`로 revert |
| `reject_entry` | `status`가 `REJECTED` | `INVALID_STATUS`로 revert |

계획표가 요구한 세 가지:

| 상황 | 모양 | DB 처리 |
| --- | --- | --- |
| 서명 불일치 (등록) | `ChainRevert(NOT_REGISTRANT)` | `status` NULL 유지 |
| 서명 불일치 (확정·반려) | `ChainRevert(NOT_APPROVER)` | `PENDING` 유지 |
| 등록 시 예산 초과 | `TxResult(status=BLOCKED, block_reason=BUDGET_EXCEEDED)` | `BLOCKED` 저장, 사유 표시 |
| 확정 시 잔량 부족 | `ChainRevert(INSUFFICIENT_BUDGET)` | `PENDING` 유지, 반려 흐름으로 |
| 확정 시 예산 마감 경과 | `ChainRevert(BUDGET_EXPIRED)` | `PENDING` 유지, 반려 흐름으로 |
| 승인·반려자가 본 값 ≠ 등록 값 | `ChainRevert(ENTRY_COMMIT_MISMATCH)` | `PENDING` 유지. 앱에 최신 항목 값을 다시 내려준다 (§5) |

`INSUFFICIENT_BUDGET`·`BUDGET_EXPIRED`는 `BudgetToken`이 `confirmEntry` 안에서 내는 에러지만, 원장 ABI에도 같은 시그니처로 선언돼 있어 **원장 ABI 하나로 해석된다.** `RESERVED_ID`(id 0)는 중복(`ENTRY_ALREADY_EXISTS`)과 다른 에러다 — 재시도 판정에 쓰지 않는다.

**서명 불일치는 `INVALID_SIGNATURE`로 오지 않는다.** EIP-712 서명은 형식만 맞으면 다른 데이터에 대한 서명이어도 실패하지 않고 엉뚱한 주소를 복구해 낸다. 컨트랙트에는 권한 없는 사람이 서명한 것으로 보여서 `NOT_REGISTRANT`·`NOT_APPROVER`가 난다. `INVALID_SIGNATURE`는 서명 바이트 자체가 깨졌을 때만 난다. 그래서 revert만으로는 "앱이 다른 값에 서명함"과 "정말 권한이 없는 사람"을 구분할 수 없다 (§7).

`RevertReason`의 값은 Solidity 에러 이름 그대로다 (`"InvalidSignature"` 등). 전체 목록은 `backend/app/chain/models.py`.

**체인 호출 전에 막는 것**

- 모델 생성 시 — 해시·`entry_commit`이 `0x` + 소문자 hex 64자가 아님, `id`가 0 이하, `occurred_at`이 음수이거나 KST 자정이 아님 (HASHING §1.3, §5), `term`이 학기 코드 `YYYYS`가 아님 (DB `Term.id`를 넘기는 실수를 여기서 막는다)
- 메서드 호출 시 — 서명이 `0x` + hex 130자가 아님. 대소문자 모두 받고 소문자로 바꿔 쓴다

서명 검사의 `ValueError`는 `ChainError`가 아니다. `ChainError`만 잡으면 500으로 새어 나가므로 API 입력 검증에서 먼저 막거나 따로 잡는다.

## 5. 승인·반려는 `entryCommit`에도 서명한다

`meta_hash`에는 `kind`·`term`·`budgetId`·`correctsId`가 없어서, 해시만 대조하면 다른 예산으로 등록된 항목도 승인이 통과한다. 그래서 `ConfirmApproval`·`RejectDecision`에 `entry_commit`이 들어간다 (식은 `docs/CONTRACTS.md` "공통 규칙").

```python
from app.chain import entry_commit, entry_commit_of

entry_commit(hash=..., amount=..., kind=..., term=..., occurred_at=..., budget_id=..., corrects_id=..., registrant=...)
entry_commit_of(chain_entry)  # get_entry 결과로 계산. 원장의 entryCommitOf(id) 와 같다
```

- 서버는 승인 화면에 **체인에 등록된 값**(`get_entry`)을 내려주고, 앱은 그 값으로 `entry_commit`을 직접 계산해 화면 내용과 함께 서명한다
- 릴레이 전에 서버가 `approval.entry_commit == entry_commit_of(get_entry(id))`를 먼저 확인하면, 어긋날 때 가스를 쓰지 않고 400으로 끝낼 수 있다
- 기대값은 `backend/tests/test_entry_commit.py`에 ethers로 뽑은 값으로 고정돼 있다. 식을 바꾸면 기대값도 ethers로 다시 뽑는다

## 6. FakeChainClient

입력과 이미 기록된 항목만으로 판정되는 원장 규칙은 `IAccountingLedger`의 검사 순서대로 흉내 낸다 — 중복 id, 해시 0, 금액 0·상한, 저장 폭, 정정 아닌 음수, 수입의 예산 id, 정정 대상(없음·미확정·종류·학기·대상 제한·예산·누적 한도), 상태 전이, 해시·`entry_commit` 불일치, 경고·반려 사유, 서명 시한, 예산 id 0인 양수 지출(`BLOCKED`, `BUDGET_NOT_FOUND`). 서명자 권한(`NOT_REGISTRANT`·`NOT_APPROVER`), 예산 상태(`TERM_MISMATCH`(예산)·`INSUFFICIENT_BUDGET`·`BUDGET_EXPIRED`·등록 시 `BLOCKED`)처럼 체인 상태가 필요한 결과와 연결 실패는 직접 지정한다.

```python
from app.chain import FakeChainClient, RevertReason, BlockReason, fake_signature

chain = FakeChainClient(clock=lambda: 1_790_000_000)  # 시각 고정. 생략하면 time.time

TREASURER = "0x1111111111111111111111111111111111111111"
sig = fake_signature(TREASURER)  # TREASURER 가 서명한 것으로 취급. 부를 때마다 다른 문자열

chain.block_next(BlockReason.BUDGET_EXCEEDED)                       # 다음 지출 등록을 BLOCKED 로
chain.fail_next("confirm_entry", RevertReason.INSUFFICIENT_BUDGET)  # 다음 확정을 revert
chain.fail_next("record_pending", RevertReason.NOT_REGISTRANT)      # 서명 불일치 (§4)
chain.unavailable_next("record_pending")                            # 연결 실패. 체인에 안 들어감
chain.unavailable_next("confirm_entry", landed=True)                # 체인엔 들어갔는데 응답만 못 받음
```

- `fail_next`·`unavailable_next`는 한 번만 적용된다. `fail_next`는 상태를 바꾸지 않는다
- `unavailable_next(landed=True)`는 체인에서 평소대로 처리한 뒤(성공이든 revert든) `ChainUnavailable`을 던진다
- 메서드 이름은 파이썬 이름(`record_pending`, `confirm_entry`, `reject_entry`)이다. 다른 값이면 `ValueError`
- `block_next`는 예산 id가 0이 아닌 **양수** 지출에만 적용된다. 수입과 음수 정정(환불)은 예산 판정을 건너뛴다
- 서명자는 서명의 앞 20바이트다. **같은 주소로 만든 서명으로 등록·확정하면 `SELF_APPROVAL`**이 난다. 테스트에서는 `fake_signature`로 서명을 만든다
- 실제 체인은 승인 권한을 먼저 보므로, **지금 총무인 사람**이 자기 건을 승인하면 `SELF_APPROVAL`이 아니라 `NOT_APPROVER`가 난다. `SELF_APPROVAL`은 등록 뒤 롤이 바뀐 경우에만 난다. 롤을 모르는 Fake는 이 둘을 구분하지 못하니 `NOT_APPROVER`는 `fail_next`로 지정한다
- `clock`을 넘기지 않으면 현재 시각으로 `deadline`을 판정한다. 고정된 `deadline`을 쓰는 테스트는 `clock`도 고정한다

## 7. 아직 정할 것

- `deadline` 값 — 서명 후 릴레이까지 얼마나 유효한가
- 한 id에 확정·반려 서명을 둘 다 릴레이하지 않는 장치 — ChainClient 안인지 서비스 계층인지 (`docs/CONTRACTS.md` EIP-712 절의 서버 규칙)
- ~~앱이 서명에 쓸 EIP-712 도메인을 내려주는 경로~~ → `GET /chain/domains` (API.md 「체인」). 배포 기록은 `app/chain/deployment.py`가 읽고, 실제 릴레이어도 여기서 주소를 읽는다
- ③에서 서버가 서명자를 먼저 복구해 확인할지 — revert만으로는 서명 불일치와 권한 없음을 구분할 수 없다 (§4)
- 예산·롤 릴레이 — `BudgetToken`(발행·증액·회수)과 `RoleManager`(롤 변경·회장 복구)도 서명 + 릴레이어 방식이다. 같은 모양으로 메서드를 더한다. 두 컨트랙트에는 원장과 이름이 같은 에러(`TermRequired`·`ReservedId` 등)가 있어 **어느 컨트랙트에서 났는지까지** 보고 분류한다
- ~~반려 사유·경고 사유 필수 검사~~ → `REASON_REQUIRED`·`REASON_NOT_ALLOWED`로 반영됨
