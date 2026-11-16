import 'package:flutter/material.dart';
import 'core/entry_merge.dart';
import 'core/enums.dart';
import 'models/entry_model.dart';
import 'services/auth_service.dart';
import 'screens/council/approval_list_screen.dart';
import 'screens/council/correction_screen.dart';
import 'screens/council/council_home_screen.dart';
import 'screens/council/expense_create_screen.dart';
import 'screens/council/hardware_test_screen.dart';
import 'screens/council/income_create_screen.dart';
import 'screens/council/inquiry_response_screen.dart';
import 'screens/council/settlement_screen.dart';
import 'screens/president/budget_plan_screen.dart';
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
  // 아래 임원 화면은 **로그인한 역할로만 열린다** ([AppRouter.onGenerateRoute]).
  // 라우트 인자로 받은 역할은 권한으로 믿지 않는다.

  /// 총무·감사·회장 홈. 인자: [UserRole] (선택 — 주면 로그인한 역할과 같아야 한다)
  static const councilHome = '/council';

  /// 지출 등록 (총무). 인자 없음
  static const councilExpense = '/council/expense';

  /// 수입 등록 (총무). 인자 없음
  static const councilIncome = '/council/income';

  /// 승인 목록 (감사·회장). 인자 없음
  static const councilApprovals = '/council/approvals';

  /// 정정 신청 (총무). 인자 없음
  static const councilCorrections = '/council/corrections';

  /// 학생 이의 답변 (감사·회장). 인자 없음
  static const councilInquiries = '/council/inquiries';

  /// 카메라·생체인증 실기 테스트 (임원). 인자 없음
  static const councilHardwareTest = '/council/hardware-test';

  /// 학기 결산 — 요약·예산 집행·메타지표 (감사·회장). 인자 없음
  static const councilSettlement = '/council/settlement';

  // ── 회장 (screens/president/) ───────────────────────────────
  /// 예산 편성 (임원). 인자: [UserRole] — 로그인한 역할과 같아야 한다.
  /// 회장이 아니면 화면이 안내만 보여준다.
  static const presidentBudgetPlan = '/president/budget';
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

      // 총무·감사·회장 — 권한은 로그인 세션으로 정한다
      case AppRoutes.councilHome:
        if (args != null && args is! UserRole) return _badArguments(settings, 'UserRole');
        final role = _sessionRole;
        // 인자는 「이 역할의 홈」이라는 요청일 뿐이다. 로그인한 역할과 다르면 열지 않는다.
        if (role == null || !_officers.contains(role) || (args != null && args != role)) {
          return _forbidden(settings);
        }
        return _page(settings, (_) => CouncilHomeScreen(role: role));
      case AppRoutes.councilExpense:
        return _guarded(settings, _treasurer, (_) => const ExpenseCreateScreen());
      case AppRoutes.councilIncome:
        return _guarded(settings, _treasurer, (_) => const IncomeCreateScreen());
      case AppRoutes.councilApprovals:
        return _guarded(settings, _approvers, (_) => const ApprovalListScreen());
      case AppRoutes.councilCorrections:
        return _guarded(settings, _treasurer, (_) => const CorrectionScreen());
      case AppRoutes.councilInquiries:
        return _guarded(settings, _approvers, (_) => const InquiryResponseScreen());
      case AppRoutes.councilHardwareTest:
        return _guarded(settings, _officers, (_) => const HardwareTestScreen());
      case AppRoutes.councilSettlement:
        return _guarded(settings, _approvers, (_) => const SettlementScreen());

      // 회장
      case AppRoutes.presidentBudgetPlan:
        if (args is! UserRole) return _badArguments(settings, 'UserRole');
        final role = _sessionRole;
        if (role == null || !_officers.contains(role) || args != role) return _forbidden(settings);
        return _page(settings, (_) => BudgetPlanScreen(role: role));
    }
    return null;
  }

  /// 지금 로그인한 역할. **임원 화면의 권한 근거는 이것뿐이다.**
  ///
  /// 라우트 인자로 받은 역할을 믿으면 학생이나 로그인하지 않은 상태에서도
  /// `pushNamed(AppRoutes.councilApprovals)` 한 줄로 임원 화면이 열린다.
  /// 쓰기 API 는 서버가 역할을 다시 확인하지만, 목업 화면은 로컬에서 성공 처리를 한다.
  static UserRole? get _sessionRole => AuthService().session?.role;

  static const _officers = {UserRole.TREASURER, UserRole.AUDITOR, UserRole.PRESIDENT};
  static const _treasurer = {UserRole.TREASURER};
  static const _approvers = {UserRole.AUDITOR, UserRole.PRESIDENT};

  /// [allowed] 역할로 로그인했을 때만 [builder] 화면을 연다. 아니면 [_forbidden].
  static MaterialPageRoute<dynamic> _guarded(
    RouteSettings settings,
    Set<UserRole> allowed,
    WidgetBuilder builder,
  ) {
    final role = _sessionRole;
    if (role == null || !allowed.contains(role)) return _forbidden(settings);
    return _page(settings, builder);
  }

  /// 로그인한 역할로는 열 수 없는 화면. 조용히 다른 화면으로 바꾸지 않고 이유를 적는다.
  static MaterialPageRoute<dynamic> _forbidden(RouteSettings settings) {
    return _page(
      settings,
      (_) => Scaffold(
        key: const Key('route_forbidden'),
        appBar: AppBar(title: const Text('화면을 열 수 없어요')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '이 화면을 열 권한이 없어요.\n로그인한 계정의 역할로는 열 수 없는 화면입니다.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
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
