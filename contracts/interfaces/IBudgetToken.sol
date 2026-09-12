// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBudgetToken
/// @notice 학기 + 항목 1줄 단위의 예산 잔량 관리. ERC 표준을 따르지 않는 커스텀 장부.
/// @dev budgetId는 백엔드 DB의 auto-increment 값을 그대로 받는다. 컨트랙트는 중복만 막는다.
interface IBudgetToken {
    // ---------------------------------------------------------------- types

    struct Budget {
        uint256 term; // 학기 식별자 (예: 20261)
        bytes32 category; // keccak256("행사비") 형태. 사람이 읽는 이름은 오프체인
        uint256 issued; // 누적 배정액 (원)
        uint256 spent; // 누적 소모액 (원)
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
    /// @notice 마감 후 미집행 잔량 회수
    event BudgetReclaimed(uint256 indexed budgetId, uint256 amount, address indexed actor);

    // --------------------------------------------------------------- errors

    error Unauthorized(address caller);
    error BudgetAlreadyExists(uint256 budgetId);
    error BudgetNotFound(uint256 budgetId);
    error BudgetExpired(uint256 budgetId, uint256 expiresAt);
    error BudgetNotExpired(uint256 budgetId, uint256 expiresAt);
    error InsufficientBudget(uint256 budgetId, uint256 remaining, uint256 requested);
    /// @dev refund 가 누적 소모액을 넘을 때
    error RefundExceedsSpent(uint256 budgetId, uint256 spent, uint256 requested);
    error ZeroAmount();

    // ------------------------------------------------------------ functions

    /// @notice 예산 신규 배정. version = 1.
    function issue(
        uint256 budgetId,
        uint256 term,
        bytes32 category,
        uint256 amount,
        uint256 expiresAt
    ) external;

    /// @notice 예산 개정(증액). version++.
    function increase(uint256 budgetId, uint256 amount, bytes32 reasonHash) external;

    /// @notice 지출 확정 시 잔량 소모. AccountingLedger 만 호출 가능.
    /// @dev 잔량 부족 또는 expiresAt 경과 시 revert.
    function spend(uint256 budgetId, uint256 amount, uint256 entryId) external;

    /// @notice 정정(음수 지출) 확정 시 잔량 복구. AccountingLedger 만 호출 가능.
    function refund(uint256 budgetId, uint256 amount, uint256 entryId) external;

    /// @notice 마감 경과 후 미집행 잔량 회수.
    function reclaim(uint256 budgetId) external;

    /// @notice 현재 잔량. 백엔드는 이 값을 쓴다.
    /// @dev 이벤트로 검증할 때: Σ BudgetIssued + Σ BudgetIncreased − Σ BudgetReclaimed − Σ BudgetSpent + Σ BudgetRefunded.
    function remaining(uint256 budgetId) external view returns (uint256);

    function getBudget(uint256 budgetId) external view returns (Budget memory);

    function exists(uint256 budgetId) external view returns (bool);
}
