// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IRoleManager} from "../interfaces/IRoleManager.sol";
import {ROLE_TREASURER, ROLE_AUDITOR, ROLE_PRESIDENT, Signatures} from "./Common.sol";

/// @title RoleManager
/// @notice 임원 롤 관리 구현. 규칙·검사 순서는 IRoleManager 주석과 docs/CONTRACTS.md "롤" 절이 정본이다.
/// @dev 자체 매핑. 한 주소 한 롤. 회장 1·총무 1·감사 2+.
///      일반 변경은 회장 + 감사 EIP-712 서명, 회장 키 분실은 감사 2명 제안 + 72시간 대기 + 회장 취소 가능.
contract RoleManager is IRoleManager, EIP712 {
    bytes32 public constant TREASURER = ROLE_TREASURER;
    bytes32 public constant AUDITOR = ROLE_AUDITOR;
    bytes32 public constant PRESIDENT = ROLE_PRESIDENT;

    uint256 public constant RECOVERY_DELAY = 72 hours;
    uint256 public constant MIN_AUDITORS = 2;

    bytes32 private constant ROLE_CHANGE_TYPEHASH =
        keccak256("RoleChange(bytes32 role,address from,address to,uint256 nonce,uint256 deadline)");
    bytes32 private constant PRESIDENT_RECOVERY_TYPEHASH =
        keccak256("PresidentRecovery(address from,address to,uint256 nonce,uint256 deadline)");
    bytes32 private constant RECOVERY_CANCEL_TYPEHASH = keccak256("RecoveryCancel(uint256 recoveryId,uint256 deadline)");

    mapping(address account => bytes32 role) private _roleOf;
    mapping(bytes32 role => uint256) private _holderCount;
    uint256 private _nonce;
    /// @dev executableAt == 0 이면 대기 중인 복구 없음
    PendingRecovery private _pending;

    /// @dev 네 주소는 서로 다르고 0이 아니어야 한다. 배포자(msg.sender)는 아무 롤도 받지 않는다.
    constructor(address president, address treasurer, address auditor1, address auditor2) EIP712("RoleManager", "1") {
        _initialGrant(PRESIDENT, president);
        _initialGrant(TREASURER, treasurer);
        _initialGrant(AUDITOR, auditor1);
        _initialGrant(AUDITOR, auditor2);
    }

    // ------------------------------------------------------------ changeRole

    function changeRole(RoleChange calldata c, bytes calldata proposerSig, bytes calldata approverSig) external {
        // 1~4: 요청 자체
        if (block.timestamp > c.deadline) revert SignatureExpired(c.deadline);
        _useNonce(c.nonce);
        if (!_isKnownRole(c.role)) revert UnknownRole(c.role);
        if (c.from == address(0) && c.to == address(0)) revert ZeroAddress();

        // 5~6: 서명자 — 회장 1 + 감사 1
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(ROLE_CHANGE_TYPEHASH, c.role, c.from, c.to, c.nonce, c.deadline))
        );
        address proposer = _recover(digest, proposerSig);
        address approver = _recover(digest, approverSig);
        if (!_isGovernor(proposer)) revert NotGovernor(proposer);
        if (!_isGovernor(approver)) revert NotGovernor(approver);
        if (proposer == approver) revert SameSigner(proposer);
        if (_roleOf[proposer] != PRESIDENT && _roleOf[approver] != PRESIDENT) revert PresidentRequired();

        // 7~8: 보유 상태
        if (c.from != address(0) && _roleOf[c.from] != c.role) revert RoleNotGranted(c.role, c.from);
        if (c.to != address(0)) _requireNoRole(c.role, c.to);

        // 9~10: 롤별 보유자 수
        if (c.from == address(0) && c.role != AUDITOR && _holderCount[c.role] != 0) {
            revert RoleCapacityExceeded(c.role);
        }
        if (c.to == address(0) && (c.role != AUDITOR || _holderCount[AUDITOR] <= MIN_AUDITORS)) {
            revert RoleMinimumViolated(c.role);
        }

        _apply(c.nonce, c.role, c.from, c.to, proposer, approver);
    }

    // ------------------------------------------------------- 회장 복구

    function proposePresidentRecovery(
        PresidentRecovery calldata r,
        bytes calldata auditorSigA,
        bytes calldata auditorSigB
    ) external {
        if (block.timestamp > r.deadline) revert SignatureExpired(r.deadline);
        _useNonce(r.nonce);
        if (r.to == address(0)) revert ZeroAddress();
        if (_roleOf[r.from] != PRESIDENT) revert RoleNotGranted(PRESIDENT, r.from);
        _requireNoRole(PRESIDENT, r.to);

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(PRESIDENT_RECOVERY_TYPEHASH, r.from, r.to, r.nonce, r.deadline))
        );
        address a = _recover(digest, auditorSigA);
        address b = _recover(digest, auditorSigB);
        if (_roleOf[a] != AUDITOR) revert NotAuditor(a);
        if (_roleOf[b] != AUDITOR) revert NotAuditor(b);
        if (a == b) revert SameSigner(a);

        uint64 executableAt = uint64(block.timestamp + RECOVERY_DELAY);
        _pending = PendingRecovery({
            recoveryId: r.nonce,
            from: r.from,
            to: r.to,
            auditorA: a,
            auditorB: b,
            executableAt: executableAt
        });
        emit PresidentRecoveryProposed(r.nonce, r.from, r.to, a, b, executableAt);
    }

    function cancelPresidentRecovery(RecoveryCancel calldata c, bytes calldata presidentSig) external {
        if (block.timestamp > c.deadline) revert SignatureExpired(c.deadline);
        if (_pending.executableAt == 0 || _pending.recoveryId != c.recoveryId) revert NoPendingRecovery(c.recoveryId);
        address signer = _recover(
            _hashTypedDataV4(keccak256(abi.encode(RECOVERY_CANCEL_TYPEHASH, c.recoveryId, c.deadline))),
            presidentSig
        );
        if (_roleOf[signer] != PRESIDENT) revert NotPresident(signer);

        delete _pending;
        emit PresidentRecoveryCancelled(c.recoveryId, signer);
    }

    function executePresidentRecovery() external {
        PendingRecovery memory p = _pending;
        if (p.executableAt == 0) revert NoPendingRecovery(0);
        if (block.timestamp < p.executableAt) revert RecoveryNotReady(p.executableAt);
        // 대기 중에 상황이 바뀌었을 수 있으니 다시 검사한다
        if (_roleOf[p.from] != PRESIDENT) revert RoleNotGranted(PRESIDENT, p.from);
        if (_roleOf[p.auditorA] != AUDITOR) revert NotAuditor(p.auditorA);
        if (_roleOf[p.auditorB] != AUDITOR) revert NotAuditor(p.auditorB);
        _requireNoRole(PRESIDENT, p.to);

        delete _pending;
        uint256 used = _nonce;
        _useNonce(used);
        _apply(used, PRESIDENT, p.from, p.to, p.auditorA, p.auditorB);
    }

    // ------------------------------------------------------------------ views

    function pendingRecovery() external view returns (PendingRecovery memory) {
        return _pending;
    }

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
        // 생성자 인자 중복은 롤이 같든 다르든 AlreadyOfficer 로 알린다 (IRoleManager 주석)
        bytes32 current = _roleOf[account];
        if (current != bytes32(0)) revert AlreadyOfficer(account, current);
        _roleOf[account] = role;
        _holderCount[role] += 1;
        emit RoleGranted(role, account, address(0), address(0));
    }

    /// @dev 요청의 nonce 가 현재 값이면 소비하고, 아니면 InvalidNonce.
    function _useNonce(uint256 given) private {
        if (given != _nonce) revert InvalidNonce(_nonce, given);
        _nonce = given + 1;
    }

    /// @dev to 는 같은 롤(RoleAlreadyGranted)도 다른 임원 롤(AlreadyOfficer)도 없어야 한다.
    function _requireNoRole(bytes32 role, address to) private view {
        bytes32 current = _roleOf[to];
        if (current == role) revert RoleAlreadyGranted(role, to);
        if (current != bytes32(0)) revert AlreadyOfficer(to, current);
    }

    /// @dev 검사를 모두 통과한 변경을 반영한다. usedNonce 는 이 변경이 소비한 nonce.
    function _apply(
        uint256 usedNonce,
        bytes32 role,
        address from,
        address to,
        address proposer,
        address approver
    ) private {
        if (from != address(0)) {
            delete _roleOf[from];
            _holderCount[role] -= 1;
            emit RoleRevoked(role, from, proposer, approver);
        }
        if (to != address(0)) {
            _roleOf[to] = role;
            _holderCount[role] += 1;
            emit RoleGranted(role, to, proposer, approver);
        }
        emit RoleChangeExecuted(usedNonce, role, from, to, proposer, approver);
    }

    function _isGovernor(address account) private view returns (bool) {
        bytes32 r = _roleOf[account];
        return r == PRESIDENT || r == AUDITOR;
    }

    function _isKnownRole(bytes32 role) private pure returns (bool) {
        return role == TREASURER || role == AUDITOR || role == PRESIDENT;
    }

    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address signer) {
        signer = Signatures.recoverOrZero(digest, signature);
        if (signer == address(0)) revert InvalidSignature();
    }
}
