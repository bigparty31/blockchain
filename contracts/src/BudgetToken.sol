// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IBudgetToken} from "../interfaces/IBudgetToken.sol";
import {IRoleManager} from "../interfaces/IRoleManager.sol";
import {ROLE_AUDITOR, ROLE_PRESIDENT, MAX_AMOUNT_WON, Signatures} from "./Common.sol";

/// @dev setLedger 가 확인하는 원장 쪽 조회 두 개만. IAccountingLedger 전체에 의존하지 않는다.
interface ILedgerWiring {
    function roleManager() external view returns (address);

    function budgetToken() external view returns (address);
}

/// @title BudgetToken
/// @notice 학기 + 항목 1줄 단위 예산 한도(issued)·소모액(spent). 규칙은 IBudgetToken 주석과 docs/CONTRACTS.md "예산" 절이 정본.
/// @dev
/// - remaining = issued − spent. 불변식 spent <= issued 는 spend(잔량 검사)·refund(spent 범위 검사)·reclaim(issued = spent)이 지킨다.
/// - "마감 경과" 는 block.timestamp > expiresAt 이다.
/// - 임원 행위(issue·increase·reclaim)는 EIP-712 서명자가 행위자다. msg.sender 는 권한 판단에 쓰지 않는다.
/// - 예산 존재는 version != 0 으로 판정한다 (issue 가 version = 1 로 시작).
contract BudgetToken is IBudgetToken, EIP712 {
    bytes32 private constant PRESIDENT = ROLE_PRESIDENT;
    bytes32 private constant AUDITOR = ROLE_AUDITOR;

    bytes32 private constant ISSUE_TYPEHASH =
        keccak256("IssueRequest(uint256 budgetId,uint256 term,bytes32 category,uint256 amount,uint256 expiresAt,uint256 deadline)");
    bytes32 private constant INCREASE_TYPEHASH =
        keccak256("IncreaseRequest(uint256 budgetId,uint256 amount,bytes32 reasonHash,uint256 version,uint256 deadline)");
    bytes32 private constant RECLAIM_TYPEHASH =
        keccak256("ReclaimRequest(uint256 budgetId,uint256 amount,uint256 reclaimCount,uint256 deadline)");

    uint256 public constant MAX_AMOUNT = MAX_AMOUNT_WON;

    IRoleManager private immutable _roleManager;
    /// @notice setLedger 를 부를 수 있는 유일한 계정. 잠긴 뒤에는 아무 권한도 없다.
    address public immutable deployer;

    address private _ledger;

    mapping(uint256 budgetId => Budget) private _budgets;
    mapping(bytes32 termCategory => uint256 budgetId) private _budgetIdOf;

    constructor(address roleManager_) EIP712("BudgetToken", "1") {
        if (roleManager_ == address(0)) revert ZeroAddress();
        _roleManager = IRoleManager(roleManager_);
        deployer = msg.sender;
    }

    // -------------------------------------------------------------- modifiers

    /// @dev _ledger 가 0 이면 msg.sender 는 0 일 수 없으므로 이 비교만으로 미설정 상태도 막힌다.
    modifier onlyLedger() {
        if (msg.sender != _ledger) revert Unauthorized(msg.sender);
        _;
    }

    // ------------------------------------------------------------------ setup

    function setLedger(address ledger_) external {
        if (msg.sender != deployer) revert Unauthorized(msg.sender);
        if (_ledger != address(0)) revert LedgerAlreadySet(_ledger);
        if (ledger_ == address(0)) revert ZeroAddress();
        ILedgerWiring l = ILedgerWiring(ledger_);
        if (l.budgetToken() != address(this) || l.roleManager() != address(_roleManager)) {
            revert LedgerMismatch(ledger_);
        }
        _ledger = ledger_;
        emit LedgerSet(ledger_);
    }

    function ledger() external view returns (address) {
        return _ledger;
    }

    function roleManager() external view returns (address) {
        return address(_roleManager);
    }

    // -------------------------------------------------------------- president

    function issue(IssueRequest calldata r, bytes calldata presidentSig) external {
        if (block.timestamp > r.deadline) revert SignatureExpired(r.deadline);
        address president = _recover(
            keccak256(abi.encode(ISSUE_TYPEHASH, r.budgetId, r.term, r.category, r.amount, r.expiresAt, r.deadline)),
            presidentSig
        );
        _requirePresident(president);

        if (r.budgetId == 0) revert ReservedId(r.budgetId); // "없음" 으로 예약 (docs/HASHING.md §2.1)
        if (r.budgetId > type(uint64).max) revert FieldOutOfRange(r.budgetId);
        if (_budgets[r.budgetId].version != 0) revert BudgetAlreadyExists(r.budgetId);
        if (r.term == 0) revert TermRequired();
        if (r.term > type(uint32).max) revert FieldOutOfRange(r.term);
        if (r.category == bytes32(0)) revert CategoryRequired();
        if (r.amount == 0) revert ZeroAmount();
        if (r.amount > MAX_AMOUNT) revert AmountOutOfRange(r.amount);
        if (r.expiresAt > type(uint64).max) revert FieldOutOfRange(r.expiresAt);
        if (r.expiresAt <= block.timestamp) revert BudgetExpired(r.budgetId, r.expiresAt);

        bytes32 key = _key(r.term, r.category);
        uint256 existing = _budgetIdOf[key];
        if (existing != 0) revert BudgetAlreadyIssued(r.term, r.category, existing);

        _budgets[r.budgetId] = Budget({
            category: r.category,
            issued: uint128(r.amount),
            spent: 0,
            term: uint32(r.term),
            expiresAt: uint64(r.expiresAt),
            version: 1,
            reclaimCount: 0
        });
        _budgetIdOf[key] = r.budgetId;

        emit BudgetIssued(r.budgetId, r.term, r.category, r.amount, r.expiresAt, president);
    }

    function increase(IncreaseRequest calldata r, bytes calldata requesterSig, bytes calldata approverSig) external {
        if (block.timestamp > r.deadline) revert SignatureExpired(r.deadline);
        bytes32 structHash = keccak256(
            abi.encode(INCREASE_TYPEHASH, r.budgetId, r.amount, r.reasonHash, r.version, r.deadline)
        );
        address requester = _recover(structHash, requesterSig);
        address approver = _recover(structHash, approverSig);
        _requirePresident(requester);
        if (!_roleManager.hasRole(AUDITOR, approver)) revert NotAuditor(approver);

        Budget storage b = _budgets[r.budgetId];
        if (b.version == 0) revert BudgetNotFound(r.budgetId);
        if (r.version != b.version) revert VersionMismatch(r.budgetId, b.version, r.version);
        if (_isExpired(b)) revert BudgetExpired(r.budgetId, b.expiresAt);
        if (r.reasonHash == bytes32(0)) revert ReasonRequired();
        if (r.amount == 0) revert ZeroAmount();
        if (r.amount > MAX_AMOUNT) revert AmountOutOfRange(r.amount); // 먼저 막아야 아래 덧셈이 넘치지 않는다
        uint256 newIssued = uint256(b.issued) + r.amount;
        if (newIssued > MAX_AMOUNT) revert AmountOutOfRange(newIssued);

        b.issued = uint128(newIssued);
        b.version += 1;
        emit BudgetIncreased(r.budgetId, r.amount, b.version, r.reasonHash, requester, approver);
    }

    function reclaim(ReclaimRequest calldata r, bytes calldata presidentSig) external {
        if (block.timestamp > r.deadline) revert SignatureExpired(r.deadline);
        address president = _recover(
            keccak256(abi.encode(RECLAIM_TYPEHASH, r.budgetId, r.amount, r.reclaimCount, r.deadline)),
            presidentSig
        );
        _requirePresident(president);

        Budget storage b = _budgets[r.budgetId];
        if (b.version == 0) revert BudgetNotFound(r.budgetId);
        if (!_isExpired(b)) revert BudgetNotExpired(r.budgetId, b.expiresAt);
        if (r.reclaimCount != b.reclaimCount) revert ReclaimCountMismatch(r.budgetId, b.reclaimCount, r.reclaimCount);
        uint256 rem = uint256(b.issued) - b.spent;
        if (rem == 0) revert ZeroAmount();
        if (r.amount != rem) revert ReclaimAmountMismatch(r.budgetId, rem, r.amount);

        b.issued = b.spent;
        b.reclaimCount += 1; // version(개정 번호)은 건드리지 않는다
        emit BudgetReclaimed(r.budgetId, rem, president);
    }

    // ----------------------------------------------------------------- ledger

    function spend(uint256 budgetId, uint256 amount, uint256 entryId) external onlyLedger {
        Budget storage b = _budgets[budgetId];
        if (b.version == 0) revert BudgetNotFound(budgetId);
        if (amount == 0) revert ZeroAmount();
        if (_isExpired(b)) revert BudgetExpired(budgetId, b.expiresAt);
        uint256 rem = uint256(b.issued) - b.spent;
        if (rem < amount) revert InsufficientBudget(budgetId, rem, amount);
        b.spent += uint128(amount); // amount <= rem <= issued <= MAX_AMOUNT
        emit BudgetSpent(budgetId, amount, entryId);
    }

    /// @dev 마감·회수 여부를 보지 않는다. spent 범위만 검사한다.
    function refund(uint256 budgetId, uint256 amount, uint256 entryId) external onlyLedger {
        Budget storage b = _budgets[budgetId];
        if (b.version == 0) revert BudgetNotFound(budgetId);
        if (amount == 0) revert ZeroAmount();
        if (amount > b.spent) revert RefundExceedsSpent(budgetId, b.spent, amount);
        b.spent -= uint128(amount);
        emit BudgetRefunded(budgetId, amount, entryId);
    }

    // ------------------------------------------------------------------ views

    function remaining(uint256 budgetId) external view returns (uint256) {
        Budget storage b = _budgets[budgetId];
        return uint256(b.issued) - b.spent;
    }

    function getBudget(uint256 budgetId) external view returns (Budget memory) {
        return _budgets[budgetId];
    }

    function exists(uint256 budgetId) external view returns (bool) {
        return _budgets[budgetId].version != 0;
    }

    function budgetIdOf(uint256 term, bytes32 category) external view returns (uint256) {
        return _budgetIdOf[_key(term, category)];
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // --------------------------------------------------------------- internal

    function _isExpired(Budget storage b) private view returns (bool) {
        return block.timestamp > b.expiresAt;
    }

    function _key(uint256 term, bytes32 category) private pure returns (bytes32) {
        return keccak256(abi.encode(term, category));
    }

    function _requirePresident(address signer) private view {
        if (!_roleManager.hasRole(PRESIDENT, signer)) revert NotPresident(signer);
    }

    function _recover(bytes32 structHash, bytes calldata signature) private view returns (address signer) {
        signer = Signatures.recoverOrZero(_hashTypedDataV4(structHash), signature);
        if (signer == address(0)) revert InvalidSignature();
    }
}
