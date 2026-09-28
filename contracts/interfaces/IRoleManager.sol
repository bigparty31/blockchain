// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRoleManager
/// @notice 학생회 임원 롤 관리. STUDENT는 온체인 롤이 아니다 (MembershipSBT 보유 여부로 판별).
/// @dev 롤 식별자는 bytes32 = keccak256(롤 이름 문자열). enum 인덱스에 의존하지 않는다.
///      docs/enums.md 의 role 표에서 STUDENT를 뺀 세 개. 백엔드도 같은 문자열을 keccak256 해서 쓴다.
///
/// 롤 변경은 오직 2인 승인 경로로만 한다. 단독 호출로 롤을 주거나 뺏는 함수는 없다.
/// - 임원(PRESIDENT·TREASURER·AUDITOR 중 어느 롤이든 보유) 한 명이 제안하고,
///   제안자가 아닌 다른 임원 한 명이 승인하면 즉시 실행된다.
/// - 한 제안은 한 번만 실행된다. 승인 시점에 조건(from 이 롤 보유, to 가 미보유)이 깨져 있으면 revert.
/// - 첫 회장·총무·감사는 생성자 인자로 받는다. 배포자는 어떤 롤도 갖지 않는다.
///   구현 컨트랙트 생성자: constructor(address president, address treasurer, address auditor)
/// - OpenZeppelin AccessControl 을 쓰지 않는다. 자체 매핑으로 구현하며 DEFAULT_ADMIN_ROLE 같은 상위 권한은 없다.
/// - 한계: 서로 다른 두 임원이 담합하면 롤을 바꿀 수 있다. 모든 변경은 이벤트로 남는다.
interface IRoleManager {
    // ---------------------------------------------------------------- types

    // 구현 컨트랙트에서 아래처럼 선언한다 (인터페이스에는 상수를 둘 수 없음):
    //   bytes32 public constant TREASURER = keccak256("TREASURER"); // 회계
    //   bytes32 public constant AUDITOR   = keccak256("AUDITOR");   // 감사
    //   bytes32 public constant PRESIDENT = keccak256("PRESIDENT"); // 회장
    // 위 셋 외의 role 값은 proposeKeyRotation 에서 UnknownRole 로 revert.

    /// @notice 롤 변경 제안. from·to 조합으로 부여·회수·교체를 모두 표현한다.
    /// @dev
    ///   from == 0, to != 0 : 신규 부여 (to 에게 role 을 준다)
    ///   from != 0, to == 0 : 회수     (from 에게서 role 을 뺏는다)
    ///   from != 0, to != 0 : 교체     (from 에게서 뺏고 to 에게 준다)
    ///   둘 다 0 이면 ZeroAddress 로 revert.
    struct KeyRotation {
        bytes32 role;
        address from;
        address to;
        address proposer;
        bool executed;
    }

    // --------------------------------------------------------------- events

    /// @notice 실행 결과. actor 는 승인자(실행을 일으킨 사람).
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
    /// @notice 교체(from != 0 && to != 0)일 때만. 부여·회수는 RoleGranted / RoleRevoked 만 낸다.
    event KeyRotated(bytes32 indexed role, address indexed from, address indexed to);

    // --------------------------------------------------------------- errors

    /// @dev 임원이 아닌 계정의 제안·승인
    error Unauthorized(address caller);
    /// @dev TREASURER / AUDITOR / PRESIDENT 외의 role 값
    error UnknownRole(bytes32 role);
    /// @dev to 가 이미 role 을 갖고 있음 (from == to 도 여기에 걸린다)
    error RoleAlreadyGranted(bytes32 role, address account);
    /// @dev from 이 role 을 갖고 있지 않음
    error RoleNotGranted(bytes32 role, address account);
    /// @dev from 과 to 가 둘 다 0, 또는 생성자 인자가 0
    error ZeroAddress();
    error RotationNotFound(uint256 rotationId);
    error RotationAlreadyExecuted(uint256 rotationId);
    /// @dev 제안자 본인이 승인하려 할 때
    error SelfApproval(uint256 rotationId);

    // ------------------------------------------------------------ functions

    function hasRole(bytes32 role, address account) external view returns (bool);

    /// @notice 롤 변경 제안 (1단계). 호출자는 임원(세 롤 중 하나 이상 보유).
    /// @dev 제안 시점에 role 유효성과 from/to 의 0 조합만 검사한다. 보유 상태는 승인(실행) 시점에 검사한다.
    /// @return rotationId 제안 식별자 (1부터 온체인 카운터)
    function proposeKeyRotation(bytes32 role, address from, address to) external returns (uint256 rotationId);

    /// @notice 롤 변경 승인 (2단계). 제안자가 아닌 임원이 호출하면 즉시 실행된다.
    /// @dev 실행 시 from != 0 이면 from 이 role 을 보유해야 하고(아니면 RoleNotGranted),
    ///      to != 0 이면 to 가 role 을 미보유해야 한다(아니면 RoleAlreadyGranted).
    function approveKeyRotation(uint256 rotationId) external;

    function getKeyRotation(uint256 rotationId) external view returns (KeyRotation memory);

    /// @notice 롤 식별자 조회 (백엔드가 하드코딩 대신 읽어갈 수 있게 노출)
    function TREASURER() external view returns (bytes32);

    function AUDITOR() external view returns (bytes32);

    function PRESIDENT() external view returns (bytes32);
}
