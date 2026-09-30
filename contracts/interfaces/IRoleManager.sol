// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRoleManager
/// @notice 학생회 임원 롤 관리. STUDENT는 온체인 롤이 아니다 (MembershipSBT 보유 여부로 판별).
/// @dev 롤 식별자는 bytes32 = keccak256(롤 이름 문자열). enum 인덱스에 의존하지 않는다.
///      docs/enums.md 의 role 표에서 STUDENT를 뺀 세 개. 백엔드도 같은 문자열을 keccak256 해서 쓴다.
///
/// 보유 규칙
/// - PRESIDENT 정확히 1명, TREASURER 정확히 1명, AUDITOR 2명 이상.
///   감사가 2명이어야 회장 키를 잃었을 때 감사 둘이 복구할 수 있고, 감사 한 명의 키를 잃어도 회장 + 다른 감사가 교체할 수 있다.
/// - 한 주소는 임원 롤을 하나만 가진다.
///
/// 일반 변경 — changeRole (PRD §7.2·§9.2 "회장+감사 2인 서명")
/// - 부여·회수·교체 전부. 같은 RoleChange 에 회장 1명 + 감사 1명이 EIP-712 서명하고 릴레이어가 한 트랜잭션으로 제출한다.
///   서명 순서(제안자·승인자)는 자유. 감사 둘만 서명하면 PresidentRequired. TREASURER 는 서명 자격이 없다(NotGovernor).
/// - 제안이 체인에 저장되지 않는다. 서명은 deadline 이 지나면 무효이고, 전역 nonce 가 변경마다 1 오르므로
///   한 변경이 실행되면 그 전에 받아 둔 다른 서명은 전부 무효가 된다.
/// - from·to 조합: from == 0 부여 / to == 0 회수 / 둘 다 있으면 교체. 둘 다 0 이면 ZeroAddress.
/// - PRESIDENT·TREASURER 는 보유자가 있으면 부여 불가(RoleCapacityExceeded), 회수 불가(RoleMinimumViolated). 교체만 가능.
///   AUDITOR 는 부여 가능, 2명 이하일 때는 회수 불가(RoleMinimumViolated).
///
/// 회장 복구 — 회장 키 분실 대비 (PRD §7.2 "기기 변경·분실이 반드시 발생")
/// - 감사 2명이 PresidentRecovery 에 서명해 proposePresidentRecovery 로 제안한다. 체인에 저장되고 RECOVERY_DELAY(72시간) 뒤 실행 가능.
/// - 대기 중에 현재 회장이 RecoveryCancel 에 서명하면 cancelPresidentRecovery 로 취소된다. 회장 키가 살아 있으면 여기서 끝난다.
/// - 대기가 끝나면 executePresidentRecovery 를 누구나 부를 수 있다 (서명 불필요). 실행 시점에 조건을 다시 검사한다:
///   from 이 여전히 회장(RoleNotGranted), 두 제안자가 여전히 감사(NotAuditor), to 가 롤 없음(AlreadyOfficer).
/// - 대기 중인 복구는 한 건뿐이다. 새 제안은 이전 제안을 덮어쓴다 (조건이 깨진 제안에 막혀 복구가 잠기지 않게).
/// - 제안은 전역 nonce 를 소비하고, 실행도 nonce 를 1 올린다 (그 사이 받아 둔 일반 변경 서명 무효화).
///
/// changeRole 검사 순서:
///   1 SignatureExpired  2 InvalidNonce  3 UnknownRole  4 ZeroAddress
///   5 InvalidSignature(두 서명 각각)  6 NotGovernor(제안자) → NotGovernor(승인자) → SameSigner → PresidentRequired
///   7 from != 0: RoleNotGranted
///   8 to != 0: RoleAlreadyGranted(같은 롤) → AlreadyOfficer(다른 롤)
///   9 부여(from == 0): RoleCapacityExceeded   10 회수(to == 0): RoleMinimumViolated
///
/// - 첫 회장·총무·감사 2명은 생성자 인자로 받는다: constructor(address president, address treasurer, address auditor1, address auditor2).
///   네 주소는 서로 다르고 0 이 아니어야 한다. 배포자는 어떤 롤도 갖지 않는다.
///   생성자 부여는 RoleGranted(role, account, proposer = 0, approver = 0) 로 남는다. proposer·approver 가 0 이면 최초 부여다.
/// - OpenZeppelin AccessControl 을 쓰지 않는다. 자체 매핑으로 구현하며 DEFAULT_ADMIN_ROLE 같은 상위 권한은 없다.
/// - 한계: 회장과 감사 한 명이 담합하면 롤을 바꿀 수 있다. 감사 두 명이 담합하면 72시간 안에 회장이 취소하지 않는 한
///   회장을 바꿀 수 있다. 회장과 감사 한 명이 동시에 키를 잃으면(감사가 2명뿐일 때) 복구할 수 없다. 모든 변경은 이벤트로 남는다.
interface IRoleManager {
    // ---------------------------------------------------------------- types

