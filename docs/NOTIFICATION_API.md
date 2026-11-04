# 알림 API 명세 (초안)

작성 손종인 · 대상 이승호(알림함·뱃지·폴링), 김경윤(이벤트 호출), 장석연(`kind` 승인) · 근거 PRD v0.13 §4.1, §4.3, §4.8, §4.9, §8

**구현 전 초안이다.** 앱은 이 형태로 먼저 만들 수 있다. 경로와 응답 형태는 PRD에 없어 제안한 값이고, 「확인이 필요한 것」이 정해지면 바뀔 수 있다. 구현 완료 후 확정본을 `docs/API.md`에 옮긴다.

## 공통

- 세 API 모두 `Authorization: Bearer <access_token>`이 필요하다. 오류는 `API.md` 인증 §3과 같다
- 역할 제한은 없고, **본인 알림만** 조회·처리한다
- **학생은 알림을 받지 않는다** (§4.8). 학생이 호출하면 빈 목록과 `0`이 온다
- 시각은 다른 API와 같이 Unix 초(정수)다
- 1단계에서 앱은 폴링으로 받는다. FCM과 `DeviceToken` API는 2단계라 여기 없다

## 1. 목록 (`GET /notifications`)

| 쿼리 | 기본값 | 설명 |
|---|---|---|
| `unread_only` | `false` | `true`면 안 읽은 알림만 |
| `limit` | `50` | 최대 100 |

**정렬:** 안 읽은 알림 먼저, 그 안에서 `notified_at` 최신순. `notified_at`은 마지막으로 알린 시각이다 — 처음에는 `created_at`과 같고 재알림 때 갱신된다. `created_at` 기준이면 재알림이 와도 위로 올라오지 않는다. 시연 규모라 페이지 넘김은 두지 않는다.

다른 승인자가 먼저 처리한 건(`resolved_at` 있음)은 응답에 나오지 않는다 (§4.8 자동 정리).

**Response (`200 OK`)**
```json
[
  {
    "id": 12,
    "kind": "ENTRY_REGISTERED",
    "entry_id": 34,
    "budget_revision_request_id": null,
    "body": "새 지출 내역이 등록되었습니다. 승인이 필요합니다.",
    "created_at": 1793548800,
    "notified_at": 1793548800,
    "read_at": null,
    "remind_count": 0
  }
]
```

- `body`는 서버가 만든 문구다. 앱은 그대로 표시한다
- 어디로 이동할지는 `entry_id`·`budget_revision_request_id` 중 값이 있는 것으로 정한다
- 앱이 모르는 `kind`가 와도 `body`를 표시한다. 오류로 처리하지 않는다

## 2. 안 읽은 수 (`GET /notifications/unread-count`)

뱃지 폴링용이다. 자동 정리된 건은 세지 않는다.

**Response (`200 OK`)**
```json
{ "count": 3 }
```

## 3. 읽음 처리 (`POST /notifications/{id}/read`)

- 이미 읽은 알림을 다시 호출해도 `200`이다
- 없는 알림과 다른 사람의 알림은 구분하지 않고 `404`다

**Response (`200 OK`)**
```json
{ "id": 12, "read_at": 1793552400 }
```

## 재알림과 읽음

- 임원이 처리할 건에만 붙는다 (§4.8). 아래 표에서 「재알림」이 O인 종류다
- 주기는 PRD 그대로다: 24시간 뒤, 이후 24시간마다 최대 3회, 72시간이 지나면 다른 승인자에게도 알린다. 간격은 서버 설정값이다
- **읽음은 처리가 아니다.** 읽어도 처리되지 않으면 재알림이 간다
- 재알림은 같은 알림 행의 `read_at`을 비우고 `remind_count`를 올리고 `notified_at`을 갱신한다. 새 알림이 아니지만 뱃지에 다시 잡히고 목록 위로 올라온다
- 처리되면 받는 사람 전원에게서 **「재알림」이 O인 종류만** 목록과 재알림에서 빠진다. 확정·반려 같은 결과 통보는 처리할 일이 아니라 남는다

**72시간 뒤 추가로 알릴 대상.** §4.8의 「다른 승인자」를 종류별로 적으면 지금은 대상이 없다. 받을 수 있는 사람이 처음부터 모두 받기 때문이다.

