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
/// ② [currentTermId] 학기의 예산. **현재 학기를 알면 그 학기에 없는 분류는 null 이다** — 다른 학기로 물러나면 지출이
/// 지난 학기로 올라간다. ③ 현재 학기를 모를 때만 학기 번호가 가장 큰(가장 최근) 예산을 보여 준다(표시용 — 제출은 막아야 한다).
BudgetModel? pickBudget(List<BudgetModel> budgets, String category, {int? pinnedId, int? currentTermId}) {
  BudgetModel? latest;
  BudgetModel? inCurrentTerm;
  for (final b in budgets) {
    if (b.category != category) continue;
    if (pinnedId != null && b.id == pinnedId) return b;
    if (currentTermId != null && b.termId == currentTermId) inCurrentTerm ??= b;
    if (latest == null || b.termId > latest.termId) latest = b;
  }
  return currentTermId != null ? inCurrentTerm : latest;
}

/// 화면에 보일 예산 — 분류마다 하나씩([pickBudget] 과 같은 규칙), 목록에서 처음 나온 분류 순서대로.
/// 현재 학기에 없는 분류는 빠진다.
List<BudgetModel> budgetsPerCategory(List<BudgetModel> budgets, {int? pinnedId, int? currentTermId}) {
  final seen = <String>{};
  return [
    for (final b in budgets)
      if (seen.add(b.category)) ...[
        if (pickBudget(budgets, b.category, pinnedId: pinnedId, currentTermId: currentTermId) case final picked?) picked,
      ],
  ];
}
