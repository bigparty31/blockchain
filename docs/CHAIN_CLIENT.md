# CHAIN_CLIENT — 백엔드가 체인을 부르는 입구

작성 손종인 · 대상 김경윤(등록·승인·이의 API), 이승호(등록·승인 화면) · 코드 `backend/app/chain/`

김경윤은 `FakeChainClient`와 릴레이(`docs/RELAY.md`)로 API를 끝까지 만든다. 배포 주소가 나오면 `CHAIN_CLIENT=web3`로 갈아끼운다. 호출하는 쪽 코드는 바꾸지 않는다.

| 됐다 | 남았다 (§8) |
| --- | --- |
| 원장 등록·확정·반려·조회, 롤·SBT·예산 조회, 이의 제기·답변 — 인터페이스·Fake·실제 구현(노드 없이 검증). 등록·확정·반려 릴레이, 멈춘 트랜잭션 재전송, 장부 잔액 집계, 학생 지갑 파생, meta_hash 모듈, 팩토리·주기 작업 | 컨트랙트 구현 뒤 통합 테스트, 예산·롤 부여·SBT 발급의 서명 방식(상의), 서버 연결 |

서명은 ChainClient가 만들지 않는다. 임원 기기가 서명한 값을 받아 릴레이만 한다 (PRD §9.2).

---

## 1. 등록은 두 단계다

총무가 서명하는 `RecordRequest` 안에 `id`가 들어 있고, `id`는 DB auto-increment다 (`docs/CONTRACTS.md` 공통 규칙). **서명하려면 id를 먼저 알아야 하는데, id는 저장해야 생긴다.** 서명은 기기 생체인증이라 서버 요청 중간에 끼워 넣을 수 없고, 서버가 대신 서명할 수도 없다. 그래서 한 번에 끝나지 않는다.

```
① 앱 → 서버   입력값                      서버: 검증 · 정규화 · id 예약 · 초안 저장  →  id 반환
② 앱          RecordRequest 구성, meta_hash 직접 계산, 생체인증 서명
③ 앱 → 서버   meta_hash + deadline + 서명  서버: 해시·서명자 확인  →  record_pending  →  Entry 생성
```

흐름·상태·실패 처리는 **`docs/RELAY.md`**, 코드는 `backend/app/relay/`.

## 2. 체인에 올리기 전 값은 Entry에 두지 않는다

`PENDING`은 **온체인에 기록됐다**는 뜻이다 (PRD §4.3). ①에서 저장만 된 값은 Entry가 아니라 **초안 테이블**에 두고, 체인에 들어간 뒤에 Entry 행을 만든다.

- Entry의 `status`는 지금 그대로다. NULL이 없다
- `docs/enums.md`는 바꾸지 않는다
- 목록·잔액·결산·검증은 Entry만 읽으면 된다. 초안을 거르는 조건이 필요 없다

## 3. 인터페이스 — `app/chain/client.py`

**`ChainClient` — AccountingLedger**

| 메서드 | 컨트랙트 | 돌려주는 값 |
| --- | --- | --- |
| `record_pending(request, signature)` | `recordPending` | `TxResult` — `PENDING` · `BLOCKED` |
| `confirm_entry(approval, signature)` | `confirmEntry` | `TxResult` — `CONFIRMED` |
| `reject_entry(decision, signature)` | `rejectEntry` | `TxResult` — `REJECTED` |
| `get_entry(entry_id)` | `exists` → `getEntry` | `ChainEntry`, 없으면 `None` |
| `get_record_result(entry_id)` | `EntryPending`·`EntryBlocked` 이벤트 | 등록 때의 `TxResult`, 없으면 `None` |
| `get_decision_result(entry_id)` | `EntryConfirmed`·`EntryRejected` 이벤트 | 확정·반려 때의 `DecisionRecord`, 없으면 `None` |

**그 밖의 인터페이스**

