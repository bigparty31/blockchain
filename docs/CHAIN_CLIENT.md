# CHAIN_CLIENT — 백엔드가 체인을 부르는 입구

작성 손종인 · 대상 김경윤(등록 API), 이승호(등록·승인 화면) · 코드 `backend/app/chain/`

지금은 **모양만** 정한다. 김경윤은 `FakeChainClient`로 등록 API를 끝까지 만들고, 나중에 실제 릴레이어로 갈아끼운다. 호출하는 쪽 코드는 바꾸지 않는다. 형식의 정본은 PR #13으로 머지된 `contracts/interfaces/IAccountingLedger.sol`이다.

| 지금 | 다음 |
| --- | --- |
| `AccountingLedger` 등록·확정·반려, `getEntry` 조회. 실제 릴레이어(`Web3ChainClient`)는 등록(`record_pending`)·조회(`get_entry`)까지, 배포 기록 읽기, 중복 전송 방지(`before_broadcast`), deadline 결정(§7) | 실제 릴레이어의 확정·반려, 한 id에 확정·반려 서명을 동시에 발급하지 않는 서버 규칙, 재시도. 예산(`BudgetToken`)·롤(`RoleManager`) 릴레이 — 둘 다 서명 + 릴레이어 방식이 됐다. 이의·SBT는 컨트랙트가 아직 없다 |

서명은 ChainClient가 만들지 않는다. 임원 기기가 서명한 값을 받아 릴레이만 한다 (PRD §9.2).

---

## 1. 등록은 두 단계다

총무가 서명하는 `RecordRequest` 안에 `id`가 들어 있고, `id`는 DB auto-increment다 (`docs/CONTRACTS.md` 공통 규칙). **서명하려면 id를 먼저 알아야 하는데, id는 저장해야 생긴다.** 서명은 기기 생체인증이라 서버 요청 중간에 끼워 넣을 수 없고, 서버가 대신 서명할 수도 없다. 그래서 한 번에 끝나지 않는다.

```
① 앱 → 서버   입력값          서버: 검증 · 정규화(HASHING §1.1) · DB 저장 · id 채번  →  id 반환
② 앱          id·term(학기 코드) 을 넣은 RecordRequest 구성, meta_hash 직접 계산, 생체인증 서명
③ 앱 → 서버   서명 + deadline  서버: 앱이 보낸 hash == 서버가 계산한 hash 확인
                              ·  signer_of(request, 서명) == 등록한 총무의 지갑 확인
                              →  record_pending  →  PENDING 또는 BLOCKED 저장
```

③에서 해시와 서명자를 먼저 대조하는 이유 — 어긋나면 체인에 올리기 전에 400으로 끝낼 수 있다. 가스도 안 쓰고, 원인도 등록 시점에 드러난다. API 이름·경로는 김경윤이 정한다.

## 2. 아직 제출 안 된 항목의 status는 NULL

`PENDING`은 **온체인에 기록됐다**는 뜻이다 (PRD §4.3). ①에서 저장만 된 초안에 `PENDING`을 쓰면 학생 앱에 체인에 없는 "승인대기"가 뜬다.

- ① 직후 `status = NULL`, ③이 성공하면 `PENDING` 또는 `BLOCKED`로 채운다
- `docs/enums.md`는 바꾸지 않는다
- 학생 앱·목록 API는 `status IS NULL`인 항목을 내려주지 않는다

## 3. 메서드

| 메서드 | 컨트랙트 | 돌려주는 status |
| --- | --- | --- |
| `record_pending(request, signature, before_broadcast=None)` | `recordPending` | `PENDING` · `BLOCKED` |
| `confirm_entry(approval, signature, before_broadcast=None)` | `confirmEntry` | `CONFIRMED` |
| `reject_entry(decision, signature, before_broadcast=None)` | `rejectEntry` | `REJECTED` |
| `get_entry(entry_id)` | `getEntry` | 없으면 `None` |
| `signer_of(payload, signature)` | 부르지 않음 | 서명자 주소 (§4). 동기 메서드 |

