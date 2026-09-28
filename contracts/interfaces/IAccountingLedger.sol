// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAccountingLedger
/// @notice 수입·지출 기록 원장. 확정된 항목은 수정할 수 없고, 정정은 correctsId 로 원본을 가리키는 새 항목으로만 한다.
/// @dev
/// - 생성자에서 RoleManager·BudgetToken 주소를 받는다: constructor(address roleManager, address budgetToken)
/// - entryId 는 백엔드 DB auto-increment 값. 컨트랙트는 중복만 막는다.
/// - amount 는 원 단위 정수. correctsId != 0 인 정정 항목에서만 음수 허용.
/// - term 은 학기 식별자(예: 20261). 서명 대상(RecordRequest)에 들어가므로 총무가 확인한 값이다.
///   수입·지출 모두 0 금지(TermRequired). 지출은 등록 시점에 예산의 term 과 대조해 다르면 revert(TermMismatch).
///   수입은 대조할 예산이 없어 서명된 값 그대로 저장한다.
/// - hash 는 PRD §8 meta_hash. 계산 규칙의 정본은 docs/HASHING.md 다.
///   구분자는 U+001F (Unit Separator) 이고 파이프(|) 가 아니다 — 목적란이 자유 입력이라
///   파이프를 쓰면 서로 다른 거래가 같은 해시를 낸다 (docs/HASHING.md §1).
///   SHA-256 32바이트를 bytes32 에 그대로 담는다 (keccak 아님). 영수증은 receipt_hash 로 이미 포함.
///   EIP-712 서명 digest 와는 별개 값 — meta_hash 는 서명 대상 struct 의 한 필드다.
/// - 예산 초과 검사는 등록(recordPending) 시점, 예산 소모(BudgetToken.spend)는 확정(confirmEntry) 시점.
///   등록 시 초과·마감·미존재면 revert 하지 않고 BLOCKED 로 저장 + EntryBlocked emit (이벤트를 남기기 위함).
///   BLOCKED 항목은 confirmEntry 에서 거부되며 잔액 계산에서도 제외한다.
///   확정 시 잔량 부족이면 그대로 revert (정상 동작). 등록 시 검사는 대기 건을 예약하지 않으므로
///   대기 여러 건이 같은 예산을 나눠 쓰다 나중 건 확정이 revert 할 수 있다. 그 경우 상태는 PENDING 그대로이고
///   앱이 rejectEntry 로 반려한다.
/// - INCOME 항목은 budgetId = 0. budgetId != 0 이면 revert(BudgetIdNotAllowedForIncome). 예산 검사·소모는 EXPENSE 에만 적용.
/// - 정정: 페어 필드는 없다. RECLASSIFY 는 양수 정정(새 예산 spend) + 음수 정정(원래 예산 refund) 2건으로 표현하고
///   순서는 서버 규칙(양수 다음 음수). 음수 정정의 budgetId 는 원본의 budgetId 와 같아야 한다(CorrectionBudgetMismatch).
///   양수 정정도 일반 지출과 같이 등록 시 잔량 검사·확정 시 spend 를 거친다.
///   한계: 한 쌍 중 한쪽만 확정된 상태가 존재할 수 있다 (사람이 한쪽만 승인하는 경우). 완화는 앱·서버 몫.
/// - 승인자(confirmEntry / rejectEntry 서명자)는 AUDITOR 또는 PRESIDENT. 등록자 != 승인자는 별도 검사.
/// - 반려는 reasonHash != 0 필수(ReasonRequired). 확정은 hadWarning == (warningReasonHash != 0) 이어야 한다.
///   경고인데 사유 0 → ReasonRequired, 경고 아닌데 사유 있음 → ReasonNotAllowed.
/// - recordPending / confirmEntry / rejectEntry 는 모두 서버 릴레이어가 호출하되,
///   EIP-712 서명자가 실제 행위자(등록자·승인자·반려자)다. ERC-2771 포워더는 쓰지 않는다.
///   릴레이어가 actor 를 파라미터로 넘기면 등록자를 위조할 수 있어 "등록자 != 승인자" 검사가 무력화되기 때문.
///   등록자(registrant) == 승인자(signer) 이면 revert.
///
/// recordPending 검사 순서 (revert 는 위에서부터, BLOCKED 판정은 revert 검사가 모두 통과한 뒤):
///   1 SignatureExpired  2 EntryAlreadyExists  3 TermRequired  4 ZeroAmount
///   5 NegativeAmountWithoutCorrection  6 NotRegistrant
///   7 INCOME: BudgetIdNotAllowedForIncome
///   8 correctsId != 0: CorrectionTargetNotFound → CorrectionTargetNotConfirmed → (amount < 0) CorrectionBudgetMismatch
///   9 EXPENSE 이고 예산이 존재하면 TermMismatch
///  10 EXPENSE 예산 판정: BUDGET_NOT_FOUND / BUDGET_EXPIRED / BUDGET_EXCEEDED → BLOCKED 저장 (revert 아님)
///   budgetId == 0 인 EXPENSE 는 BUDGET_NOT_FOUND 로 BLOCKED (백엔드 FakeChainClient 와 동일).
interface IAccountingLedger {
    // ---------------------------------------------------------------- types