| 인터페이스 | 메서드 | 쓰는 곳 |
| --- | --- | --- |
| `LedgerEvents` | `safe_block()`, `confirmed_entries(from, to)` | 장부 잔액 집계 (§6.2) |
| `RoleReader` | `has_role(role, account)` | 릴레이의 보내기 전 롤 확인 (RELAY §4, §9) |
| `ObjectionClient` | `raise_objection`, `answer_objection`, `get_objection` | 이의 API |
| `MembershipReader` | `has_valid_membership`, `token_of`, `get_membership` | 이의 제기 전 회원 확인, 학생 화면 |
| `BudgetReader` | `get_budget`, `remaining` | 예산 집행률 화면. 잔량은 `remaining()`이 정본이다 (CONTRACTS 이벤트 절) |

**두지 않은 것** — 예산 발행·증액·회수, 롤 부여·키 교체, SBT 발급·소각. 호출자가 회장·감사 본인(`msg.sender`)이라 릴레이할 수 없다 (§8).

`getEntry`·`getObjection`은 없는 id에도 0으로 채운 구조체를 돌려준다. 그대로 옮기면 없는 항목이 `PENDING`·`OPEN`으로 보이므로 `exists(id)`를 먼저 확인한다.

`get_record_result`·`get_decision_result`는 쓰기 메서드의 응답을 못 받았을 때(연결 실패, 서버 재시작) tx 해시와 `BLOCKED` 사유를 되찾는 용도다. `getEntry`에는 둘 다 없다.

**`DecisionRecord`** — 확정·반려 결과(`confirm_entry`·`reject_entry`·`get_decision_result`)는 `TxResult`에 `approver`, `had_warning`, `warning_reason_hash`, `reason_hash`, `block_number`를 더해 돌려준다. 단건 검증(HASHING §2)은 경고 무시 승인 사유·반려 사유를 `getEntry`가 아니라 이 이벤트 값으로 대조한다.

주소(`registrant`·`approver`·`raiser`·`responder`)는 EIP-55 체크섬 주소(대소문자 섞임)다. DB의 `wallet_address`와 비교할 때는 **양쪽을 소문자로 맞춘다.** Fake도 같은 형식으로 돌려준다.

쓰기 메서드는 **트랜잭션이 블록에 들어갈 때까지 기다린 뒤** 최종 상태를 돌려준다. `recordPending`은 반환값이 없어 `PENDING`/`BLOCKED`를 이벤트로만 알 수 있기 때문이다.

**롤** — `Role.TREASURER`·`AUDITOR`·`PRESIDENT`. 식별자는 이름의 keccak256(`Role.X.id`)이고 enum 숫자가 아니다. 확정·반려 서명자는 `AUDITOR`·`PRESIDENT`, 이의 답변 서명자는 임원 셋 모두다 (`docs/CONTRACTS.md` 함수 표).

### 서명 대상 — `app/chain/eip712.py`

- `typed_data(domain, struct)` — 앱이 서명할 typed data (`eth_signTypedData_v4` 모양)
- `recover_signer(domain, struct, signature)` — 서명자 주소. 체인에 보내기 전에 서버가 확인하는 데 쓴다
- `domain_separator(domain)` — 컨트랙트의 `DOMAIN_SEPARATOR()`와 같아야 하는 값. 시작 점검이 비교한다
- 도메인은 컨트랙트마다 다르다 — `name`이 컨트랙트명이다 (`docs/CONTRACTS.md` "EIP-712"). 원장은 `settings.domain`(`"AccountingLedger"`), 이의 답변은 `settings.objection_domain`(`"ObjectionRegistry"`)
- 구조체(`RecordRequest`·`ConfirmApproval`·`RejectDecision`·`AnswerRequest`) 타입 문자열이 `.sol`의 typehash 주석과 같은지 테스트가 확인한다

## 4. 결과와 실패

