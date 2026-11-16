// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IMembershipSBT} from "../interfaces/IMembershipSBT.sol";
import {IRoleManager} from "../interfaces/IRoleManager.sol";
import {ROLE_AUDITOR, ROLE_PRESIDENT, Signatures} from "./Common.sol";

/// @title MembershipSBT
/// @notice 학기 단위 학생 회원 증명. 규칙은 IMembershipSBT 주석과 docs/CONTRACTS.md "회원권" 절이 정본.
/// @dev
/// - 발행·소각은 PRESIDENT 또는 AUDITOR 의 EIP-712 서명 1개로 실행한다. 호출자(릴레이어)는 권한 판단에 쓰지 않는다.
/// - 서명자별 nonce 는 발행·소각이 공유하고, 성공한 요청마다 1 오른다 (전부 건너뛴 배치 포함).
/// - 전송은 _update 에서 막는다 (from·to 가 모두 있으면 Soulbound). 승인 두 함수는 직접 Soulbound 로 revert 한다.
/// - 발행은 _mint 를 쓴다 (_safeMint 의 수신 콜백이 없으므로 재진입 경로가 없다). 수령자는 학생 지갑(EOA)이다.
/// - 검사 순서 (발행): SignatureExpired → EmptyBatch → BatchTooLarge → InvalidSignature → NotApprover
///   → InvalidNonce → TermRequired → ZeroAddress.
/// - 검사 순서 (소각): SignatureExpired → InvalidSignature → NotApprover → InvalidNonce → TermRequired
///   → ZeroAddress → InvalidBurnReason → NoMembership.
contract MembershipSBT is IMembershipSBT, ERC721, EIP712 {
    bytes32 private constant PRESIDENT = ROLE_PRESIDENT;
    bytes32 private constant AUDITOR = ROLE_AUDITOR;

    bytes32 private constant MINT_BATCH_TYPEHASH =
        keccak256("MintBatchRequest(address[] recipients,uint256 term,uint256 nonce,uint256 deadline)");
    bytes32 private constant BURN_TYPEHASH =
        keccak256("BurnRequest(address holder,uint256 term,uint8 reason,uint256 nonce,uint256 deadline)");

    uint256 public constant MAX_BATCH_SIZE = 100;

    IRoleManager private immutable _roleManager;

    /// @dev 마지막으로 발급한 tokenId. 첫 발급이 1 이다 (0 은 "없음").
    uint256 private _lastTokenId;

    mapping(address account => mapping(uint256 term => uint256 tokenId)) private _tokenOf;
    mapping(address signer => uint256) private _nonces;

    constructor(address roleManager_) ERC721("MembershipSBT", "MSBT") EIP712("MembershipSBT", "1") {
        if (roleManager_ == address(0)) revert ZeroAddress();
        _roleManager = IRoleManager(roleManager_);
    }

    // ---------------------------------------------------------- 발행·소각

    function mintBatchRelayed(MintBatchRequest calldata r, bytes calldata signature) external {
        if (block.timestamp > r.deadline) revert SignatureExpired(r.deadline);
        uint256 n = r.recipients.length;
        if (n == 0) revert EmptyBatch();
        if (n > MAX_BATCH_SIZE) revert BatchTooLarge(n);

        // EIP-712 의 address[] 는 원소를 32바이트씩 이어 붙인 값의 keccak256 이다.
        // abi.encodePacked 는 배열 원소를 32바이트로 채우므로 그 값과 같다.
        address signer = _recover(
            keccak256(
                abi.encode(
                    MINT_BATCH_TYPEHASH,
                    keccak256(abi.encodePacked(r.recipients)),
                    r.term,
                    r.nonce,
                    r.deadline
                )
            ),
            signature
        );
        _requireApprover(signer);
        _useNonce(signer, r.nonce);
        if (r.term == 0) revert TermRequired();
        for (uint256 i = 0; i < n; ++i) {
            if (r.recipients[i] == address(0)) revert ZeroAddress();
        }

        for (uint256 i = 0; i < n; ++i) {
            address to = r.recipients[i];
            // 이미 유효하면 건너뛴다. 같은 배치 안의 중복도 앞에서 발급된 뒤라 여기서 걸린다.
            if (_tokenOf[to][r.term] != 0) {
                emit MembershipSkipped(to, r.term, signer);
                continue;
            }
            uint256 tokenId = ++_lastTokenId;
            _tokenOf[to][r.term] = tokenId;
            _mint(to, tokenId);
            emit MembershipMinted(tokenId, to, r.term, signer);
        }
    }

    function burnRelayed(BurnRequest calldata r, bytes calldata signature) external {
        if (block.timestamp > r.deadline) revert SignatureExpired(r.deadline);
        address signer = _recover(
            keccak256(abi.encode(BURN_TYPEHASH, r.holder, r.term, r.reason, r.nonce, r.deadline)),
            signature
        );
        _requireApprover(signer);
        _useNonce(signer, r.nonce);
        if (r.term == 0) revert TermRequired();
        if (r.holder == address(0)) revert ZeroAddress();
        if (r.reason > uint8(type(BurnReason).max)) revert InvalidBurnReason(r.reason);
        uint256 tokenId = _tokenOf[r.holder][r.term];
        if (tokenId == 0) revert NoMembership(r.holder, r.term);

        delete _tokenOf[r.holder][r.term]; // 같은 학기 재발행을 허용한다
        _burn(tokenId);
        emit MembershipBurned(tokenId, r.holder, r.term, r.reason, signer);
    }

    // ------------------------------------------------------------------ views

    function hasValidMembership(address account, uint256 term) external view returns (bool) {
        return _tokenOf[account][term] != 0;
    }

    function tokenOf(address account, uint256 term) external view returns (uint256) {
        return _tokenOf[account][term];
    }

    function nonces(address signer) external view returns (uint256) {
        return _nonces[signer];
    }

    function roleManager() external view returns (address) {
        return address(_roleManager);
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ----------------------------------------------------------- 전송 차단

    function approve(address, uint256) public pure override(ERC721, IERC721) {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) public pure override(ERC721, IERC721) {
        revert Soulbound();
    }

    /// @dev 발행(from = 0)·소각(to = 0)만 통과시킨다. transferFrom·safeTransferFrom 두 형태가 모두 여기로 들어온다.
    ///      권한 검사(super)보다 먼저 막으므로 보유자 본인이 보내도 Soulbound 다.
    ///      (to = 0 인 transferFrom 은 ERC721 이 이보다 먼저 ERC721InvalidReceiver 로 막는다.)
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == type(IMembershipSBT).interfaceId || super.supportsInterface(interfaceId);
    }

    // --------------------------------------------------------------- internal

    function _requireApprover(address signer) private view {
        if (!_roleManager.hasRole(PRESIDENT, signer) && !_roleManager.hasRole(AUDITOR, signer)) {
            revert NotApprover(signer);
        }
    }

    function _useNonce(address signer, uint256 nonce) private {
        uint256 expected = _nonces[signer];
        if (nonce != expected) revert InvalidNonce(expected, nonce);
        _nonces[signer] = expected + 1;
    }

    function _recover(bytes32 structHash, bytes calldata signature) private view returns (address signer) {
        signer = Signatures.recoverOrZero(_hashTypedDataV4(structHash), signature);
        if (signer == address(0)) revert InvalidSignature();
    }
}
