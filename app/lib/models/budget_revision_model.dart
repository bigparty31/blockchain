/// 예산 증액 요청의 상태 — 서버 `BudgetRevisionRequest.status` (docs/API.md §3).
///
/// `PENDING`(회장 서명 대기) → `PRESIDENT_SIGNED`(감사 승인 대기) → `APPROVED` / `REJECTED`.
/// 감사 승인 중 시한 만료·버전 불일치가 나면 서버가 `PENDING` 으로 되돌린다 (회장 재서명).
enum BudgetRevisionStatus { PENDING, PRESIDENT_SIGNED, APPROVED, REJECTED }

/// 백엔드 `BudgetRevisionResponse` 매핑 (docs/API.md §3.1).
///
/// **서명에 들어가는 값은 기본값으로 메우지 않는다.** `BudgetModel.fromJson` 처럼 `?? 0` 으로 메우면
/// 응답이 깨졌을 때 0원·0번 예산에 서명하게 된다. 그런 응답은 [FormatException] 으로 거부한다.
class BudgetRevisionModel {
  final int id;
  final int termId;
  final String category;

  /// 증액 대상 예산. 서버는 발행된 예산에만 요청을 만들므로 응답에서는 항상 있다.
  final int budgetId;

  /// **증액분**이다 (변경 후 총액이 아님) — `IncreaseRequest.amount`.
  final int requestedAmount;

  /// 서버가 정본화(`canonical_text`)해 저장한 사유. `reasonHash` 는 이 값으로 다시 계산한다.
  final String reason;
  final int requestedBy;
  final DateTime requestedAt;
  final BudgetRevisionStatus status;
  final int? blockedEntryId;

  /// 회장 서명 단계에서 채워진다. 감사는 이 두 값을 **그대로** 서명한다.
  final int? presidentSignedBy;
  final int? signatureDeadline;
  final int? signedVersion;

  final String? txIncrease;
  final String? rejectReason;

  const BudgetRevisionModel({
    required this.id,
    required this.termId,
    required this.category,
    required this.budgetId,
    required this.requestedAmount,
    required this.reason,
    required this.requestedBy,
    required this.requestedAt,
    required this.status,
    this.blockedEntryId,
    this.presidentSignedBy,
    this.signatureDeadline,
    this.signedVersion,
    this.txIncrease,
    this.rejectReason,
  });

  factory BudgetRevisionModel.fromJson(Map<String, dynamic> json) {
    T need<T>(String key) {
      final v = json[key];
      if (v is! T) throw FormatException('증액 요청 응답의 $key 형식이 올바르지 않아요');
      return v;
    }

    final statusName = need<String>('status');
    final status = BudgetRevisionStatus.values.where((s) => s.name == statusName);
    if (status.isEmpty) throw FormatException('알 수 없는 증액 요청 상태: $statusName');

    final requestedAt = DateTime.tryParse(need<String>('requested_at'));
    if (requestedAt == null) throw const FormatException('증액 요청 응답의 requested_at 형식이 올바르지 않아요');

    return BudgetRevisionModel(
      id: need<int>('id'),
      termId: need<int>('term_id'),
      category: need<String>('category'),
      budgetId: need<int>('budget_id'),
      requestedAmount: need<int>('requested_amount'),
      reason: need<String>('reason'),
      requestedBy: need<int>('requested_by'),
      requestedAt: requestedAt,
      status: status.single,
      blockedEntryId: json['blocked_entry_id'] as int?,
      presidentSignedBy: json['president_signed_by'] as int?,
      signatureDeadline: json['signature_deadline'] as int?,
      signedVersion: json['signed_version'] as int?,
      txIncrease: json['tx_increase'] as String?,
      rejectReason: json['reject_reason'] as String?,
    );
  }
}
