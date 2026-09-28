// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBudgetToken} from "../interfaces/IBudgetToken.sol";
import {IRoleManager} from "../interfaces/IRoleManager.sol";

/// @title BudgetToken
/// @notice 학기 + 항목 1줄 단위 예산 한도(issued)·소모액(spent). 규칙은 IBudgetToken 주석과 docs/CONTRACTS.md "예산" 절이 정본.
/// @dev
/// - remaining = issued − spent. 불변식 spent <= issued 는 spend(잔량 검사)·refund(spent 범위 검사)·reclaim(issued = spent)이 지킨다.
/// - "마감 경과" 는 block.timestamp > expiresAt 이다. expiresAt 당일 자정(초)까지는 유효.
/// - spend / refund 호출자는 setLedger 로 한 번 정한 원장 하나.
contract BudgetToken is IBudgetToken {
    bytes32 private constant PRESIDENT = keccak256("PRESIDENT");

    IRoleManager public immutable roleManager;
    /// @notice setLedger 를 부를 수 있는 유일한 계정. 잠긴 뒤에는 아무 권한도 없다.
    address public immutable deployer;

    address private _ledger;

    mapping(uint256 budgetId => Budget) private _budgets;
    mapping(uint256 budgetId => bool) private _exists;

    constructor(address roleManager_) {
        if (roleManager_ == address(0)) revert ZeroAddress();
        roleManager = IRoleManager(roleManager_);
        deployer = msg.sender;
    }

    // -------------------------------------------------------------- modifiers

    modifier onlyPresident() {
        if (!roleManager.hasRole(PRESIDENT, msg.sender)) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyLedger() {
        if (msg.sender != _ledger || _ledger == address(0)) revert Unauthorized(msg.sender);
        _;
    }

    modifier mustExist(uint256 budgetId) {
        if (!_exists[budgetId]) revert BudgetNotFound(budgetId);
        _;
    }

    // ------------------------------------------------------------------ setup

    function setLedger(address ledger_) external {
        if (msg.sender != deployer) revert Unauthorized(msg.sender);
        if (_ledger != address(0)) revert LedgerAlreadySet(_ledger);
        if (ledger_ == address(0)) revert ZeroAddress();
        _ledger = ledger_;
        emit LedgerSet(ledger_);
    }

    function ledger() external view returns (address) {
        return _ledger;
    }

    // -------------------------------------------------------------- president

    function issue(
        uint256 budgetId,
        uint256 term,
        bytes32 category,
        uint256 amount,
        uint256 expiresAt
    ) external onlyPresident {
        if (budgetId == 0) revert ReservedId(budgetId); // "없음" 으로 예약 (docs/HASHING.md §2.1)
        if (_exists[budgetId]) revert BudgetAlreadyExists(budgetId);
        if (term == 0) revert TermRequired();
        if (amount == 0) revert ZeroAmount();
        if (expiresAt <= block.timestamp) revert BudgetExpired(budgetId, expiresAt);

        _budgets[budgetId] = Budget({
            term: term,
            category: category,
            issued: amount,
            spent: 0,
            expiresAt: expiresAt,
            version: 1
        });
        _exists[budgetId] = true;

        emit BudgetIssued(budgetId, term, category, amount, expiresAt);
    }

    function increase(uint256 budgetId, uint256 amount, bytes32 reasonHash) external onlyPresident mustExist(budgetId) {
        if (amount == 0) revert ZeroAmount();
        Budget storage b = _budgets[budgetId];
        b.issued += amount;
        b.version += 1;
        emit BudgetIncreased(budgetId, amount, b.version, reasonHash);
    }

    function reclaim(uint256 budgetId) external onlyPresident mustExist(budgetId) {
        Budget storage b = _budgets[budgetId];
        if (!_isExpired(b)) revert BudgetNotExpired(budgetId, b.expiresAt);
        uint256 rem = b.issued - b.spent;
        if (rem == 0) revert ZeroAmount();
        b.issued = b.spent;
        emit BudgetReclaimed(budgetId, rem, msg.sender);
    }

    // ----------------------------------------------------------------- ledger

    function spend(uint256 budgetId, uint256 amount, uint256 entryId) external onlyLedger mustExist(budgetId) {
        if (amount == 0) revert ZeroAmount();
        Budget storage b = _budgets[budgetId];
        if (_isExpired(b)) revert BudgetExpired(budgetId, b.expiresAt);
        uint256 rem = b.issued - b.spent;
        if (rem < amount) revert InsufficientBudget(budgetId, rem, amount);
        b.spent += amount;
        emit BudgetSpent(budgetId, amount, entryId);
    }

    /// @dev 마감·회수 여부를 보지 않는다. spent 범위만 검사한다.
    function refund(uint256 budgetId, uint256 amount, uint256 entryId) external onlyLedger mustExist(budgetId) {
        if (amount == 0) revert ZeroAmount();
        Budget storage b = _budgets[budgetId];
        if (amount > b.spent) revert RefundExceedsSpent(budgetId, b.spent, amount);
        b.spent -= amount;
        emit BudgetRefunded(budgetId, amount, entryId);
    }

    // ------------------------------------------------------------------ views

    function remaining(uint256 budgetId) external view returns (uint256) {
        Budget storage b = _budgets[budgetId];
        return b.issued - b.spent;
    }

    function getBudget(uint256 budgetId) external view returns (Budget memory) {
        return _budgets[budgetId];
    }

    function exists(uint256 budgetId) external view returns (bool) {
        return _exists[budgetId];
    }

    // --------------------------------------------------------------- internal

    function _isExpired(Budget storage b) private view returns (bool) {
        return block.timestamp > b.expiresAt;
    }
}
