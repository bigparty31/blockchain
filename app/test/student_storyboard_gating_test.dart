import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/app_theme.dart';
import 'package:student_council_app/core/entry_merge.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/screens/student/entry_detail_screen.dart';
import 'package:student_council_app/screens/student/objection_screen.dart';

/// 스토리보드가 못박은 **「누를 수 있는가」** 규칙들.
///
/// 화면이 멀쩡히 그려져도 이 조건이 빠지면 규칙이 조용히 뚫린다 —
/// 확정되지 않은 항목에 이의가 달리거나(스토리보드 5 「화면 전체 규칙」),
/// 빈 본문이 제출된다(스토리보드 5 ③). 둘 다 눈으로는 안 보이는 회귀라
/// 여기서 못 박아 둔다.
///
/// **범위 한계** — SBT 미보유로 막히는 경우는 여기서 다루지 않는다.
/// 보유 여부가 `http` 조회 결과라 위젯 테스트의 가짜 시계 아래에서는
/// 그 Future 가 끝나지 않는다 (`student_layout_test.dart` 의 같은 한계).
void main() {
  group('이의 제기 버튼 (스토리보드 4 ⑤)', () {
    testWidgets('확정된 항목이 아니면 회색이고 눌리지 않는다', (tester) async {
      await _pumpDetail(tester, _chain(EntryStatus.PENDING));

      final button = _objectionButton(tester);
      expect(button.enabled, isFalse, reason: '확정 전에는 회색이어야 한다');
      expect(button.onPressed, isNull, reason: '확정 전에는 아예 눌리지 않아야 한다');
      expect(find.text('확정된 항목에만 이의를 제기할 수 있습니다.'), findsOneWidget,
          reason: '회색 버튼만 두면 학생은 이유를 알 길이 없다');
    });

    testWidgets('반려된 항목에도 제기할 수 없다', (tester) async {
      await _pumpDetail(tester, _chain(EntryStatus.REJECTED));

      expect(_objectionButton(tester).onPressed, isNull);
    });

    testWidgets('확정된 항목에는 열려 있다', (tester) async {
      await _pumpDetail(tester, _chain(EntryStatus.CONFIRMED));

      final button = _objectionButton(tester);
      expect(button.enabled, isTrue);
      expect(button.onPressed, isNotNull);
    });
  });

  group('이의 제출 버튼 (스토리보드 5 ③)', () {
    testWidgets('빈 본문에서는 회색이고 눌리지 않는다', (tester) async {
      await _pumpObjection(tester);

      final button = _submitButton(tester);
      expect(button.enabled, isFalse);
      expect(button.onPressed, isNull);
    });

    testWidgets('공백만 쳐도 활성되지 않는다', (tester) async {
      await _pumpObjection(tester);

      await tester.enterText(find.byType(TextField), '   \n  ');
      await tester.pump();

      expect(_submitButton(tester).onPressed, isNull,
          reason: '공백만으로 제출되면 빈 이의가 접수된다');
    });

    testWidgets('내용을 치면 활성된다', (tester) async {
      await _pumpObjection(tester);

      await tester.enterText(find.byType(TextField), '금액 확인 부탁드립니다');
      await tester.pump();

      final button = _submitButton(tester);
      expect(button.enabled, isTrue);
      expect(button.onPressed, isNotNull);
    });
  });
}

/// 지출 상세에서 유일한 그라디언트 버튼이 이의 제기 버튼이다.
GradientButton _objectionButton(WidgetTester tester) =>
    tester.widget<GradientButton>(find.byType(GradientButton));

GradientButton _submitButton(WidgetTester tester) =>
    tester.widget<GradientButton>(find.byType(GradientButton));

Future<void> _pumpDetail(WidgetTester tester, EntryChain chain) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.themeData,
    home: EntryDetailScreen(chain: chain),
  ));
  await tester.pump();

  // 이의 제기 버튼은 화면 맨 아래에 있다. `ListView` 는 보이는 만큼만 만들기
  // 때문에 스크롤해서 끌어올리지 않으면 트리에 아예 없다.
  await tester.dragUntilVisible(
    find.byType(GradientButton),
    find.byType(Scrollable).first,
    const Offset(0, -300),
  );
  await tester.pump();
}

Future<void> _pumpObjection(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.themeData,
    home: ObjectionScreen(entry: _entry(EntryStatus.CONFIRMED)),
  ));
  await tester.pump();
}

EntryChain _chain(EntryStatus status) =>
    EntryChain(original: _entry(status));

EntryModel _entry(EntryStatus status) {
  final occurredAt = Hashing.kstMidnightOf(2026, 9, 20);
  return EntryModel(
    id: 31,
    termId: 1,
    kind: EntryKind.EXPENSE,
    amount: 35000,
    counterparty: '한결문구',
    purpose: '신입생 환영회 문구류',
    occurredAt: occurredAt,
    metaHash: Hashing.metaHash(
      amount: 35000,
      counterparty: '한결문구',
      purpose: '신입생 환영회 문구류',
      occurredAt: occurredAt,
    ),
    status: status,
    createdBy: 2,
    approvedBy: status == EntryStatus.CONFIRMED ? 3 : null,
  );
}