| 종류 | 모양 | 온체인 |
| --- | --- | --- |
| 정상 | `TxResult(tx_hash, status, block_reason)` · 이의는 `ObjectionTx(tx_hash, status)` | 기록됨 |
| revert | `ChainRevert(reason, detail, data)` | **바뀌지 않음** |
| 보내지 못함 | `ChainNotSent(message, tx_hash)` — 보내기 전 RPC 실패, 노드가 거부(잔고 부족·nonce 어긋남 등) | **들어가지 않음이 확정.** 같은 서명으로 다시 보내도 된다 |
| 연결 실패 | `ChainUnavailable(message, tx_hash)` — 보낸 뒤 결과를 모름 | **들어갔는지 모름** |
| 입력 형식 오류 | `ValueError` — 모델 생성 시, 서명은 메서드 호출 시 | 체인에 보내기 전에 막힘 |
| 설정 오류 | `ChainConfigError` — chainId·주소·도메인·롤 식별자·ABI가 체인과 다름 | 재시도로 안 풀린다. `ChainError`가 아니다 |

**`BLOCKED`는 예외가 아니다.** 트랜잭션은 성공했고 예산 조건 위반이 기록된 것이다. 에러 처리 분기에 넣지 말 것.

**`ChainNotSent`와 `ChainUnavailable`을 나누는 이유** — 보내지 못한 것이 확실한데 "결과 모름"으로 두면, 릴레이가 서명 시한 + 120초 동안 `SUBMITTING`으로 묶고 반대 결정까지 막는다. 그래서 릴레이는 `ChainNotSent`면 바로 `FAILED(NotSent)`로, `ChainUnavailable`이면 `SUBMITTING`으로 두고 대조에 맡긴다. `eth_sendRawTransaction`이 "already known"으로 거부하면 이미 멤풀에 있다는 뜻이라 보낸 것으로 본다.

**`ChainUnavailable`이면 바로 재시도하지 않는다.** 먼저 들어갔는지 확인한다. 확정·반려 때는 항목이 원래 있으므로 `None`인지가 아니라 `status`로 판단한다. 릴레이가 이것을 대신 한다 (RELAY §5, §9).

| 메서드 | 이미 들어간 것으로 보는 조건 | 확인 없이 다시 보내면 |
| --- | --- | --- |
| `record_pending` | `get_entry(id)`가 `None`이 아님 | `ENTRY_ALREADY_EXISTS`로 revert |
| `confirm_entry` | `status`가 `CONFIRMED` | `INVALID_STATUS`로 revert |
| `reject_entry` | `status`가 `REJECTED` | `INVALID_STATUS`로 revert |
| `raise_objection` | `get_objection(id)`가 `None`이 아님 | `OBJECTION_ALREADY_EXISTS`로 revert |
| `answer_objection` | `status`가 `ANSWERED` | `OBJECTION_ALREADY_ANSWERED`로 revert |

계획표가 요구한 세 가지:

| 상황 | 모양 | 처리 |
| --- | --- | --- |
| 서명 불일치 | 릴레이가 체인 전에 `RelayError(SIGNER_MISMATCH)` | 그대로, 다시 서명 |
| 등록 시 예산 초과 | `TxResult(status=BLOCKED, block_reason=BUDGET_EXCEEDED)` | Entry를 `BLOCKED`로 만들고 사유 표시 |
| 확정 시 잔량 부족 | `ChainRevert(INSUFFICIENT_BUDGET)` | `PENDING` 유지, 반려 흐름으로 |

**서명 불일치는 `INVALID_SIGNATURE`로 오지 않는다.** EIP-712 서명은 형식만 맞으면 다른 데이터에 대한 서명이어도 실패하지 않고 엉뚱한 주소를 복구해 낸다. 컨트랙트에는 권한 없는 사람이 서명한 것으로 보여서 `NOT_REGISTRANT`·`NOT_APPROVER`·`NOT_RESPONDER`가 난다. `INVALID_SIGNATURE`는 서명 바이트 자체가 깨졌을 때만 난다.

revert만으로는 "앱이 다른 값에 서명함"과 "정말 권한이 없는 사람"을 구분할 수 없다. 그래서 릴레이는 체인에 보내기 전에 서버에서 서명자를 복구해 비교하고, 롤 조회를 붙이면 롤도 먼저 본다 (RELAY §4, §9).

**`RevertReason`** — 값은 Solidity 에러 이름 그대로다. 전체 목록은 `backend/app/chain/models.py`.

