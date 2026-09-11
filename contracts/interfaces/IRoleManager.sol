// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRoleManager
/// @notice 학생회 임원 롤 관리. STUDENT는 온체인 롤이 아니다 (MembershipSBT 보유 여부로 판별).
/// @dev 롤 순서는 docs/enums.md 의 role 순서에서 STUDENT를 뺀 것.
interface IRoleManager {
    // ---------------------------------------------------------------- types

    enum Role {
        TREASURER, // 0 회계
        AUDITOR, // 1 감사
        PRESIDENT // 2 회장
    }

    /// @notice 키 교체 제안. 회장·감사 중 한 명이 제안하고 다른 한 명이 승인해야 실행된다.
    struct KeyRotation {
        Role role;
        address from;
        address to;
        address proposer;
        bool executed;
    }

    // --------------------------------------------------------------- events

    event RoleGranted(Role indexed role, address indexed account, address indexed actor);
    event RoleRevoked(Role indexed role, address indexed account, address indexed actor);

    event KeyRotationProposed(
        uint256 indexed rotationId,
        Role indexed role,
        address from,
        address to,
        address indexed proposer
    );
    event KeyRotationApproved(uint256 indexed rotationId, address indexed approver);
    event KeyRotated(Role indexed role, address indexed from, address indexed to);

    // --------------------------------------------------------------- errors

    error Unauthorized(address caller);
    error RoleAlreadyGranted(Role role, address account);
    error RoleNotGranted(Role role, address account);
    error ZeroAddress();
    error RotationNotFound(uint256 rotationId);
    error RotationAlreadyExecuted(uint256 rotationId);
    /// @dev 제안자 본인이 승인하려 할 때
    error SelfApproval(uint256 rotationId);

    // ------------------------------------------------------------ functions

    function grantRole(Role role, address account) external;

    function revokeRole(Role role, address account) external;

    function hasRole(Role role, address account) external view returns (bool);

    /// @notice 키 교체 제안 (1단계). 호출자는 PRESIDENT 또는 AUDITOR.
    /// @return rotationId 제안 식별자
    function proposeKeyRotation(Role role, address from, address to) external returns (uint256 rotationId);

    /// @notice 키 교체 승인 (2단계). 제안자가 아닌 PRESIDENT 또는 AUDITOR가 호출하면 즉시 실행된다.
    function approveKeyRotation(uint256 rotationId) external;

    function getKeyRotation(uint256 rotationId) external view returns (KeyRotation memory);
}
