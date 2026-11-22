import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/format.dart';
import 'package:student_council_app/models/budget_model.dart';
import 'package:student_council_app/models/settlement_model.dart';

/// 서버는 비율을 소수 4자리로 먼저 반올림해 내려준다(0.134467 → 0.1345). 그 값을 다시 소수 1자리로
/// 반올림하면 13.4% 가 13.5% 로 올라가 학생 홈(편성·잔량으로 직접 계산)과 어긋났다.
void main() {
  test('예산 집행 — 서버가 반올림한 비율이 아니라 집행액·편성액으로 계산한다', () {
    final b = BudgetExecution.fromJson({
      'budget_id': 1,
      'category': '행사비',
      'initial_amount': 600000,
      'planned_amount': 600000,
      'version': 2,
      'spent': 80680,
      'remaining': 519320,
      'execution_rate': 0.1345,
    });
    expect(Fmt.percent(b.executionRate!), '13.4%');
  });

  test('예산 집행 — 편성액이 0 이면 비율이 없다', () {
    final b = BudgetExecution.fromJson({
      'budget_id': 1,
      'category': '행사비',
      'initial_amount': 0,
      'planned_amount': 0,
      'version': 1,
      'spent': 0,
      'remaining': 0,
      'execution_rate': null,
    });
    expect(b.executionRate, isNull);
  });

  test('예산 목록(개정 화면) — 편성·잔량으로 계산한다', () {
    final b = BudgetModel.fromJson({
      'id': 1,
      'term_id': 1,
      'category': '행사비',
      'planned_amount': 600000,
      'remaining_amount': 519320,
      'execution_rate': 0.1345,
      'version': 2,
      'expires_at': 0,
    });
    expect(Fmt.percent(b.executionRate), '13.4%');
  });
}