- `confirmEntry`는 `BudgetToken.spend`·`refund`를 부르므로 `INSUFFICIENT_BUDGET` 말고도 `BUDGET_EXPIRED`(등록 뒤 예산 마감이 지남), `BUDGET_NOT_FOUND`, `REFUND_EXCEEDS_SPENT`(감액 정정이 소모액보다 큼)가 올 수 있다. 모두 항목은 `PENDING` 그대로다. `BUDGET_EXPIRED`를 어떻게 처리할지는 정하지 않았다 (RELAY §8)
- 에러는 **호출한 컨트랙트의 ABI로만** selector를 찾는다 — 원장 호출은 AccountingLedger·BudgetToken, 이의는 ObjectionRegistry. 이름이 같고 뜻이 다른 에러(RoleManager의 `SelfApproval(uint256)` 등)를 엉뚱하게 옮기지 않기 위해서다. 이름이 같고 인자만 다른 에러(`ZeroAmount(uint256)`·`ZeroAmount()`)는 같은 값이 된다
- **목록에 없는 에러·`require` 문자열·panic은 `UNKNOWN`** 이다. 에러 이름·인자는 `detail`에, 원본 revert 데이터는 `data`에 남는다

**체인 호출 전에 막는 것**

- 모델 생성 시 — 해시가 `0x` + 소문자 hex 64자가 아님, `id`가 0 이하, `occurred_at`이 음수이거나 KST 자정이 아님 (HASHING §1.3, §5)
- 메서드 호출 시 — 서명이 `0x` + hex 130자가 아님(대소문자 모두 받고 소문자로 바꿔 쓴다), 주소·해시 형식

서명 검사의 `ValueError`는 `ChainError`가 아니다. `ChainError`만 잡으면 500으로 새어 나가므로 API 입력 검증에서 먼저 막거나 따로 잡는다. 릴레이는 이것을 `RelayError(INVALID_SIGNATURE)`로 바꿔 준다.

## 5. FakeChainClient

`ChainClient`·`LedgerEvents`·`RoleReader`·`ObjectionClient`·`MembershipReader`·`BudgetReader`를 한 객체로 흉내 낸다. 트랜잭션 하나가 블록 하나다.

입력만으로 판정되는 컨트랙트 규칙은 그대로 흉내 낸다 — 중복 id, 금액 0, 정정 아닌 음수, 정정 대상 없음·미확정, 상태 전이, 해시 불일치, 서명 시한, 예산 id 0인 지출(`BLOCKED`, `BUDGET_NOT_FOUND`), 이의 중복·대상 항목·이미 답변됨. 예산 잔량·학기 회원 여부처럼 체인 상태가 필요한 결과와 연결 실패는 직접 지정한다.

```python
from app.chain import FakeChainClient, RevertReason, BlockReason, Role, fake_signature, fake_recover_signer

chain = FakeChainClient(clock=lambda: 1_790_000_000)  # 시각 고정. 생략하면 time.time
# FakeChainClient(enforce_roles=True) 면 grant_role 로 준 롤이 없는 서명자를 NotRegistrant 등으로 거부한다

TREASURER = "0x1111111111111111111111111111111111111111"
sig = fake_signature(TREASURER)  # TREASURER 가 서명한 것으로 취급. 부를 때마다 다른 문자열

chain.grant_role(Role.TREASURER, TREASURER)
chain.grant_membership(STUDENT, term=20262)                         # SBT 가 이미 발급된 상태로
chain.set_budget(ChainBudget(...), remaining=1_500_000)             # 예산이 발행된 상태로 (확정과 잔량은 연결하지 않는다)
chain.block_next(BlockReason.BUDGET_EXCEEDED)                       # 다음 지출 등록을 BLOCKED 로
chain.fail_next("confirm_entry", RevertReason.INSUFFICIENT_BUDGET)  # 다음 확정을 revert
chain.fail_next("raise_objection", RevertReason.NOT_MEMBER)         # 회원 아님
chain.unavailable_next("record_pending")                            # 연결 실패. 체인에 안 들어감
chain.unavailable_next("confirm_entry", landed=True)                # 체인엔 들어갔는데 응답만 못 받음
chain.unavailable_next("get_entry")                                 # 조회 연결 실패
chain.not_sent_next("record_pending")                               # 보내지 못함 (잔고 부족 등). 상태 그대로
```

