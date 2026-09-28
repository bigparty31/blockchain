// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRoleManager} from "../interfaces/IRoleManager.sol";

/// @title RoleManager
/// @notice 임원 롤 관리 구현. 규칙·검사 순서는 IRoleManager 주석과 docs/CONTRACTS.md "롤" 절이 정본이다.
/// @dev 자체 매핑. 한 주소 한 롤. 모든 변경은 임원 2인(제안자 ≠ 승인자) 경로로만.
contract RoleManager is IRoleManager {
    bytes32 public constant TREASURER = keccak256("TREASURER");
    bytes32 public constant AUDITOR = keccak256("AUDITOR");
    bytes32 public constant PRESIDENT = keccak256("PRESIDENT");

    /// @notice 회수 후에도 남아 있어야 하는 최소 임원 수. 2인 승인 경로가 막히지 않게 한다.
    uint256 public constant MIN_OFFICERS = 2;

    mapping(address account => bytes32 role) private _roleOf;
    uint256 private _officerCount;

    mapping(uint256 changeId => RoleChange) private _changes;
    uint256 private _changeCount;

    /// @param president 첫 회장
    /// @param treasurer 첫 총무
    /// @param auditor 첫 감사
    /// @dev 세 주소는 서로 다르고 0이 아니어야 한다. 배포자(msg.sender)는 아무 롤도 받지 않는다.
    constructor(address president, address treasurer, address auditor) {
        _grant(PRESIDENT, president, address(0), msg.sender);
        _grant(TREASURER, treasurer, address(0), msg.sender);
        _grant(AUDITOR, auditor, address(0), msg.sender);
    }

    // ------------------------------------------------------------------ views

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return role != bytes32(0) && _roleOf[account] == role;
    }

    function roleOf(address account) external view returns (bytes32) {
        return _roleOf[account];
    }

    function officerCount() external view returns (uint256) {
        return _officerCount;
    }

    function getRoleChange(uint256 changeId) external view returns (RoleChange memory) {
        return _changes[changeId];
    }

    // -------------------------------------------------------------- propose

    function proposeRoleChange(bytes32 role, address from, address to) external returns (uint256 changeId) {
        if (!_isOfficer(msg.sender)) revert Unauthorized(msg.sender);
        if (!_isKnownRole(role)) revert UnknownRole(role);
        if (from == address(0) && to == address(0)) revert ZeroAddress();

        changeId = ++_changeCount;
        _changes[changeId] = RoleChange({role: role, from: from, to: to, proposer: msg.sender, executed: false});

        emit RoleChangeProposed(changeId, role, from, to, msg.sender);
    }

    // -------------------------------------------------------------- approve

    function approveRoleChange(uint256 changeId) external {
        RoleChange storage c = _changes[changeId];

        // 1~5: 제안·승인자 상태
        if (c.proposer == address(0)) revert ChangeNotFound(changeId);
        if (c.executed) revert ChangeAlreadyExecuted(changeId);
        if (!_isOfficer(msg.sender)) revert Unauthorized(msg.sender);
        if (msg.sender == c.proposer) revert SelfApproval(changeId);
        if (!_isOfficer(c.proposer)) revert ProposerNotOfficer(changeId, c.proposer);

        bytes32 role = c.role;
        address from = c.from;
        address to = c.to;

        // 6: from 은 role 을 갖고 있어야 한다
        if (from != address(0) && _roleOf[from] != role) revert RoleNotGranted(role, from);

        // 7: to 는 어떤 임원 롤도 없어야 한다 (같은 롤이면 RoleAlreadyGranted, 다른 롤이면 AlreadyOfficer)
        if (to != address(0)) {
            bytes32 current = _roleOf[to];
            if (current == role) revert RoleAlreadyGranted(role, to);
            if (current != bytes32(0)) revert AlreadyOfficer(to, current);
        }

        // 8: 회수는 임원 수 하한을 지켜야 한다
        if (to == address(0)) {
            uint256 remaining = _officerCount - 1;
            if (remaining < MIN_OFFICERS) revert TooFewOfficers(remaining, MIN_OFFICERS);
        }

        c.executed = true;
        emit RoleChangeApproved(changeId, msg.sender);

        if (from != address(0)) {
            delete _roleOf[from];
            _officerCount -= 1;
            emit RoleRevoked(role, from, c.proposer, msg.sender);
        }
        if (to != address(0)) {
            _roleOf[to] = role;
            _officerCount += 1;
            emit RoleGranted(role, to, c.proposer, msg.sender);
        }
        if (from != address(0) && to != address(0)) {
            emit RoleReplaced(role, from, to, c.proposer, msg.sender);
        }
    }

    // ------------------------------------------------------------- internal

    /// @dev 생성자 전용. 실행 경로의 부여는 approveRoleChange 안에 인라인되어 있다.
    function _grant(bytes32 role, address account, address proposer, address approver) private {
        if (account == address(0)) revert ZeroAddress();
        bytes32 current = _roleOf[account];
        if (current != bytes32(0)) revert AlreadyOfficer(account, current);
        _roleOf[account] = role;
        _officerCount += 1;
        emit RoleGranted(role, account, proposer, approver);
    }

    function _isOfficer(address account) private view returns (bool) {
        return _roleOf[account] != bytes32(0);
    }

    function _isKnownRole(bytes32 role) private pure returns (bool) {
        return role == TREASURER || role == AUDITOR || role == PRESIDENT;
    }
}
