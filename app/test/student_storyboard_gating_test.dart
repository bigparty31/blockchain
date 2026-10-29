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
/// **범위 한계** — 보유 여부가 `http` 조회 결과라 위젯 테스트의 가짜 시계
/// 아래에서는 그 Future 가 끝나지 않는다 (`student_layout_test.dart` 의 같은
/// 한계). 그래서 여기서 볼 수 있는 멤버십 상태는 「아직 모름」뿐이다.
/// 보유·미보유로 갈리는 판정은 `student_resilience_test.dart` 가
/// `canObject`·`objectionBlock` 을 직접 불러 못박는다.
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

    testWidgets('확정된 항목이어도 납부 확인 전에는 막혀 있다', (tester) async {
      await _pumpDetail(tester, _chain(EntryStatus.CONFIRMED));

      // 위젯 테스트의 가짜 시계 아래에서는 `fetchMyMembership` 의 Future 가 끝나지
      // 않아 멤버십이 계속 null — 즉 「아직 모름」이다. `canObject` 가 fail-closed
      // 라 이때는 막힌다.
      final button = _objectionButton(tester);
      expect(button.enabled, isFalse);
      expect(button.onPressed, isNotNull,
          reason: '눌러서 이유를 들을 수는 있어야 한다 (스토리보드 4 ⑤)');

      // **「납부 확인이 필요합니다」라고 말하지 않는다** — 조회가 안 됐을 뿐이다.
      expect(find.textContaining('확인할 수 없어'), findsOneWidget);
      expect(find.textContaining('납부가 확인되면'), findsNothing,
          reason: '모름을 미보유 문구로 안내하면 납부한 학생에게 거짓을 말한다');
      expect(find.text('다시 시도'), findsOneWidget,
          reason: '막는 데서 끝내면 서버가 돌아와도 학생은 길이 없다');
    });
  });

  group('이의 제출 버튼 (스토리보드 5 ③)', () {
    testWidgets('빈 본문에서는 회색이고 눌리지 않는다', (tester) async {
      await _pumpObjection(tester);

      final button = await _submitButton(tester);
      expect(button.enabled, isFalse);
      expect(button.onPressed, isNull);
    });

    testWidgets('공백만 쳐도 활성되지 않는다', (tester) async {
      await _pumpObjection(tester);

      await tester.enterText(find.byType(TextField), '   \n  ');
      await tester.pump();

      expect((await _submitButton(tester)).onPressed, isNull,
          reason: '공백만으로 제출되면 빈 이의가 접수된다');
    });

    testWidgets('내용을 치면 활성된다', (tester) async {
      await _pumpObjection(tester);

      await tester.enterText(find.byType(TextField), '금액 확인 부탁드립니다');
      await tester.pump();

      final button = await _submitButton(tester);
      expect(button.enabled, isTrue);
      expect(button.onPressed, isNotNull);
    });
  });

  group('이의 본문 최소 길이 (student_screens.md §2.4)', () {
    testWidgets('10자 미만이면 눌리지 않고, 왜인지 말해 준다', (tester) async {
      await _pumpObjection(tester);

      await tester.enterText(find.byType(TextField), '이상함');
      await tester.pump();

      // 안내 줄을 버튼보다 먼저 본다 — 버튼을 끌어올리면 위로 밀려 트리에서 빠진다.
      expect(find.textContaining('10자 이상'), findsOneWidget,
          reason: '회색 버튼만 두면 학생은 왜 안 눌리는지 알 길이 없다');
      expect((await _submitButton(tester)).onPressed, isNull,
          reason: '「이상함」 한 줄로는 학생회가 답할 수 없다');
    });

    testWidgets('딱 10자면 활성된다', (tester) async {
      await _pumpObjection(tester);

      await tester.enterText(find.byType(TextField), '열글자짜리이의본문');
      await tester.pump();
      expect((await _submitButton(tester)).onPressed, isNull,
          reason: '9자는 아직 막는다');

      await tester.enterText(find.byType(TextField), '열글자짜리이의본문요');
      await tester.pump();
      expect((await _submitButton(tester)).onPressed, isNotNull);
    });

    testWidgets('앞뒤 공백·개행으로 10자를 채울 수는 없다', (tester) async {
      await _pumpObjection(tester);

      // 정본화한 값으로 재기 때문에 앞뒤 공백은 길이에 안 들어간다
      // (backend_requests.md §1-3 — 검사는 canonicalText 로, 전송은 원문 그대로).
      // 「   \n  이상함\n   」 는 정본화하면 3자다.
      await tester.enterText(find.byType(TextField), '   \n  이상함\n   ');
      await tester.pump();

      expect((await _submitButton(tester)).onPressed, isNull);
    });

    testWidgets('비어 있을 때는 길이 안내를 띄우지 않는다', (tester) async {
      await _pumpObjection(tester);

      expect(find.textContaining('10자 이상'), findsNothing,
          reason: '아직 안 쓴 사람에게 경고처럼 보이면 안 된다');
    });
  });
}

/// 지출 상세에서 유일한 그라디언트 버튼이 이의 제기 버튼이다.
GradientButton _objectionButton(WidgetTester tester) =>
    tester.widget<GradientButton>(find.byType(GradientButton));

/// 이의 제기 화면에서 유일한 그라디언트 버튼이 제출 버튼이다.
///
/// **쓸 때마다 끌어올린다.** 본문 길이에 따라 「10자 이상 적어 주세요」 줄이
/// 붙었다 떨어져서 화면 높이가 바뀌는데, `ListView` 는 보이는 만큼만 만들기
/// 때문에 그 몇 픽셀 차이로 버튼이 트리에서 사라진다.
Future<GradientButton> _submitButton(WidgetTester tester) async {
  await tester.dragUntilVisible(
    find.byType(GradientButton),
    find.byType(Scrollable).first,
    const Offset(0, -300),
  );
  await tester.pump();
  return tester.widget<GradientButton>(find.byType(GradientButton));
}

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
