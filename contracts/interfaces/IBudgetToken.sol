// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBudgetToken
/// @notice 학기 + 항목 1줄 단위의 예산 잔량 관리. ERC 표준을 따르지 않는 커스텀 장부.
/// @dev
/// - budgetId는 백엔드 DB의 auto-increment 값을 그대로 받는다. 컨트랙트는 중복만 막는다.
/// - issued 는 "현재 한도"다. remaining() = issued − spent. 불변식: 항상 spent <= issued.
///   increase 는 issued 를 올리고, reclaim 은 issued 를 spent 까지 내린다. 그래서 issued 는 회수 후 줄어든다.
///   최초 발행액·누적 증액은 이벤트(BudgetIssued + BudgetIncreased)로 계산한다.
/// - 개정은 증액(increase)만 있다. 감액 함수는 만들지 않는다 (향후 과제).
/// - spend 는 잔량 부족·마감 경과 시 revert. refund 는 마감·회수와 무관하게 성공하되
///   spent 를 넘는 금액은 RefundExceedsSpent 로 revert (spent 만 줄인다).
///   회수된 예산에 refund 가 오면 remaining 이 다시 생기지만 마감이 지나 spend 는 막히고, reclaim 을 다시 부르면 된다.
/// - reclaim 은 마감(expiresAt) 뒤에만 가능하고, 여러 번 부를 수 있다. 회수할 잔량이 0이면 ZeroAmount.
/// - spend / refund 호출자는 AccountingLedger 하나로 제한한다. 원장 주소는 배포자가 setLedger 로 한 번만 넣고 잠근다.
///   두 번째 호출은 LedgerAlreadySet 으로 revert. 배포 순서: RoleManager → BudgetToken → AccountingLedger → setLedger.
/// - issue / increase / reclaim 호출자는 PRESIDENT (RoleManager.hasRole 로 판정).
interface IBudgetToken {
    // ---------------------------------------------------------------- types

    struct Budget {
        uint256 term; // 학기 식별자 (예: 20261). 0 금지
        bytes32 category; // keccak256("행사비") 형태. 사람이 읽는 이름은 오프체인
        uint256 issued; // 현재 한도 (원). increase 로 오르고 reclaim 으로 spent 까지 내려간다
        uint256 spent; // 누적 소모액 (원). spend 로 오르고 refund 로 내려간다
        uint256 expiresAt; // 집행 마감 (unix seconds)
        uint16 version; // 개정 횟수. issue 시 1, increase 마다 +1
    }

    // --------------------------------------------------------------- events

    event BudgetIssued(
        uint256 indexed budgetId,
        uint256 indexed term,
        bytes32 category,
        uint256 amount,
        uint256 expiresAt
    );
    event BudgetIncreased(uint256 indexed budgetId, uint256 amount, uint16 version, bytes32 reasonHash);
    event BudgetSpent(uint256 indexed budgetId, uint256 amount, uint256 entryId);
    event BudgetRefunded(uint256 indexed budgetId, uint256 amount, uint256 entryId);
    /// @notice 마감 후 미집행 잔량 회수. amount 는 이번 호출로 줄어든 issued 양
    event BudgetReclaimed(uint256 indexed budgetId, uint256 amount, address indexed actor);
    /// @notice setLedger 가 딱 한 번 낸다
    event LedgerSet(address indexed ledger);

    // --------------------------------------------------------------- errors

    error Unauthorized(address caller);
    /// @dev budgetId == 0. "없음" 으로 예약된 값. 중복(BudgetAlreadyExists)과 구분한다
    error ReservedId(uint256 budgetId);
    error BudgetAlreadyExists(uint256 budgetId);
    error BudgetNotFound(uint256 budgetId);
    error BudgetExpired(uint256 budgetId, uint256 expiresAt);
    error BudgetNotExpired(uint256 budgetId, uint256 expiresAt);
    error InsufficientBudget(uint256 budgetId, uint256 remaining, uint256 requested);
    /// @dev refund 가 누적 소모액을 넘을 때
    error RefundExceedsSpent(uint256 budgetId, uint256 spent, uint256 requested);
    error ZeroAmount();
    /// @dev issue 에 term == 0
    error TermRequired();
    /// @dev setLedger 두 번째 호출
    error LedgerAlreadySet(address ledger);
    error ZeroAddress();

    // ------------------------------------------------------------ functions

    /// @notice spend / refund 를 부를 수 있는 원장 주소를 1회 설정. 호출자는 배포자. 이후 잠긴다.
    function setLedger(address ledger) external;

    /// @notice 설정된 원장 주소. 미설정이면 address(0)
    function ledger() external view returns (address);

    /// @notice 예산 신규 배정. version = 1. budgetId == 0 이면 ReservedId, term == 0 이면 TermRequired.
    function issue(
        uint256 budgetId,
        uint256 term,
        bytes32 category,
        uint256 amount,
        uint256 expiresAt
    ) external;

    /// @notice 예산 개정(증액). version++. issued 에 더한다. 덮어쓰기 없음.
    function increase(uint256 budgetId, uint256 amount, bytes32 reasonHash) external;

    /// @notice 지출 확정 시 잔량 소모. AccountingLedger 만 호출 가능.
    /// @dev 잔량 부족 또는 expiresAt 경과 시 revert.
    function spend(uint256 budgetId, uint256 amount, uint256 entryId) external;

    /// @notice 정정(음수 지출) 확정 시 잔량 복구. AccountingLedger 만 호출 가능.
    /// @dev 마감·회수 여부를 보지 않는다. amount > spent 이면 RefundExceedsSpent.
    function refund(uint256 budgetId, uint256 amount, uint256 entryId) external;

    /// @notice 마감 경과 후 미집행 잔량 회수. issued 를 spent 까지 내린다. 재호출 가능.
    function reclaim(uint256 budgetId) external;

    /// @notice 현재 잔량 = issued − spent. 백엔드는 이 값을 쓴다.
    /// @dev 이벤트로 검증할 때: Σ BudgetIssued + Σ BudgetIncreased − Σ BudgetReclaimed − Σ BudgetSpent + Σ BudgetRefunded.
    function remaining(uint256 budgetId) external view returns (uint256);

    function getBudget(uint256 budgetId) external view returns (Budget memory);

    function exists(uint256 budgetId) external view returns (bool);
}
