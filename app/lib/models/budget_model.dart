/// 백엔드 BudgetResponse 스키마 1:1 매핑
class BudgetModel {
  final int id;
  final int termId;
  final String category;
  final int plannedAmount;
  final int remainingAmount;
  final double executionRate;
  final int version;
  final int expiresAt;
  final String? revisionReason;

  BudgetModel({
    required this.id,
    required this.termId,
    required this.category,
    required this.plannedAmount,
    required this.remainingAmount,
    required this.executionRate,
    required this.version,
    required this.expiresAt,
    this.revisionReason,
  });

  factory BudgetModel.fromJson(Map<String, dynamic> json) {
    return BudgetModel(
      id: json['id'] ?? 0,
      termId: json['term_id'] ?? 1,
      category: json['category'] ?? '',
      plannedAmount: json['planned_amount'] ?? 0,
      remainingAmount: json['remaining_amount'] ?? 0,
      executionRate: (json['execution_rate'] as num?)?.toDouble() ?? 0.0,
      version: json['version'] ?? 1,
      expiresAt: json['expires_at'] ?? 0,
      revisionReason: json['revision_reason'],
    );
  }
}