- `fail_next`·`unavailable_next`는 한 번만 적용된다. `fail_next`는 상태를 바꾸지 않는다
- `unavailable_next(landed=True)`는 체인에서 평소대로 처리한 뒤(성공이든 revert든) `ChainUnavailable`을 던진다. 조회 메서드에는 `landed`가 의미 없다
- 메서드 이름은 파이썬 이름이다. `fail_next`는 쓰기 메서드만, `unavailable_next`는 조회 메서드도 받는다. 다른 값이면 `ValueError`
- 롤은 **`enforce_roles=True`일 때만** 검사한다. 기본값은 검사하지 않아 기존 테스트가 롤을 몰라도 된다
- `raise_objection`은 회원 여부를 보지 않는다. 컨트랙트가 어느 학기 기준으로 `NotMember`를 판정하는지 정해지지 않았다 (§8). 필요하면 `fail_next`로 지정한다
- `block_next`는 예산 id가 0이 아닌 지출에만 적용된다. 수입 등록은 예산 검사를 안 한다
- 서명자는 서명의 앞 20바이트다. **같은 주소로 만든 서명으로 등록·확정하면 `SELF_APPROVAL`**이 난다. 서버의 서명자 확인 자리에는 `fake_recover_signer`를 넣는다
- `clock`을 넘기지 않으면 현재 시각으로 `deadline`을 판정한다. 고정된 `deadline`을 쓰는 테스트는 `clock`도 고정한다

## 6. 실제 구현

```python
from app.chain import create_chain_services

services = create_chain_services()  # CHAIN_CLIENT=fake | web3
warnings = await services.check()   # 서버 시작 때. 어긋나면 ChainConfigError
services.ledger, services.roles, services.objections, services.memberships, services.budgets, services.events
services.recover_signer, services.recover_answer_signer  # 원장 도메인, 이의 도메인
```

`CHAIN_CLIENT`가 없으면 에러다 — 실수로 가짜 체인이 운영에 붙지 않게 하려는 것이다.

**구성** — 릴레이어 계정이 하나라서 **`Web3Relayer` 하나를 모든 클라이언트가 나눠 쓴다.** nonce를 여기서 관리하므로 따로 만들면 둘이 같은 nonce를 골라 한쪽 트랜잭션이 밀려난다. 팩토리가 이렇게 묶어 준다.

| 클래스 | 컨트랙트 | 설정 |
| --- | --- | --- |
| `Web3ChainClient` | AccountingLedger (`ChainClient`·`LedgerEvents`) | 필수 |
| `Web3RoleReader` | RoleManager | `CHAIN_ROLE_MANAGER_ADDRESS` 있을 때 |
| `Web3ObjectionClient` | ObjectionRegistry | `CHAIN_OBJECTION_ADDRESS` 있을 때 |
| `Web3MembershipReader` | MembershipSBT | `CHAIN_MEMBERSHIP_ADDRESS` 있을 때 |
| `Web3BudgetReader` | BudgetToken (조회만) | `CHAIN_BUDGET_ADDRESS` 있을 때 |

**설정** — 환경변수. 앞의 넷은 필수다.