`getEntry`는 없는 id에도 0으로 채운 구조체(`registrant == 0`)를 돌려주고, status 0은 `PENDING`이다. 그대로 옮기면 없는 항목이 `PENDING`으로 보이므로 실제 구현은 `exists(id)`를 먼저 확인해 없으면 `None`을 돌려준다. (`statusOf`는 없는 id면 `EntryNotFound`로 revert한다.) 반환 튜플 순서는 저장 배치를 따르므로 **위치가 아니라 필드 이름으로 읽는다** (HASHING §2).

`ChainEntry.term`은 학기 코드 `YYYYS`다. **DB의 `Term.id`가 아니다** — 체인에 넘길 때와 비교할 때 `Term`의 학기 코드로 바꾼다.

`registrant`·`approver`는 web3.py가 돌려주는 EIP-55 체크섬 주소(대소문자 섞임)다. DB의 `wallet_address`와 비교할 때는 **양쪽을 소문자로 맞춘다.** Fake도 같은 형식으로 돌려준다.

쓰기 메서드는 **트랜잭션이 블록에 들어갈 때까지 기다린 뒤** 최종 상태를 돌려준다. `recordPending`은 반환값이 없어 `PENDING`/`BLOCKED`를 이벤트로만 알 수 있기 때문이다. 파이썬에서는 `async`로 기다린다.

**`before_broadcast`** (세 쓰기 메서드의 선택 인자) — 트랜잭션에 서명해 hash가 정해진 뒤, **체인에 보내기 직전에** 그 hash로 불린다. 서비스는 여기서 `tx_pending`(확정·반려는 `tx_confirm`)을 조건부 UPDATE(`WHERE tx_pending IS NULL AND status IS NULL`)로 선점한다. 처리 중 상태가 보내기 전에 DB에 남아 같은 항목을 두 번 보내지 않고, 응답을 잃어도 어느 트랜잭션인지 안다.

**선점은 자기 콜백이 불렸을 때만 다룬다.** 서비스는 콜백 안에서 선점하니 콜백이 불렸는지 안다. 같은 결과(`ChainRevert`·`ChainUnavailable`)가 콜백 **전에도** 올 수 있다 — 시뮬레이션 revert, 시뮬레이션·nonce 조회 중 연결 실패. 그때는 선점도 없으니 `tx_pending`을 건드리지 않는다. 그 값은 다른 요청의 선점일 수 있다.

| 자기 콜백이 불린 뒤의 결과 | DB 처리 |
| --- | --- |
| 콜백이 예외를 던짐 | **보내지 않는다.** 그 예외가 그대로 올라온다 (선점 실패 = 다른 요청이 처리 중) |
| 결과(`PENDING`·`BLOCKED`) | `status`를 채운다 |
| `ChainRevert` | 체인에 남은 것이 없다. **선점한 `tx_pending`을 비운다** (다시 초안) |
| `ChainSetupError` | 노드가 전송을 거절했다(릴레이어 잔액 부족, nonce). 들어가지 않았으니 **선점한 `tx_pending`을 비운다.** 응답은 503 |
| `ChainUnavailable` | `tx_pending`을 둔 채 `get_entry`로 확인한다 (§4) |

