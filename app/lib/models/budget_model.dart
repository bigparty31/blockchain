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

/// 같은 분류의 예산은 학기마다 하나씩 있다 — `GET /budgets` 는 전 학기를 준다. 분류 이름만으로 고르면
/// 목록에서 처음 나온(가장 오래된) 학기의 예산이 걸려, 지난 학기 예산에 지출이 올라가고 체인이 학기 불일치로 거부한다.
///
/// 고르는 순서: ① [pinnedId] 가 그 분류의 예산이면 그것(지난 건을 다시 등록·이어쓸 때 그 건의 예산) →
/// ② [currentTermId] 학기의 예산 → ③ 없으면 학기 번호가 가장 큰(가장 최근) 예산. 없으면 null.
BudgetModel? pickBudget(List<BudgetModel> budgets, String category, {int? pinnedId, int? currentTermId}) {
  BudgetModel? latest;
  BudgetModel? inCurrentTerm;
  for (final b in budgets) {
    if (b.category != category) continue;
    if (pinnedId != null && b.id == pinnedId) return b;
    if (currentTermId != null && b.termId == currentTermId) inCurrentTerm ??= b;
    if (latest == null || b.termId > latest.termId) latest = b;
  }
  return inCurrentTerm ?? latest;
}

/// 화면에 보일 예산 — 분류마다 하나씩([pickBudget] 과 같은 규칙), 목록에서 처음 나온 분류 순서대로.
List<BudgetModel> budgetsPerCategory(List<BudgetModel> budgets, {int? pinnedId, int? currentTermId}) {
  final seen = <String>{};
  return [
    for (final b in budgets)
      if (seen.add(b.category)) pickBudget(budgets, b.category, pinnedId: pinnedId, currentTermId: currentTermId)!,
  ];
}

