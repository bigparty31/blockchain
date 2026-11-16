import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/logout_action.dart';
import 'package:student_council_app/core/role_home.dart';
import 'package:student_council_app/screens/login_screen.dart';
import 'package:student_council_app/services/api_service.dart';
import 'package:student_council_app/services/auth_service.dart';
import 'package:student_council_app/services/student_api_service.dart';

/// 로그아웃 — 작성지침에 없는 동작이라 여기가 유일한 규격이다.
///
/// 지키는 것 세 가지:
///   1. 확인하지 않으면 아무 일도 일어나지 않는다
///   2. 토큰이 **기기에서 지워진다** (세션만 비우면 앱을 다시 켤 때 되살아난다)
///   3. 쌓인 화면이 모두 버려진다 (뒤로 가서 로그아웃 전 화면으로 못 돌아간다)
void main() {
  late MemoryTokenStore store;

  /// 로그인·내정보에 응답하는 가짜 서버.
  MockClient authServer(String role) {
    return MockClient((req) async {
      if (req.url.path == '/auth/login') {
        return http.Response(
          jsonEncode({
            'access_token': 'token-abc',
            'token_type': 'bearer',
            'role': role,
            'name': '김학생',
            'wallet_address': null,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (req.url.path == '/auth/me') {
        return http.Response(
          jsonEncode({'id': 1, 'student_no': '20240001', 'name': '김학생', 'role': role}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 404);
    });
  }

  /// 홈 화면이 실제 네트워크를 타지 않게 막는다 (`login_screen_test.dart` 와 같은 이유).
  ///
  /// 총무·감사 홈도 승인 대기 건수를 읽으므로 [ApiService] 까지 막아야 한다.
  void stubScreens() {
    final empty = MockClient((req) async {
      final body = req.url.path == '/entries' || req.url.path == '/budgets' ? '[]' : '{}';
      return http.Response(body, 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    StudentApiService.client = empty;
    ApiService.client = empty;
  }

  setUp(() async {
    store = MemoryTokenStore();
    AuthService.store = store;
    // 잠금 보관소도 갈아끼운다 — 기본값은 `flutter_secure_storage` 라
    // 테스트에서 플랫폼 채널이 응답하지 않는다.
    AuthService.lockStore = MemoryLoginLockStore();
    await AuthService().resetAttempts();
    AuthService().onUnauthorized = null;
    stubScreens();
  });

  tearDown(() async {
    await AuthService().logout();
    AuthService.client = http.Client();
    StudentApiService.client = http.Client();
    ApiService.client = http.Client();
  });

  /// 로그인한 상태에서 역할별 홈을 띄운다.
  Future<void> pumpLoggedIn(WidgetTester tester, UserRole role) async {
    AuthService.client = authServer(role.code);
    await AuthService().login('20240001', 'userPassword123!');
    expect(AuthService().session, isNotNull, reason: '로그인이 안 된 상태로 테스트를 시작했다');
    expect(store.value?.token, 'token-abc');

    await tester.pumpWidget(MaterialApp(home: homeScreenFor(role)));
    // 홈 화면의 조회 Future 는 가짜 시계에서 끝나지 않아 pumpAndSettle 을 쓰지 않는다.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  for (final role in UserRole.values) {
    testWidgets('${role.label} 홈에 로그아웃 버튼이 있다', (tester) async {
      await pumpLoggedIn(tester, role);
      expect(
        find.byKey(const Key('logout_action')),
        findsOneWidget,
        reason: '${role.label} 화면에 로그아웃이 없으면 그 기기의 세션을 끊을 방법이 없다',
      );
      // 공용 위젯이어야 한다 — 화면마다 따로 구현하면 한쪽만 고쳐진다.
      expect(find.byType(LogoutAction), findsOneWidget);
    });
  }

  testWidgets('취소하면 세션과 토큰이 그대로다', (tester) async {
    await pumpLoggedIn(tester, UserRole.STUDENT);

    await tester.tap(find.byKey(const Key('logout_action')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(find.text('취소'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(AuthService().session, isNotNull);
    expect(store.value?.token, 'token-abc', reason: '취소했는데 토큰이 지워졌다');
    expect(find.byType(LoginScreen), findsNothing);
  });

  testWidgets('바깥을 눌러 닫아도 로그아웃되지 않는다', (tester) async {
    await pumpLoggedIn(tester, UserRole.STUDENT);

    await tester.tap(find.byKey(const Key('logout_action')));
    await tester.pump(const Duration(milliseconds: 400));

    // 모달 바깥(화면 맨 위) 탭
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(AlertDialog), findsNothing);
    expect(AuthService().session, isNotNull);
    expect(store.value?.token, 'token-abc');
  });

  testWidgets('확인하면 토큰을 지우고 로그인 화면으로 간다', (tester) async {
    await pumpLoggedIn(tester, UserRole.STUDENT);

    await tester.tap(find.byKey(const Key('logout_action')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('logout_confirm')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(AuthService().session, isNull);
    // 세션만 비우고 보관소를 두면 앱을 다시 켤 때 그 세션으로 되살아난다.
    expect(store.value?.token, isNull, reason: '기기에서 토큰이 지워지지 않았다');
    expect(AuthService().authHeaders, isEmpty);
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('임원도 토큰이 지워진다', (tester) async {
    await pumpLoggedIn(tester, UserRole.TREASURER);

    await tester.tap(find.byKey(const Key('logout_action')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('logout_confirm')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(store.value?.token, isNull, reason: '임원 세션이 남으면 다음 사람에게 승인 화면이 열린다');
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  /// 3차 리뷰 Low — 삭제 실패 경고가 두 번 뜬다.
  ///
  /// `confirmAndLogout` 이 스낵바를 띄우고 로그인 화면으로 보내면, 로그인 화면의
  /// `initState` 가 **같은 깃발**을 보고 같은 경고를 한 번 더 띄웠다. 사용자는
  /// 같은 말을 두 번 들으면 두 번 실패한 것으로 읽는다.
  testWidgets('삭제 실패 경고는 한 번만 뜬다', (tester) async {
    await pumpLoggedIn(tester, UserRole.STUDENT);
    store.failOnClear = true;

    await tester.tap(find.byKey(const Key('logout_action')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('logout_confirm')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(LoginScreen), findsOneWidget);
    // 화면 전환이 끝날 때까지는 같은 스낵바가 두 Scaffold 에 함께 들어가 있다
    // (`ScaffoldMessenger` 가 등록된 Scaffold 마다 넣는다). 개수로 세지 않는다.
    expect(
      find.textContaining('이 기기에서 로그인 정보를 지우지 못했습니다'),
      findsAtLeastNWidgets(1),
      reason: '지우지 못한 사실을 알리지 않았다',
    );
    expect(
      find.textContaining('이전 로그인 정보를 지우지 못했습니다'),
      findsNothing,
      reason: '로그인 화면이 같은 경고를 한 번 더 띄웠다',
    );
    expect(
      AuthService().tokenClearFailed,
      isFalse,
      reason: '우리가 직접 알렸으면 깃발을 내려야 한다 — 로그인 화면이 같은 경고를 또 띄운다',
    );

    // tearDown 의 logout 이 또 던지지 않게 되돌린다.
    store.failOnClear = false;

    // 첫 경고가 사라진 뒤, 로그인 화면이 뒤이어 같은 말을 또 하지 않는다.
    await tester.pump(const Duration(seconds: 7));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SnackBar), findsNothing, reason: '같은 경고가 한 번 더 떴다');
  });

  testWidgets('로그아웃 뒤에는 세션을 되살릴 수 없다', (tester) async {
    await pumpLoggedIn(tester, UserRole.STUDENT);

    await tester.tap(find.byKey(const Key('logout_action')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('logout_confirm')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // 앱을 다시 켠 것과 같다 — 보관소가 비었으므로 서버에 묻지도 않는다.
    expect(await AuthService().restore(), isNull);
  });
}
