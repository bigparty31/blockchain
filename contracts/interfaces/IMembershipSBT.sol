// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title IMembershipSBT
/// @notice 학기 단위 학생 회원 증명. 전송 불가(구현체에서 _update 오버라이드로 mint/burn 만 허용).
/// @dev
/// - 1인 1학기 1개.
/// - 학번 평문 온체인 금지. commitment = keccak256(abi.encodePacked(studentId, salt)) 만 저장.
/// - STUDENT 는 온체인 롤이 아니며 hasValidMembership 으로 판별한다.
interface IMembershipSBT is IERC721 {
    // ---------------------------------------------------------------- types

    struct Membership {
        uint256 term;
        bytes32 commitment;
    }

    // --------------------------------------------------------------- events

    event MembershipMinted(uint256 indexed tokenId, address indexed to, uint256 indexed term, bytes32 commitment);
    event MembershipBurned(uint256 indexed tokenId, address indexed from, uint256 indexed term);

    // --------------------------------------------------------------- errors

    error Unauthorized(address caller);
    error AlreadyMember(address account, uint256 term);
    error ArrayLengthMismatch();
    error ZeroAddress();
    /// @dev 전송 시도. mint/burn 만 허용
    error Soulbound();

    // ------------------------------------------------------------ functions

    /// @notice 일괄 발급. tokenId 는 온체인 카운터(1부터)로 발급하며 MembershipMinted 로 알린다.
    /// @return tokenIds to 와 같은 순서로 발급된 tokenId
    function mintBatch(
        uint256 term,
        address[] calldata to,
        bytes32[] calldata commitments
    ) external returns (uint256[] memory tokenIds);

    function burn(uint256 tokenId) external;

    function hasValidMembership(address account, uint256 term) external view returns (bool);

    function tokenOf(address account, uint256 term) external view returns (uint256 tokenId);

    function getMembership(uint256 tokenId) external view returns (Membership memory);

    /// @notice 다음에 발급될 tokenId
    function nextTokenId() external view returns (uint256);
}
