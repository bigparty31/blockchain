# CHAIN_CLIENT — 백엔드가 체인을 부르는 입구

작성 손종인 · 대상 김경윤(등록 API), 이승호(등록·승인 화면) · 코드 `backend/app/chain/`

이번 주는 **모양만** 정한다. 김경윤은 `FakeChainClient`로 등록 API를 끝까지 만들고, 다음 주에 실제 릴레이어로 갈아끼운다. 호출하는 쪽 코드는 바꾸지 않는다.

| 이번 주 | 다음 주 |
| --- | --- |
| `AccountingLedger` 등록·확정·반려, `getEntry` 조회 | 예산·이의·SBT·롤, 실제 릴레이어, deadline 정책, 중복 릴레이 방지 |

서명은 ChainClient가 만들지 않는다. 임원 기기가 서명한 값을 받아 릴레이만 한다 (PRD §9.2).

---

## 1. 등록은 두 단계다

총무가 서명하는 `RecordRequest` 안에 `id`가 들어 있고, `id`는 DB auto-increment다 (`docs/CONTRACTS.md` 공통 규칙). **서명하려면 id를 먼저 알아야 하는데, id는 저장해야 생긴다.** 서명은 기기 생체인증이라 서버 요청 중간에 끼워 넣을 수 없고, 서버가 대신 서명할 수도 없다. 그래서 한 번에 끝나지 않는다.

```
① 앱 → 서버   입력값          서버: 검증 · 정규화(HASHING §1.1) · DB 저장 · id 채번  →  id 반환
② 앱          id 를 넣은 RecordRequest 구성, meta_hash 직접 계산, 생체인증 서명
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

`getEntry`는 없는 id에도 0으로 채운 구조체를 돌려주고, status 0은 `PENDING`이다. 그대로 옮기면 없는 항목이 `PENDING`으로 보이므로 실제 구현은 `exists(id)`를 먼저 확인해 없으면 `None`을 돌려준다.

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

**서명 불일치는 `INVALID_SIGNATURE`로 오지 않는다.** EIP-712 서명은 형식만 맞으면 다른 데이터에 대한 서명이어도 실패하지 않고 엉뚱한 주소를 복구해 낸다. 컨트랙트에는 권한 없는 사람이 서명한 것으로 보여서 `NOT_REGISTRANT`·`NOT_APPROVER`가 난다. `INVALID_SIGNATURE`는 서명 바이트 자체가 깨졌을 때만 난다. 그래서 revert만으로는 "앱이 다른 값에 서명함"과 "정말 권한이 없는 사람"을 구분할 수 없다 (§6).

`RevertReason`의 값은 Solidity 에러 이름 그대로다 (`"InvalidSignature"` 등). 전체 목록은 `backend/app/chain/models.py`.

**체인 호출 전에 막는 것**

- 모델 생성 시 — 해시가 `0x` + 소문자 hex 64자가 아님, `id`가 0 이하, `occurred_at`이 음수이거나 KST 자정이 아님 (HASHING §1.3, §5)
- 메서드 호출 시 — 서명이 `0x` + hex 130자가 아님. 대소문자 모두 받고 소문자로 바꿔 쓴다

서명 검사의 `ValueError`는 `ChainError`가 아니다. `ChainError`만 잡으면 500으로 새어 나가므로 API 입력 검증에서 먼저 막거나 따로 잡는다.

## 5. FakeChainClient

입력만으로 판정되는 컨트랙트 규칙은 그대로 흉내 낸다 — 중복 id, 금액 0, 정정 아닌 음수, 정정 대상 없음·미확정, 상태 전이, 해시 불일치, 서명 시한, 예산 id 0인 지출(`BLOCKED`, `BUDGET_NOT_FOUND`). 서명자·권한·예산 잔량처럼 체인 상태가 필요한 결과와 연결 실패는 직접 지정한다.

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
- `block_next`는 예산 id가 0이 아닌 지출에만 적용된다. 수입 등록은 예산 검사를 안 한다
- 서명자는 서명의 앞 20바이트다. **같은 주소로 만든 서명으로 등록·확정하면 `SELF_APPROVAL`**이 난다. 테스트에서는 `fake_signature`로 서명을 만든다
- `clock`을 넘기지 않으면 현재 시각으로 `deadline`을 판정한다. 고정된 `deadline`을 쓰는 테스트는 `clock`도 고정한다

## 6. 다음 주에 정할 것

자리만 두고 이번 주엔 정하지 않았다.

- `deadline` 값 — 서명 후 릴레이까지 얼마나 유효한가
- 한 id에 확정·반려 서명을 둘 다 릴레이하지 않는 장치 — ChainClient 안인지 서비스 계층인지
- 반려 사유·경고 사유 필수 검사 — `AccountingLedger` 구현 때 revert로 추가 예정. 에러 이름이 정해지면 `RevertReason`에 넣는다
- 앱이 서명에 쓸 EIP-712 도메인(`chainId`, `verifyingContract`)을 내려주는 경로
- ③에서 서버가 서명자를 먼저 복구해 확인할지 — revert만으로는 서명 불일치와 권한 없음을 구분할 수 없다 (§4)
