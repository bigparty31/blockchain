import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/entry_merge.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/router.dart';
import 'package:student_council_app/screens/council/approval_list_screen.dart';
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

  group('인자가 필요 없는 화면', () {
    final cases = <String, Type>{
      AppRoutes.studentHome: StudentHomeScreen,
      AppRoutes.studentEntries: EntryListScreen,
      AppRoutes.studentSbt: MySbtScreen,
      AppRoutes.councilExpense: ExpenseCreateScreen,
      AppRoutes.councilIncome: IncomeCreateScreen,
      AppRoutes.councilApprovals: ApprovalListScreen,
      AppRoutes.councilCorrections: CorrectionScreen,
      AppRoutes.councilInquiries: InquiryResponseScreen,
      AppRoutes.councilHardwareTest: HardwareTestScreen,
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

    testWidgets('총무 홈은 역할을 받고, 없으면 총무다', (tester) async {
      final auditor = await buildOf(tester, AppRoutes.councilHome, UserRole.AUDITOR);
      expect((auditor as CouncilHomeScreen).role, UserRole.AUDITOR);

      final byDefault = await buildOf(tester, AppRoutes.councilHome);
      expect((byDefault as CouncilHomeScreen).role, UserRole.TREASURER);
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