    /// @dev docs/enums.md kind 순서 그대로
    enum Kind {
        INCOME, // 0
        EXPENSE // 1
    }

    /// @dev docs/enums.md entry status 순서 그대로
    enum Status {
        PENDING, // 0
        CONFIRMED, // 1
        REJECTED, // 2
        BLOCKED // 3
    }

    /// @dev docs/enums.md block_reason 순서 그대로. EntryBlocked.reason 값.
    enum BlockReason {
        BUDGET_EXCEEDED, // 0 잔량 부족
        BUDGET_EXPIRED, // 1 집행 마감 경과
        BUDGET_NOT_FOUND // 2 존재하지 않는 budgetId
    }

    struct Entry {
        bytes32 hash; // PRD §8 meta_hash (SHA-256). docs/CONTRACTS.md "entry.hash" 절
        int256 amount; // 원. 정정 항목만 음수 가능
        Kind kind;
        Status status;
        uint256 term; // 학기 식별자. 0 아님. 지출은 예산 term 과 일치
        uint256 occurredAt; // 실제 발생 시각 (unix seconds). 기록 시각은 블록에 있음
        uint256 budgetId;
        uint256 correctsId; // 정정 대상 entryId. 0 이면 정정 아님
        address registrant; // 등록자 (recordPending 서명자)
        address approver; // 확정/반려한 사람 (confirmEntry/rejectEntry 서명자). 미처리면 address(0)
    }

    // EIP-712 서명 대상 struct 들. deadline 은 서명 유효 시한 (unix seconds).
    // 각 id 는 한 번만 상태 전이하므로 nonce 는 두지 않는다.

    /// @dev typehash:
    ///   keccak256("RecordRequest(uint256 id,bytes32 hash,int256 amount,uint8 kind,uint256 term,uint256 occurredAt,uint256 budgetId,uint256 correctsId,uint256 deadline)")
    struct RecordRequest {
        uint256 id;
        bytes32 hash;
        int256 amount;
        Kind kind; // EIP-712 타입 문자열에서는 uint8
        uint256 term;
        uint256 occurredAt;
        uint256 budgetId;
        uint256 correctsId;
        uint256 deadline;
    }

    /// @dev typehash:
    ///   keccak256("ConfirmApproval(uint256 id,bytes32 hash,bool hadWarning,bytes32 warningReasonHash,uint256 deadline)")
    struct ConfirmApproval {
        uint256 id;
        bytes32 hash;
        bool hadWarning;
        bytes32 warningReasonHash;
        uint256 deadline;
    }

    /// @dev typehash:
    ///   keccak256("RejectDecision(uint256 id,bytes32 reasonHash,uint256 deadline)")
    struct RejectDecision {
        uint256 id;
        bytes32 reasonHash;
        uint256 deadline;
    }

    // --------------------------------------------------------------- events
    // 손종인(백엔드)이 이 이벤트만으로 장부 잔액을 계산한다. EntryConfirmed 에 금액·kind·term 을 반복해서 담는 이유.
    // 장부 잔액 = Σ EntryConfirmed.amount (kind == INCOME) − Σ EntryConfirmed.amount (kind == EXPENSE).
    // 학기별 합계는 term 으로 나눈다. 수입·지출 모두 양수로 들어오므로 kind 로 나눠 빼야 한다. 그냥 더하면 안 된다.
    // 예산 잔량은 이 이벤트로 계산하지 않는다. 구현은 BudgetToken.remaining() 호출,
    // 이벤트 재계산(Issued + Increased − Reclaimed − Spent + Refunded)은 검증용.
    // EntryPending / EntryBlocked / EntryRejected 는 잔액에 영향 없음.

