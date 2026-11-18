// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IAccountingLedger} from "../interfaces/IAccountingLedger.sol";
import {IMembershipSBT} from "../interfaces/IMembershipSBT.sol";
import {IObjectionRegistry} from "../interfaces/IObjectionRegistry.sol";
import {IRoleManager} from "../interfaces/IRoleManager.sol";
import {ROLE_AUDITOR, ROLE_PRESIDENT, Signatures} from "./Common.sol";

/// @title ObjectionRegistry
/// @notice 학생 이의 제기·감사 답변의 해시 기록. 규칙은 IObjectionRegistry 주석과 docs/CONTRACTS.md "이의" 절이 정본.
/// @dev
/// - 이의는 원장 항목의 상태를 바꾸지 않는다. 원장·SBT 는 읽기만 한다.
/// - raise 는 릴레이어만 부른다 (학생 서명 없음, 릴레이어 신뢰 — PRD v0.17 §4.5·§13).
/// - answer 는 AUDITOR 또는 PRESIDENT 의 EIP-712 서명 1개. 호출자(릴레이어)는 권한 판단에 쓰지 않는다.
/// - 검사 순서 (제기): Unauthorized → ReservedId → ObjectionAlreadyExists → EntryNotFound → NotMember.
/// - 검사 순서 (답변): SignatureExpired → InvalidSignature → NotResponder → ObjectionNotFound
///   → ObjectionAlreadyAnswered.
contract ObjectionRegistry is IObjectionRegistry, EIP712 {
    bytes32 private constant PRESIDENT = ROLE_PRESIDENT;
    bytes32 private constant AUDITOR = ROLE_AUDITOR;

    bytes32 private constant ANSWER_TYPEHASH =
        keccak256("AnswerRequest(uint256 objectionId,bytes32 answerHash,uint256 deadline)");

    IRoleManager private immutable _roleManager;
    IAccountingLedger private immutable _ledger;
    IMembershipSBT private immutable _sbt;
    address private immutable _relayer;

    /// @dev raiser == address(0) 이면 없는 이의 (raise 는 SBT 보유자만 받으므로 0 주소가 저장될 수 없다).
    mapping(uint256 objectionId => Objection) private _objections;

    constructor(address roleManager_, address ledger_, address membershipSBT_, address relayer_)
        EIP712("ObjectionRegistry", "1")
    {
        if (
            roleManager_ == address(0) || ledger_ == address(0) || membershipSBT_ == address(0)
                || relayer_ == address(0)
        ) revert ZeroAddress();
        _roleManager = IRoleManager(roleManager_);
        _ledger = IAccountingLedger(ledger_);
        _sbt = IMembershipSBT(membershipSBT_);
        _relayer = relayer_;
    }

    // ------------------------------------------------------------ 제기·답변

    function raise(uint256 objectionId, uint256 entryId, bytes32 contentHash, address raiser) external {
        if (msg.sender != _relayer) revert Unauthorized(msg.sender);
        if (objectionId == 0) revert ReservedId();
        if (_objections[objectionId].raiser != address(0)) revert ObjectionAlreadyExists(objectionId);
        if (!_ledger.exists(entryId)) revert EntryNotFound(entryId);
        // 이의 자격은 그 항목 학기의 회원권이다 (PRD §4.5). 0 주소는 회원권이 없으므로 여기서 걸린다.
        uint256 term = _ledger.getEntry(entryId).term;
        if (!_sbt.hasValidMembership(raiser, term)) revert NotMember(raiser);

        _objections[objectionId] = Objection({
            entryId: entryId,
            contentHash: contentHash,
            answerHash: bytes32(0),
            status: ObjectionStatus.OPEN,
            raiser: raiser,
            responder: address(0)
        });
        emit ObjectionRaised(objectionId, entryId, contentHash, raiser);
    }

    function answer(AnswerRequest calldata r, bytes calldata signature) external {
        if (block.timestamp > r.deadline) revert SignatureExpired(r.deadline);
        address signer = Signatures.recoverOrZero(
            _hashTypedDataV4(keccak256(abi.encode(ANSWER_TYPEHASH, r.objectionId, r.answerHash, r.deadline))),
            signature
        );
        if (signer == address(0)) revert InvalidSignature();
        if (!_roleManager.hasRole(AUDITOR, signer) && !_roleManager.hasRole(PRESIDENT, signer)) {
            revert NotResponder(signer);
        }
        Objection storage o = _objections[r.objectionId];
        if (o.raiser == address(0)) revert ObjectionNotFound(r.objectionId);
        if (o.status != ObjectionStatus.OPEN) revert ObjectionAlreadyAnswered(r.objectionId);

        o.answerHash = r.answerHash;
        o.status = ObjectionStatus.ANSWERED;
        o.responder = signer;
        emit ObjectionAnswered(r.objectionId, r.answerHash, signer);
    }

    // ------------------------------------------------------------------ views

    /// @notice 없는 id 는 빈 구조체 (raiser == address(0)). 원장 getEntry 와 같다 — status 0(OPEN)만 보고 판단하지 않는다.
    function getObjection(uint256 objectionId) external view returns (Objection memory) {
        return _objections[objectionId];
    }

    function exists(uint256 objectionId) external view returns (bool) {
        return _objections[objectionId].raiser != address(0);
    }

    function relayer() external view returns (address) {
        return _relayer;
    }

    function roleManager() external view returns (address) {
        return address(_roleManager);
    }

    function ledger() external view returns (address) {
        return address(_ledger);
    }

    function membershipSBT() external view returns (address) {
        return address(_sbt);
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