콜백은 릴레이어 lock을 쥔 채 불린다. **콜백 안에서 같은 클라이언트로 다시 보내거나 닫지 않는다** — 영원히 기다리게 되므로 실제 구현과 Fake 모두 바로 `RuntimeError`를 낸다. 콜백은 DB 선점만 한다.

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
| 앱이 다른 값에 서명함 (등록·확정·반려) | `signer_of` 결과 ≠ 기대 지갑. **체인에 보내지 않는다** | 400. `status` NULL·`PENDING` 그대로 |
| 서명자는 맞는데 등록 권한 없음 | `ChainRevert(NOT_REGISTRANT)` | `status` NULL 유지 |
| 서명자는 맞는데 승인 권한 없음 | `ChainRevert(NOT_APPROVER)` | `PENDING` 유지 |
| 등록 시 예산 초과 | `TxResult(status=BLOCKED, block_reason=BUDGET_EXCEEDED)` | `BLOCKED` 저장, 사유 표시 |
| 확정 시 잔량 부족 | `ChainRevert(INSUFFICIENT_BUDGET)` | `PENDING` 유지, 반려 흐름으로 |
| 확정 시 예산 마감 경과 | `ChainRevert(BUDGET_EXPIRED)` | `PENDING` 유지, 반려 흐름으로 |
| 승인·반려자가 본 값 ≠ 등록 값 | `ChainRevert(ENTRY_COMMIT_MISMATCH)` | `PENDING` 유지. 앱에 최신 항목 값을 다시 내려준다 (§5) |
| 체인이 거부했지만 원인을 해석할 수 없음 | `ChainRevert(UNKNOWN)` | 상태 그대로. **500 + 서버 로그** (`detail`에 원본) |

`INSUFFICIENT_BUDGET`·`BUDGET_EXPIRED`는 `BudgetToken`이 `confirmEntry` 안에서 내는 에러지만, 원장 ABI에도 같은 시그니처로 선언돼 있어 **원장 ABI 하나로 해석된다.** `RESERVED_ID`(id 0)는 중복(`ENTRY_ALREADY_EXISTS`)과 다른 에러다 — 재시도 판정에 쓰지 않는다.

**서명 불일치는 `INVALID_SIGNATURE`로 오지 않는다.** EIP-712 서명은 형식만 맞으면 다른 데이터에 대한 서명이어도 실패하지 않고 엉뚱한 주소를 복구해 낸다. 컨트랙트에는 권한 없는 사람이 서명한 것으로 보여서 `NOT_REGISTRANT`·`NOT_APPROVER`가 난다. `INVALID_SIGNATURE`는 서명 바이트 자체가 깨졌을 때만 난다. 그래서 revert만으로는 "앱이 다른 값에 서명함"과 "정말 권한이 없는 사람"을 구분할 수 없다. **그래서 서버가 릴레이 전에 `signer_of`로 서명자를 복구해 기대 지갑(등록은 `created_by`의 지갑, 확정·반려는 요청한 감사·회장의 지갑)과 소문자로 맞춰 비교한다.** 이 검사를 통과한 뒤에 오는 `NOT_REGISTRANT`·`NOT_APPROVER`는 서명자의 롤 문제다 (등록 뒤 롤이 바뀐 경우 등).

`RevertReason`의 값은 Solidity 에러 이름 그대로다 (`"InvalidSignature"` 등). 전체 목록은 `backend/app/chain/models.py`. 해석은 `backend/app/chain/revert.py`가 원장 ABI로 한다.

**예외는 `UNKNOWN` 하나다.** revert는 확실하지만(온체인 상태 그대로) 원인을 해석할 수 없을 때 쓴다 — 원장 ABI에 없는 에러(BudgetToken 고유 에러 등), `RevertReason`에 없는 원장 에러(생성자 전용), 빈 revert 데이터, `Panic`, `Error(string)`. 원본은 `detail`에 남는다. 연결 실패와는 다르다 — 그쪽은 `ChainUnavailable`이고 트랜잭션이 들어갔는지 모른다. `detail`은 `id=5, current=BLOCKED, expected=PENDING`처럼 인자를 ABI 이름으로 적은 로그·디버깅용 문자열이고 화면 문구로 쓰지 않는다.