| `kind` | 처음 받는 사람 | 72시간 뒤 추가 대상 |
|---|---|---|
| `ENTRY_REGISTERED`, `ENTRY_EDIT_REQUESTED` | 감사 전원, 회장 | 없음. 승인자 전원이 이미 받았다 |
| `REVISION_REQUESTED` | 회장 | 없음. 회장은 1명이고 증액 요청 서명은 회장만 한다 |
| `REVISION_PRESIDENT_SIGNED` | 감사 전원 | 없음. 증액 승인은 감사만 한다 |
| `SIGNATURE_DEADLINE_NEAR` | 감사 전원 | 없음. 같은 이유다 |

표는 §4.8의 「감사」를 감사 전원으로 읽은 것이다. 이 표대로면 72시간 규칙은 구현하지 않는다. 추가 대상이 생기면 그 사람의 **새 행**을 만든다 — 위의 「같은 행」은 이미 받은 사람에게 다시 알릴 때만이다.

## `kind` 값

이벤트와 받는 사람은 §4.8이다. 값은 `docs/enums.md`의 notification kind와 같다 (PR #31). 증액 쪽은 `REVISION_*`, T4 수정 요청은 `ENTRY_EDIT_REQUESTED`다 — 「개정」은 예산 용어다. 이의 제기는 v0.13 범위 밖이라 없다.

| `kind` | 이벤트 | 받는 사람 | 연결 | 재알림 |
|---|---|---|---|---|
| `ENTRY_REGISTERED` | 지출·수입·정정 등록 | 감사 전원, 회장 | `entry_id` | O |
| `ENTRY_EDIT_REQUESTED` | T4 수정 요청 (§4.3) | 감사 전원, 회장 | `entry_id` | O |
| `ENTRY_CONFIRMED` | 확정 | 총무 | `entry_id` | |
| `ENTRY_REJECTED` | 반려 | 총무 | `entry_id` | |
| `ENTRY_CONFIRM_FAILED` | 확정 실패 (아래 「확정 실패의 기준」) | 총무 | `entry_id` | |
| `ENTRY_BLOCKED` | `BLOCKED` | 총무, 회장 | `entry_id` | |
| `REVISION_REQUESTED` | 증액 요청, 시한 만료 후 재서명 요청 (§4.1) | 회장 | `budget_revision_request_id` | O |
| `REVISION_PRESIDENT_SIGNED` | 회장 서명 완료 | 감사 | `budget_revision_request_id` | O |
| `REVISION_APPROVED` | 증액 승인 | 총무, 회장 | `budget_revision_request_id` | |
| `REVISION_REJECTED` | 증액 반려 | 총무, 회장 | `budget_revision_request_id` | |
| `ROLE_CHANGE_REQUESTED` | 롤 변경 서명 요청 (시연할 때만) | 상대 서명자 | 없음 | |
| `PRESIDENT_RECOVERY_PROPOSED` | 회장 복구 제안 (시연할 때만) | 회장, 감사 | 없음 | |
| `RECLASSIFY_PAIR_UNCONFIRMED` | 재분류 짝 미확정 | 해당 처리자 | `entry_id` | |
| `SIGNATURE_DEADLINE_NEAR` | 서명 시한 임박 | 해당 처리자 | `budget_revision_request_id` | O |

## 서버 함수 (김경윤 호출용)

위치는 `app/services/notifications.py`다. **11/7 테이블이 생기기 전까지는 아무것도 하지 않는 빈 함수다.** 호출은 지금부터 넣어도 된다.

```python
def create_notification(
    db: Session,
    kind: NotificationKind,
    *,
    entry_id: Optional[int] = None,
    budget_revision_request_id: Optional[int] = None,
    user_ids: Optional[Iterable[int]] = None,
) -> None:
    """알림 행을 db 세션에 추가한다. commit 하지 않는다."""


def resolve_notifications(
    db: Session,
    *,
    entry_id: Optional[int] = None,
    budget_revision_request_id: Optional[int] = None,
) -> None:
    """처리된 건의 알림 중 재알림 대상 종류만 받는 사람 전원에게서 닫는다. commit 하지 않는다."""
```

- **상태 변경과 같은 세션으로 부르고, 호출한 쪽이 함께 commit 한다** (§4.8). 롤백되면 알림도 남지 않는다
- 받는 사람은 `kind`에 따라 함수가 정한다. `user_ids`는 「해당 처리자」처럼 표만으로 정해지지 않는 종류에만 넘긴다
- `resolve_notifications`는 「재알림」이 O인 종류(`ENTRY_REGISTERED`, `ENTRY_EDIT_REQUESTED`, `REVISION_REQUESTED`, `REVISION_PRESIDENT_SIGNED`, `SIGNATURE_DEADLINE_NEAR`)만 닫는다. 총무가 받을 `ENTRY_CONFIRMED`·`ENTRY_REJECTED` 같은 결과 통보는 닫지 않는다
- **한 처리에서 둘 다 부르면 `resolve_notifications`를 먼저 부른다.** 증액은 다음 단계 알림도 재알림 대상이라, 순서가 바뀌면 방금 만든 `REVISION_PRESIDENT_SIGNED`까지 닫힌다
- 문구(`body`)는 인자로 받지 않는다. 서버가 `kind`로 만든다

**호출 위치 (제안)**

| 이벤트 | 어디서 | 담당 |
|---|---|---|
| 등록, `BLOCKED`, 확정, 반려 | `chain_tx.py`의 상태 반영 단계 (`settle`). `_update`가 1행일 때만 | 손종인 |
| 확정 실패 | `relay_confirm`의 `ChainRevert` 처리. 상태 반영이 없어 자체 세션으로 commit | 손종인 |
| T4 수정 요청 | 수정 요청 라우터 | 김경윤 |
| 증액 요청, 회장 서명 완료, 증액 승인·반려 | 예산 라우터 | 김경윤 |
| 시한 만료 후 재서명 요청 | 만료 처리 함수 | 김경윤 |
| 재분류 짝 미확정, 서명 시한 임박 | 재알림 작업 | 손종인 |

체인을 거치는 항목 이벤트를 `chain_tx.py`에 둔 이유: 상태 반영은 `chain_tx.py`가 자기 세션으로 commit 하고 라우터는 그 결과만 받는다. 그래서 라우터에서 부르면 §4.8의 「같은 트랜잭션」이 될 수 없다. 재제출로 같은 건의 결과를 다시 받아도 상태가 실제로 바뀔 때 한 번만 기록된다.

**닫는 위치**

| 처리 | 닫히는 알림 | 어디서 | 담당 |
|---|---|---|---|
| 항목 확정·반려 | `ENTRY_REGISTERED`, `ENTRY_EDIT_REQUESTED` | `chain_tx.py`의 `settle`. `_update`가 1행일 때만 | 손종인 |
| 회장 서명 | `REVISION_REQUESTED` | 회장 서명 라우터 | 김경윤 |
| 증액 승인·반려 | 그 요청의 재알림 대상 전부 | 승인·반려 라우터 | 김경윤 |
| 시한 만료로 `PENDING` 복귀 | `REVISION_PRESIDENT_SIGNED`, `SIGNATURE_DEADLINE_NEAR` | 만료 처리 함수 | 김경윤 |

모두 `entry_id` 또는 `budget_revision_request_id`로 닫고, 그다음에 다음 단계 알림을 만든다.

**확정 실패의 기준**

- **알리는 것:** `InsufficientBudget`, `BudgetExpired`. 항목이 `PENDING`으로 남고 총무가 반려 후 재등록이나 증액 요청으로 조치할 수 있는 실패다 (§4.1). 대부분 시뮬레이션에서 걸려 선점 전에 끝나므로 시뮬레이션 revert도 포함한다
- **알리지 않는 것:** 그 밖의 revert(서명·`entryCommit` 불일치, 권한, 이미 처리됨)는 승인자의 요청 응답으로 끝난다. 총무가 할 일이 없다. `ChainUnavailable`은 실패가 아니라 결과를 모르는 것이라 알리지 않는다
- **반복 방지:** 그 항목의 `ENTRY_CONFIRM_FAILED` 중 안 읽은 행이 있으면 새로 만들지 않는다. 총무가 읽은 뒤 다시 실패하면 한 번 더 알린다
- 체인에 남은 것이 없어 상태 전이가 없으므로 항목의 다른 칸은 바꾸지 않고 알림 행만 기록한다

## 확인이 필요한 것

| 대상 | 내용 |
|---|---|
| 장석연 | §4.8 표에 「T4 수정 요청 → 감사 전원, 회장」 행 추가 (리뷰에서 추가하기로 함, PRD 반영 대기) |
| 장석연 | §4.8의 「감사」가 감사 전원인가. 맞으면 위 표대로 72시간 규칙은 대상이 없어 구현하지 않는다 |
| 장석연 | §8 `Notification`에 `notified_at`을 더해도 되는가 (재알림 정렬 기준) |
| 김경윤 | 위 「호출 위치」와 「닫는 위치」의 담당을 확인한다. `chain_tx.py`에서 기록하는 것은 장석연이 동의했다 |
| 이승호 | 경로와 응답 형태로 화면을 만들 수 있는가. 폴링은 화면 동기화(§4.9)와 같은 15초를 제안한다 |
