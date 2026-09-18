import '../core/enums.dart';

/// `AccountingLedger.getEntry(id)` 가 돌려주는 온체인 Entry (HASHING.md §2)
///
/// ```
/// Entry { hash, amount, kind, status, occurredAt, budgetId, correctsId,
///         registrant, approver }
/// ```
///
/// **해시 비교만으로는 검증이 반쪽이다.** `kind` 와 `budget_id` 는 `meta_hash` 에
/// 들어가지 않아서, 수입↔지출을 뒤바꾸거나 예산 항목을 옮겨도 해시가 한 글자도
/// 변하지 않는다 (§2 실측). 그래서 이 값들을 체인에서 직접 읽어 대조해야 한다.
class OnChainEntry {
  /// 온체인에 기록된 `meta_hash`. SHA-256 출력 32바이트이며 keccak 이 아니다.
  final String hash;
  final int amount;
  final EntryKind kind;
  final EntryStatus status;
  final int occurredAt;

  /// 없으면 `0`. DB 의 `budget_id = NULL` 에 대응한다 (§2.1).
  final int budgetId;

  /// 정정이 아니면 `0`. DB 의 `corrects_entry_id = NULL` 에 대응한다 (§2.1).
  final int correctsId;

  /// 등록자 지갑 주소. DB 의 `created_by`(user id)와 값 자체가 다르므로
  /// `User.wallet_address` 로 옮긴 뒤 대조해야 한다.
  final String registrant;

  /// 확정자 **또는 반려자**의 지갑 주소. 미처리면 `address(0)`.
  ///
  /// 컨트랙트의 `approver` 는 둘을 겸하는데 DB 에는 `approved_by` 만 있고
  /// 반려자 컬럼이 없다. 그래서 `REJECTED` 항목에서는 이 필드를 비교하지 않는다
  /// (`rejected_by` 컬럼 추가 요청됨 — HASHING.md §8).
  final String approver;

  const OnChainEntry({
    required this.hash,
    required this.amount,
    required this.kind,
    required this.status,
    required this.occurredAt,
    required this.budgetId,
    required this.correctsId,
    required this.registrant,
    required this.approver,
  });

  /// 비어 있는 주소. DB 의 `NULL` 에 대응한다.
  static const String zeroAddress = '0x0000000000000000000000000000000000000000';

  bool get hasApprover => !_isZeroAddress(approver);

  static bool _isZeroAddress(String address) {
    final lower = address.toLowerCase();
    return lower == zeroAddress || lower == '0x0' || address.isEmpty;
  }

  factory OnChainEntry.fromJson(Map<String, dynamic> json) {
    return OnChainEntry(
      hash: json['hash'] ?? '',
      amount: json['amount'] ?? 0,
      kind: EntryKind.fromCode(json['kind'] ?? 'EXPENSE'),
      status: EntryStatus.fromCode(json['status'] ?? 'PENDING'),
      occurredAt: json['occurred_at'] ?? 0,
      budgetId: json['budget_id'] ?? 0,
      correctsId: json['corrects_id'] ?? 0,
      registrant: json['registrant'] ?? zeroAddress,
      approver: json['approver'] ?? zeroAddress,
    );
  }
}
