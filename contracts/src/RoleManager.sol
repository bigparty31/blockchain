// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IRoleManager} from "../interfaces/IRoleManager.sol";

/// @title RoleManager
/// @notice 임원 롤 관리 구현. 규칙·검사 순서는 IRoleManager 주석과 docs/CONTRACTS.md "롤" 절이 정본이다.
/// @dev 자체 매핑. 한 주소 한 롤. 회장 1·총무 1·감사 1+. 변경은 거버너(회장·감사) 2인 EIP-712 서명 + 릴레이어 제출.
contract RoleManager is IRoleManager, EIP712 {
    bytes32 public constant TREASURER = keccak256("TREASURER");
    bytes32 public constant AUDITOR = keccak256("AUDITOR");
    bytes32 public constant PRESIDENT = keccak256("PRESIDENT");

    bytes32 private constant ROLE_CHANGE_TYPEHASH =
        keccak256("RoleChange(bytes32 role,address from,address to,uint256 nonce,uint256 deadline)");

    mapping(address account => bytes32 role) private _roleOf;
    mapping(bytes32 role => uint256) private _holderCount;
    uint256 private _nonce;

    /// @dev 세 주소는 서로 다르고 0이 아니어야 한다. 배포자(msg.sender)는 아무 롤도 받지 않는다.
    constructor(address president, address treasurer, address auditor) EIP712("RoleManager", "1") {
        _initialGrant(PRESIDENT, president);
        _initialGrant(TREASURER, treasurer);
        _initialGrant(AUDITOR, auditor);
    }

    // ------------------------------------------------------------------ change

    function changeRole(RoleChange calldata c, bytes calldata proposerSig, bytes calldata approverSig) external {
        // 1~4: 요청 자체
        if (block.timestamp > c.deadline) revert SignatureExpired(c.deadline);
        if (c.nonce != _nonce) revert InvalidNonce(_nonce, c.nonce);
        if (!_isKnownRole(c.role)) revert UnknownRole(c.role);
        if (c.from == address(0) && c.to == address(0)) revert ZeroAddress();

        // 5~6: 서명자
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(ROLE_CHANGE_TYPEHASH, c.role, c.from, c.to, c.nonce, c.deadline))
        );
        address proposer = _recover(digest, proposerSig);
        address approver = _recover(digest, approverSig);
        if (!_isGovernor(proposer)) revert NotGovernor(proposer);
        if (!_isGovernor(approver)) revert NotGovernor(approver);
        if (proposer == approver) revert SameSigner(proposer);

        // 7~8: 보유 상태
        if (c.from != address(0) && _roleOf[c.from] != c.role) revert RoleNotGranted(c.role, c.from);
        if (c.to != address(0)) {
            bytes32 current = _roleOf[c.to];
            if (current == c.role) revert RoleAlreadyGranted(c.role, c.to);
            if (current != bytes32(0)) revert AlreadyOfficer(c.to, current);
        }

        // 9~10: 롤별 보유자 수
        if (c.from == address(0) && c.role != AUDITOR && _holderCount[c.role] != 0) {
            revert RoleCapacityExceeded(c.role);
        }
        if (c.to == address(0) && (c.role != AUDITOR || _holderCount[c.role] == 1)) {
            revert RoleMinimumViolated(c.role);
        }

        uint256 used = _nonce;
        _nonce = used + 1;

        if (c.from != address(0)) {
            delete _roleOf[c.from];
            _holderCount[c.role] -= 1;
            emit RoleRevoked(c.role, c.from, proposer, approver);
        }
        if (c.to != address(0)) {
            _roleOf[c.to] = c.role;
            _holderCount[c.role] += 1;
            emit RoleGranted(c.role, c.to, proposer, approver);
        }
        emit RoleChangeExecuted(used, c.role, c.from, c.to, proposer, approver);
    }

    // ------------------------------------------------------------------ views

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return role != bytes32(0) && _roleOf[account] == role;
    }

    function roleOf(address account) external view returns (bytes32) {
        return _roleOf[account];
    }

    function holderCount(bytes32 role) external view returns (uint256) {
        return _holderCount[role];
    }

    function isGovernor(address account) external view returns (bool) {
        return _isGovernor(account);
    }

    function nonce() external view returns (uint256) {
        return _nonce;
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ------------------------------------------------------------- internal

    /// @dev 생성자 전용. proposer·approver 0 이 최초 부여 표시다.
    function _initialGrant(bytes32 role, address account) private {
        if (account == address(0)) revert ZeroAddress();
        bytes32 current = _roleOf[account];
        if (current != bytes32(0)) revert AlreadyOfficer(account, current);
        _roleOf[account] = role;
        _holderCount[role] += 1;
        emit RoleGranted(role, account, address(0), address(0));
    }

    function _isGovernor(address account) private view returns (bool) {
        bytes32 r = _roleOf[account];
        return r == PRESIDENT || r == AUDITOR;
    }

    function _isKnownRole(bytes32 role) private pure returns (bool) {
        return role == TREASURER || role == AUDITOR || role == PRESIDENT;
    }

    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address) {
        (address signer, ECDSA.RecoverError err, ) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || signer == address(0)) revert InvalidSignature();
        return signer;
    }
}
