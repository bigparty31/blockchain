import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/entry_merge.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/models/entry_model.dart';

/// #50 갈라진 정정 이력 · #105 학기 합산 — 둘 다 「조용히 틀린 숫자」가 되는 회귀라
/// 화면 밖 함수로 못박는다.
EntryModel entry({
  required int id,
  required int amount,
  EntryKind kind = EntryKind.EXPENSE,
  EntryStatus status = EntryStatus.CONFIRMED,
  int? termCode,
  int? correctsEntryId,
}) =>
    EntryModel(
      id: id,
      termId: 1,
      termCode: termCode,
      kind: kind,
      amount: amount,
      counterparty: '거래처$id',
      purpose: '목적$id',
      occurredAt: 1700000000 + id,
      metaHash: '0x${id.toString().padLeft(64, '0')}',
      status: status,
      createdBy: 2,
      correctsEntryId: correctsEntryId,
    );

void main() {
  group('#50 갈라진 정정 이력', () {
    test('한 원본에 정정이 둘 갈리고 그중 앞 건에 후속 정정이 붙어도 빠지지 않는다', () {
      // #1 원본 ← #2, #3 (형제) · #2 ← #4 (후속)
      final entries = [
        entry(id: 1, amount: 50000),
        entry(id: 2, amount: -20000, correctsEntryId: 1),
        entry(id: 3, amount: -5000, correctsEntryId: 1),
        entry(id: 4, amount: -1000, correctsEntryId: 2),
      ];

      final chains = EntryMerge.fold(entries);

      expect(chains.length, 1, reason: '원본 하나이므로 체인도 하나');
      final ids = chains.single.corrections.map((e) => e.id).toList();
      expect(ids, [2, 3, 4], reason: '#4 가 빠지면 금액이 틀리고 화면에서도 사라진다');
    });

    test('빠진 정정만큼 최종 금액이 어긋나지 않는다', () {
      final entries = [
        entry(id: 1, amount: 50000),
        entry(id: 2, amount: -20000, correctsEntryId: 1),
        entry(id: 3, amount: -5000, correctsEntryId: 1),
        entry(id: 4, amount: -1000, correctsEntryId: 2),
      ];

      // 50,000 − 20,000 − 5,000 − 1,000
      expect(EntryMerge.fold(entries).single.finalAmount, 24000);
    });

    test('깊은 사슬(A←B←C←D)도 그대로 이어진다', () {
      final entries = [
        entry(id: 1, amount: 10000),
        entry(id: 2, amount: -1000, correctsEntryId: 1),
        entry(id: 3, amount: -100, correctsEntryId: 2),
        entry(id: 4, amount: -10, correctsEntryId: 3),
      ];

      expect(
        EntryMerge.fold(entries).single.corrections.map((e) => e.id).toList(),
        [2, 3, 4],
      );
    });

    test('정정이 모두 체인에 들어가 검증 대상이 된다', () {
      final entries = [
        entry(id: 1, amount: 50000),
        entry(id: 2, amount: -20000, correctsEntryId: 1),
        entry(id: 3, amount: -5000, correctsEntryId: 1),
        entry(id: 4, amount: -1000, correctsEntryId: 2),
      ];

      // allEntries 를 돌며 검증하므로 하나라도 빠지면 검증 안 된 숫자에 배지가 붙는다
      expect(
        EntryMerge.fold(entries).single.allEntries.map((e) => e.id).toList(),
        [1, 2, 3, 4],
      );
    });
  });

  group('#105 학기 합산', () {
    final entries = [
      entry(id: 1, amount: 100000, kind: EntryKind.INCOME, termCode: 20262),
      entry(id: 2, amount: 30000, termCode: 20262),
      entry(id: 3, amount: 999000, kind: EntryKind.INCOME, termCode: 20261), // 지난 학기
      entry(id: 4, amount: 888000, termCode: 20261), // 지난 학기
    ];

    test('학기를 주면 그 학기만 더한다', () {
      expect(EntryMerge.totalIncome(entries, termCode: 20262), 100000);
      expect(EntryMerge.totalExpense(entries, termCode: 20262), 30000);
      expect(EntryMerge.ledgerBalance(entries, termCode: 20262), 70000);
    });

    test('학기를 주지 않으면 예전처럼 전부 더한다', () {
      expect(EntryMerge.totalIncome(entries), 1099000);
      expect(EntryMerge.totalExpense(entries), 918000);
    });

    test('학기를 모르는 항목(term_code 없음)은 빼지 않는다', () {
      // 옛 서버·시연용 더미는 term_code 를 싣지 않는다. 거르면 합계가 통째로 0 이 되어
      // 「학생이 직접 센다」는 이 화면의 목적이 사라진다.
      final legacy = [
        entry(id: 1, amount: 70000, kind: EntryKind.INCOME),
        entry(id: 2, amount: 20000),
      ];
      expect(EntryMerge.totalIncome(legacy, termCode: 20262), 70000);
      expect(EntryMerge.ledgerBalance(legacy, termCode: 20262), 50000);
    });

    test('확정되지 않은 건은 학기가 맞아도 더하지 않는다', () {
      final withPending = [
        ...entries,
        entry(id: 5, amount: 500000, status: EntryStatus.PENDING, termCode: 20262),
      ];
      expect(EntryMerge.totalExpense(withPending, termCode: 20262), 30000);
    });
  });
}