| 환경변수 | 뜻 | 기본값 |
| --- | --- | --- |
| `CHAIN_RPC_URL` | 노드 주소 | — |
| `CHAIN_ID` | 31337 Hardhat 로컬, 80002 Polygon Amoy | — |
| `CHAIN_LEDGER_ADDRESS` | AccountingLedger 주소 | — |
| `CHAIN_RELAYER_KEY` | 가스를 대납하는 서버 계정 키. **임원 키가 아니다.** 저장소에 넣지 않는다 | — |
| `CHAIN_ROLE_MANAGER_ADDRESS` · `CHAIN_OBJECTION_ADDRESS` · `CHAIN_MEMBERSHIP_ADDRESS` · `CHAIN_BUDGET_ADDRESS` | 없으면 그 클라이언트를 붙이지 않는다 | — |
| `CHAIN_DEPLOY_BLOCK` | 컨트랙트 중 가장 이른 배포 블록. 이벤트를 여기까지만 거슬러 찾는다 | 0 |
| `CHAIN_CONFIRMATIONS` | 보낸 뒤 포함된 블록을 1로 세어 이만큼 쌓일 때까지 응답을 기다린다 | 1 |
| `CHAIN_FINALITY_BLOCKS` | 잔액 집계용. 노드가 `finalized` 태그를 못 줄 때 head에서 이만큼 뒤까지만 확정으로 본다 | 64 |
| `CHAIN_RECEIPT_TIMEOUT_SECONDS` | 넘으면 `ChainUnavailable`. 재전송·확인 블록 대기 포함 | 120 |
| `CHAIN_REPLACE_AFTER_SECONDS` · `CHAIN_MAX_REPLACEMENTS` · `CHAIN_FEE_BUMP` | 재전송 간격 · 최대 횟수 · 수수료 배수 | 30 · 3 · 1.25 |
| `CHAIN_LOG_CHUNK_BLOCKS` | `eth_getLogs` 한 번에 볼 블록 수. 공개 RPC는 범위를 제한한다 | 2000 |
| `CHAIN_GAS_BUFFER` · `CHAIN_POLL_SECONDS` · `CHAIN_MIN_RELAYER_BALANCE_WEI` | 가스 여유 배수 · 조회 간격 · 잔고 경고 기준 | 1.2 · 2 · 0.1 ETH |

**시작 점검 (`check`)** — chainId가 설정과 같은지, 주소마다 컨트랙트가 있는지, 원장·이의의 `DOMAIN_SEPARATOR()`가 서버 계산값과 같은지, RoleManager의 `TREASURER()` 등이 서버가 쓰는 keccak256(이름)과 같은지. 도메인이 다르면 모든 서명이 권한 없음으로 실패하므로 시작 단계에서 막는다. 릴레이어 잔고가 적으면 경고만 돌려준다.

**보내는 순서**

1. **가스 추정** — revert 될 호출은 여기서 `ChainRevert`로 끝난다. 보내지 않았으니 가스도 안 쓴다. RPC가 실패하면 `ChainNotSent`
2. **nonce** — 락 안에서 순서대로 준다. 노드가 전송을 거부하면 `ChainNotSent`, 연결이 끊기면 `ChainUnavailable`이고, 어느 쪽이든 다음 전송 때 nonce를 체인에서 다시 읽는다
3. **수수료** — EIP-1559. `maxFeePerGas = 기본료 × 2 + 우선 수수료`
4. **전송 → 영수증 대기** — `CHAIN_REPLACE_AFTER_SECONDS` 동안 안 들어가면 **같은 nonce로 수수료를 올려 다시 보낸다** (직전 수수료 × `CHAIN_FEE_BUMP`와 지금 시세 중 큰 값. 노드는 10% 이상 올려야 교체를 받는다). 보낸 것 중 먼저 들어간 것의 영수증을 쓴다. 같은 nonce라 둘 이상 들어갈 수 없다. 재전송이 거부되면(앞선 것이 이미 들어감 등) 앞선 것을 계속 기다린다
5. **확인 블록 대기** — 블록 번호 조회가 잠깐 실패해도 시한까지 계속 기다린다. 기다리는 사이 블록이 바뀌면 `ChainUnavailable`
6. **영수증이 실패(status 0)면** — 영수증에는 이유가 없어서 직전 블록 상태로 다시 실행해 revert 데이터를 얻는다

