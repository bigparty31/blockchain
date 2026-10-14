import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/budget_plan.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/router.dart';
import 'package:student_council_app/screens/president/budget_plan_screen.dart';
import 'package:student_council_app/services/budget_issuer.dart';

/// 예산 편성 화면(스토리보드 15)이 상태별로 제대로 그려지고 동작하는지 본다.
///
/// 규칙 자체(KST 환산·중복·한도)는 `budget_plan_test.dart` 가 본다. 여기서는
/// 규칙이 **화면에서 실제로 지켜지는지**, 즉 사용자가 누르는 흐름을 본다.
void main() {
  DateTime fixedNow() => DateTime.utc(2026, 10, 6, 3); // 2026-10-06 12:00 KST

  /// 화면을 띄운다. 높이를 크게 잡아 카드가 여러 장이어도 ListView 가 다 그리게 한다.
  Future<FakeBudgetIssuer> pumpScreen(
    WidgetTester tester, {
    UserRole role = UserRole.PRESIDENT,
    FakeBudgetIssuer? issuer,
    double width = 411,
    double scale = 1.0,
    VoidCallback? onConnectWallet,
  }) async {
    tester.view.physicalSize = Size(width, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fake = issuer ?? FakeBudgetIssuer(delay: const Duration(milliseconds: 100));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: BudgetPlanScreen(
          role: role,
          issuer: fake,
          clock: fixedNow,
          onConnectWallet: onConnectWallet,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return fake;
  }

  ElevatedButton confirmButton(WidgetTester tester) =>
      tester.widget<ElevatedButton>(find.byWidgetPredicate((w) => w is ElevatedButton));

  Future<void> addCard(WidgetTester tester) async {
    await tester.tap(find.text('항목 추가'));
    await tester.pumpAndSettle();
  }

  /// [index] 번째 카드를 사용자가 하는 그대로 채운다: 카테고리 고르기 → 금액 입력 → 마감일 고르기.
  /// 카드를 차례대로 채운다고 가정한다(아직 안 채운 「마감일 선택」이 맨 앞에 있어야 한다).
  Future<void> fillCard(WidgetTester tester, int index, {required String category, required String amount}) async {
    await tester.tap(find.byType(DropdownButton<BudgetCategory>).at(index));
    await tester.pumpAndSettle();
    await tester.tap(find.text(category).last);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(index), amount);
    await tester.pumpAndSettle();

    await tester.tap(find.text('마감일 선택').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // 달력은 오늘+30일을 미리 골라 둔다
    await tester.pumpAndSettle();
  }

  Future<void> pressConfirmAndAccept(WidgetTester tester) async {
    await tester.tap(find.text('편성 확정'));
    await tester.pumpAndSettle();
    expect(find.text('확정하면 수정할 수 없어요'), findsOneWidget);
    await tester.tap(find.text('확정'));
  }

  group('기본 상태', () {
    testWidgets('처음엔 「항목을 추가하세요」와 회색 확정 버튼, 가짜 발행 배너가 보인다', (tester) async {
      await pumpScreen(tester);

      expect(find.text('예산 편성'), findsOneWidget); // 앱바
      expect(find.text('항목을 추가하세요'), findsOneWidget);
      expect(confirmButton(tester).onPressed, isNull);
      expect(find.text('가짜 발행입니다'), findsOneWidget);
    });

    testWidgets('항목 추가는 카테고리 수(8)까지만 된다', (tester) async {
      await pumpScreen(tester);
      for (var i = 0; i < 8; i++) {
        await addCard(tester);
      }
      expect(find.byType(DropdownButton<BudgetCategory>), findsNWidgets(8));

      final addButton = tester.widget<OutlinedButton>(find.byWidgetPredicate((w) => w is OutlinedButton));
      expect(addButton.onPressed, isNull);
    });

    testWidgets('감사 계정에는 편성 화면 대신 안내만 보인다', (tester) async {
      await pumpScreen(tester, role: UserRole.AUDITOR);

      expect(find.text('예산 편성은 학생회장만 할 수 있어요'), findsOneWidget);
      expect(find.text('편성 확정'), findsNothing);
      expect(find.text('항목 추가'), findsNothing);
    });
  });

  group('편성 흐름', () {
    testWidgets('채워야 확정이 켜지고, 확정하면 발행되어 읽기 전용이 된다', (tester) async {
      final issuer = await pumpScreen(tester);
      await addCard(tester);
      expect(confirmButton(tester).onPressed, isNull); // 빈 카드가 있으면 회색

      await fillCard(tester, 0, category: '행사비', amount: '2500000');
      expect(find.text('₩ 2,500,000'), findsOneWidget); // 입력한 금액을 읽기 쉽게 다시 보여준다
      expect(confirmButton(tester).onPressed, isNotNull);

      await pressConfirmAndAccept(tester);
      await tester.pump(); // 팝업이 닫히고 발행이 시작된다
      await tester.pump(const Duration(milliseconds: 20));

      // 발행 중 — 입력·추가·확정이 잠긴다 (스토리보드 15 D)
      expect(find.text('온체인에 기록하는 중이에요'), findsOneWidget);
      expect(find.text('처리 중...'), findsOneWidget);
      expect(confirmButton(tester).onPressed, isNull);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);

      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      // 확정 후 — 읽기 전용 (스토리보드 15 E): 추가·확정 버튼이 사라지고 카드가 잠긴다
      expect(find.text('예산이 확정됐어요'), findsOneWidget);
      expect(find.text('항목 추가'), findsNothing);
      expect(find.text('편성 확정'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(find.byTooltip('항목 삭제'), findsNothing);
      expect(issuer.sent, [BudgetCategory.event]);
    });

    testWidgets('확정 팝업에서 취소하면 아무것도 발행되지 않는다', (tester) async {
      final issuer = await pumpScreen(tester);
      await addCard(tester);
      await fillCard(tester, 0, category: '행사비', amount: '1000000');

      await tester.tap(find.text('편성 확정'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();

      expect(issuer.callCount, 0);
      expect(find.text('예산이 확정됐어요'), findsNothing);
      expect(confirmButton(tester).onPressed, isNotNull);
    });

    testWidgets('이미 고른 카테고리는 다른 카드의 목록에서 빠진다', (tester) async {
      await pumpScreen(tester);
      await addCard(tester);
      await fillCard(tester, 0, category: '행사비', amount: '1000000');
      await addCard(tester);

      await tester.tap(find.byType(DropdownButton<BudgetCategory>).at(1));
      await tester.pumpAndSettle();

      // 열린 목록(오버레이)에는 행사비가 없고 나머지 7종이 있다. 첫 카드가 보여주는 「행사비」 글자는 목록과 별개다.
      expect(find.text('사업비'), findsOneWidget);
      expect(find.text('예비비'), findsOneWidget);
      expect(find.text('행사비'), findsOneWidget); // 첫 카드에 보이는 선택값 하나뿐
    });

    testWidgets('삭제는 확인 팝업을 거친다', (tester) async {
      await pumpScreen(tester);
      await addCard(tester);

      await tester.tap(find.byTooltip('항목 삭제'));
      await tester.pumpAndSettle();
      expect(find.text('이 항목을 삭제할까요?'), findsOneWidget);

      await tester.tap(find.text('삭제'));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButton<BudgetCategory>), findsNothing);
      expect(find.text('항목을 추가하세요'), findsOneWidget);
    });
  });

  group('실패 경로', () {
    testWidgets('지갑이 없으면 안내와 「지갑 연결하기」가 뜨고, 연결 후 다시 확정할 수 있다', (tester) async {
      final issuer = FakeBudgetIssuer(delay: const Duration(milliseconds: 50), walletConnected: false);
      var connectTaps = 0;
      await pumpScreen(tester, issuer: issuer, onConnectWallet: () {
        connectTaps++;
        issuer.walletConnected = true; // 지갑 모듈이 없어서 가짜 발행기의 스위치를 켜는 걸로 대신한다
      });
      await addCard(tester);
      await fillCard(tester, 0, category: '행사비', amount: '1000000');

      await pressConfirmAndAccept(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(find.text('회장 지갑이 연결되지 않았어요'), findsOneWidget);
      expect(find.text('예산이 확정됐어요'), findsNothing);
      expect(issuer.sent, isEmpty); // 한 줄도 나가지 않았다
      expect(confirmButton(tester).onPressed, isNotNull); // 입력은 그대로고 다시 누를 수 있다

      await tester.tap(find.text('지갑 연결하기'));
      await tester.pumpAndSettle();
      expect(connectTaps, 1);

      await pressConfirmAndAccept(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(find.text('예산이 확정됐어요'), findsOneWidget);
      expect(find.text('회장 지갑이 연결되지 않았어요'), findsNothing);
    });

    testWidgets('지갑 모듈이 없으면 「지갑 연결하기」는 준비 중이라고 알려준다', (tester) async {
      await pumpScreen(tester, issuer: FakeBudgetIssuer(walletConnected: false));
      await addCard(tester);
      await fillCard(tester, 0, category: '행사비', amount: '1000000');
      await pressConfirmAndAccept(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('지갑 연결하기'));
      await tester.pump();

      expect(find.text('지갑 연결 기능은 아직 준비 중이에요'), findsOneWidget);
    });

    testWidgets('일부만 성공하면 성공한 줄은 잠기고 안내가 뜬다', (tester) async {
      final issuer = FakeBudgetIssuer(forcedOutcomes: {
        BudgetCategory.project: const BudgetIssueOutcome(BudgetIssueStatus.rejected, message: '체인이 거부했어요'),
      });
      await pumpScreen(tester, issuer: issuer);
      await addCard(tester);
      await fillCard(tester, 0, category: '행사비', amount: '1000000');
      await addCard(tester);
      await fillCard(tester, 1, category: '사업비', amount: '500000');

      await pressConfirmAndAccept(tester);
      await tester.pumpAndSettle();

      expect(find.text('일부만 발행됐어요'), findsOneWidget);
      expect(find.textContaining('체인이 거부했어요'), findsOneWidget);
      expect(find.text('발행됨'), findsOneWidget);
      // 첫 카드(발행됨)는 잠기고 둘째 카드(거부됨)만 고칠 수 있다
      final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields[0].enabled, isFalse);
      expect(fields[1].enabled, isTrue);
      expect(confirmButton(tester).onPressed, isNotNull);
    });

    testWidgets('응답이 없으면 확정 버튼이 잠긴다', (tester) async {
      final issuer = FakeBudgetIssuer(forcedOutcomes: {
        BudgetCategory.event: BudgetIssueOutcome.noResponse,
      });
      await pumpScreen(tester, issuer: issuer);
      await addCard(tester);
      await fillCard(tester, 0, category: '행사비', amount: '1000000');

      await pressConfirmAndAccept(tester);
      await tester.pumpAndSettle();

      expect(find.text('응답이 없는 항목이 있어요'), findsOneWidget);
      expect(confirmButton(tester).onPressed, isNull);
    });

    testWidgets('발행 중에는 뒤로 나갈 수 없고, 끝나면 나갈 수 있다', (tester) async {
      tester.view.physicalSize = const Size(411, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final issuer = FakeBudgetIssuer(delay: const Duration(milliseconds: 100));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => BudgetPlanScreen(role: UserRole.PRESIDENT, issuer: issuer, clock: fixedNow),
                    ),
                  ),
                  child: const Text('열기'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      await addCard(tester);
      await fillCard(tester, 0, category: '행사비', amount: '1000000');

      await pressConfirmAndAccept(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('온체인에 기록하는 중이에요'), findsOneWidget);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      await navigator.maybePop();
      await tester.pump();
      expect(find.text('온체인에 기록하는 중이에요'), findsOneWidget, reason: '발행 중에는 화면이 닫히면 안 된다');

      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      await navigator.maybePop();
      await tester.pumpAndSettle();
      expect(find.text('예산 편성'), findsNothing, reason: '발행이 끝나면 나갈 수 있다');
    });
  });

  group('라우터', () {
    Future<Widget?> built(WidgetTester tester, Object? arguments) async {
      late BuildContext context;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        context = c;
        return const SizedBox();
      })));
      final route = AppRouter.onGenerateRoute(
        RouteSettings(name: AppRoutes.presidentBudgetPlan, arguments: arguments),
      );
      return (route! as MaterialPageRoute<dynamic>).builder(context);
    }

    testWidgets('UserRole 인자로 예산 편성 화면을 만든다', (tester) async {
      final widget = await built(tester, UserRole.PRESIDENT);
      expect(widget, isA<BudgetPlanScreen>());
      expect((widget! as BudgetPlanScreen).role, UserRole.PRESIDENT);
    });

    testWidgets('인자가 없거나 틀리면 오류 화면을 띄운다 — 조용히 기본값으로 대체하지 않는다', (tester) async {
      expect(await built(tester, null), isNot(isA<BudgetPlanScreen>()));
      expect(await built(tester, 'PRESIDENT'), isNot(isA<BudgetPlanScreen>()));
    });
  });

  group('좁은 폰·큰 글자에서 넘치지 않는다', () {
    const widths = [320.0, 360.0];
    const scales = [1.0, 1.5];

    for (final width in widths) {
      for (final scale in scales) {
        testWidgets('폭 ${width.toInt()}dp · 글자 ${(scale * 100).toInt()}% — 빈 화면부터 확정 후까지', (tester) async {
          void expectNoOverflow(String where) {
            final e = tester.takeException();
            expect(e, isNull, reason: '$where 에서 넘침: $e');
          }

          final issuer = FakeBudgetIssuer(
            delay: const Duration(milliseconds: 50),
            forcedOutcomes: {
              BudgetCategory.project: const BudgetIssueOutcome(BudgetIssueStatus.rejected, message: '체인이 거부했어요'),
            },
          );
          await pumpScreen(tester, issuer: issuer, width: width, scale: scale);
          expectNoOverflow('빈 화면');

          await addCard(tester);
          await fillCard(tester, 0, category: '행사비', amount: '2500000');
          await addCard(tester);
          await fillCard(tester, 1, category: '사업비', amount: '1500000');
          expectNoOverflow('카드 두 장');

          await tester.tap(find.text('편성 확정'));
          await tester.pumpAndSettle();
          expectNoOverflow('확정 팝업');

          await tester.tap(find.text('확정'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 20));
          expectNoOverflow('발행 중');

          await tester.pump(const Duration(milliseconds: 200));
          await tester.pumpAndSettle();
          expectNoOverflow('일부만 성공');
        });
      }
    }
  });
}