revert는 시뮬레이션(`eth_call`)뿐 아니라 **전송 응답**으로도 온다 — Hardhat은 revert하는 트랜잭션도 블록에 넣고 `eth_sendRawTransaction`에 에러를 돌려준다. 둘 다 결과가 확정된 `ChainRevert`다. 반면 노드가 전송 자체를 거절한 경우(릴레이어 잔액 부족, nonce)는 revert가 아니고 트랜잭션도 들어가지 않았다. 이 구분은 전송 경로가 한다.

연결할 때 `RevertReason`이 전부 원장 ABI에 있는지 확인한다. 컨트랙트 에러 이름이 바뀌면 revert가 모두 `UNKNOWN`이 되므로, 그 전에 `ChainSetupError`로 막는다.

**체인 호출 전에 막는 것**

- 모델 생성 시 — 해시·`entry_commit`이 `0x` + 소문자 hex 64자가 아님, `id`가 0 이하, `occurred_at`이 음수이거나 KST 자정이 아님 (HASHING §1.3, §5), `term`이 학기 코드 `YYYYS`가 아님 (DB `Term.id`를 넘기는 실수를 여기서 막는다)
- 메서드 호출 시 — 서명이 `0x` + hex 130자가 아님. 대소문자 모두 받고 소문자로 바꿔 쓴다
- 서비스가 `signer_of`로 — 서명자가 기대 지갑과 다름(400). 실제 구현은 컨트랙트가 `INVALID_SIGNATURE`로 거부할 서명(v가 27·28·0·1이 아님, high-s)과 EIP-712 타입 범위를 넘는 값(uint256·int256)도 여기서 `ValueError`로 막는다

실제 구현의 쓰기 메서드는 보내기 전에 서명을 컨트랙트가 받는 모양(v 27·28, low-s)으로 맞춘다. 호출자는 앱이 준 서명을 그대로 넘긴다.

**보내는 순서와 실패** — 실제 구현은 릴레이어 lock 안에서 시뮬레이션(`estimate_gas`) → nonce → 로컬 서명 → `before_broadcast` → 전송 → receipt 순서로 한다. revert할 요청은 시뮬레이션에서 가스 없이, 콜백 전에 걸린다. 시뮬레이션은 **다음 블록(pending) 기준**이다 — Hardhat은 블록이 없으면 최신 블록 시각이 낡아, 최신 블록 기준이면 이미 만료된 서명이 시뮬레이션을 통과하고 채굴에서 revert한다.

| 전송 단계의 상황 | 결과 | 체인 |
| --- | --- | --- |
| 전송 응답이 revert (Hardhat은 revert하는 트랜잭션도 블록에 넣는다) | `ChainRevert` | 상태 그대로, 릴레이어 nonce만 쓰임 |
| 릴레이어 잔액 부족 | `ChainSetupError` → 503 | 들어가지 않음 |
| nonce가 낮음 (다른 프로세스가 같은 키로 보냄 — 워커 2개 이상) | `ChainSetupError` → 503 | 들어가지 않음 |
| 같은 트랜잭션이 이미 노드에 있음 ("already known") | receipt를 기다려 정상 처리 | — |
| 연결 실패, receipt 30초 초과, 그 밖 | `ChainUnavailable` | 모름 → `get_entry` |

