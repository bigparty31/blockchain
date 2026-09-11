# Enums

## role

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