    // 구현 컨트랙트에서 아래처럼 선언한다 (인터페이스에는 상수를 둘 수 없음):
    //   bytes32 public constant TREASURER = keccak256("TREASURER"); // 회계
    //   bytes32 public constant AUDITOR   = keccak256("AUDITOR");   // 감사
    //   bytes32 public constant PRESIDENT = keccak256("PRESIDENT"); // 회장

    /// @notice 일반 롤 변경 요청. 회장·감사가 같은 값에 서명한다.
    /// @dev typehash:
    ///   keccak256("RoleChange(bytes32 role,address from,address to,uint256 nonce,uint256 deadline)")
    ///   EIP-712 도메인: name = "RoleManager", version = "1".
    struct RoleChange {
        bytes32 role;
        address from;
        address to;
        uint256 nonce; // 현재 nonce() 값이어야 한다
        uint256 deadline; // 서명 유효 시한 (unix seconds)
    }

    /// @notice 회장 복구 제안. 감사 2명이 같은 값에 서명한다.
    /// @dev typehash:
    ///   keccak256("PresidentRecovery(address from,address to,uint256 nonce,uint256 deadline)")
    ///   from = 현재 회장, to = 새 회장. nonce 는 현재 nonce() 이고, 그 값이 이 복구의 recoveryId 가 된다.
    struct PresidentRecovery {
        address from;
        address to;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice 회장 복구 취소. 현재 회장이 서명한다.
    /// @dev typehash:
    ///   keccak256("RecoveryCancel(uint256 recoveryId,uint256 deadline)")
    struct RecoveryCancel {
        uint256 recoveryId;
        uint256 deadline;
    }

    /// @notice 대기 중인 회장 복구. recoveryId == 0 && executableAt == 0 이면 없음.
    struct PendingRecovery {
        uint256 recoveryId;
        address from;
        address to;
        address auditorA;
        address auditorB;
        uint64 executableAt;
    }

    // --------------------------------------------------------------- events

    /// @notice 부여 결과 (신규 부여, 교체의 to 쪽). 생성자 부여는 proposer·approver 가 0.
    ///         회장 복구는 proposer·approver 가 두 감사.
    event RoleGranted(bytes32 indexed role, address indexed account, address proposer, address indexed approver);
    /// @notice 회수 결과 (회수, 교체의 from 쪽).
    event RoleRevoked(bytes32 indexed role, address indexed account, address proposer, address indexed approver);
    /// @notice 변경 한 번에 한 번 (changeRole, executePresidentRecovery). 교체일 때 RoleRevoked·RoleGranted 를 한 변경으로 묶는다.
    event RoleChangeExecuted(
        uint256 indexed nonce,
        bytes32 indexed role,
        address from,
        address to,
        address proposer,
        address approver
    );
    event PresidentRecoveryProposed(
        uint256 indexed recoveryId,
        address indexed from,
        address indexed to,
        address auditorA,
        address auditorB,
        uint256 executableAt
    );
    event PresidentRecoveryCancelled(uint256 indexed recoveryId, address indexed president);

    // --------------------------------------------------------------- errors

