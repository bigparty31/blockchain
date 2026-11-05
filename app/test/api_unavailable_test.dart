import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/screens/council/budget_revision_screen.dart';
import 'package:student_council_app/screens/council/correction_screen.dart';
import 'package:student_council_app/screens/council/council_home_screen.dart';
import 'package:student_council_app/screens/council/expense_create_screen.dart';
import 'package:student_council_app/screens/council/registration_result.dart';
import 'package:student_council_app/services/api_service.dart';
import 'package:student_council_app/services/auth_service.dart';

/// **조회가 실패하면 실패로 보여 준다. 더미 값으로 덮지 않는다** (PRD v0.14 §7.3).
///
/// 덮으면 서버가 죽어도 더미 건이 화면에 보이고, 임원이 그 건에 서명하게 된다.
/// 시연용 더미는 개발 빌드(`DEV_TOOLS`)에서만 켠다 — 발표·배포 빌드의 기본값이 꺼짐이다.
void main() {
  setUp(() {
    ApiService.useDemoData = false;
    ApiService.client = MockClient((_) async => http.Response('{}', 503));
  });

  tearDown(() => ApiService.client = http.Client());

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(411, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: home));
    await tester.pumpAndSettle();
  }

  group('ApiService', () {
    test('발표·배포 빌드의 기본값은 더미를 쓰지 않는 것이다', () {
      // 테스트 실행은 DEV_TOOLS 없이 하므로, 기본값이 그대로 false 여야 한다.
      expect(const bool.fromEnvironment('DEV_TOOLS'), isFalse);
    });

    test('서버 오류면 더미 대신 ApiUnavailable', () async {
      await expectLater(ApiService().fetchEntries(), throwsA(isA<ApiUnavailable>()));
      await expectLater(ApiService().fetchBudgets(), throwsA(isA<ApiUnavailable>()));
      await expectLater(ApiService().fetchBalance(), throwsA(isA<ApiUnavailable>()));
    });

    test('연결 실패도 마찬가지', () async {
      ApiService.client = MockClient((_) async => throw http.ClientException('연결 실패'));
      await expectLater(ApiService().fetchEntries(), throwsA(isA<ApiUnavailable>()));
    });

    test('개발 빌드처럼 더미를 켜면 더미를 돌려준다', () async {
      ApiService.useDemoData = true;
      expect(await ApiService().fetchBudgets(), isNotEmpty);
    });

    test('예산을 못 읽으면 등록 결과를 흉내 내지 않는다 — 통과로 간주하지 않는다', () async {
      await expectLater(
        simulateExpenseRegistration(category: '행사비', amount: 1000),
        throwsA(isA<ApiUnavailable>()),
      );
    });
  });

  group('401 · 403', () {
    /// 가짜 서버로 로그인해 토큰을 갖게 한다 (`logout_test.dart` 와 같은 방식).
    Future<void> login() async {
      AuthService.store = MemoryTokenStore();
      AuthService().resetAttempts();
      http.Response json(Object body) =>
          http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      AuthService.client = MockClient((req) async => req.url.path == '/auth/login'
          ? json({'access_token': 'token-auditor', 'token_type': 'bearer', 'role': 'AUDITOR', 'name': '감사'})
          : json({'id': 3, 'student_no': '20240003', 'name': '감사', 'role': 'AUDITOR'}));
      await AuthService().login('20240003', 'userPassword123!');
    }

    tearDown(() async {
      AuthService().onUnauthorized = null;
      await AuthService().logout();
      AuthService.client = http.Client();
    });

    test('로그인 토큰을 붙여 보낸다', () async {
      await login();
      String? auth;
      ApiService.client = MockClient((req) async {
        auth = req.headers['Authorization'];
        return http.Response('[]', 200);
      });
      await ApiService().fetchEntries();
      expect(auth, 'Bearer token-auditor');
    });

    test('403 은 권한 없음이다 — 개발 빌드여도 더미로 메우지 않는다', () async {
      ApiService.useDemoData = true;
      ApiService.client = MockClient((_) async => http.Response('{}', 403));
      await expectLater(
        ApiService().fetchEntries(),
        throwsA(isA<ApiForbidden>().having((e) => e.message, 'message', '이 작업을 할 권한이 없어요.')),
      );
      expect(await ApiService().fetchPendingCount(), isNull);
    });

    test('401 은 세션을 비우고 로그인 화면으로 보낸다', () async {
      await login();
      var sentToLogin = false;
      AuthService().onUnauthorized = () => sentToLogin = true;
      ApiService.useDemoData = true;
      ApiService.client = MockClient((_) async => http.Response('{}', 401));

      await expectLater(ApiService().fetchBudgets(), throwsA(isA<ApiUnauthorized>()));
      expect(AuthService().session, isNull);
      expect(sentToLogin, isTrue);
    });

    testWidgets('화면은 403 이유를 그대로 적는다', (tester) async {
      ApiService.client = MockClient((_) async => http.Response('{}', 403));
      await pump(tester, const CouncilHomeScreen(role: UserRole.TREASURER));
      // 내 등록 현황과 장부 잔액 둘 다 403 이다 — 둘 다 「권한 없음」으로 적는다.
      expect(find.text('이 작업을 할 권한이 없어요.'), findsNWidgets(2));
      expect(tester.widget<Text>(find.byKey(const Key('balance_failed'))).data, '이 작업을 할 권한이 없어요.');
    });
  });

  group('화면', () {
    testWidgets('총무 홈 — 내 등록 건을 0 건으로 적지 않고 못 읽었다고 적는다', (tester) async {
      await pump(tester, const CouncilHomeScreen(role: UserRole.TREASURER));
      expect(find.byKey(const Key('my_entry_status_failed')), findsOneWidget);
      expect(find.text('대기 -'), findsOneWidget);
      expect(find.text('대기 0'), findsNothing);
    });

    testWidgets('총무·감사 홈 — 장부 잔액을 지어내지 않고 못 읽었다고 적는다', (tester) async {
      await pump(tester, const CouncilHomeScreen(role: UserRole.AUDITOR));
      expect(find.byKey(const Key('balance_failed')), findsOneWidget);
      expect(find.text('₩ 4,965,000'), findsNothing);
    });

    testWidgets('지출 등록 — 예산 잔량을 못 읽었다고 적는다', (tester) async {
      await pump(tester, const ExpenseCreateScreen());
      expect(find.byKey(const Key('budgets_failed')), findsOneWidget);
    });

    testWidgets('예산 개정 요청 — 예산 목록을 못 읽었다고 적고 다시 시도할 수 있다', (tester) async {
      await pump(tester, const BudgetRevisionScreen());
      expect(find.byKey(const Key('budgets_failed')), findsOneWidget);

      ApiService.useDemoData = true; // 서버가 돌아온 것처럼
      await tester.tap(find.text('다시 시도'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('budgets_failed')), findsNothing);
    });

    testWidgets('정정 등록 — 내역을 못 읽은 것을 「없는 내역」으로 적지 않는다', (tester) async {
      await pump(tester, const CorrectionScreen());
      await tester.enterText(find.widgetWithText(TextFormField, '정정 대상 내역 ID (Entry ID) *'), '1');
      await tester.tap(find.text('내역 조회'));
      await tester.pumpAndSettle();
      expect(find.textContaining('내역을(를) 불러오지 못했어요'), findsOneWidget);
    });
  });
}
