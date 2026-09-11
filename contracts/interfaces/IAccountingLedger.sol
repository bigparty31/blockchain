// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAccountingLedger
/// @notice 수입·지출 기록 원장. 확정된 항목은 수정할 수 없고, 정정은 correctsId 로 원본을 가리키는 새 항목으로만 한다.
/// @dev
/// - entryId 는 백엔드 DB auto-increment 값. 컨트랙트는 중복만 막는다.
/// - amount 는 원 단위 정수. correctsId != 0 인 정정 항목에서만 음수 허용.
/// - 예산 초과 검사는 등록(recordPending) 시점, 예산 소모(BudgetToken.spend)는 확정(confirmEntry) 시점.
///   등록 시 초과면 revert 하지 않고 BLOCKED 로 저장 + EntryBlocked emit (이벤트를 남기기 위함).
///   BLOCKED 항목은 confirmEntry 에서 거부되며 잔액 계산에서도 제외한다.
///   확정 시 잔량 부족이면 그대로 revert (정상 동작).
/// - recordPending / confirmEntry / rejectEntry 는 모두 서버 릴레이어가 호출하되,
///   EIP-712 서명자가 실제 행위자(등록자·승인자·반려자)다. ERC-2771 포워더는 쓰지 않는다.
///   릴레이어가 actor 를 파라미터로 넘기면 등록자를 위조할 수 있어 "등록자 != 승인자" 검사가 무력화되기 때문.
///   등록자(registrant) == 승인자(signer) 이면 revert.
interface IAccountingLedger {
    // ---------------------------------------------------------------- types

    /// @dev docs/enums.md kind 순서 그대로
    enum Kind {
        INCOME, // 0
        EXPENSE // 1
    }

    /// @dev docs/enums.md entry status 순서 그대로
    enum Status {
        PENDING, // 0
        CONFIRMED, // 1
        REJECTED, // 2
        BLOCKED // 3
    }

    /// @dev docs/enums.md block_reason 순서 그대로. EntryBlocked.reason 값.
    enum BlockReason {
        BUDGET_EXCEEDED, // 0 잔량 부족
        BUDGET_EXPIRED, // 1 집행 마감 경과
        BUDGET_NOT_FOUND // 2 존재하지 않는 budgetId
    }

    struct Entry {
        bytes32 hash; // 오프체인 기록(영수증·내용) 해시
        int256 amount; // 원. 정정 항목만 음수 가능
        Kind kind;
        Status status;
        uint256 occurredAt; // 실제 발생 시각 (unix seconds). 기록 시각은 블록에 있음
        uint256 budgetId;
        uint256 correctsId; // 정정 대상 entryId. 0 이면 정정 아님
        address registrant; // 등록자 (recordPending 서명자)
        address approver; // 확정/반려한 사람 (confirmEntry/rejectEntry 서명자). 미처리면 address(0)
    }

    // EIP-712 서명 대상 struct 들. deadline 은 서명 유효 시한 (unix seconds).
    // 각 id 는 한 번만 상태 전이하므로 nonce 는 두지 않는다.

    /// @dev typehash:
    ///   keccak256("RecordRequest(uint256 id,bytes32 hash,int256 amount,uint8 kind,uint256 occurredAt,uint256 budgetId,uint256 correctsId,uint256 deadline)")
    struct RecordRequest {
        uint256 id;
        bytes32 hash;
        int256 amount;
        Kind kind; // EIP-712 타입 문자열에서는 uint8
        uint256 occurredAt;
        uint256 budgetId;
        uint256 correctsId;
        uint256 deadline;
    }

    /// @dev typehash:
    ///   keccak256("ConfirmApproval(uint256 id,bytes32 hash,bool hadWarning,bytes32 warningReasonHash,uint256 deadline)")
    struct ConfirmApproval {
        uint256 id;
        bytes32 hash;
        bool hadWarning;
        bytes32 warningReasonHash;
        uint256 deadline;
    }

    /// @dev typehash:
    ///   keccak256("RejectDecision(uint256 id,bytes32 reasonHash,uint256 deadline)")
    struct RejectDecision {
        uint256 id;
        bytes32 reasonHash;
        uint256 deadline;
    }

    // --------------------------------------------------------------- events
    // 손종인(백엔드)이 이 이벤트만으로 잔액을 계산한다. EntryConfirmed 에 금액·kind 를 반복해서 담는 이유.
    // 잔액 = Σ EntryConfirmed.amount (budgetId 별). EntryPending / EntryBlocked / EntryRejected 는 잔액에 영향 없음.

    event EntryPending(
        uint256 indexed id,
        bytes32 hash,
        int256 amount,
        uint8 kind,
        uint256 indexed budgetId,
        uint256 correctsId,
        address indexed actor
    );

    event EntryConfirmed(
        uint256 indexed id,
        bytes32 hash,
        int256 amount,
        uint8 kind,
        uint256 indexed budgetId,
        bool hadWarning,
        bytes32 warningReasonHash,
        address indexed actor
    );

    event EntryRejected(uint256 indexed id, bytes32 reasonHash, address indexed actor);

    event EntryBlocked(uint256 indexed id, uint256 indexed budgetId, uint256 attempted, uint8 reason);

    // --------------------------------------------------------------- errors

    error Unauthorized(address caller);
    error EntryAlreadyExists(uint256 id);
    error EntryNotFound(uint256 id);
    /// @dev PENDING 이 아닌 항목(BLOCKED 포함)을 확정/반려하려 할 때
    error InvalidStatus(uint256 id, Status current, Status expected);
    /// @dev correctsId == 0 인데 amount < 0
    error NegativeAmountWithoutCorrection(uint256 id);
    error ZeroAmount(uint256 id);
    error CorrectionTargetNotFound(uint256 id, uint256 correctsId);
    /// @dev 정정 대상이 CONFIRMED 가 아님
    error CorrectionTargetNotConfirmed(uint256 id, uint256 correctsId);
    /// @dev 저장된 hash 와 confirm 에 넘긴 hash 불일치
    error HashMismatch(uint256 id, bytes32 expected, bytes32 actual);
    error InvalidSignature();
    error SignatureExpired(uint256 deadline);
    /// @dev 서명자가 등록 권한 롤(TREASURER)이 아님
    error NotRegistrant(address signer);
    /// @dev 서명자가 승인 권한 롤이 아님
    error NotApprover(address signer);
    /// @dev 등록자 == 승인자
    error SelfApproval(uint256 id, address account);

    // ------------------------------------------------------------ functions

    /// @notice 항목 등록. 호출자는 릴레이어, request 의 EIP-712 서명자가 등록자(registrant).
    /// @dev 지출이고 예산 초과/마감/미존재면 revert 대신 BLOCKED 저장 + EntryBlocked emit.
    function recordPending(RecordRequest calldata request, bytes calldata signature) external;

    /// @notice 항목 확정. approval 의 EIP-712 서명자가 승인자. 지출이면 BudgetToken.spend/refund 를 호출한다.
    /// @dev PENDING 이 아니면(BLOCKED 포함) revert. BudgetToken 호출 실패 시 전체 revert.
    function confirmEntry(ConfirmApproval calldata approval, bytes calldata signature) external;

    /// @notice 항목 반려. decision 의 EIP-712 서명자가 반려자.
    function rejectEntry(RejectDecision calldata decision, bytes calldata signature) external;

    function getEntry(uint256 id) external view returns (Entry memory);

    function statusOf(uint256 id) external view returns (Status);

    function exists(uint256 id) external view returns (bool);

    /// @notice EIP-712 도메인 분리자 (백엔드가 서명 만들 때 필요)
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
