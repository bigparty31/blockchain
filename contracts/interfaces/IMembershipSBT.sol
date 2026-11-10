// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title IMembershipSBT
/// @notice 학기 단위 학생 회원 증명. 전송 불가. 온체인에는 지갑 주소만 두고 학번 등 식별정보는 저장하지 않는다.
/// @dev
/// - 한 (account, term) 에는 유효한 회원권이 하나뿐이다. STUDENT 는 온체인 롤이 아니라 hasValidMembership 으로 판별한다.
/// - term 은 학기 코드 YYYYS (예: 20261 = 2026년 1학기). 0 금지(TermRequired).
/// - 발행·소각은 RoleManager 의 PRESIDENT 또는 AUDITOR 서명 1개로 실행한다.
///   호출자는 롤이 없는 릴레이어이며 msg.sender 는 권한 판단에 쓰지 않는다. 이벤트 actor 는 서명자다.
/// - nonce 는 서명자별로 하나이며 발행·소각이 공유한다. 성공한 요청마다 1 증가한다.
/// - 배치는 1~100명. 빈 배열·상한 초과·0 주소가 하나라도 있으면 배치 전체를 revert 한다.
///   이미 유효한 수령자는 revert 하지 않고 MembershipSkipped 로 넘긴다.
/// - 소각하면 tokenOf 를 비워 같은 학기 재발행을 허용한다.
/// - transferFrom·safeTransferFrom·approve·setApprovalForAll 은 Soulbound 로 revert 한다. mint/burn 만 허용.
/// - EIP-712 도메인: name = "MembershipSBT", version = "1".
interface IMembershipSBT is IERC721 {
    // ---------------------------------------------------------------- types

    /// @dev docs/enums.md 의 burn_reason 표 순서 그대로 (REFUND / WITHDRAWAL).
    enum BurnReason {
        REFUND, // 0
        WITHDRAWAL // 1
    }

    /// @dev typehash:
    ///   keccak256("MintBatchRequest(address[] recipients,uint256 term,uint256 nonce,uint256 deadline)")
    ///   EIP-712 의 address[] 필드는 keccak256(abi.encodePacked(recipients)) 로 해시해 인코딩한다.
    struct MintBatchRequest {
        address[] recipients;
        uint256 term;
        uint256 nonce;
        uint256 deadline; // 서명 유효 시한 (unix seconds)
    }

    /// @dev typehash:
    ///   keccak256("BurnRequest(address holder,uint256 term,uint8 reason,uint256 nonce,uint256 deadline)")
    struct BurnRequest {
        address holder;
        uint256 term;
        uint8 reason; // BurnReason 값. docs/enums.md burn_reason 순서
        uint256 nonce;
        uint256 deadline; // 서명 유효 시한 (unix seconds)
    }

    // --------------------------------------------------------------- events

    /// @notice actor = 발행 서명자
    event MembershipMinted(uint256 indexed tokenId, address indexed to, uint256 term, address indexed actor);
    /// @notice 이미 유효한 (to, term) 이므로 발행을 건너뜀. actor = 발행 서명자.
    event MembershipSkipped(address indexed to, uint256 indexed term, address indexed actor);
    /// @notice actor = 소각 서명자. reason 은 BurnReason 값.
    event MembershipBurned(
        uint256 indexed tokenId,
        address indexed from,
        uint256 term,
        uint8 reason,
        address indexed actor
    );

    // --------------------------------------------------------------- errors

    /// @dev 서명자가 PRESIDENT 또는 AUDITOR 가 아님
    error NotApprover(address signer);
    error EmptyBatch();
    /// @dev recipients 길이가 MAX_BATCH_SIZE 를 넘음
    error BatchTooLarge(uint256 size);
    /// @dev term == 0
    error TermRequired();
    /// @dev 수령자 또는 소각 대상이 address(0)
    error ZeroAddress();
    /// @dev 전송·승인 시도. mint/burn 만 허용
    error Soulbound();
    /// @dev 소각 대상 (holder, term) 에 유효한 회원권이 없음
    error NoMembership(address holder, uint256 term);
    /// @dev reason 이 BurnReason 범위 밖
    error InvalidBurnReason(uint8 reason);
    error InvalidSignature();
    error SignatureExpired(uint256 deadline);
    /// @dev 서명자별 현재 nonce 와 요청 nonce 가 다름 (발행·소각 공유)
    error InvalidNonce(uint256 expected, uint256 actual);

    // ------------------------------------------------------------ functions

    /// @notice 일괄 발급. PRESIDENT 또는 AUDITOR 서명. tokenId 는 온체인 카운터로 1부터 새로 발급한다.
    /// @dev 유효한 수령자는 MembershipSkipped, 새 발급은 MembershipMinted. 0 주소는 배치 전체 revert.
    function mintBatchRelayed(MintBatchRequest calldata r, bytes calldata signature) external;

    /// @notice 학기 회원권 소각. PRESIDENT 또는 AUDITOR 서명. 대상이 없으면 NoMembership.
    /// @dev tokenOf 를 비워 같은 학기 재발행을 허용한다. reason 은 BurnReason 값.
    function burnRelayed(BurnRequest calldata r, bytes calldata signature) external;

    /// @notice 해당 학기에 소각되지 않은 회원권을 보유하는지 조회.
    function hasValidMembership(address account, uint256 term) external view returns (bool);

    /// @notice 해당 학기의 유효한 tokenId. 없거나 소각됐으면 0.
    function tokenOf(address account, uint256 term) external view returns (uint256 tokenId);

    /// @notice 서명자별 다음 nonce. 발행·소각이 공유한다.
    function nonces(address signer) external view returns (uint256);

    /// @notice EIP-712 도메인 분리자 (백엔드가 서명 만들 때 필요)
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice 일괄 발급 인원 상한 (100명)
    function MAX_BATCH_SIZE() external view returns (uint256);
}
