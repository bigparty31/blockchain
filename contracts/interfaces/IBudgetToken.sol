// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBudgetToken
/// @notice 학기 + 항목 1줄 단위의 예산 한도·소모액 관리. ERC 표준을 따르지 않는 커스텀 장부.
/// @dev
/// - budgetId는 백엔드 DB의 auto-increment 값을 그대로 받는다. 0 은 "없음" 으로 예약(ReservedId).
/// - 한 (term, category) 에는 예산이 하나뿐이다. 두 번째 발행은 BudgetAlreadyIssued. 한도를 늘리려면 증액(increase)을 쓴다.
///   회수된 뒤에도 같은 (term, category) 는 다시 발행할 수 없다.
/// - term 은 학기 코드 YYYYS (예: 20261 = 2026년 1학기). DB 의 Term.id 가 아니다. docs/CONTRACTS.md "term" 절.
/// - issued 는 "현재 한도"다. remaining() = issued − spent. 불변식: 항상 spent <= issued.
///   increase 는 issued 를 올리고, reclaim 은 issued 를 spent 까지 내린다. 그래서 issued 는 회수 후 줄어든다.
///   최초 발행액·누적 증액은 이벤트(BudgetIssued + BudgetIncreased)로 계산한다.
/// - 개정은 증액만 있다. 감액 함수는 만들지 않는다 (향후 과제). 마감이 지난 예산은 증액할 수 없다(BudgetExpired).
/// - spend 는 잔량 부족·마감 경과 시 revert. refund 는 마감·회수와 무관하게 성공하되
///   spent 를 넘는 금액은 RefundExceedsSpent 로 revert (spent 만 줄인다).
/// - reclaim 은 마감(expiresAt) 뒤에만 가능하고, 여러 번 부를 수 있다. 회수할 잔량이 0이면 ZeroAmount.
///
/// 권한 모델 (PRD §9.2): 임원은 기기에서 EIP-712 서명만 하고 릴레이어가 제출한다. msg.sender 는 권한 판단에 쓰지 않는다.
/// - issue   : PRESIDENT 서명 1개 (PRD §3 예산 편성)
/// - increase: PRESIDENT 요청 서명 + AUDITOR 승인 서명, 같은 IncreaseRequest 에 (PRD §4.1 "개정 사유 입력과 감사 승인 필수")
///             reasonHash 0 금지(ReasonRequired). version 은 현재 예산 version 이어야 해서 한 서명은 한 번만 쓰인다.
/// - reclaim : PRESIDENT 서명 1개. amount 는 현재 잔량과 같아야 한다(회장이 회수액을 확인하고 서명).
///             reclaimCount 는 현재 회수 횟수여야 하고 회수마다 1 오르므로 한 서명은 한 번만 쓰인다(ReclaimCountMismatch).
///             회수 횟수는 version(개정 번호, PRD §4.1 의 v1·v2)과 따로 센다. 회수가 개정 번호를 올리면 학생 화면과 결산 지표가 틀어진다.
/// - EIP-712 도메인: name = "BudgetToken", version = "1".
///
/// - spend / refund 호출자는 AccountingLedger 하나로 제한한다. 원장 주소는 배포자가 setLedger 로 한 번만 넣고 잠근다.
///   setLedger 는 원장의 roleManager()·budgetToken() 이 이 컨트랙트와 맞는지 확인한다(LedgerMismatch).
///   배포 순서: RoleManager → BudgetToken → AccountingLedger → setLedger.
/// - 금액 상한 MAX_AMOUNT (1e15 원). 저장 필드 폭(uint128·uint64·uint32)을 넘는 값은 FieldOutOfRange.
interface IBudgetToken {
    // ---------------------------------------------------------------- types

