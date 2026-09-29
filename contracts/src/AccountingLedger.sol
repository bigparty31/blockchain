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
/// - Entry 는 4 슬롯. 좁히기 전 범위 검사는 recordPending 2~5 단계에서 끝낸다. 항목 존재는 registrant != 0.
contract AccountingLedger is IAccountingLedger, EIP712 {
    bytes32 private constant TREASURER = keccak256("TREASURER");
    bytes32 private constant AUDITOR = keccak256("AUDITOR");
    bytes32 private constant PRESIDENT = keccak256("PRESIDENT");

    bytes32 private constant RECORD_REQUEST_TYPEHASH =
        keccak256(
            "RecordRequest(uint256 id,bytes32 hash,int256 amount,uint8 kind,uint256 term,uint256 occurredAt,uint256 budgetId,uint256 correctsId,uint256 deadline)"
        );
    bytes32 private constant CONFIRM_APPROVAL_TYPEHASH =
        keccak256(
            "ConfirmApproval(uint256 id,bytes32 hash,bytes32 entryCommit,bool hadWarning,bytes32 warningReasonHash,uint256 deadline)"
        );
    bytes32 private constant REJECT_DECISION_TYPEHASH =
        keccak256("RejectDecision(uint256 id,bytes32 reasonHash,uint256 deadline)");

    uint256 public constant MAX_AMOUNT = 1e15;

    IRoleManager private immutable _roleManager;
    IBudgetToken private immutable _budgetToken;

    mapping(uint256 id => Entry) private _entries;
    /// @dev 정정 가능 항목(원본·재분류 양수 정정)별 순금액. 그 항목을 대상으로 하는 음수 정정의 상한.
    mapping(uint256 id => uint256) private _netAmount;

    constructor(address roleManager_, address budgetToken_) EIP712("AccountingLedger", "1") {
        if (roleManager_ == address(0) || budgetToken_ == address(0)) revert ZeroAddress();
        _roleManager = IRoleManager(roleManager_);
        _budgetToken = IBudgetToken(budgetToken_);
    }

    // ----------------------------------------------------------------- record

    function recordPending(RecordRequest calldata r, bytes calldata signature) external {
        // 1~5: 입력 자체로 판정되는 것
        if (block.timestamp > r.deadline) revert SignatureExpired(r.deadline);
        if (r.id == 0) revert ReservedId(r.id); // 0 은 "없음" 으로 예약
        if (r.id > type(uint64).max) revert FieldOutOfRange(r.id, r.id);
        if (_exists(r.id)) revert EntryAlreadyExists(r.id);
        if (r.term == 0) revert TermRequired(r.id);
        if (r.term > type(uint32).max) revert FieldOutOfRange(r.id, r.term);
        if (r.amount == 0) revert ZeroAmount(r.id);
        if (r.amount > int256(MAX_AMOUNT) || r.amount < -int256(MAX_AMOUNT)) revert AmountOutOfRange(r.id, r.amount);
        if (r.amount < 0 && r.correctsId == 0) revert NegativeAmountWithoutCorrection(r.id);
        if (r.occurredAt > type(uint64).max) revert FieldOutOfRange(r.id, r.occurredAt);
        if (r.budgetId > type(uint64).max) revert FieldOutOfRange(r.id, r.budgetId);
        if (r.correctsId > type(uint64).max) revert FieldOutOfRange(r.id, r.correctsId);

        // 6: 서명자 = 등록자, TREASURER 여야 한다
        address registrant = _recover(_hashRecordRequest(r), signature);
        if (!_roleManager.hasRole(TREASURER, registrant)) revert NotRegistrant(registrant);

        // 7: 수입은 예산이 없다
        if (r.kind == Kind.INCOME && r.budgetId != 0) revert BudgetIdNotAllowedForIncome(r.id, r.budgetId);

        // 8: 정정 대상 검사
        if (r.correctsId != 0) _checkCorrection(r);

        // 9~10: 지출의 예산 판정. 9 는 revert, 10 은 BLOCKED 저장.
        (bool blocked, BlockReason reason) = _judgeBudget(r);

        _entries[r.id] = Entry({
            hash: r.hash,
            amount: int128(r.amount),
            budgetId: uint64(r.budgetId),
            correctsId: uint64(r.correctsId),
            registrant: registrant,
            occurredAt: uint64(r.occurredAt),
            term: uint32(r.term),
            approver: address(0),
            kind: r.kind,
            status: blocked ? Status.BLOCKED : Status.PENDING
        });

        if (blocked) {
            emit EntryBlocked(r.id, r.hash, uint256(r.amount), r.term, r.budgetId, uint8(reason), registrant);
        } else {
            emit EntryPending(r.id, r.hash, r.amount, uint8(r.kind), r.term, r.budgetId, r.correctsId, registrant);
        }
    }

    // ---------------------------------------------------------------- confirm

    function confirmEntry(ConfirmApproval calldata a, bytes calldata signature) external {
        if (block.timestamp > a.deadline) revert SignatureExpired(a.deadline);
        if (!_exists(a.id)) revert EntryNotFound(a.id);
        Entry storage e = _entries[a.id];
        if (e.status != Status.PENDING) revert InvalidStatus(a.id, e.status, Status.PENDING);
        if (e.hash != a.hash) revert HashMismatch(a.id, e.hash, a.hash);
        {
            bytes32 commit = _entryCommit(e);
            if (commit != a.entryCommit) revert EntryCommitMismatch(a.id, commit, a.entryCommit);
        }
        if (a.hadWarning && a.warningReasonHash == bytes32(0)) revert ReasonRequired(a.id);
        if (!a.hadWarning && a.warningReasonHash != bytes32(0)) revert ReasonNotAllowed(a.id);

        address approver = _recover(_hashConfirmApproval(a), signature);
        _requireApprover(approver);
        if (approver == e.registrant) revert SelfApproval(a.id, approver);

        _settle(a.id, e);

        e.status = Status.CONFIRMED;
        e.approver = approver;

        emit EntryConfirmed(
            a.id,
            a.hash,
            e.amount,
            uint8(e.kind),
            e.term,
            e.budgetId,
            a.hadWarning,
            a.warningReasonHash,
            approver
        );
    }

    /// @dev 확정의 돈 쪽 효과. 정정 상한 최종 검사 → 예산 spend/refund → 순금액 갱신.
    ///      BudgetToken 이 revert 하면 전체가 되돌려져 상태는 PENDING 유지.
    function _settle(uint256 id, Entry storage e) private {
        int256 amount = e.amount;
        uint256 correctsId = e.correctsId;
        uint256 budgetId = e.budgetId;

        // 음수 정정: 확정 시점 최종 검사 (대기 중 다른 정정이 먼저 확정됐을 수 있다)
        if (correctsId != 0 && amount < 0) {
            _checkCorrectionCap(id, correctsId, amount);
        }

        if (e.kind == Kind.EXPENSE) {
            if (amount > 0) {
                _budgetToken.spend(budgetId, uint256(amount), id);
            } else {
                _budgetToken.refund(budgetId, uint256(-amount), id);
            }
        }

        // 자기 순금액을 갖는 것은 원본과 재분류 양수 정정만 (정정 가능 항목).
        // 같은 예산 양수 정정은 대상의 순금액에 흡수되고, 음수 정정은 대상의 순금액을 줄인다.
        if (amount > 0 && _isCorrectable(e)) {
            _netAmount[id] = uint256(amount);
        }
        if (correctsId != 0 && _entries[correctsId].budgetId == budgetId) {
            if (amount > 0) {
                _netAmount[correctsId] += uint256(amount);
            } else {
                _netAmount[correctsId] -= uint256(-amount); // _checkCorrectionCap 이 범위를 보장
            }
        }
    }

    // ----------------------------------------------------------------- reject

    function rejectEntry(RejectDecision calldata d, bytes calldata signature) external {
        if (block.timestamp > d.deadline) revert SignatureExpired(d.deadline);
        if (!_exists(d.id)) revert EntryNotFound(d.id);
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
        if (!_exists(id)) revert EntryNotFound(id);
        return _entries[id].status;
    }

    function exists(uint256 id) external view returns (bool) {
        return _exists(id);
    }

    function entryCommitOf(uint256 id) external view returns (bytes32) {
        if (!_exists(id)) return bytes32(0);
        return _entryCommit(_entries[id]);
    }

    function netAmountOf(uint256 id) external view returns (uint256) {
        return _netAmount[id];
    }

    function roleManager() external view returns (address) {
        return address(_roleManager);
    }

    function budgetToken() external view returns (address) {
        return address(_budgetToken);
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // --------------------------------------------------------------- internal

    function _exists(uint256 id) private view returns (bool) {
        return _entries[id].registrant != address(0);
    }

    /// @dev recordPending 8 단계. 순서는 IAccountingLedger 주석.
    function _checkCorrection(RecordRequest calldata r) private view {
        if (!_exists(r.correctsId)) revert CorrectionTargetNotFound(r.id, r.correctsId);
        Entry storage original = _entries[r.correctsId];
        if (original.status != Status.CONFIRMED) revert CorrectionTargetNotConfirmed(r.id, r.correctsId);
        if (original.kind != r.kind) revert CorrectionKindMismatch(r.id, original.kind, r.kind);
        if (original.term != r.term) revert TermMismatch(r.id, original.term, r.term);
        if (!_isCorrectable(original)) revert InvalidCorrectionTarget(r.id, r.correctsId);
        if (r.amount < 0) {
            if (original.budgetId != r.budgetId) {
                revert CorrectionBudgetMismatch(r.id, original.budgetId, r.budgetId);
            }
            _checkCorrectionCap(r.id, r.correctsId, r.amount);
        }
    }

    /// @dev recordPending 9~10 단계. 지출만. 음수 정정은 10 을 건너뛴다 (refund 는 마감·잔량과 무관).
    function _judgeBudget(RecordRequest calldata r) private view returns (bool blocked, BlockReason reason) {
        if (r.kind != Kind.EXPENSE) return (false, reason);
        IBudgetToken.Budget memory b; // budgetId 0 이면 version 0 = 없음 (호출하지 않는다)
        if (r.budgetId != 0) b = _budgetToken.getBudget(r.budgetId);
        if (b.version != 0) {
            if (b.term != r.term) revert TermMismatch(r.id, b.term, r.term);
            if (r.amount > 0) {
                if (block.timestamp > b.expiresAt) return (true, BlockReason.BUDGET_EXPIRED);
                if (uint256(b.issued) - b.spent < uint256(r.amount)) return (true, BlockReason.BUDGET_EXCEEDED);
            }
        } else if (r.amount > 0) {
            return (true, BlockReason.BUDGET_NOT_FOUND);
        }
        return (false, reason);
    }

    function _requireApprover(address signer) private view {
        if (!_roleManager.hasRole(AUDITOR, signer) && !_roleManager.hasRole(PRESIDENT, signer)) {
            revert NotApprover(signer);
        }
    }

    /// @dev 정정 가능 항목인가: 원본(정정 아님) 또는 원본과 다른 예산으로 간 양수 정정(재분류).
    ///      같은 예산 양수 정정과 음수 정정은 정정 대상이 될 수 없고 자기 순금액도 갖지 않는다.
    function _isCorrectable(Entry storage e) private view returns (bool) {
        if (e.correctsId == 0) return true;
        return e.amount > 0 && e.budgetId != _entries[e.correctsId].budgetId;
    }

    /// @dev 음수 정정 amount 의 절대값이 대상 순금액을 넘으면 revert. amount 는 이미 MAX_AMOUNT 범위 안이다.
    function _checkCorrectionCap(uint256 id, uint256 correctsId, int256 amount) private view {
        uint256 requested = uint256(-amount);
        uint256 net = _netAmount[correctsId];
        if (requested > net) revert CorrectionExceedsOriginal(id, correctsId, net, requested);
    }

    /// @dev docs/CONTRACTS.md "공통 규칙" 의 entryCommit 식. 저장 폭과 무관하게 uint256·int256 으로 인코딩한다.
    function _entryCommit(Entry storage e) private view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    e.hash,
                    int256(e.amount),
                    uint8(e.kind),
                    uint256(e.term),
                    uint256(e.budgetId),
                    uint256(e.correctsId),
                    e.registrant
                )
            );
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
        return
            keccak256(
                abi.encode(
                    CONFIRM_APPROVAL_TYPEHASH,
                    a.id,
                    a.hash,
                    a.entryCommit,
                    a.hadWarning,
                    a.warningReasonHash,
                    a.deadline
                )
            );
    }

    function _hashRejectDecision(RejectDecision calldata d) private pure returns (bytes32) {
        return keccak256(abi.encode(REJECT_DECISION_TYPEHASH, d.id, d.reasonHash, d.deadline));
    }
}
