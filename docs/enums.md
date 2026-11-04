# Enums

## role

온체인 롤은 이름 기준(`bytes32 = keccak256("TREASURER")` 등), 숫자 아님. `STUDENT`는 온체인 롤이 아니다 (SBT 보유로 판별).

| 값 | 설명 |
| --- | --- |
| `STUDENT` | 학생 |
| `TREASURER` | 회계 |
| `AUDITOR` | 감사 |
| `PRESIDENT` | 회장 |

## kind

| 값 | 설명 |
| --- | --- |
| `INCOME` | 수입 |
| `EXPENSE` | 지출 |

## entry status

| 값 | 설명 |
| --- | --- |
| `PENDING` | 대기 |
| `CONFIRMED` | 확정 |
| `REJECTED` | 반려 |
| `BLOCKED` | 차단 |

## correction_reason

| 값 | 설명 |
| --- | --- |
| `INPUT_ERROR` | 입력 오류 |
| `RECEIPT_RECHECK` | 영수증 재확인 |
| `REFUND` | 환불 |
| `RECLASSIFY` | 재분류 |

## ocr_status

| 값 | 설명 |
| --- | --- |
| `MATCH` | 일치 |
| `MISMATCH` | 불일치 |
| `DUPLICATE` | 중복 |
| `NO_NUMBER` | 번호 없음 |
| `UNREADABLE` | 판독 불가 |

## block_reason

`EntryBlocked.reason`. 등록 시점 예산 검사 실패 사유. 온체인 enum 순서 = 이 표 순서.

| 값 | 설명 |
| --- | --- |
| `BUDGET_EXCEEDED` | 잔량 부족 |
| `BUDGET_EXPIRED` | 집행 마감 경과 |
| `BUDGET_NOT_FOUND` | 존재하지 않는 예산 |

## objection status

| 값 | 설명 |
| --- | --- |
| `OPEN` | 미답변 |
| `ANSWERED` | 답변 완료 |

## notification kind

서버 알림의 종류. 온체인 값이 아니다. 받는 사람은 PRD §4.8 표를 따른다. 증액 쪽은 `REVISION_*`, T4 수정 요청은 `ENTRY_EDIT_REQUESTED`다 — 「개정」은 예산 용어다.

| 값 | 설명 |
| --- | --- |
| `ENTRY_REGISTERED` | 지출·수입·정정 등록 |
| `ENTRY_EDIT_REQUESTED` | T4 수정 요청 |
| `ENTRY_CONFIRMED` | 확정 |
| `ENTRY_REJECTED` | 반려 |
| `ENTRY_CONFIRM_FAILED` | 확정 실패 |
| `ENTRY_BLOCKED` | 차단 |
| `REVISION_REQUESTED` | 증액 요청, 시한 만료 후 재서명 요청 |
| `REVISION_PRESIDENT_SIGNED` | 회장 서명 완료 |
| `REVISION_APPROVED` | 증액 승인 |
| `REVISION_REJECTED` | 증액 반려 |
| `ROLE_CHANGE_REQUESTED` | 롤 변경 서명 요청 |
| `PRESIDENT_RECOVERY_PROPOSED` | 회장 복구 제안 |
| `RECLASSIFY_PAIR_UNCONFIRMED` | 재분류 짝 미확정 |
| `SIGNATURE_DEADLINE_NEAR` | 서명 시한 임박 |