재전송이 없으면 한 건이 멤풀에 멈췄을 때 뒤따르는 nonce가 줄줄이 밀린다. 재전송해도 `CHAIN_RECEIPT_TIMEOUT_SECONDS` 안에 안 들어가면 **같은 nonce로 0원 자기 전송을 수수료를 더 올려 보내 그 nonce를 비운다** (기다리지 않는다). 원래 트랜잭션이 먼저 들어가면 이 전송은 거부되는데, 어느 쪽이든 nonce는 소모돼 뒤 트랜잭션이 막히지 않는다. 이 전송마저 보내지 못하면 다음 전송 때 nonce를 체인에서 다시 읽는다. 호출한 쪽에는 마지막으로 보낸 tx 해시를 담아 `ChainUnavailable`을 던지고, 서명 시한이 지나면 대조가 실패로 정리한다.

**이벤트 조회** — `get_record_result`·`get_decision_result`는 id로 걸러 최신 블록부터 `CHAIN_DEPLOY_BLOCK`까지 `CHAIN_LOG_CHUNK_BLOCKS`씩 거슬러 찾는다. 대조는 대개 최근 항목을 찾기 때문이다. `EntryPending`과 `EntryBlocked`가 함께 오면 `BLOCKED`로 읽는다. `confirmed_entries`는 앞에서부터 나눠 읽는다.

**ABI** — `backend/app/chain/abi/*.json`(인터페이스 5개)은 `contracts/interfaces/`에서 뽑은 것이다. 인터페이스가 바뀌면 `python scripts/export_abi.py`로 다시 뽑아 함께 커밋한다. IMembershipSBT가 import하는 OpenZeppelin은 저장소 루트의 `node_modules`가 있으면 그것을, 없으면 고정 버전(v5.0.2) 파일만 받아 쓴다. 구현이 나오면 구현에만 있는 에러가 더해질 수 있으니 한 번 더 뽑는다.

**검증 범위** — `tests/fake_node.py`의 가짜 JSON-RPC 노드에 붙여 web3.py의 요청·응답·예외를 실제로 거친다. 인코딩, 에러 변환, 이벤트 해석, nonce(원장·이의가 나눠 쓸 때 포함), 재전송, 확인 블록, 시작 점검까지다. **컨트랙트가 실제로 그렇게 동작하는지는 확인하지 않았다** (§8).

### 6.1 학생 지갑 — `app/chain/wallets.py`

`StudentWallets(mnemonic).address(wallet_index)` — `m/44'/60'/0'/0/{index}` 주소 (PRD §9.2). 서버 시작 때 한 번 만든다. 만들 때 공통 경로까지 한 번 내려가고 니모닉·시드는 들고 있지 않으며, 학생마다 마지막 한 단계만 계산하고 주소를 캐시한다. 한 번만 쓸 때는 `student_address(mnemonic, index)`. 학생은 체인에 쓰지 않으므로 서버가 쓰는 것은 이의 제기의 `raiser`와 SBT 발급 대상 주소뿐이라 **주소만** 만든다. 니모닉은 환경변수 `STUDENT_WALLET_MNEMONIC`으로 받고 저장소에 넣지 않는다. `User.wallet_index`가 경로 마지막 숫자다.

### 6.2 장부 잔액 집계 — `app/chain/aggregate.py`

```
장부 잔액 = Σ EntryConfirmed.amount (INCOME) − Σ EntryConfirmed.amount (EXPENSE)
```

`LedgerAggregator(events, totals_store).refresh()` — 마지막으로 반영한 블록 다음부터 `safe_block()`까지의 `EntryConfirmed`만 읽어 합계를 갱신하고 저장한다. `safe_block()`은 노드의 `finalized` 블록이고, 태그를 못 주면 head − `CHAIN_FINALITY_BLOCKS`다 — 저장한 합계는 되돌리지 않으므로 보낼 때의 확인 블록 수(기본 1)보다 깊게 본다. 정정 항목은 음수로 오므로 그대로 더한다. `PENDING`·`REJECTED`·`BLOCKED`는 들어가지 않는다. 체인을 못 읽으면 저장된 합계는 그대로다.

예산 잔량은 여기서 계산하지 않는다 — `BudgetToken.remaining()`이 정본이다 (`docs/CONTRACTS.md`). 합계를 저장할 곳(`TotalsStore`)의 DB 구현은 서버 연결 때 붙인다.

