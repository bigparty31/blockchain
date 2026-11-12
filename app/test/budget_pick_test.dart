import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/models/budget_model.dart';
import 'package:student_council_app/screens/council/correction_screen.dart';

/// 같은 분류의 예산은 학기마다 하나씩 있다 — `GET /budgets` 는 전 학기를 준다.
/// 분류 이름만으로 고르면 가장 오래된 학기의 예산이 걸려, 지난 학기 예산에 지출이 올라간다.
void main() {
  BudgetModel b(int id, int termId, String category, {int remaining = 1000}) => BudgetModel(
        id: id,
        termId: termId,
        category: category,
        plannedAmount: 5000,
        remainingAmount: remaining,
        executionRate: 0,
        version: 1,
        expiresAt: 0,
      );

  final all = [b(1, 1, '행사비', remaining: 100), b(2, 1, '사업비'), b(11, 2, '행사비', remaining: 900), b(12, 2, '사업비')];

  group('pickBudget', () {
    test('현재 학기의 예산을 고른다 — 먼저 나온 지난 학기 예산이 아니라', () {
      expect(pickBudget(all, '행사비', currentTermId: 2)?.id, 11);
      expect(pickBudget(all, '행사비', currentTermId: 1)?.id, 1);
    });

    test('현재 학기를 모르면 가장 최근 학기(학기 번호가 가장 큰 것)의 예산을 고른다', () {
      expect(pickBudget(all, '행사비')?.id, 11);
      expect(pickBudget(all.reversed.toList(), '행사비')?.id, 11, reason: '목록 순서와 무관하다');
    });

    test('현재 학기에 그 분류가 없으면 가장 최근 학기로 물러난다', () {
      expect(pickBudget([b(1, 1, '운영비'), b(11, 2, '행사비')], '운영비', currentTermId: 2)?.id, 1);
    });

    test('고정한 예산 번호가 그 분류의 예산이면 학기와 상관없이 그것을 고른다 — 지난 학기 건을 다시 등록할 때', () {
      expect(pickBudget(all, '행사비', pinnedId: 1, currentTermId: 2)?.id, 1);
    });

    test('고정한 번호가 다른 분류의 예산이거나 목록에 없으면 무시한다', () {
      expect(pickBudget(all, '행사비', pinnedId: 2, currentTermId: 2)?.id, 11);
      expect(pickBudget(all, '행사비', pinnedId: 99, currentTermId: 2)?.id, 11);
    });

    test('그 분류의 예산이 없으면 null', () {
      expect(pickBudget(all, '운영비'), isNull);
      expect(pickBudget(const [], '행사비'), isNull);
    });
  });

  group('budgetsPerCategory', () {
    test('분류마다 하나씩, 고르는 규칙은 pickBudget 과 같다 — 처음 나온 분류 순서를 지킨다', () {
      final shown = budgetsPerCategory(all, currentTermId: 2);
      expect(shown.map((x) => x.id), [11, 12]);
    });

    test('고정한 예산이 있으면 그 분류는 그것으로 보인다', () {
      expect(budgetsPerCategory(all, pinnedId: 1, currentTermId: 2).map((x) => x.id), [1, 12]);
    });
  });
  group('reclassifyCandidates', () {
    test('정정 대상과 같은 학기의 다른 예산만 — 학기가 다르면 체인이 학기 불일치로 거부한다', () {
      expect(reclassifyCandidates(all, termId: 2, fromBudgetId: 11).map((x) => x.id), [12]);
      expect(reclassifyCandidates(all, termId: 1, fromBudgetId: 2).map((x) => x.id), [1]);
    });

    test('정정 대상을 아직 모르면 거르지 않는다', () {
      expect(reclassifyCandidates(all, termId: null, fromBudgetId: null), hasLength(4));
    });
  });
}