    event EntryPending(
        uint256 indexed id,
        bytes32 hash,
        int256 amount,
        uint8 kind,
        uint256 term,
        uint256 indexed budgetId,
        uint256 correctsId,
        address indexed actor
    );

    event EntryConfirmed(
        uint256 indexed id,
        bytes32 hash,
        int256 amount,
        uint8 kind,
        uint256 term,
        uint256 indexed budgetId,
        bool hadWarning,
        bytes32 warningReasonHash,
        address indexed actor
    );

    event EntryRejected(uint256 indexed id, bytes32 reasonHash, address indexed actor);

    event EntryBlocked(uint256 indexed id, uint256 indexed budgetId, uint256 attempted, uint8 reason);

    // --------------------------------------------------------------- errors

    error Unauthorized(address caller);
    error EntryAlreadyExists(uint256 id);
    error EntryNotFound(uint256 id);
    /// @dev PENDING 이 아닌 항목(BLOCKED 포함)을 확정/반려하려 할 때
    error InvalidStatus(uint256 id, Status current, Status expected);
    /// @dev correctsId == 0 인데 amount < 0
    error NegativeAmountWithoutCorrection(uint256 id);
    error ZeroAmount(uint256 id);
    error CorrectionTargetNotFound(uint256 id, uint256 correctsId);
    /// @dev 정정 대상이 CONFIRMED 가 아님
    error CorrectionTargetNotConfirmed(uint256 id, uint256 correctsId);
    /// @dev 음수 정정의 budgetId 가 원본(correctsId)의 budgetId 와 다름
    error CorrectionBudgetMismatch(uint256 id, uint256 expected, uint256 actual);
    /// @dev 저장된 hash 와 confirm 에 넘긴 hash 불일치
    error HashMismatch(uint256 id, bytes32 expected, bytes32 actual);
    error InvalidSignature();
    error SignatureExpired(uint256 deadline);
    /// @dev 서명자가 등록 권한 롤(TREASURER)이 아님
    error NotRegistrant(address signer);
    /// @dev 서명자가 승인 권한 롤(AUDITOR 또는 PRESIDENT)이 아님
    error NotApprover(address signer);
    /// @dev 등록자 == 승인자
    error SelfApproval(uint256 id, address account);
    /// @dev term == 0
    error TermRequired(uint256 id);
    /// @dev EXPENSE 의 term 이 예산(budgetId)의 term 과 다름
    error TermMismatch(uint256 id, uint256 expected, uint256 actual);
    /// @dev INCOME 인데 budgetId != 0
    error BudgetIdNotAllowedForIncome(uint256 id, uint256 budgetId);
    /// @dev 반려 사유 0, 또는 hadWarning 인데 warningReasonHash 0
    error ReasonRequired(uint256 id);
    /// @dev hadWarning 이 아닌데 warningReasonHash != 0
    error ReasonNotAllowed(uint256 id);

    // ------------------------------------------------------------ functions

    /// @notice 항목 등록. 호출자는 릴레이어, request 의 EIP-712 서명자가 등록자(registrant).
    /// @dev 지출이고 예산 초과/마감/미존재면 revert 대신 BLOCKED 저장 + EntryBlocked emit. 검사 순서는 위 @dev 참고.
    function recordPending(RecordRequest calldata request, bytes calldata signature) external;

    /// @notice 항목 확정. approval 의 EIP-712 서명자가 승인자(AUDITOR 또는 PRESIDENT, 등록자 제외).
    ///         지출이면 BudgetToken.spend(양수) / refund(음수) 를 호출한다.
    /// @dev PENDING 이 아니면(BLOCKED 포함) revert. BudgetToken 호출 실패(잔량 부족·마감 등) 시 전체 revert 하고 상태는 PENDING 유지.
    ///      hadWarning == (warningReasonHash != 0) 이 아니면 ReasonRequired / ReasonNotAllowed.
    function confirmEntry(ConfirmApproval calldata approval, bytes calldata signature) external;

    /// @notice 항목 반려. decision 의 EIP-712 서명자가 반려자(AUDITOR 또는 PRESIDENT, 등록자 제외).
    /// @dev reasonHash == 0 이면 ReasonRequired.
    function rejectEntry(RejectDecision calldata decision, bytes calldata signature) external;

    function getEntry(uint256 id) external view returns (Entry memory);

    function statusOf(uint256 id) external view returns (Status);

    function exists(uint256 id) external view returns (bool);

    /// @notice EIP-712 도메인 분리자 (백엔드가 서명 만들 때 필요)
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