receipt가 실패(`status` 0)로 오는 노드(Hardhat 외)에서는 그 블록 직전 상태로 다시 불러 revert 사유를 얻는다.

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
chain.fail_next("record_pending", RevertReason.NOT_REGISTRANT)      # 서명자의 등록 권한 없음 (§4)
chain.unavailable_next("record_pending")                            # 연결 실패. 체인에 안 들어감
chain.unavailable_next("confirm_entry", landed=True)                # 체인엔 들어갔는데 응답만 못 받음
```

- `fail_next`·`unavailable_next`는 한 번만 적용된다. `fail_next`는 상태를 바꾸지 않는다
- `unavailable_next(landed=True)`는 체인에서 평소대로 처리한 뒤(성공이든 revert든) `ChainUnavailable`을 던진다
- 메서드 이름은 파이썬 이름(`record_pending`, `confirm_entry`, `reject_entry`)이다. 다른 값이면 `ValueError`
- `block_next`는 예산 id가 0이 아닌 **양수** 지출에만 적용된다. 수입과 음수 정정(환불)은 예산 판정을 건너뛴다
- 서명자는 서명의 앞 20바이트다. **같은 주소로 만든 서명으로 등록·확정하면 `SELF_APPROVAL`**이 난다. 테스트에서는 `fake_signature`로 서명을 만든다
- `before_broadcast`는 실제 구현과 같은 시점에 부른다 — 검사를 통과한 뒤, 상태를 바꾸기 전. 검사에서 걸리면 부르지 않고, 콜백이 예외를 던지면 상태와 지정(`block_next`·`unavailable_next`)이 그대로다
- 쓰기는 실제 구현처럼 lock 안에서 한 줄로 처리한다. 콜백이 await하는 동안 같은 id가 또 와도 두 번째는 `ENTRY_ALREADY_EXISTS`다
- `unavailable_next(method, landed=False, sent=True)` — `sent=False`는 보내기 전(시뮬레이션 중) 끊김이라 콜백이 불리지 않는다(선점 없는 `ChainUnavailable`). `sent=True`는 보낸 뒤 응답을 못 받은 것이라 콜백이 불리고, `landed`가 기록 여부다. revert할 입력은 지정과 상관없이 `ChainRevert`로 먼저 끝나고 지정은 남는다
- 같은 시나리오를 Fake와 실제 체인에 돌려 결과와 `get_entry` 값이 같은지 `backend/tests/test_chain_parity.py`가 확인한다
- `signer_of`는 그 주소를 돌려준다. 가짜 서명은 값에 묶여 있지 않아 payload는 보지 않는다 — "앱이 다른 값에 서명함"을 흉내 내려면 다른 주소로 `fake_signature`를 만든다
- 실제 체인은 승인 권한을 먼저 보므로, **지금 총무인 사람**이 자기 건을 승인하면 `SELF_APPROVAL`이 아니라 `NOT_APPROVER`가 난다. `SELF_APPROVAL`은 등록 뒤 롤이 바뀐 경우에만 난다. 롤을 모르는 Fake는 이 둘을 구분하지 못하니 `NOT_APPROVER`는 `fail_next`로 지정한다
- `clock`을 넘기지 않으면 현재 시각으로 `deadline`을 판정한다. 고정된 `deadline`을 쓰는 테스트는 `clock`도 고정한다

## 7. 아직 정할 것

- ~~`deadline` 값~~ → 기존 규정대로 나눈다. **만료 판정은 컨트랙트**(`SignatureExpired`, 검사 순서 1)라 ChainClient는 시뮬레이션에서 `ChainRevert(SIGNATURE_EXPIRED)`로 돌려준다. **발급 기본값(발급 + 10분)과 만료된 초안의 410·400은 API 규정**(API.md §2.3)이라 등록 API가 검사한다. 주의 — Hardhat은 블록이 없으면 최신 블록 시각이 마지막 블록에 머무른다. 그래서 실제 구현은 다음 블록(pending) 시각으로 시뮬레이션해, 이미 만료된 서명을 보내기 전에 거른다. deadline은 실제 시각 기준으로 정한다
- 한 id에 확정·반려 서명을 둘 다 릴레이하지 않는 장치 — ChainClient 안인지 서비스 계층인지 (`docs/CONTRACTS.md` EIP-712 절의 서버 규칙)
- ~~앱이 서명에 쓸 EIP-712 도메인을 내려주는 경로~~ → `GET /chain/domains` (API.md 「체인」). 배포 기록은 `app/chain/deployment.py`가 읽고, 실제 릴레이어도 여기서 주소를 읽는다
- ~~③에서 서버가 서명자를 먼저 복구해 확인할지~~ → 확인한다. 서비스가 `ChainClient.signer_of`로 복구한 주소를 기대 지갑과 비교하고, 다르면 체인에 보내지 않는다 (§4). 서비스가 `app/chain/eip712.py`를 직접 부르지 않는 이유는 FakeChainClient로도 같은 흐름을 테스트하기 위해서다
- 예산·롤 릴레이 — `BudgetToken`(발행·증액·회수)과 `RoleManager`(롤 변경·회장 복구)도 서명 + 릴레이어 방식이다. 같은 모양으로 메서드를 더한다. 두 컨트랙트에는 원장과 이름이 같은 에러(`TermRequired`·`ReservedId` 등)가 있어 **어느 컨트랙트에서 났는지까지** 보고 분류한다
- ~~반려 사유·경고 사유 필수 검사~~ → `REASON_REQUIRED`·`REASON_NOT_ALLOWED`로 반영됨

## 8. 클라이언트 받기 — provider

API에서는 구현을 직접 만들지 않고 의존성으로 받는다. Fake와 실제 구현이 환경변수로 갈린다.

```python
from fastapi import Depends
from app.chain import ChainClient
from app.chain.provider import get_chain_client

