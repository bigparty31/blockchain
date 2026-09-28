// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IAccountingLedger} from "../interfaces/IAccountingLedger.sol";
import {IBudgetToken} from "../interfaces/IBudgetToken.sol";
import {IRoleManager} from "../interfaces/IRoleManager.sol";

/// @title AccountingLedger
/// @notice 수입·지출 원장 구현. 규칙·검사 순서는 IAccountingLedger 주석과 docs/CONTRACTS.md 가 정본이다.
/// @dev
/// - 상태를 바꾸는 외부 함수는 recordPending / confirmEntry / rejectEntry 셋뿐이다. 확정 항목을 고치는 경로는 없다.
/// - 호출자는 릴레이어. 행위자는 EIP-712 서명자다. msg.sender 는 어디에도 쓰지 않는다.
/// - 서명 바이트가 깨졌을 때만 InvalidSignature. 다른 값에 대한 서명은 엉뚱한 주소가 복구되어 NotRegistrant / NotApprover 로 난다.
contract AccountingLedger is IAccountingLedger, EIP712 {
    bytes32 private constant TREASURER = keccak256("TREASURER");
    bytes32 private constant AUDITOR = keccak256("AUDITOR");
    bytes32 private constant PRESIDENT = keccak256("PRESIDENT");

    bytes32 private constant RECORD_REQUEST_TYPEHASH =
        keccak256(
            "RecordRequest(uint256 id,bytes32 hash,int256 amount,uint8 kind,uint256 term,uint256 occurredAt,uint256 budgetId,uint256 correctsId,uint256 deadline)"
        );
    bytes32 private constant CONFIRM_APPROVAL_TYPEHASH =
        keccak256("ConfirmApproval(uint256 id,bytes32 hash,bool hadWarning,bytes32 warningReasonHash,uint256 deadline)");
    bytes32 private constant REJECT_DECISION_TYPEHASH =
        keccak256("RejectDecision(uint256 id,bytes32 reasonHash,uint256 deadline)");

    IRoleManager public immutable roleManager;
    IBudgetToken public immutable budgetToken;

    mapping(uint256 id => Entry) private _entries;
    mapping(uint256 id => bool) private _exists;
    /// @dev 원본별 순금액. 음수 정정의 상한. 같은 budgetId 로 가는 정정만 반영한다.
    mapping(uint256 id => uint256) private _netAmount;

    constructor(address roleManager_, address budgetToken_) EIP712("AccountingLedger", "1") {
        roleManager = IRoleManager(roleManager_);
        budgetToken = IBudgetToken(budgetToken_);
    }

    // ----------------------------------------------------------------- record

    function recordPending(RecordRequest calldata r, bytes calldata signature) external {
        // 1~5: 입력 자체로 판정되는 것
        if (block.timestamp > r.deadline) revert SignatureExpired(r.deadline);
        if (r.id == 0 || _exists[r.id]) revert EntryAlreadyExists(r.id); // 0 은 "없음" 으로 예약
        if (r.term == 0) revert TermRequired(r.id);
        if (r.amount == 0) revert ZeroAmount(r.id);
        if (r.amount < 0 && r.correctsId == 0) revert NegativeAmountWithoutCorrection(r.id);

        // 6: 서명자 = 등록자, TREASURER 여야 한다
        address registrant = _recover(_hashRecordRequest(r), signature);
        if (!roleManager.hasRole(TREASURER, registrant)) revert NotRegistrant(registrant);

        // 7: 수입은 예산이 없다
        if (r.kind == Kind.INCOME && r.budgetId != 0) revert BudgetIdNotAllowedForIncome(r.id, r.budgetId);

        // 8: 정정 대상 검사
        if (r.correctsId != 0) {
            if (!_exists[r.correctsId]) revert CorrectionTargetNotFound(r.id, r.correctsId);
            Entry storage original = _entries[r.correctsId];
            if (original.status != Status.CONFIRMED) revert CorrectionTargetNotConfirmed(r.id, r.correctsId);
            if (r.amount < 0) {
                if (original.budgetId != r.budgetId) {
                    revert CorrectionBudgetMismatch(r.id, original.budgetId, r.budgetId);
                }
                _checkCorrectionCap(r.id, r.correctsId, r.amount);
            }
        }

        // 9~10: 지출의 예산 판정. 9 는 revert, 10 은 BLOCKED 저장.
        bool blocked = false;
        BlockReason reason;
        if (r.kind == Kind.EXPENSE) {
            bool budgetExists = r.budgetId != 0 && budgetToken.exists(r.budgetId);
            if (budgetExists) {
                IBudgetToken.Budget memory b = budgetToken.getBudget(r.budgetId);
                if (b.term != r.term) revert TermMismatch(r.id, b.term, r.term);
                if (r.amount > 0) {
                    if (block.timestamp > b.expiresAt) {
                        (blocked, reason) = (true, BlockReason.BUDGET_EXPIRED);
                    } else if (b.issued - b.spent < uint256(r.amount)) {
                        (blocked, reason) = (true, BlockReason.BUDGET_EXCEEDED);
                    }
                }
            } else if (r.amount > 0) {
                (blocked, reason) = (true, BlockReason.BUDGET_NOT_FOUND);
            }
            // 음수 정정(refund)은 마감·잔량·존재 여부와 무관하게 등록된다. budgetId 는 8 에서 원본과 같음이 확인됨.
        }

        _entries[r.id] = Entry({
            hash: r.hash,
            amount: r.amount,
            kind: r.kind,
            status: blocked ? Status.BLOCKED : Status.PENDING,
            term: r.term,
            occurredAt: r.occurredAt,
            budgetId: r.budgetId,
            correctsId: r.correctsId,
            registrant: registrant,
            approver: address(0)
        });
        _exists[r.id] = true;

        if (blocked) {
            emit EntryBlocked(r.id, r.budgetId, _abs(r.amount), uint8(reason));
        } else {
            emit EntryPending(r.id, r.hash, r.amount, uint8(r.kind), r.term, r.budgetId, r.correctsId, registrant);
        }
    }

    // ---------------------------------------------------------------- confirm

    function confirmEntry(ConfirmApproval calldata a, bytes calldata signature) external {
        if (block.timestamp > a.deadline) revert SignatureExpired(a.deadline);
        if (!_exists[a.id]) revert EntryNotFound(a.id);
        Entry storage e = _entries[a.id];
        if (e.status != Status.PENDING) revert InvalidStatus(a.id, e.status, Status.PENDING);
        if (e.hash != a.hash) revert HashMismatch(a.id, e.hash, a.hash);
        if (a.hadWarning && a.warningReasonHash == bytes32(0)) revert ReasonRequired(a.id);
        if (!a.hadWarning && a.warningReasonHash != bytes32(0)) revert ReasonNotAllowed(a.id);

        address approver = _recover(_hashConfirmApproval(a), signature);
        _requireApprover(approver);
        if (approver == e.registrant) revert SelfApproval(a.id, approver);

        // 음수 정정: 확정 시점 최종 검사 (대기 중 다른 정정이 먼저 확정됐을 수 있다)
        if (e.correctsId != 0 && e.amount < 0) {
            _checkCorrectionCap(a.id, e.correctsId, e.amount);
        }

        // 예산 반영. 실패하면 전체 revert, 상태는 PENDING 유지.
        if (e.kind == Kind.EXPENSE) {
            if (e.amount > 0) {
                budgetToken.spend(e.budgetId, uint256(e.amount), a.id);
            } else {
                budgetToken.refund(e.budgetId, _abs(e.amount), a.id);
            }
        }

        e.status = Status.CONFIRMED;
        e.approver = approver;

        // 순금액 갱신
        if (e.amount > 0) {
            _netAmount[a.id] = uint256(e.amount);
        }
        if (e.correctsId != 0 && _entries[e.correctsId].budgetId == e.budgetId) {
            if (e.amount > 0) {
                _netAmount[e.correctsId] += uint256(e.amount);
            } else {
                _netAmount[e.correctsId] -= _abs(e.amount); // _checkCorrectionCap 이 범위를 보장
            }
        }

        emit EntryConfirmed(
            a.id,
            e.hash,
            e.amount,
            uint8(e.kind),
            e.term,
            e.budgetId,
            a.hadWarning,
            a.warningReasonHash,
            approver
        );
    }

    // ----------------------------------------------------------------- reject

    function rejectEntry(RejectDecision calldata d, bytes calldata signature) external {
        if (block.timestamp > d.deadline) revert SignatureExpired(d.deadline);
        if (!_exists[d.id]) revert EntryNotFound(d.id);
        Entry storage e = _entries[d.id];
        if (e.status != Status.PENDING) revert InvalidStatus(d.id, e.status, Status.PENDING);
        if (d.reasonHash == bytes32(0)) revert ReasonRequired(d.id);

        address approver = _recover(_hashRejectDecision(d), signature);
        _requireApprover(approver);
        if (approver == e.registrant) revert SelfApproval(d.id, approver);

        e.status = Status.REJECTED;
        e.approver = approver;

        emit EntryRejected(d.id, d.reasonHash, approver);
    }

    // ------------------------------------------------------------------ views

    /// @dev 없는 id 는 0 으로 채운 구조체. 백엔드는 exists() 를 먼저 본다 (docs/CHAIN_CLIENT.md §3).
    function getEntry(uint256 id) external view returns (Entry memory) {
        return _entries[id];
    }

    function statusOf(uint256 id) external view returns (Status) {
        return _entries[id].status;
    }

    function exists(uint256 id) external view returns (bool) {
        return _exists[id];
    }

    function netAmountOf(uint256 id) external view returns (uint256) {
        return _netAmount[id];
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // --------------------------------------------------------------- internal

    function _requireApprover(address signer) private view {
        if (!roleManager.hasRole(AUDITOR, signer) && !roleManager.hasRole(PRESIDENT, signer)) {
            revert NotApprover(signer);
        }
    }

    /// @dev 음수 정정 amount 의 절대값이 원본 순금액을 넘으면 revert.
    function _checkCorrectionCap(uint256 id, uint256 correctsId, int256 amount) private view {
        uint256 requested = _abs(amount);
        uint256 net = _netAmount[correctsId];
        if (requested > net) revert CorrectionExceedsOriginal(id, correctsId, net, requested);
    }

    function _recover(bytes32 structHash, bytes calldata signature) private view returns (address) {
        (address signer, ECDSA.RecoverError err, ) = ECDSA.tryRecover(_hashTypedDataV4(structHash), signature);
        if (err != ECDSA.RecoverError.NoError || signer == address(0)) revert InvalidSignature();
        return signer;
    }

    function _hashRecordRequest(RecordRequest calldata r) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    RECORD_REQUEST_TYPEHASH,
                    r.id,
                    r.hash,
                    r.amount,
                    uint8(r.kind),
                    r.term,
                    r.occurredAt,
                    r.budgetId,
                    r.correctsId,
                    r.deadline
                )
            );
    }

    function _hashConfirmApproval(ConfirmApproval calldata a) private pure returns (bytes32) {
        return keccak256(abi.encode(CONFIRM_APPROVAL_TYPEHASH, a.id, a.hash, a.hadWarning, a.warningReasonHash, a.deadline));
    }

    function _hashRejectDecision(RejectDecision calldata d) private pure returns (bytes32) {
        return keccak256(abi.encode(REJECT_DECISION_TYPEHASH, d.id, d.reasonHash, d.deadline));
    }

    function _abs(int256 x) private pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
