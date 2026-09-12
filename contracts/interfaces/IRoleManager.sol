// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRoleManager
/// @notice 학생회 임원 롤 관리. STUDENT는 온체인 롤이 아니다 (MembershipSBT 보유 여부로 판별).
/// @dev 롤 식별자는 bytes32 = keccak256(롤 이름 문자열). enum 인덱스에 의존하지 않는다.
///      docs/enums.md 의 role 표에서 STUDENT를 뺀 세 개. 백엔드도 같은 문자열을 keccak256 해서 쓴다.
interface IRoleManager {
    // ---------------------------------------------------------------- types

    // 구현 컨트랙트에서 아래처럼 선언한다 (인터페이스에는 상수를 둘 수 없음):
    //   bytes32 public constant TREASURER = keccak256("TREASURER"); // 회계
    //   bytes32 public constant AUDITOR   = keccak256("AUDITOR");   // 감사
    //   bytes32 public constant PRESIDENT = keccak256("PRESIDENT"); // 회장
    // 위 셋 외의 role 값은 grantRole 에서 UnknownRole 로 revert.

    /// @notice 키 교체 제안. 회장·감사 중 한 명이 제안하고 다른 한 명이 승인해야 실행된다.
    struct KeyRotation {
        bytes32 role;
        address from;
        address to;
        address proposer;
        bool executed;
    }

    // --------------------------------------------------------------- events

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed actor);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed actor);

    event KeyRotationProposed(
        uint256 indexed rotationId,
        bytes32 indexed role,
        address from,
        address to,
        address indexed proposer
    );
    event KeyRotationApproved(uint256 indexed rotationId, address indexed approver);
    event KeyRotated(bytes32 indexed role, address indexed from, address indexed to);

    // --------------------------------------------------------------- errors

    error Unauthorized(address caller);
    /// @dev TREASURER / AUDITOR / PRESIDENT 외의 role 값
    error UnknownRole(bytes32 role);
    error RoleAlreadyGranted(bytes32 role, address account);
    error RoleNotGranted(bytes32 role, address account);
    error ZeroAddress();
    error RotationNotFound(uint256 rotationId);
    error RotationAlreadyExecuted(uint256 rotationId);
    /// @dev 제안자 본인이 승인하려 할 때
    error SelfApproval(uint256 rotationId);

    // ------------------------------------------------------------ functions

    function grantRole(bytes32 role, address account) external;

    function revokeRole(bytes32 role, address account) external;

    function hasRole(bytes32 role, address account) external view returns (bool);

    /// @notice 키 교체 제안 (1단계). 호출자는 PRESIDENT 또는 AUDITOR.
    /// @return rotationId 제안 식별자
    function proposeKeyRotation(bytes32 role, address from, address to) external returns (uint256 rotationId);

    /// @notice 키 교체 승인 (2단계). 제안자가 아닌 PRESIDENT 또는 AUDITOR가 호출하면 즉시 실행된다.
    function approveKeyRotation(uint256 rotationId) external;

    function getKeyRotation(uint256 rotationId) external view returns (KeyRotation memory);

    /// @notice 롤 식별자 조회 (백엔드가 하드코딩 대신 읽어갈 수 있게 노출)
    function TREASURER() external view returns (bytes32);

    function AUDITOR() external view returns (bytes32);

    function PRESIDENT() external view returns (bytes32);
}
