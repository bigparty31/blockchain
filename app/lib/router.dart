import 'package:flutter/material.dart';
import 'core/entry_merge.dart';
import 'core/enums.dart';
import 'models/entry_model.dart';
import 'screens/council/approval_list_screen.dart';
import 'screens/council/correction_screen.dart';
import 'screens/council/council_home_screen.dart';
import 'screens/council/expense_create_screen.dart';
import 'screens/council/hardware_test_screen.dart';
import 'screens/council/income_create_screen.dart';
import 'screens/council/inquiry_response_screen.dart';
import 'screens/student/entry_detail_screen.dart';
import 'screens/student/entry_list_screen.dart';
import 'screens/student/my_sbt_screen.dart';
import 'screens/student/objection_screen.dart';
import 'screens/student/student_home_screen.dart';

/// 화면 라우트 이름 — **공용 파일**. 화면을 추가할 때 여기에 한 줄과 [AppRouter] 에 한 case 를 더한다.
///
/// 이름을 미리 다 등록해 두면 이후 화면 작업이 이 파일을 고치지 않아도 되어 병합 충돌이 없다
/// (1주차 계획서 「공통 규칙」). 로그인 화면은 `main.dart` 의 `home` 이라 여기에 두지 않는다.
///
/// 인자가 필요한 화면은 `Navigator.pushNamed(context, name, arguments: ...)` 로 넘긴다.
class AppRoutes {
  AppRoutes._();

  // ── 학생 (screens/student/) ─────────────────────────────────
  /// 학생 홈. 인자 없음
  static const studentHome = '/student';

  /// 내역 목록. 인자 없음
  static const studentEntries = '/student/entries';

  /// 내역 상세. 인자: [EntryChain]
  static const studentEntryDetail = '/student/entries/detail';

  /// 이의 제기. 인자: [EntryModel]
  static const studentObjection = '/student/objection';

  /// 내 SBT·QR. 인자 없음
  static const studentSbt = '/student/sbt';

  // ── 총무·감사 (screens/council/) ────────────────────────────
  /// 총무·감사 홈. 인자: [UserRole] (없으면 총무)
  static const councilHome = '/council';

  /// 지출 등록. 인자 없음
  static const councilExpense = '/council/expense';

  /// 수입 등록. 인자 없음
  static const councilIncome = '/council/income';

  /// 승인 목록. 인자 없음
  static const councilApprovals = '/council/approvals';

  /// 정정 신청. 인자 없음
  static const councilCorrections = '/council/corrections';

  /// 학생 이의 답변. 인자 없음
  static const councilInquiries = '/council/inquiries';

  /// 카메라·생체인증 실기 테스트. 인자 없음
  static const councilHardwareTest = '/council/hardware-test';
}

/// `MaterialApp.onGenerateRoute` 에 연결하는 라우터.
///
/// 이름을 모르는 경로는 null 을 돌려주므로 Flutter 기본 동작(`onUnknownRoute`)으로 넘어간다.
/// 인자 타입이 틀리면 화면 대신 오류 화면을 띄운다 — 조용히 기본값으로 대체하지 않는다.
class AppRouter {
  AppRouter._();

  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    final args = settings.arguments;

    switch (settings.name) {
      // 학생
      case AppRoutes.studentHome:
        return _page(settings, (_) => const StudentHomeScreen());
      case AppRoutes.studentEntries:
        return _page(settings, (_) => const EntryListScreen());
      case AppRoutes.studentEntryDetail:
        if (args is! EntryChain) return _badArguments(settings, 'EntryChain');
        return _page(settings, (_) => EntryDetailScreen(chain: args));
      case AppRoutes.studentObjection:
        if (args is! EntryModel) return _badArguments(settings, 'EntryModel');
        return _page(settings, (_) => ObjectionScreen(entry: args));
      case AppRoutes.studentSbt:
        return _page(settings, (_) => const MySbtScreen());

      // 총무·감사
      case AppRoutes.councilHome:
        if (args != null && args is! UserRole) return _badArguments(settings, 'UserRole');
        final role = args as UserRole? ?? UserRole.TREASURER;
        return _page(settings, (_) => CouncilHomeScreen(role: role));
      case AppRoutes.councilExpense:
        return _page(settings, (_) => const ExpenseCreateScreen());
      case AppRoutes.councilIncome:
        return _page(settings, (_) => const IncomeCreateScreen());
      case AppRoutes.councilApprovals:
        return _page(settings, (_) => const ApprovalListScreen());
      case AppRoutes.councilCorrections:
        return _page(settings, (_) => const CorrectionScreen());
      case AppRoutes.councilInquiries:
        return _page(settings, (_) => const InquiryResponseScreen());
      case AppRoutes.councilHardwareTest:
        return _page(settings, (_) => const HardwareTestScreen());
    }
    return null;
  }

  static MaterialPageRoute<dynamic> _page(RouteSettings settings, WidgetBuilder builder) {
    return MaterialPageRoute<dynamic>(settings: settings, builder: builder);
  }

  static MaterialPageRoute<dynamic> _badArguments(RouteSettings settings, String expected) {
    return _page(
      settings,
      (_) => Scaffold(
        appBar: AppBar(title: const Text('화면을 열 수 없어요')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '${settings.name} 에는 $expected 인자가 필요합니다.\n'
              '(받은 값: ${settings.arguments.runtimeType})',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