    /// @dev TREASURER / AUDITOR / PRESIDENT 외의 role 값
    error UnknownRole(bytes32 role);
    /// @dev to 가 이미 같은 role 을 갖고 있음 (from == to 도 여기에 걸린다)
    error RoleAlreadyGranted(bytes32 role, address account);
    /// @dev from 이 role 을 갖고 있지 않음
    error RoleNotGranted(bytes32 role, address account);
    /// @dev to 가 이미 다른 임원 롤을 갖고 있음 (한 주소 한 롤). 생성자 인자가 중복될 때도 같은 에러
    error AlreadyOfficer(address account, bytes32 currentRole);
    /// @dev 보유자가 이미 있는 PRESIDENT·TREASURER 에 신규 부여
    error RoleCapacityExceeded(bytes32 role);
    /// @dev PRESIDENT·TREASURER 회수, 또는 감사가 2명 이하일 때 감사 회수
    error RoleMinimumViolated(bytes32 role);
    /// @dev from 과 to 가 둘 다 0, 복구의 to 가 0, 또는 생성자 인자가 0
    error ZeroAddress();
    error InvalidSignature();
    error SignatureExpired(uint256 deadline);
    /// @dev 요청의 nonce 가 현재 nonce() 와 다름 (이미 쓰였거나 다른 변경이 먼저 실행됨)
    error InvalidNonce(uint256 expected, uint256 actual);
    /// @dev changeRole 서명자가 회장·감사가 아님
    error NotGovernor(address signer);
    /// @dev 두 서명자가 같은 주소
    error SameSigner(address signer);
    /// @dev changeRole 의 두 서명자 중 회장이 없음 (감사 둘만으로는 일반 변경 불가. 회장 교체는 복구 경로를 쓴다)
    error PresidentRequired();
    /// @dev 복구 제안·실행의 서명자(제안자)가 감사가 아님
    error NotAuditor(address signer);
    /// @dev 복구 취소 서명자가 현재 회장이 아님
    error NotPresident(address signer);
    /// @dev 대기 중인 복구가 없거나 recoveryId 가 다름
    error NoPendingRecovery(uint256 recoveryId);
    /// @dev 대기 기간이 아직 안 지남
    error RecoveryNotReady(uint256 executableAt);

    // ------------------------------------------------------------ functions

    /// @notice 일반 롤 변경. 호출자는 릴레이어. 회장 1 + 감사 1 서명. 검사 순서는 위 @dev 참고.
    function changeRole(RoleChange calldata change, bytes calldata proposerSig, bytes calldata approverSig) external;

    /// @notice 회장 복구 제안. 감사 2명 서명. 기존 대기 복구는 덮어쓴다.
    function proposePresidentRecovery(
        PresidentRecovery calldata recovery,
        bytes calldata auditorSigA,
        bytes calldata auditorSigB
    ) external;

    /// @notice 회장 복구 취소. 현재 회장 서명.
    function cancelPresidentRecovery(RecoveryCancel calldata cancel, bytes calldata presidentSig) external;

    /// @notice 대기 기간이 지난 회장 복구 실행. 서명 없이 누구나 호출.
    function executePresidentRecovery() external;

    function pendingRecovery() external view returns (PendingRecovery memory);

    /// @notice 회장 복구 대기 기간 (초). 72시간.
    function RECOVERY_DELAY() external view returns (uint256);

    /// @notice 감사 최소 인원. 2.
    function MIN_AUDITORS() external view returns (uint256);

    function hasRole(bytes32 role, address account) external view returns (bool);

    /// @notice account 가 가진 임원 롤. 없으면 bytes32(0)
    function roleOf(address account) external view returns (bytes32);

    /// @notice role 의 현재 보유자 수
    function holderCount(bytes32 role) external view returns (uint256);

    /// @notice PRESIDENT 또는 AUDITOR 인가 (롤 변경 서명 자격)
    function isGovernor(address account) external view returns (bool);

    /// @notice 다음 서명 요청이 써야 하는 nonce. 0 부터 시작해 변경·복구 제안·복구 실행마다 1 오른다
    function nonce() external view returns (uint256);

    /// @notice EIP-712 도메인 분리자 (앱이 롤 변경 서명을 만들 때 필요)
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice 롤 식별자 조회 (백엔드가 하드코딩 대신 읽어갈 수 있게 노출)
    function TREASURER() external view returns (bytes32);

    function AUDITOR() external view returns (bytes32);

    function PRESIDENT() external view returns (bytes32);
}