    /// @dev 3 슬롯으로 묶인다: [category] [issued | spent] [term | expiresAt | version | reclaimCount]
    struct Budget {
        bytes32 category; // keccak256("행사비") 형태. 사람이 읽는 이름은 오프체인
        uint128 issued; // 현재 한도 (원). increase 로 오르고 reclaim 으로 spent 까지 내려간다
        uint128 spent; // 누적 소모액 (원). spend 로 오르고 refund 로 내려간다
        uint32 term; // 학기 코드 YYYYS. 0 금지
        uint64 expiresAt; // 집행 마감 (unix seconds)
        uint16 version; // 개정 횟수. issue 시 1, increase 마다 +1. 0 이면 존재하지 않음
        uint16 reclaimCount; // 회수 횟수. issue 시 0, reclaim 마다 +1. 회수 서명 재사용 방지용
    }

    /// @dev typehash:
    ///   keccak256("IssueRequest(uint256 budgetId,uint256 term,bytes32 category,uint256 amount,uint256 expiresAt,uint256 deadline)")
    struct IssueRequest {
        uint256 budgetId;
        uint256 term;
        bytes32 category;
        uint256 amount;
        uint256 expiresAt;
        uint256 deadline;
    }

    /// @dev typehash:
    ///   keccak256("IncreaseRequest(uint256 budgetId,uint256 amount,bytes32 reasonHash,uint256 version,uint256 deadline)")
    ///   version 은 증액 "전" 의 현재 version.
    struct IncreaseRequest {
        uint256 budgetId;
        uint256 amount;
        bytes32 reasonHash;
        uint256 version;
        uint256 deadline;
    }

    /// @dev typehash:
    ///   keccak256("ReclaimRequest(uint256 budgetId,uint256 amount,uint256 reclaimCount,uint256 deadline)")
    ///   amount 는 현재 잔량(remaining), reclaimCount 는 회수 "전" 의 현재 회수 횟수.
    struct ReclaimRequest {
        uint256 budgetId;
        uint256 amount;
        uint256 reclaimCount;
        uint256 deadline;
    }

    // --------------------------------------------------------------- events

    event BudgetIssued(
        uint256 indexed budgetId,
        uint256 indexed term,
        bytes32 category,
        uint256 amount,
        uint256 expiresAt,
        address indexed actor
    );
    /// @notice requester = 회장(요청 서명자), approver = 감사(승인 서명자)
    event BudgetIncreased(
        uint256 indexed budgetId,
        uint256 amount,
        uint16 version,
        bytes32 reasonHash,
        address indexed requester,
        address indexed approver
    );
    event BudgetSpent(uint256 indexed budgetId, uint256 amount, uint256 entryId);
    event BudgetRefunded(uint256 indexed budgetId, uint256 amount, uint256 entryId);
    /// @notice 마감 후 미집행 잔량 회수. amount 는 이번 호출로 줄어든 issued 양
    event BudgetReclaimed(uint256 indexed budgetId, uint256 amount, address indexed actor);
    /// @notice setLedger 가 딱 한 번 낸다
    event LedgerSet(address indexed ledger);

    // --------------------------------------------------------------- errors

