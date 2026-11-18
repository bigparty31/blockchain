// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IObjectionRegistry
/// @notice 학생이 특정 회계 항목에 제기하는 이의. 본문은 오프체인, 온체인에는 해시만.
/// @dev
/// - objectionId 는 백엔드 DB auto-increment. 컨트랙트는 중복만 막는다.
/// - 이의는 AccountingLedger 의 entry 상태에 영향을 주지 않는다.
/// - 상태는 docs/enums.md objection status 순서 그대로 (OPEN / ANSWERED).
/// - raise 는 릴레이어 신뢰 (학생 키는 서버 보관이라 서명 의미 없음). 생성자에서 정한 릴레이어 주소만 부를 수 있다.
///   raiser 가 대상 항목 학기(entry.term)의 MembershipSBT 를 가졌는지 컨트랙트가 확인한다.
///   항목 상태(확정·대기 중 등)는 보지 않는다 — 어떤 상태에 이의를 받을지는 서버가 정한다 (PRD v0.16 §4.5).
///   answer 는 임원 행위이므로 EIP-712 서명자가 실제 답변자 (AUDITOR 또는 PRESIDENT).
///   한 이의는 한 번만 답변되므로 nonce 는 두지 않는다 (재사용은 ObjectionAlreadyAnswered 로 막힌다).
interface IObjectionRegistry {
    // ---------------------------------------------------------------- types

    enum ObjectionStatus {
        OPEN, // 0
        ANSWERED // 1
    }

    struct Objection {
        uint256 entryId;
        bytes32 contentHash;
        bytes32 answerHash; // ANSWERED 전엔 0
        ObjectionStatus status;
        address raiser;
        address responder; // ANSWERED 전엔 address(0)
    }

    /// @dev typehash:
    ///   keccak256("AnswerRequest(uint256 objectionId,bytes32 answerHash,uint256 deadline)")
    struct AnswerRequest {
        uint256 objectionId;
        bytes32 answerHash;
        uint256 deadline; // 서명 유효 시한 (unix seconds)
    }

    // --------------------------------------------------------------- events

    event ObjectionRaised(
        uint256 indexed objectionId,
        uint256 indexed entryId,
        bytes32 contentHash,
        address indexed raiser
    );
    event ObjectionAnswered(uint256 indexed objectionId, bytes32 answerHash, address indexed responder);

    // --------------------------------------------------------------- errors

    error Unauthorized(address caller);
    /// @dev objectionId == 0 ("없음" 예약값). 중복(ObjectionAlreadyExists)과 구분한다
    error ReservedId();
    error ZeroAddress();
    error ObjectionAlreadyExists(uint256 objectionId);
    error ObjectionNotFound(uint256 objectionId);
    error ObjectionAlreadyAnswered(uint256 objectionId);
    error EntryNotFound(uint256 entryId);
    /// @dev raiser 가 해당 학기 MembershipSBT 를 갖고 있지 않음
    error NotMember(address raiser);
    error InvalidSignature();
    error SignatureExpired(uint256 deadline);
    /// @dev 서명자가 답변 권한 롤이 아님
    error NotResponder(address signer);

    // ------------------------------------------------------------ functions

    /// @notice 이의 제기. 호출자는 릴레이어, raiser 는 실제 학생(SBT 보유자). 릴레이어 신뢰.
    function raise(uint256 objectionId, uint256 entryId, bytes32 contentHash, address raiser) external;

    /// @notice 답변. request 의 EIP-712 서명자가 답변자(임원).
    function answer(AnswerRequest calldata request, bytes calldata signature) external;

    /// @notice 없는 id 는 빈 구조체 (raiser == address(0)). status 0(OPEN)만 보고 판단하지 않는다
    function getObjection(uint256 objectionId) external view returns (Objection memory);

    function exists(uint256 objectionId) external view returns (bool);

    /// @notice raise 를 부를 수 있는 유일한 주소 (서버 릴레이어). 생성자에서 정하고 바꾸지 않는다
    function relayer() external view returns (address);

    function roleManager() external view returns (address);

    function ledger() external view returns (address);

    function membershipSBT() external view returns (address);

    /// @notice EIP-712 도메인 분리자 (백엔드가 서명 만들 때 필요)
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
