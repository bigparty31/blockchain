"""체인(스마트 컨트랙트)과 API 스키마가 공통으로 참조하는 상수."""

# 원장·예산 토큰 금액 상한 (IAccountingLedger / IBudgetToken MAX_AMOUNT). 넘으면 체인이 revert 한다.
MAX_AMOUNT = 10**15