    /// @dev spend/refund 를 원장이 아닌 계정이 호출, setLedger 를 배포자가 아닌 계정이 호출
    error Unauthorized(address caller);
    /// @dev budgetId == 0. "없음" 으로 예약된 값. 중복(BudgetAlreadyExists)과 구분한다
    error ReservedId(uint256 budgetId);
    error BudgetAlreadyExists(uint256 budgetId);
    /// @dev 같은 (term, category) 에 이미 예산이 있음
    error BudgetAlreadyIssued(uint256 term, bytes32 category, uint256 existingBudgetId);
    error BudgetNotFound(uint256 budgetId);
    error BudgetExpired(uint256 budgetId, uint256 expiresAt);
    error BudgetNotExpired(uint256 budgetId, uint256 expiresAt);
    error InsufficientBudget(uint256 budgetId, uint256 remaining, uint256 requested);
    /// @dev refund 가 누적 소모액을 넘을 때
    error RefundExceedsSpent(uint256 budgetId, uint256 spent, uint256 requested);
    error ZeroAmount();
    /// @dev issue 에 term == 0
    error TermRequired();
    /// @dev issue 에 category == 0. 해시 0 은 시스템 전체에서 "없음" 이다
    error CategoryRequired();
    /// @dev 금액이 MAX_AMOUNT 를 넘거나, 증액 후 한도가 MAX_AMOUNT 를 넘음
    error AmountOutOfRange(uint256 amount);
    /// @dev budgetId·term·expiresAt 이 저장 필드 폭을 넘음
    error FieldOutOfRange(uint256 value);
    /// @dev 증액 사유 해시가 0
    error ReasonRequired();
    /// @dev IncreaseRequest.version 이 현재 version 과 다름 (이미 쓰인 서명이거나 다른 증액이 먼저 실행됨)
    error VersionMismatch(uint256 budgetId, uint256 expected, uint256 actual);
    /// @dev ReclaimRequest.amount 가 현재 잔량과 다름
    error ReclaimAmountMismatch(uint256 budgetId, uint256 expected, uint256 actual);
    /// @dev ReclaimRequest.reclaimCount 가 현재 회수 횟수와 다름 (이미 쓰인 서명)
    error ReclaimCountMismatch(uint256 budgetId, uint256 expected, uint256 actual);
    error InvalidSignature();
    error SignatureExpired(uint256 deadline);
    /// @dev 서명자가 PRESIDENT 가 아님 (issue·reclaim 서명, increase 요청 서명)
    error NotPresident(address signer);
    /// @dev 서명자가 AUDITOR 가 아님 (increase 승인 서명)
    error NotAuditor(address signer);
    /// @dev setLedger 두 번째 호출
    error LedgerAlreadySet(address ledger);
    /// @dev setLedger 대상의 roleManager()·budgetToken() 이 이 컨트랙트와 맞지 않음
    error LedgerMismatch(address ledger);
    error ZeroAddress();

    // ------------------------------------------------------------ functions

    /// @notice spend / refund 를 부를 수 있는 원장 주소를 1회 설정. 호출자는 배포자. 이후 잠긴다.
    function setLedger(address ledger) external;

    /// @notice 설정된 원장 주소. 미설정이면 address(0)
    function ledger() external view returns (address);

    function roleManager() external view returns (address);

    /// @notice 예산 신규 배정. 회장 서명. version = 1. term == 0 은 TermRequired, category == 0 은 CategoryRequired.
    function issue(IssueRequest calldata request, bytes calldata presidentSig) external;

    /// @notice 예산 개정(증액). 회장 요청 서명 + 감사 승인 서명. version++. issued 에 더한다.
    function increase(IncreaseRequest calldata request, bytes calldata requesterSig, bytes calldata approverSig) external;

    /// @notice 마감 경과 후 미집행 잔량 회수. 회장 서명. issued 를 spent 까지 내린다. 재호출 가능.
    function reclaim(ReclaimRequest calldata request, bytes calldata presidentSig) external;

    /// @notice 지출 확정 시 잔량 소모. AccountingLedger 만 호출 가능.
    /// @dev 잔량 부족 또는 expiresAt 경과 시 revert.
    function spend(uint256 budgetId, uint256 amount, uint256 entryId) external;

    /// @notice 정정(음수 지출) 확정 시 잔량 복구. AccountingLedger 만 호출 가능.
    /// @dev 마감·회수 여부를 보지 않는다. amount > spent 이면 RefundExceedsSpent.
    function refund(uint256 budgetId, uint256 amount, uint256 entryId) external;

    /// @notice 현재 잔량 = issued − spent. 백엔드는 이 값을 쓴다.
    /// @dev 이벤트로 검증할 때: Σ BudgetIssued + Σ BudgetIncreased − Σ BudgetReclaimed − Σ BudgetSpent + Σ BudgetRefunded.
    function remaining(uint256 budgetId) external view returns (uint256);

    /// @notice 없는 budgetId 는 0 으로 채운 구조체 (version == 0).
    function getBudget(uint256 budgetId) external view returns (Budget memory);

    function exists(uint256 budgetId) external view returns (bool);

    /// @notice (term, category) 에 발행된 budgetId. 없으면 0
    function budgetIdOf(uint256 term, bytes32 category) external view returns (uint256);

    /// @notice EIP-712 도메인 분리자 (앱이 예산 서명을 만들 때 필요)
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice 금액 상한 (원)
    function MAX_AMOUNT() external view returns (uint256);
}
