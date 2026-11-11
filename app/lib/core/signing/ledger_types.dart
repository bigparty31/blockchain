import 'package:web3dart/web3dart.dart' show keccak256;

import '../enums.dart';
import 'eip712.dart';

/// 원장(`AccountingLedger`) 도메인으로 서명하는 세 구조체.
///
/// 필드 이름·순서·타입은 `IAccountingLedger.sol` 의 typehash, `backend/app/chain/eip712.py` 와 같다.
/// 하나라도 다르면 모든 서명이 다른 다이제스트가 된다.
class LedgerTypes {
  LedgerTypes._();

  static const domainName = 'AccountingLedger';

  /// 총무 — 등록(PENDING) 기록.
  static const recordRequestFields = [
    Eip712Field('id', 'uint256'),
    Eip712Field('hash', 'bytes32'),
    Eip712Field('amount', 'int256'),
    Eip712Field('kind', 'uint8'),
    Eip712Field('term', 'uint256'),
    Eip712Field('occurredAt', 'uint256'),
    Eip712Field('budgetId', 'uint256'),
    Eip712Field('correctsId', 'uint256'),
    Eip712Field('deadline', 'uint256'),
  ];

  /// 감사·회장 — 확정.
  static const confirmApprovalFields = [
    Eip712Field('id', 'uint256'),
    Eip712Field('hash', 'bytes32'),
    Eip712Field('entryCommit', 'bytes32'),
    Eip712Field('hadWarning', 'bool'),
    Eip712Field('warningReasonHash', 'bytes32'),
    Eip712Field('deadline', 'uint256'),
  ];

  /// 감사·회장 — 반려.
  static const rejectDecisionFields = [
    Eip712Field('id', 'uint256'),
    Eip712Field('entryCommit', 'bytes32'),
    Eip712Field('reasonHash', 'bytes32'),
    Eip712Field('deadline', 'uint256'),
  ];

  /// 원장의 `Kind` — EIP-712 타입 문자열에서는 `uint8`. 순서가 컨트랙트 enum 순서다.
  static int kindCode(EntryKind kind) => kind == EntryKind.INCOME ? 0 : 1;

  static Eip712Message recordRequest({
    required int id,
    required String hash,
    required int amount,
    required EntryKind kind,
    required int term,
    required int occurredAt,
    required int budgetId,
    required int correctsId,
    required int deadline,
  }) =>
      Eip712Message('RecordRequest', recordRequestFields, {
        'id': id,
        'hash': hash,
        'amount': amount,
        'kind': kindCode(kind),
        'term': term,
        'occurredAt': occurredAt,
        'budgetId': budgetId,
        'correctsId': correctsId,
        'deadline': deadline,
      });

  static Eip712Message confirmApproval({
    required int id,
    required String hash,
    required String entryCommit,
    required bool hadWarning,
    required String warningReasonHash,
    required int deadline,
  }) =>
      Eip712Message('ConfirmApproval', confirmApprovalFields, {
        'id': id,
        'hash': hash,
        'entryCommit': entryCommit,
        'hadWarning': hadWarning,
        'warningReasonHash': warningReasonHash,
        'deadline': deadline,
      });

  static Eip712Message rejectDecision({
    required int id,
    required String entryCommit,
    required String reasonHash,
    required int deadline,
  }) =>
      Eip712Message('RejectDecision', rejectDecisionFields, {
        'id': id,
        'entryCommit': entryCommit,
        'reasonHash': reasonHash,
        'deadline': deadline,
      });

  /// 승인·반려자가 함께 서명하는 등록값 전체 (`docs/CONTRACTS.md` — entryCommit).
  ///
  /// `meta_hash` 에는 종류·학기·예산·정정 대상·등록자가 없어서, 해시만 대조하면 총무가 다른 예산으로
  /// 등록해도 승인이 통과한다. 그래서 이 값까지 서명에 묶는다.
  ///
  ///   keccak256(abi.encode(bytes32 hash, int256 amount, uint8 kind, uint256 term,
  ///                        uint256 occurredAt, uint256 budgetId, uint256 correctsId, address registrant))
  ///
  /// [term] 은 학기 코드(`YYYYS`)다 — DB 의 `term_id` 를 넣으면 체인 값과 갈린다.
  static String entryCommit({
    required String hash,
    required int amount,
    required EntryKind kind,
    required int term,
    required int occurredAt,
    required int budgetId,
    required int correctsId,
    required String registrant,
  }) =>
      Eip712.toHex(keccak256(Eip712.concat([
        Eip712.encodeValue('bytes32', hash),
        Eip712.encodeValue('int256', amount),
        Eip712.encodeValue('uint8', kindCode(kind)),
        Eip712.encodeValue('uint256', term),
        Eip712.encodeValue('uint256', occurredAt),
        Eip712.encodeValue('uint256', budgetId),
        Eip712.encodeValue('uint256', correctsId),
        Eip712.encodeValue('address', registrant),
      ])));
}