### 6.3 주기 작업 — `app/relay/runner.py`

`run_periodically([(이름, 작업), ...], interval_seconds, stop)` — 등록·결정 대조와 잔액 집계를 일정 간격으로 돌린다. **한 작업이 실패해도 로그만 남기고 다음 작업과 다음 회차를 계속한다.** 대조가 한 번 실패했다고 멈추면 `SUBMITTING`이 영영 마무리되지 않기 때문이다. 서버 시작 때 백그라운드 태스크로 띄우고 끝낼 때 `stop`을 켠다.

## 7. 실행과 테스트

Python 3.10 이상 (web3.py·eth-account 요구).

```
cd backend
pip install -r requirements-dev.txt
pytest
```

## 8. 남은 것

**컨트랙트 구현이 나와야 하는 것 (장석연)**

- Hardhat 로컬 노드 통합 테스트 — 배포 → `check` → 등록·확정·반려·이의 → revert 매핑 → 이벤트 조회 → 재전송. 가짜 노드로는 컨트랙트 동작을 확인할 수 없다
- 구현 ABI로 다시 뽑기, Amoy 배포 주소·배포 블록, 릴레이어 계정과 테스트 토큰
- 반려·경고 사유 필수 검사의 에러 이름 → `RevertReason`에 넣는다

**상의해야 하는 것**

- ⚠️ **예산·롤·SBT 쓰기 함수는 지금 인터페이스로 릴레이할 수 없다** (장석연) — `BudgetToken.issue`·`increase`·`reclaim`, `RoleManager.grantRole`·`revokeRole`·`proposeKeyRotation`·`approveKeyRotation`, `MembershipSBT.mintBatch`·`burn`은 서명 인자가 없어 `msg.sender`가 행위자다 (`docs/CONTRACTS.md` 함수 표: 호출자 PRESIDENT 등). PRD는 회장·감사가 기기에서 서명하고 서버가 가스를 대납하는 구조라 이대로는 맞지 않는다. 임원 기기가 가스를 내고 직접 보내거나, 인터페이스에 EIP-712 서명 버전을 더해야 한다. **이벤트·함수 모양은 배포 뒤 바꾸기 어려우니 구현 전에 정한다**
- `raise`의 `NotMember`는 어느 학기 기준인가 (장석연) — 원장 항목에는 학기가 없다 (HASHING §8). 서버가 보내기 전에 `has_valid_membership`으로 확인하려면 기준이 필요하다
- SBT commitment 규칙 (손종인 결정, 김경윤 ERD) — `keccak256(abi.encodePacked(studentId, salt))`에서 `studentId`의 타입(문자열·숫자)과 인코딩, `salt` 길이가 정해지지 않았다. 나중에 대조하려면 `salt`를 저장할 칼럼도 필요한데 PRD §8의 `Membership`에는 없다
- 이의 제기·답변을 등록 릴레이처럼 제출 상태로 관리할지 (김경윤, 이의 API) — 체인 호출은 됐지만, 응답을 못 받았을 때 누가 대조할지는 이의 API 설계와 함께 정한다
- 등록·확정·반려 흐름의 상의할 것은 RELAY §8

**나중에 고칠 것**

- 이벤트 조회 범위 — `get_record_result`·`get_decision_result`는 최신 블록부터 `CHAIN_DEPLOY_BLOCK`까지 거슬러 찾는다. 운영이 몇 달을 넘기거나 오래된 항목을 자주 검증하게 되면 느려진다. 초안·결정에 저장된 `deadline` 전후 블록만 보거나, 체인 이벤트를 DB에 모아 두는 방식(체인 이벤트 집계)으로 바꾼다. 메서드 모양은 그대로라 호출하는 쪽은 바꾸지 않는다

**합의 뒤 붙일 것**

- 서버 연결 — `main.py`에서 `create_chain_services`·`check` 호출, FastAPI 의존성 주입, `run_periodically` 시작, 라우터
- DB 구현 — `DraftStore`·`DecisionStore`·`TotalsStore`
