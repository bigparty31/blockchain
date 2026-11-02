# 알림 API 명세 (초안)

작성 손종인 · 대상 이승호, 장정아(알림함·뱃지·폴링), 김경윤(이벤트 호출), 장석연(`kind` 승인) · 근거 PRD v0.13 §4.8, §4.9, §8

**구현 전 초안이다.** 앱은 이 형태로 먼저 만들 수 있다. 경로와 응답 형태는 PRD에 없어 제안한 값이고, 「확인이 필요한 것」이 정해지면 바뀔 수 있다. 구현 완료 후 확정본을 `docs/API.md`에 옮긴다.

## 공통

- 세 API 모두 `Authorization: Bearer <access_token>`이 필요하다. 오류는 `API.md` 인증 §3과 같다
- 역할 제한은 없고, **본인 알림만** 조회·처리한다
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
    "objection_id": null,
    "body": "새 지출 내역이 등록되었습니다. 승인이 필요합니다.",
    "created_at": 1793548800,
    "read_at": null,
    "remind_count": 0
  }
]
```

- `body`는 서버가 만든 문구다. 앱은 그대로 표시한다
- 어디로 이동할지는 `entry_id`·`budget_revision_request_id`·`objection_id` 중 값이 있는 것으로 정한다
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

- 주기는 PRD 그대로다: 24시간 뒤, 이후 24시간마다 최대 3회, 72시간이 지나면 다른 승인자에게도 알린다. 간격은 서버 설정값이다
- **읽음은 처리가 아니다.** 읽어도 처리되지 않으면 재알림이 간다
- 재알림은 같은 알림 행의 `read_at`을 비우고 `remind_count`를 올린다. 새 알림이 아니지만 뱃지에 다시 잡히고 목록 위로 올라온다
- 처리되면 받는 사람 전원의 알림이 목록과 재알림에서 빠진다

## `kind` 값 (제안 — 승인 필요)

이벤트와 받는 사람은 §4.8이다. **`kind` 이름은 제안이고 `docs/enums.md`에 올리려면 장석연 승인이 필요하다.** 「재알림」은 PRD에 구분이 없어 제안한 값이다.

| `kind` | 이벤트 | 받는 사람 | 연결 | 재알림 |
|---|---|---|---|---|
| `ENTRY_REGISTERED` | 지출·수입·정정 등록 | 감사 전원, 회장 | `entry_id` | O |
| `ENTRY_CONFIRMED` | 확정 | 총무 | `entry_id` | |
| `ENTRY_REJECTED` | 반려 | 총무 | `entry_id` | |
| `ENTRY_CONFIRM_FAILED` | 확정 실패 | 총무 | `entry_id` | |
| `ENTRY_BLOCKED` | `BLOCKED` | 총무, 회장 | `entry_id` | |
| `REVISION_REQUESTED` | 증액 요청 | 회장 | `budget_revision_request_id` | O |
| `REVISION_PRESIDENT_SIGNED` | 회장 서명 완료 | 감사 | `budget_revision_request_id` | O |
| `REVISION_APPROVED` | 증액 승인 | 총무, 회장 | `budget_revision_request_id` | |
| `REVISION_REJECTED` | 증액 반려 | 총무, 회장 | `budget_revision_request_id` | |
| `OBJECTION_RAISED` | 이의 제기 | 감사, 회장 | `objection_id` | O |
| `OBJECTION_ANSWERED` | 이의 답변 | 제기한 학생 | `objection_id` | |
| `ROLE_CHANGE_REQUESTED` | 롤 변경 서명 요청 | 상대 서명자 | 없음 | O |
| `PRESIDENT_RECOVERY_PROPOSED` | 회장 복구 제안 | 회장, 감사 | 없음 | |
| `RECLASSIFY_PAIR_UNCONFIRMED` | 재분류 짝 미확정 | 해당 처리자 | `entry_id` | O |
| `SIGNATURE_DEADLINE_NEAR` | 서명 시한 임박 | 해당 처리자 | `budget_revision_request_id` | |

## 확인이 필요한 것

| 대상 | 내용 |
|---|---|
| 장석연 | `kind` 이름을 `docs/enums.md`에 올려도 되는가 |
| 장석연 | S14는 학생 알림함에 「내 관련 확정」을 넣지만 §4.8 표에서 확정은 총무에게만 간다. 학생 수신은 이의 답변만으로 보는가 |
| 장석연 | 「재알림」 구분이 맞는가. 처리가 필요한 종류에만 다시 보내는 것으로 잡았다 |
| 이승호, 장정아 | 경로와 응답 형태로 화면을 만들 수 있는가. 폴링은 화면 동기화(§4.9)와 같은 15초를 제안한다 |