@router.post("/entries/{id}/submit")
async def submit(id: int, req: ..., chain: ChainClient = Depends(get_chain_client)):
    ...
```

| 환경변수 | 비었을 때 | 있을 때 |
| --- | --- | --- |
| `CHAIN_RPC_URL` | `FakeChainClient` + **경고 로그** (가짜 서명이 통과하므로 개발·테스트 전용) | `Web3ChainClient` (예: `http://127.0.0.1:8545`) |
| `RELAYER_PRIVATE_KEY` | — | 릴레이어 전용 키 (로컬은 Hardhat 계정 4). **임원 키를 넣으면 시작을 거부한다** (PRD §9.2) |

- 실제 클라이언트는 **첫 요청 때** 연결하고 재사용한다. 노드가 꺼져 있어도 체인을 쓰지 않는 API는 돈다
- 연결할 때 점검한다 — 체인 id, 원장 코드 존재, `DOMAIN_SEPARATOR`, 원장의 RoleManager·BudgetToken, 릴레이어에 롤 없음, 릴레이어 잔액
- 점검·연결 실패는 `ChainSetupError`(배포 기록 문제는 하위 클래스 `DeploymentError`)이고 **API는 503**을 돌려준다 (`app/main.py`). 메시지에 원인과 해결 방법이 있다 — 예: "원장 주소에 컨트랙트가 없다 … `npm run deploy:local`"
- 요청마다 재배포·노드 재시작을 확인해, 있었으면 다시 연결한다. **서버를 다시 켤 필요가 없다.** 배포 기록·ABI 파일은 수정 시각이 바뀌었을 때만 다시 읽고, 원장 코드는 5초 간격으로만 확인한다
- **확실히 낡았을 때만** 교체한다. 노드에 닿지 못해 확인할 수 없으면 그대로 쓰고, 실제 호출이 실패를 알린다 — 일시적 실패로 교체하면 보내던 트랜잭션과 엇갈린다
- 연결할 때 컨트랙트끼리 가리키는 주소(원장↔BudgetToken↔RoleManager)와 세 컨트랙트의 `DOMAIN_SEPARATOR`·코드 존재를 확인한다. 일부만 다시 배포된 조합은 시작을 거부한다
- 릴레이어 키 하나로 트랜잭션을 보내므로 전송은 **릴레이어 주소마다 lock 하나**로 직렬화한다. 클라이언트를 교체해도 같은 lock을 쓰고, 교체된 클라이언트는 보내던 트랜잭션이 끝난 뒤 닫힌다. 다른 프로세스와는 나누지 못하니 **uvicorn 워커는 1개**로 띄운다 (`--workers` 를 주지 않는 기본값)
- 테스트는 `reset_chain_client()`로 만들어 둔 클라이언트를 버리고, 실제 연결은 `close_chain_client()`로 닫는다
