import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/entry_merge.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/router.dart';
import 'package:student_council_app/screens/council/approval_list_screen.dart';
import 'package:student_council_app/screens/council/budget_revision_approval_screen.dart';
import 'package:student_council_app/screens/council/correction_screen.dart';
import 'package:student_council_app/screens/council/council_home_screen.dart';
import 'package:student_council_app/screens/council/expense_create_screen.dart';
import 'package:student_council_app/screens/council/hardware_test_screen.dart';
import 'package:student_council_app/screens/council/income_create_screen.dart';
import 'package:student_council_app/screens/council/inquiry_response_screen.dart';
import 'package:student_council_app/screens/student/entry_detail_screen.dart';
import 'package:student_council_app/screens/student/entry_list_screen.dart';
import 'package:student_council_app/screens/student/my_sbt_screen.dart';
import 'package:student_council_app/screens/student/objection_screen.dart';
import 'package:student_council_app/screens/student/student_home_screen.dart';

import 'support/session.dart';

/// 라우트 이름을 미리 등록해 두는 공용 파일(`router.dart`)이 약속대로 동작하는지 본다.
///
/// 화면을 실제로 그리지 않고 라우트가 만드는 위젯의 종류만 확인한다
/// (학생·총무 화면은 서버 호출을 하므로 테스트에서 띄우지 않는다).
void main() {
  final entry = EntryModel(
    id: 1,
    termId: 1,
    kind: EntryKind.EXPENSE,
    amount: 35000,
    counterparty: '한결문구',
    purpose: '신입생 환영회 명찰 및 필기구 구매',
    occurredAt: 1788793200,
    metaHash: '0x24ae73988d927fb39f45eb6024e9ff8ffa19e8501603565bd82710ea8df4b937',
    status: EntryStatus.CONFIRMED,
    createdBy: 2,
  );

  /// 라우트가 만드는 첫 위젯. 화면을 그리지 않고 `builder` 만 호출한다.
  Future<Widget> buildOf(WidgetTester tester, String name, [Object? arguments]) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(home: Builder(builder: (c) {
        context = c;
        return const SizedBox();
      })),
    );
    final route = AppRouter.onGenerateRoute(RouteSettings(name: name, arguments: arguments));
    expect(route, isA<MaterialPageRoute<dynamic>>(), reason: name);
    return (route! as MaterialPageRoute<dynamic>).builder(context);
  }

  group('인자가 필요 없는 화면 (학생)', () {
    final cases = <String, Type>{
      AppRoutes.studentHome: StudentHomeScreen,
      AppRoutes.studentEntries: EntryListScreen,
      AppRoutes.studentSbt: MySbtScreen,
    };

    for (final e in cases.entries) {
      testWidgets('${e.key} → ${e.value}', (tester) async {
        final widget = await buildOf(tester, e.key);
        expect(widget.runtimeType, e.value);
      });
    }
  });

  group('인자가 있는 화면', () {
    testWidgets('내역 상세는 EntryChain 을 받는다', (tester) async {
      final chain = EntryChain(original: entry);
      final widget = await buildOf(tester, AppRoutes.studentEntryDetail, chain);
      expect(widget, isA<EntryDetailScreen>());
      expect((widget as EntryDetailScreen).chain, same(chain));
    });

    testWidgets('이의 제기는 EntryModel 을 받는다', (tester) async {
      final widget = await buildOf(tester, AppRoutes.studentObjection, entry);
      expect(widget, isA<ObjectionScreen>());
      expect((widget as ObjectionScreen).entry, same(entry));
    });

  });

  /// **임원 화면의 권한은 로그인 세션으로 정한다.** 라우트 인자로 받은 역할은 믿지 않는다 —
  /// 믿으면 학생·미로그인 상태에서도 `pushNamed` 한 줄로 임원 화면이 열린다.
  group('임원 화면 — 로그인한 역할로만 열린다', () {
    tearDown(signOutForTest);

    Future<void> expectForbidden(WidgetTester tester, Widget widget, String reason) async {
      await tester.pumpWidget(MaterialApp(home: widget));
      expect(find.textContaining('이 화면을 열 권한이 없어요.'), findsOneWidget, reason: reason);
    }

    /// 경로 → (화면, 열 수 있는 역할)
    final cases = <String, (Type, Set<UserRole>)>{
      AppRoutes.councilExpense: (ExpenseCreateScreen, {UserRole.TREASURER}),
      AppRoutes.councilIncome: (IncomeCreateScreen, {UserRole.TREASURER}),
      AppRoutes.councilCorrections: (CorrectionScreen, {UserRole.TREASURER}),
      AppRoutes.councilApprovals: (ApprovalListScreen, {UserRole.AUDITOR, UserRole.PRESIDENT}),
      AppRoutes.councilInquiries: (InquiryResponseScreen, {UserRole.AUDITOR, UserRole.PRESIDENT}),
      AppRoutes.councilHardwareTest: (HardwareTestScreen, {UserRole.TREASURER, UserRole.AUDITOR, UserRole.PRESIDENT}),
      AppRoutes.councilBudgetRevisions: (BudgetRevisionApprovalScreen, {UserRole.AUDITOR, UserRole.PRESIDENT}),
    };

    for (final e in cases.entries) {
      testWidgets('${e.key} → ${e.value.$1} (${e.value.$2.map((r) => r.code).join('·')} 만)', (tester) async {
        for (final role in [null, ...UserRole.values]) {
          if (role == null) {
            await signOutForTest();
          } else {
            await signInAs(role);
          }
          final widget = await buildOf(tester, e.key);
          final who = role?.code ?? '로그인 안 함';
          if (e.value.$2.contains(role)) {
            expect(widget.runtimeType, e.value.$1, reason: who);
          } else {
            await expectForbidden(tester, widget, who);
          }
        }
      });
    }

    testWidgets('홈은 로그인한 역할로 열린다 — 인자로 다른 역할을 주장할 수 없다', (tester) async {
      await signInAs(UserRole.AUDITOR);
      expect(((await buildOf(tester, AppRoutes.councilHome)) as CouncilHomeScreen).role, UserRole.AUDITOR);
      expect(
        ((await buildOf(tester, AppRoutes.councilHome, UserRole.AUDITOR)) as CouncilHomeScreen).role,
        UserRole.AUDITOR,
      );
      await expectForbidden(tester, await buildOf(tester, AppRoutes.councilHome, UserRole.PRESIDENT), '감사가 회장 홈 요청');

      await signInAs(UserRole.STUDENT);
      await expectForbidden(tester, await buildOf(tester, AppRoutes.councilHome, UserRole.TREASURER), '학생');

      await signOutForTest();
      await expectForbidden(tester, await buildOf(tester, AppRoutes.councilHome), '로그인 안 함');
    });
  });

  group('잘못된 요청', () {
    testWidgets('인자 타입이 틀리면 조용히 넘기지 않고 오류 화면을 띄운다', (tester) async {
      for (final bad in [
        (AppRoutes.studentEntryDetail, '문자열'),
        (AppRoutes.studentEntryDetail, null),
        (AppRoutes.studentObjection, 123),
        (AppRoutes.councilHome, '감사'),
      ]) {
        final widget = await buildOf(tester, bad.$1, bad.$2);
        await tester.pumpWidget(MaterialApp(home: widget));
        expect(find.text('화면을 열 수 없어요'), findsOneWidget, reason: '${bad.$1} / ${bad.$2}');
      }
    });

    test('모르는 이름은 null 을 돌려 Flutter 기본 처리(onUnknownRoute)로 넘긴다', () {
      expect(AppRouter.onGenerateRoute(const RouteSettings(name: '/없는-화면')), isNull);
      expect(AppRouter.onGenerateRoute(const RouteSettings(name: '/')), isNull);
    });
  });

  test('라우트 이름은 서로 겹치지 않는다', () {
    const names = [
      AppRoutes.studentHome,
      AppRoutes.studentEntries,
      AppRoutes.studentEntryDetail,
      AppRoutes.studentObjection,
      AppRoutes.studentSbt,
      AppRoutes.councilHome,
      AppRoutes.councilExpense,
      AppRoutes.councilIncome,
      AppRoutes.councilApprovals,
      AppRoutes.councilCorrections,
      AppRoutes.councilInquiries,
      AppRoutes.councilHardwareTest,
    ];
    expect(names.toSet().length, names.length);
  });
}
