// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRoleManager
/// @notice 학생회 임원 롤 관리. STUDENT는 온체인 롤이 아니다 (MembershipSBT 보유 여부로 판별).
/// @dev 롤 식별자는 bytes32 = keccak256(롤 이름 문자열). enum 인덱스에 의존하지 않는다.
///      docs/enums.md 의 role 표에서 STUDENT를 뺀 세 개. 백엔드도 같은 문자열을 keccak256 해서 쓴다.
///
/// 롤 변경은 오직 2인 승인 경로로만 한다. 단독 호출로 롤을 주거나 뺏는 함수는 없다.
/// - 임원(PRESIDENT·TREASURER·AUDITOR 중 하나 보유) 한 명이 제안하고,
///   제안자가 아닌 다른 임원 한 명이 승인하면 즉시 실행된다.
/// - 한 제안은 한 번만 실행된다.
/// - 보유 상태 검사는 전부 승인(실행) 시점에 한다. 제안과 승인 사이에 상태가 바뀔 수 있기 때문이다.
///   승인 시점 검사 순서:
///     1 ChangeNotFound  2 ChangeAlreadyExecuted  3 Unauthorized(승인자가 임원 아님)  4 SelfApproval
///     5 ProposerNotOfficer(제안자가 더는 임원 아님)
///     6 from != 0: RoleNotGranted(from 이 role 미보유)
///     7 to != 0: RoleAlreadyGranted(to 가 같은 role 보유) → AlreadyOfficer(to 가 다른 임원 롤 보유)
///     8 to == 0 (회수): TooFewOfficers(실행 후 임원 수 < 2)
/// - 한 주소는 임원 롤을 하나만 가진다. 교체(from != 0, to != 0)는 임원 수를 바꾸지 않는다.
/// - 첫 회장·총무·감사는 생성자 인자로 받는다. 세 주소는 서로 다르고 0 이 아니어야 한다. 배포자는 어떤 롤도 갖지 않는다.
///   구현 컨트랙트 생성자: constructor(address president, address treasurer, address auditor)
/// - OpenZeppelin AccessControl 을 쓰지 않는다. 자체 매핑으로 구현하며 DEFAULT_ADMIN_ROLE 같은 상위 권한은 없다.
/// - 한계: 서로 다른 두 임원이 담합하면 롤을 바꿀 수 있다. 모든 변경은 제안자·승인자와 함께 이벤트로 남는다.
interface IRoleManager {
    // ---------------------------------------------------------------- types

    // 구현 컨트랙트에서 아래처럼 선언한다 (인터페이스에는 상수를 둘 수 없음):
    //   bytes32 public constant TREASURER = keccak256("TREASURER"); // 회계
    //   bytes32 public constant AUDITOR   = keccak256("AUDITOR");   // 감사
    //   bytes32 public constant PRESIDENT = keccak256("PRESIDENT"); // 회장
    // 위 셋 외의 role 값은 proposeRoleChange 에서 UnknownRole 로 revert.

    /// @notice 롤 변경 제안. from·to 조합으로 부여·회수·교체를 모두 표현한다.
    /// @dev
    ///   from == 0, to != 0 : 신규 부여 (to 에게 role 을 준다)
    ///   from != 0, to == 0 : 회수     (from 에게서 role 을 뺏는다)
    ///   from != 0, to != 0 : 교체     (from 에게서 뺏고 to 에게 준다)
    ///   둘 다 0 이면 ZeroAddress 로 revert.
    struct RoleChange {
        bytes32 role;
        address from;
        address to;
        address proposer;
        bool executed;
    }

    // --------------------------------------------------------------- events

    /// @notice 부여 결과 (신규 부여, 교체의 to 쪽). proposer 는 제안자, approver 는 승인자(실행자).
    event RoleGranted(bytes32 indexed role, address indexed account, address proposer, address indexed approver);
    /// @notice 회수 결과 (회수, 교체의 from 쪽).
    event RoleRevoked(bytes32 indexed role, address indexed account, address proposer, address indexed approver);
    /// @notice 교체(from != 0 && to != 0)일 때만 RoleRevoked·RoleGranted 에 더해 낸다.
    ///         두 이벤트가 한 변경으로 묶인 것임을 인덱서가 알 수 있게 하기 위함.
    event RoleReplaced(bytes32 indexed role, address indexed from, address indexed to, address proposer, address approver);

    event RoleChangeProposed(
        uint256 indexed changeId,
        bytes32 indexed role,
        address from,
        address to,
        address indexed proposer
    );
    event RoleChangeApproved(uint256 indexed changeId, address indexed approver);

    // --------------------------------------------------------------- errors

    /// @dev 임원이 아닌 계정의 제안·승인
    error Unauthorized(address caller);
    /// @dev TREASURER / AUDITOR / PRESIDENT 외의 role 값
    error UnknownRole(bytes32 role);
    /// @dev to 가 이미 같은 role 을 갖고 있음 (from == to 도 여기에 걸린다)
    error RoleAlreadyGranted(bytes32 role, address account);
    /// @dev from 이 role 을 갖고 있지 않음
    error RoleNotGranted(bytes32 role, address account);
    /// @dev to 가 이미 다른 임원 롤을 갖고 있음 (한 주소 한 롤). 생성자 인자가 중복될 때도 같은 에러
    error AlreadyOfficer(address account, bytes32 currentRole);
    /// @dev 회수를 실행하면 임원 수가 2 명 미만이 됨
    error TooFewOfficers(uint256 remaining, uint256 minimum);
    /// @dev 승인 시점에 제안자가 더는 임원이 아님
    error ProposerNotOfficer(uint256 changeId, address proposer);
    /// @dev from 과 to 가 둘 다 0, 또는 생성자 인자가 0
    error ZeroAddress();
    error ChangeNotFound(uint256 changeId);
    error ChangeAlreadyExecuted(uint256 changeId);
    /// @dev 제안자 본인이 승인하려 할 때
    error SelfApproval(uint256 changeId);

    // ------------------------------------------------------------ functions

    function hasRole(bytes32 role, address account) external view returns (bool);

    /// @notice account 가 가진 임원 롤. 없으면 bytes32(0). 한 주소 한 롤이므로 단일 값
    function roleOf(address account) external view returns (bytes32);

    /// @notice 현재 임원 수 (롤을 가진 주소 수). 회수 시 2 미만이 되면 revert
    function officerCount() external view returns (uint256);

    /// @notice 롤 변경 제안 (1단계). 호출자는 임원.
    /// @dev 제안 시점에는 role 유효성과 from/to 의 0 조합만 검사한다. 보유 상태는 승인 시점에 검사한다.
    /// @return changeId 제안 식별자 (1부터 온체인 카운터)
    function proposeRoleChange(bytes32 role, address from, address to) external returns (uint256 changeId);

    /// @notice 롤 변경 승인 (2단계). 제안자가 아닌 임원이 호출하면 즉시 실행된다. 검사 순서는 위 @dev 참고.
    function approveRoleChange(uint256 changeId) external;

    function getRoleChange(uint256 changeId) external view returns (RoleChange memory);

    /// @notice 롤 식별자 조회 (백엔드가 하드코딩 대신 읽어갈 수 있게 노출)
    function TREASURER() external view returns (bytes32);

    function AUDITOR() external view returns (bytes32);

    function PRESIDENT() external view returns (bytes32);
}
