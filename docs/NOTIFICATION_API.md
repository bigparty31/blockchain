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

**정렬:** 안 읽은 알림 먼저, 그 안에서 최신순. 시연 규모라 페이지 넘김은 두지 않는다.

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
- 재알림은 같은 알림 행의 `read_at`을 비우고 `remind_count`를 올린다. 새 알림이 아니지만 뱃지에 다시 잡히고 목록 위로 올라온다
- 처리되면 받는 사람 전원의 알림이 목록과 재알림에서 빠진다

## `kind` 값

이벤트와 받는 사람은 §4.8이다. 값은 `docs/enums.md`의 notification kind와 같다 (PR #31). 증액 쪽은 `REVISION_*`, T4 수정 요청은 `ENTRY_EDIT_REQUESTED`다 — 「개정」은 예산 용어다. 이의 제기는 v0.13 범위 밖이라 없다.

| `kind` | 이벤트 | 받는 사람 | 연결 | 재알림 |
|---|---|---|---|---|
| `ENTRY_REGISTERED` | 지출·수입·정정 등록 | 감사 전원, 회장 | `entry_id` | O |
| `ENTRY_EDIT_REQUESTED` | T4 수정 요청 (§4.3) | 감사 전원, 회장 | `entry_id` | O |
| `ENTRY_CONFIRMED` | 확정 | 총무 | `entry_id` | |
| `ENTRY_REJECTED` | 반려 | 총무 | `entry_id` | |
| `ENTRY_CONFIRM_FAILED` | 확정 실패 | 총무 | `entry_id` | |
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
    """처리된 건의 알림을 받는 사람 전원에게서 닫는다. commit 하지 않는다."""
```

- **상태 변경과 같은 세션으로 부르고, 호출한 쪽이 함께 commit 한다** (§4.8). 롤백되면 알림도 남지 않는다
- 받는 사람은 `kind`에 따라 함수가 정한다. `user_ids`는 「해당 처리자」처럼 표만으로 정해지지 않는 종류에만 넘긴다
- 문구(`body`)는 인자로 받지 않는다. 서버가 `kind`로 만든다

**호출 위치 (제안)**

| 이벤트 | 어디서 | 담당 |
|---|---|---|
| 등록, `BLOCKED`, 확정, 반려, 확정 실패 | `chain_tx.py`의 상태 반영 단계 | 손종인 |
| T4 수정 요청 | 수정 요청 라우터 | 김경윤 |
| 증액 요청, 회장 서명 완료, 증액 승인·반려 | 예산 라우터 | 김경윤 |
| 시한 만료 후 재서명 요청 | 만료 처리 함수 | 김경윤 |
| 재분류 짝 미확정, 서명 시한 임박 | 재알림 작업 | 손종인 |

체인을 거치는 항목 이벤트를 `chain_tx.py`에 둔 이유: 상태 반영은 `chain_tx.py`가 자기 세션으로 commit 하고 라우터는 그 결과만 받는다. 그래서 라우터에서 부르면 §4.8의 「같은 트랜잭션」이 될 수 없다. 재제출로 같은 건의 결과를 다시 받아도 상태가 실제로 바뀔 때 한 번만 기록된다.

## 확인이 필요한 것

| 대상 | 내용 |
|---|---|
| 장석연 | §4.8 표에 「T4 수정 요청 → 감사 전원, 회장」 행 추가 (PR #31 리뷰에서 추가하기로 함, PRD 반영 대기) |
| 장석연, 김경윤 | §4.8은 라우터 호출을 김경윤으로 적었다. 위 「호출 위치」대로 등록·확정·반려는 `chain_tx.py`에서 기록해도 되는가 |
| 이승호 | 경로와 응답 형태로 화면을 만들 수 있는가. 폴링은 화면 동기화(§4.9)와 같은 15초를 제안한다 |
