// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAccountingLedger
/// @notice 수입·지출 기록 원장. 확정된 항목은 수정할 수 없고, 정정은 correctsId 로 원본을 가리키는 새 항목으로만 한다.
/// @dev
/// - 생성자에서 RoleManager·BudgetToken 주소를 받는다: constructor(address roleManager, address budgetToken). 0 이면 ZeroAddress.
/// - entryId 는 백엔드 DB auto-increment 값. 컨트랙트는 중복만 막는다. 0 은 "없음" 으로 예약(ReservedId).
/// - amount 는 원 단위 정수. correctsId != 0 인 정정 항목에서만 음수 허용. |amount| <= MAX_AMOUNT (1e15 원).
/// - term 은 학기 코드 YYYYS (예: 20261 = 2026년 1학기). DB 의 Term.id 가 아니다.
///   서명 대상(RecordRequest)에 들어가므로 총무가 확인한 값이다. 수입·지출 모두 0 금지(TermRequired).
///   지출은 등록 시점에 예산의 term 과 대조해 다르면 revert(TermMismatch). 정정은 원본의 term 과 같아야 한다(TermMismatch).
///   정정이 아닌 수입은 대조할 대상이 없어 서명된 값 그대로 저장한다.
/// - 저장 필드 폭: id·budgetId·correctsId·occurredAt 은 uint64, term 은 uint32, amount 는 int128.
///   넘는 값은 FieldOutOfRange / AmountOutOfRange. 요청 struct 의 EIP-712 타입은 uint256·int256 그대로다.
/// - hash 는 PRD §8 meta_hash. 계산 규칙의 정본은 docs/HASHING.md 다.
///   구분자는 U+001F (Unit Separator) 이고 파이프(|) 가 아니다 — 목적란이 자유 입력이라
///   파이프를 쓰면 서로 다른 거래가 같은 해시를 낸다 (docs/HASHING.md §1).
///   SHA-256 32바이트를 bytes32 에 그대로 담는다 (keccak 아님). 영수증은 receipt_hash 로 이미 포함.
///   EIP-712 서명 digest 와는 별개 값 — meta_hash 는 서명 대상 struct 의 한 필드다.
/// - meta_hash 에는 kind·term·budgetId·correctsId 가 없다. 그래서 승인자는 entryCommit 에도 서명한다:
///     entryCommit = keccak256(abi.encode(bytes32 hash, int256 amount, uint8 kind, uint256 term,
///                                        uint256 budgetId, uint256 correctsId, address registrant))
///   confirmEntry 는 저장된 항목으로 같은 값을 계산해 다르면 EntryCommitMismatch. entryCommitOf(id) 로 조회할 수 있다.
///   승인자가 화면에서 본 예산·학기·종류·등록자가 체인에 올라간 값과 같다는 보증이다.
/// - 예산 초과 검사는 등록(recordPending) 시점, 예산 소모(BudgetToken.spend)는 확정(confirmEntry) 시점.
///   등록 시 초과·마감·미존재면 revert 하지 않고 BLOCKED 로 저장 + EntryBlocked emit (이벤트를 남기기 위함).
///   BLOCKED 항목은 confirmEntry 에서 거부되며 잔액 계산에서도 제외한다.
///   확정 시 잔량 부족이면 그대로 revert (정상 동작). 등록 시 검사는 대기 건을 예약하지 않으므로
///   대기 여러 건이 같은 예산을 나눠 쓰다 나중 건 확정이 revert 할 수 있다. 그 경우 상태는 PENDING 그대로이고
///   앱이 rejectEntry 로 반려한다.
/// - INCOME 항목은 budgetId = 0. budgetId != 0 이면 revert(BudgetIdNotAllowedForIncome). 예산 검사·소모는 EXPENSE 에만 적용.
/// - 정정: 페어 필드는 없다. RECLASSIFY 는 양수 정정(새 예산 spend) + 음수 정정(원래 예산 refund) 2건으로 표현하고
///   순서는 서버 규칙(양수 다음 음수). 음수 정정의 budgetId 는 원본의 budgetId 와 같아야 한다(CorrectionBudgetMismatch).
///   양수 정정도 일반 지출과 같이 등록 시 잔량 검사·확정 시 spend 를 거친다.
///   차액(amount)이 0 인 정정은 등록 시 ZeroAmount 로 revert (일반 항목과 같은 검사).
///   정정의 kind·term 은 원본과 같아야 한다(CorrectionKindMismatch / TermMismatch).
///   정정 대상(correctsId)은 "정정 가능 항목" 이어야 한다: 원본(정정이 아닌 항목)이거나,
///   원본과 다른 budgetId 로 간 양수 정정(재분류)이다. 그 외 정정 항목(같은 예산 양수 정정, 음수 정정)을
///   대상으로 하면 InvalidCorrectionTarget. 같은 금액이 두 항목의 순금액에 잡혀 소모액보다 많이 refund 되는 것을 막는다.
///   음수 정정의 범위는 대상별 누적으로 검사한다: 정정 가능 항목마다 순금액 netAmountOf(id) 를 둔다.
///   확정 시 = 자기 amount(양수), 그 항목을 대상으로 하는 정정이 확정될 때 += 정정 amount (음수면 빠진다).
///   단 원본과 다른 예산으로 가는 양수 정정(재분류)은 원본 순금액에 더하지 않고 자기 순금액을 새로 가진다.
///   음수 정정 확정으로 대상 순금액이 0 아래로 가면 CorrectionExceedsOriginal. 등록 시에도 현재 순금액으로
///   같은 검사를 먼저 해 조기에 걸러낸다 (대기 중인 다른 정정은 예약하지 않으므로 확정 시 검사가 최종). 수입·지출 모두 적용.
///   같은 예산 양수 정정은 순금액을 갖지 않는다(대상의 순금액에 흡수됨). 재분류 금액은 재분류 양수 정정을 대상으로 한
///   음수 정정으로만 되돌린다.
///   한계: 한 쌍 중 한쪽만 확정된 상태가 존재할 수 있다 (사람이 한쪽만 승인하는 경우). 완화는 앱·서버 몫.
/// - 승인자(confirmEntry / rejectEntry 서명자)는 AUDITOR 또는 PRESIDENT. 등록자 != 승인자는 별도 검사.
/// - 반려는 reasonHash != 0 필수(ReasonRequired). 확정은 hadWarning == (warningReasonHash != 0) 이어야 한다.
///   경고인데 사유 0 → ReasonRequired, 경고 아닌데 사유 있음 → ReasonNotAllowed.
/// - recordPending / confirmEntry / rejectEntry 는 모두 서버 릴레이어가 호출하되,
///   EIP-712 서명자가 실제 행위자(등록자·승인자·반려자)다. ERC-2771 포워더는 쓰지 않는다.
///   릴레이어가 actor 를 파라미터로 넘기면 등록자를 위조할 수 있어 "등록자 != 승인자" 검사가 무력화되기 때문.
///   등록자(registrant) == 승인자(signer) 이면 revert.
/// - kind 가 0·1 이 아닌 요청은 ABI 디코딩 단계에서 에러 데이터 없이 revert 한다. 컨트랙트가 손쓸 수 없어 백엔드가 먼저 막는다.
///
/// recordPending 검사 순서 (revert 는 위에서부터, BLOCKED 판정은 revert 검사가 모두 통과한 뒤):
///   1 SignatureExpired
///   2 ReservedId(id == 0) → FieldOutOfRange(id) → EntryAlreadyExists
///   3 TermRequired → FieldOutOfRange(term)
///   4 ZeroAmount → AmountOutOfRange
///   5 NegativeAmountWithoutCorrection → FieldOutOfRange(occurredAt·budgetId·correctsId)
///   6 NotRegistrant
///   7 INCOME: BudgetIdNotAllowedForIncome
///   8 correctsId != 0: CorrectionTargetNotFound → CorrectionTargetNotConfirmed → CorrectionKindMismatch
///     → TermMismatch(원본 term) → InvalidCorrectionTarget → (amount < 0) CorrectionBudgetMismatch
///     → (amount < 0) CorrectionExceedsOriginal(현재 순금액 기준 선검사)
///   9 EXPENSE 이고 예산이 존재하면 TermMismatch(예산 term)
///  10 EXPENSE 예산 판정: BUDGET_NOT_FOUND / BUDGET_EXPIRED / BUDGET_EXCEEDED → BLOCKED 저장 (revert 아님)
///   budgetId == 0 인 EXPENSE 는 BUDGET_NOT_FOUND 로 BLOCKED (백엔드 FakeChainClient 와 동일).
///   음수 정정은 10 을 건너뛴다 (refund 는 마감·잔량과 무관).
///
/// confirmEntry 검사 순서:
///   1 SignatureExpired  2 EntryNotFound  3 InvalidStatus  4 HashMismatch  5 EntryCommitMismatch
///   6 ReasonRequired / ReasonNotAllowed  7 InvalidSignature → NotApprover → SelfApproval
///   8 (음수 정정) CorrectionExceedsOriginal  9 BudgetToken.spend / refund 의 에러가 그대로 올라온다
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

    /// @dev 4 슬롯으로 묶인다:
    ///   [hash] [amount | budgetId | correctsId] [registrant | occurredAt | term] [approver | kind | status]
    ///   필드 순서가 저장 배치를 결정하므로 바꾸지 않는다. getEntry 의 반환 튜플 순서도 이 순서다.
    struct Entry {
        bytes32 hash; // PRD §8 meta_hash (SHA-256). docs/CONTRACTS.md "entry.hash" 절
        int128 amount; // 원. 정정 항목만 음수 가능
        uint64 budgetId;
        uint64 correctsId; // 정정 대상 entryId. 0 이면 정정 아님
        address registrant; // 등록자 (recordPending 서명자). 0 이면 항목 없음
        uint64 occurredAt; // 실제 발생 시각 (unix seconds). 기록 시각은 블록에 있음
        uint32 term; // 학기 코드 YYYYS. 0 아님
        address approver; // 확정/반려한 사람 (confirmEntry/rejectEntry 서명자). 미처리면 address(0)
        Kind kind;
        Status status;
    }

    // EIP-712 서명 대상 struct 들. deadline 은 서명 유효 시한 (unix seconds).
    // 각 id 는 한 번만 상태 전이하므로 nonce 는 두지 않는다.
    // EIP-712 도메인: name = "AccountingLedger", version = "1".

    /// @dev typehash:
    ///   keccak256("RecordRequest(uint256 id,bytes32 hash,int256 amount,uint8 kind,uint256 term,uint256 occurredAt,uint256 budgetId,uint256 correctsId,uint256 deadline)")
    struct RecordRequest {
        uint256 id;
        bytes32 hash;
        int256 amount;
        Kind kind; // EIP-712 타입 문자열에서는 uint8
        uint256 term;
        uint256 occurredAt;
        uint256 budgetId;
        uint256 correctsId;
        uint256 deadline;
    }

    /// @dev typehash:
    ///   keccak256("ConfirmApproval(uint256 id,bytes32 hash,bytes32 entryCommit,bool hadWarning,bytes32 warningReasonHash,uint256 deadline)")
    ///   entryCommit 은 위 @dev 의 식. 앱은 서버가 내려준 항목 값으로 직접 계산해 화면 내용과 함께 서명한다.
    struct ConfirmApproval {
        uint256 id;
        bytes32 hash;
        bytes32 entryCommit;
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
    // 손종인(백엔드)이 이 이벤트만으로 장부 잔액을 계산한다. EntryConfirmed 에 금액·kind·term 을 반복해서 담는 이유.
    // 장부 잔액 = Σ EntryConfirmed.amount (kind == INCOME) − Σ EntryConfirmed.amount (kind == EXPENSE).
    // 학기별 합계는 term 으로 나눈다. 원본 수입·지출은 양수로 들어오므로 kind 로 나눠 빼야 한다. 그냥 더하면 안 된다.
    // 음수 정정은 EntryConfirmed.amount 가 음수로 온다. 같은 식에 그대로 더하면 원본에서 빠진다.
    // 예산 잔량은 이 이벤트로 계산하지 않는다. 구현은 BudgetToken.remaining() 호출,
    // 이벤트 재계산(Issued + Increased − Reclaimed − Spent + Refunded)은 검증용.
    // EntryPending / EntryBlocked / EntryRejected 는 잔액에 영향 없음.

    event EntryPending(
        uint256 indexed id,
        bytes32 hash,
        int256 amount,
        uint8 kind,
        uint256 term,
        uint256 indexed budgetId,
        uint256 correctsId,
        address indexed actor
    );

    event EntryConfirmed(
        uint256 indexed id,
        bytes32 hash,
        int256 amount,
        uint8 kind,
        uint256 term,
        uint256 indexed budgetId,
        bool hadWarning,
        bytes32 warningReasonHash,
        address indexed actor
    );

    event EntryRejected(uint256 indexed id, bytes32 reasonHash, address indexed actor);

    /// @notice 등록 시점 예산 판정으로 차단된 시도. 학기별 초과 시도 지표를 이벤트만으로 낼 수 있게 term·등록자를 담는다.
    event EntryBlocked(
        uint256 indexed id,
        bytes32 hash,
        uint256 attempted,
        uint256 term,
        uint256 indexed budgetId,
        uint8 reason,
        address indexed actor
    );

    // --------------------------------------------------------------- errors

    /// @dev id == 0. "없음" 으로 예약된 값 (docs/HASHING.md §2.1). 중복(EntryAlreadyExists)과 구분한다
    error ReservedId(uint256 id);
    error EntryAlreadyExists(uint256 id);
    /// @dev 없는 id 의 확정·반려·statusOf
    error EntryNotFound(uint256 id);
    /// @dev PENDING 이 아닌 항목(BLOCKED 포함)을 확정/반려하려 할 때
    error InvalidStatus(uint256 id, Status current, Status expected);
    /// @dev correctsId == 0 인데 amount < 0
    error NegativeAmountWithoutCorrection(uint256 id);
    error ZeroAmount(uint256 id);
    /// @dev |amount| > MAX_AMOUNT
    error AmountOutOfRange(uint256 id, int256 amount);
    /// @dev id·term·occurredAt·budgetId·correctsId 가 저장 필드 폭을 넘음. value 는 넘은 값
    error FieldOutOfRange(uint256 id, uint256 value);
    error CorrectionTargetNotFound(uint256 id, uint256 correctsId);
    /// @dev 정정 대상이 CONFIRMED 가 아님
    error CorrectionTargetNotConfirmed(uint256 id, uint256 correctsId);
    /// @dev 정정의 kind 가 원본의 kind 와 다름
    error CorrectionKindMismatch(uint256 id, Kind expected, Kind actual);
    /// @dev 정정 대상이 원본도, 재분류 양수 정정도 아님 (같은 예산 양수 정정·음수 정정은 대상이 될 수 없다)
    error InvalidCorrectionTarget(uint256 id, uint256 correctsId);
    /// @dev 음수 정정의 budgetId 가 원본(correctsId)의 budgetId 와 다름
    error CorrectionBudgetMismatch(uint256 id, uint256 expected, uint256 actual);
    /// @dev 음수 정정 누적이 대상의 순금액을 넘음. netAmount 는 현재 순금액, requested 는 이번 정정의 절대값
    error CorrectionExceedsOriginal(uint256 id, uint256 correctsId, uint256 netAmount, uint256 requested);
    /// @dev 저장된 hash 와 confirm 에 넘긴 hash 불일치
    error HashMismatch(uint256 id, bytes32 expected, bytes32 actual);
    /// @dev 저장된 항목으로 계산한 entryCommit 과 승인자가 서명한 entryCommit 불일치
    error EntryCommitMismatch(uint256 id, bytes32 expected, bytes32 actual);
    error InvalidSignature();
    error SignatureExpired(uint256 deadline);
    /// @dev 서명자가 등록 권한 롤(TREASURER)이 아님
    error NotRegistrant(address signer);
    /// @dev 서명자가 승인 권한 롤(AUDITOR 또는 PRESIDENT)이 아님
    error NotApprover(address signer);
    /// @dev 등록자 == 승인자
    error SelfApproval(uint256 id, address account);
    /// @dev term == 0
    error TermRequired(uint256 id);
    /// @dev 지출의 term 이 예산 term 과 다름, 또는 정정의 term 이 원본 term 과 다름
    error TermMismatch(uint256 id, uint256 expected, uint256 actual);
    /// @dev INCOME 인데 budgetId != 0
    error BudgetIdNotAllowedForIncome(uint256 id, uint256 budgetId);
    /// @dev 반려 사유 0, 또는 hadWarning 인데 warningReasonHash 0
    error ReasonRequired(uint256 id);
    /// @dev hadWarning 이 아닌데 warningReasonHash != 0
    error ReasonNotAllowed(uint256 id);
    /// @dev 생성자 인자가 0
    error ZeroAddress();

    // ------------------------------------------------------------ functions

    /// @notice 항목 등록. 호출자는 릴레이어, request 의 EIP-712 서명자가 등록자(registrant).
    /// @dev 지출이고 예산 초과/마감/미존재면 revert 대신 BLOCKED 저장 + EntryBlocked emit. 검사 순서는 위 @dev 참고.
    function recordPending(RecordRequest calldata request, bytes calldata signature) external;

    /// @notice 항목 확정. approval 의 EIP-712 서명자가 승인자(AUDITOR 또는 PRESIDENT, 등록자 제외).
    ///         지출이면 BudgetToken.spend(양수) / refund(음수) 를 호출한다.
    /// @dev PENDING 이 아니면(BLOCKED 포함) revert. BudgetToken 호출 실패(잔량 부족·마감 등) 시 전체 revert 하고 상태는 PENDING 유지.
    function confirmEntry(ConfirmApproval calldata approval, bytes calldata signature) external;

    /// @notice 항목 반려. decision 의 EIP-712 서명자가 반려자(AUDITOR 또는 PRESIDENT, 등록자 제외).
    /// @dev reasonHash == 0 이면 ReasonRequired.
    function rejectEntry(RejectDecision calldata decision, bytes calldata signature) external;

    /// @notice 없는 id 는 0 으로 채운 구조체 (registrant == 0). 백엔드는 exists() 를 먼저 본다.
    function getEntry(uint256 id) external view returns (Entry memory);

    /// @notice 없는 id 는 EntryNotFound 로 revert (0 = PENDING 으로 오해하지 않게).
    function statusOf(uint256 id) external view returns (Status);

    function exists(uint256 id) external view returns (bool);

    /// @notice 저장된 항목으로 계산한 entryCommit. 없는 id 는 bytes32(0)
    function entryCommitOf(uint256 id) external view returns (bytes32);

    /// @notice 정정 가능 항목(원본 또는 재분류 양수 정정)의 현재 순금액
    ///         = 자기 amount + Σ 그 항목을 대상으로 확정된 정정 amount (재분류 양수 정정은 제외).
    ///         CONFIRMED 가 아니거나 정정 가능 항목이 아니면 0. 그 항목을 대상으로 하는 음수 정정의 상한이다.
    function netAmountOf(uint256 id) external view returns (uint256);

    function roleManager() external view returns (address);

    function budgetToken() external view returns (address);

    /// @notice 금액 상한 (원). |amount| 가 이 값을 넘으면 AmountOutOfRange
    function MAX_AMOUNT() external view returns (uint256);

    /// @notice EIP-712 도메인 분리자 (앱이 서명 만들 때 필요)
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
