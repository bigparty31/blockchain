import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/screens/login_screen.dart';
import 'package:student_council_app/services/auth_service.dart';
import 'package:student_council_app/services/student_api_service.dart';

/// 화면 1 로그인 — 작성지침 「1. 로그인」 요소 블록 ①~④ 를 못박는다.
///
/// 네트워크를 타지 않는다 ([AuthService.client] 주입). 실제 서버에 붙으면
/// 그 머신에 서버가 떠 있는지에 따라 결과가 갈린다
/// (`student_api_service.dart` 의 `client` 주석과 같은 이유).
void main() {
  late List<http.Request> sent;

  /// 로그인·내정보 두 경로에 응답하는 가짜 서버.
  MockClient server({
    int loginStatus = 200,
    String role = 'STUDENT',
    int meStatus = 200,
    bool offline = false,
  }) {
    return MockClient((req) async {
      sent.add(req);
      if (offline) throw http.ClientException('연결 실패');

      if (req.url.path == '/auth/login') {
        if (loginStatus != 200) {
          return http.Response(
            jsonEncode({'detail': '학번 또는 비밀번호가 올바르지 않습니다.'}),
            loginStatus,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
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
        if (meStatus != 200) return http.Response('{}', meStatus);
        return http.Response(
          jsonEncode({'id': 1, 'student_no': '20240001', 'name': '김학생', 'role': role}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }

      return http.Response('{}', 404);
    });
  }

  /// 로그인 성공 후 이동하는 화면(`StudentHomeScreen` 등)이 실제 네트워크를 타지
  /// 않게 막는다. 막지 않으면 그 화면의 조회가 3초씩 기다려 `pumpAndSettle` 이 넘어간다.
  void stubDestinationScreen() {
    StudentApiService.client = MockClient((req) async {
      // 목록·예산은 리스트, 그 밖은 빈 객체. 어느 쪽도 화면을 멈추게 하지 않는다.
      final body = req.url.path == '/entries' || req.url.path == '/budgets' ? '[]' : '{}';
      return http.Response(body, 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
  }

  setUp(() {
    sent = [];
    AuthService.store = MemoryTokenStore();
    AuthService().resetAttempts();
    AuthService().onUnauthorized = null;
  });

  tearDown(() async {
    await AuthService().logout();
    AuthService.client = http.Client();
    StudentApiService.client = http.Client();
  });

  Future<void> pumpLogin(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pump();
  }

  /// 로그인 성공 뒤에는 `pumpAndSettle` 을 쓰지 않는다.
  ///
  /// 이동한 화면(`StudentHomeScreen`)의 조회 Future 가 위젯 테스트의 가짜 시계
  /// 아래에서는 완료되지 않아 로딩 스피너가 계속 돌고, `pumpAndSettle` 은 멈출
  /// 프레임이 없어 시간 초과로 끝난다 (`student_layout_test.dart` 의 같은 이유).
  /// 두 번의 await(`/auth/login`, `/auth/me`)와 화면 전환 350ms 를 덮을 만큼만 돌린다.
  Future<void> pumpLoginRequest(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> enter(WidgetTester tester, String studentNo, String pw) async {
    await tester.enterText(find.byKey(const Key('login_student_no')), studentNo);
    await tester.enterText(find.byKey(const Key('login_password')), pw);
    await tester.pump();
  }

  group('③ 로그인 버튼 — 활성 조건', () {
    testWidgets('①② 중 하나라도 비면 누를 수 없다', (tester) async {
      // 401 로 둔다 — 이 테스트는 버튼 활성 조건만 보므로 성공해 화면을 떠나면 안 된다.
      AuthService.client = server(loginStatus: 401);
      await pumpLogin(tester);

      // 둘 다 빈 상태
      await tester.tap(find.byKey(const Key('login_submit')));
      await tester.pump();
      expect(sent, isEmpty, reason: '입력이 비었는데 로그인 요청이 나갔다');

      // 학번만
      await tester.enterText(find.byKey(const Key('login_student_no')), '20240001');
      await tester.pump();
      await tester.tap(find.byKey(const Key('login_submit')));
      await tester.pump();
      expect(sent, isEmpty, reason: '비밀번호가 비었는데 로그인 요청이 나갔다');

      // 비밀번호까지
      await tester.enterText(find.byKey(const Key('login_password')), 'userPassword123!');
      await tester.pump();
      await tester.tap(find.byKey(const Key('login_submit')));
      await tester.pumpAndSettle();
      expect(sent.where((r) => r.url.path == '/auth/login'), hasLength(1));
    });

    testWidgets('로딩 중에는 ①②가 잠기고 두 번 눌러도 한 번만 보낸다', (tester) async {
      // 응답을 붙잡아 두어 로딩 상태를 관찰한다.
      final gate = Completer<void>();
      AuthService.client = MockClient((req) async {
        sent.add(req);
        await gate.future;
        return http.Response(
          jsonEncode({'detail': '학번 또는 비밀번호가 올바르지 않습니다.'}),
          401,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      await pumpLogin(tester);
      await enter(tester, '20240001', 'userPassword123!');
      await tester.tap(find.byKey(const Key('login_submit')));
      await tester.pump();

      expect(find.text('로그인 중…'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(const Key('login_student_no'))).enabled,
        isFalse,
        reason: '로딩 중에는 입력이 잠겨야 한다',
      );
      expect(tester.widget<TextField>(find.byKey(const Key('login_password'))).enabled, isFalse);

      // 로딩 중 버튼은 사라졌지만, 남아 있었더라도 중복 호출은 막힌다
      expect(find.byKey(const Key('login_submit')), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      expect(sent.where((r) => r.url.path == '/auth/login'), hasLength(1));
    });

    testWidgets('학번을 보낸다 — block1 같은 아이디가 아니다', (tester) async {
      AuthService.client = server(loginStatus: 401);
      await pumpLogin(tester);
      await enter(tester, '20240001', 'userPassword123!');
      await tester.tap(find.byKey(const Key('login_submit')));
      await tester.pumpAndSettle();

      final login = sent.firstWhere((r) => r.url.path == '/auth/login');
      final body = jsonDecode(login.body) as Map<String, dynamic>;
      expect(body['student_no'], '20240001');
      expect(body['password'], 'userPassword123!', reason: '비밀번호를 서버로 보내지 않았다');
    });
  });

  group('③ 실패 (1) — 401', () {
    testWidgets('팝업이 뜨고, 어느 쪽이 틀렸는지 말하지 않는다', (tester) async {
      AuthService.client = server(loginStatus: 401);
      await pumpLogin(tester);
      await enter(tester, '20249999', 'wrong');
      await tester.tap(find.byKey(const Key('login_submit')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('학번 또는 비밀번호가 올바르지 않습니다.'), findsOneWidget);

      // 계정 존재 여부가 드러나는 문구가 없어야 한다 (작성지침 「화면 전체 규칙」).
      expect(find.textContaining('등록되지 않은'), findsNothing);
      expect(find.textContaining('비밀번호가 틀렸'), findsNothing);
      expect(find.textContaining('block'), findsNothing);
    });

    testWidgets('②만 비우고 ①은 남긴다', (tester) async {
      AuthService.client = server(loginStatus: 401);
      await pumpLogin(tester);
      await enter(tester, '20240001', 'wrong');
      await tester.tap(find.byKey(const Key('login_submit')));
      await tester.pumpAndSettle();

      final studentNo = tester.widget<TextField>(find.byKey(const Key('login_student_no')));
      final pw = tester.widget<TextField>(find.byKey(const Key('login_password')));
      expect(studentNo.controller!.text, '20240001', reason: '학번을 다시 치게 만들면 안 된다');
      expect(pw.controller!.text, isEmpty);
    });

    testWidgets('팝업이 열려 있어도 입력란은 잠겨 있지 않다', (tester) async {
      AuthService.client = server(loginStatus: 401);
      await pumpLogin(tester);
      await enter(tester, '20240001', 'wrong');
      await tester.tap(find.byKey(const Key('login_submit')));
      await tester.pumpAndSettle();

      // 팝업을 띄운 채 로딩을 유지하면, 확인을 눌러 닫기 전에는 비밀번호를
      // 다시 칠 수 없다. 로딩은 요청이 끝난 시점에 끝나야 한다.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('로그인 중…'), findsNothing);
      expect(tester.widget<TextField>(find.byKey(const Key('login_password'))).enabled, isTrue);
    });
  });

  group('③ 실패 (2) — 연속 5회 차단', () {
    testWidgets('5회째에 문구가 바뀌고 그 뒤 요청이 나가지 않는다', (tester) async {
      AuthService.client = server(loginStatus: 401);
      await pumpLogin(tester);

      for (var i = 0; i < AuthService.maxAttempts; i++) {
        await enter(tester, '20240001', 'wrong$i');
        await tester.tap(find.byKey(const Key('login_submit')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('확인'));
        await tester.pumpAndSettle();
      }

      expect(
        sent.where((r) => r.url.path == '/auth/login'),
        hasLength(AuthService.maxAttempts),
      );
      expect(find.textContaining('일시 차단'), findsNothing, reason: '팝업은 닫았다');
      // 화면에 차단 안내가 남아 있다
      expect(find.textContaining('연속 실패로 차단'), findsOneWidget);

      // 차단 중에는 더 보내지 않는다
      final before = sent.length;
      await enter(tester, '20240001', 'again');
      await tester.tap(find.byKey(const Key('login_submit')));
      await tester.pumpAndSettle();
      expect(sent.length, before, reason: '차단 중인데 로그인 요청이 나갔다');

      // 타이머가 돌고 있으므로 테스트를 끝내기 전에 멈춘다
      AuthService().resetAttempts();
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('③ 실패 (3) — 서버 무응답', () {
    testWidgets('팝업이 아니라 토스트이고 ①②는 그대로다', (tester) async {
      AuthService.client = server(offline: true);
      await pumpLogin(tester);
      await enter(tester, '20240001', 'userPassword123!');
      await tester.tap(find.byKey(const Key('login_submit')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('연결에 실패'), findsOneWidget);

      final studentNo = tester.widget<TextField>(find.byKey(const Key('login_student_no')));
      final pw = tester.widget<TextField>(find.byKey(const Key('login_password')));
      expect(studentNo.controller!.text, '20240001');
      expect(pw.controller!.text, 'userPassword123!', reason: '연결 실패는 비밀번호 탓이 아니다');
    });

    testWidgets('연결 실패는 차단 횟수에 세지 않는다', (tester) async {
      AuthService.client = server(offline: true);
      await pumpLogin(tester);

      for (var i = 0; i < AuthService.maxAttempts + 2; i++) {
        await enter(tester, '20240001', 'pw');
        await tester.tap(find.byKey(const Key('login_submit')));
        await tester.pumpAndSettle();
      }

      expect(AuthService().lockRemaining, isNull,
          reason: '와이파이가 끊긴 것으로 차단되면 복구할 방법이 없다');
    });
  });

  group('성공 — 세션과 역할 분기', () {
    testWidgets('토큰을 보관하고 user id 까지 채운다', (tester) async {
      final store = MemoryTokenStore();
      AuthService.store = store;
      AuthService.client = server();
      stubDestinationScreen();

      await pumpLogin(tester);
      await enter(tester, '20240001', 'userPassword123!');
      await tester.tap(find.byKey(const Key('login_submit')));
      await pumpLoginRequest(tester);

      expect(store.value, 'token-abc', reason: '토큰이 기기에 저장되지 않았다');
      final session = AuthService().session;
      expect(session, isNotNull);
      expect(session!.userId, 1, reason: '자기 승인 차단·푸시 토큰 연결에 user id 가 필요하다');
      expect(session.role, UserRole.STUDENT);
      expect(AuthService().authHeaders['Authorization'], 'Bearer token-abc');
    });

    testWidgets('학생은 학생 화면으로 가고 로그인 화면은 스택에서 사라진다', (tester) async {
      AuthService.client = server(role: 'STUDENT');
      stubDestinationScreen();
      await pumpLogin(tester);
      await enter(tester, '20240001', 'userPassword123!');
      await tester.tap(find.byKey(const Key('login_submit')));
      await pumpLoginRequest(tester);

      // pushReplacement — 뒤로 가도 로그인으로 돌아오지 않는다
      expect(find.byType(LoginScreen), findsNothing);
      expect(find.byKey(const Key('login_submit')), findsNothing);
    });

    testWidgets('/auth/me 가 실패하면 반쪽 세션을 만들지 않는다', (tester) async {
      final store = MemoryTokenStore();
      AuthService.store = store;
      AuthService.client = server(meStatus: 500);

      await pumpLogin(tester);
      await enter(tester, '20240001', 'userPassword123!');
      await tester.tap(find.byKey(const Key('login_submit')));
      await tester.pumpAndSettle();

      expect(AuthService().session, isNull);
      expect(store.value, isNull, reason: 'id 없는 세션의 토큰을 저장하면 안 된다');
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byType(LoginScreen), findsOneWidget, reason: '로그인 화면에 머물러야 한다');
    });
  });

  group('세션 복원과 만료', () {
    test('보관된 토큰으로 세션을 되살린다', () async {
      AuthService.store = MemoryTokenStore('token-abc');
      AuthService.client = server();

      final session = await AuthService().restore();
      expect(session, isNotNull);
      expect(session!.userId, 1);
      expect(session.role, UserRole.STUDENT);
    });

    test('만료된 토큰은 지우고 null 을 준다', () async {
      final store = MemoryTokenStore('expired');
      AuthService.store = store;
      AuthService.client = server(meStatus: 401);

      expect(await AuthService().restore(), isNull);
      expect(store.value, isNull, reason: '거부된 토큰을 남겨 두면 매번 401 을 맞는다');
    });

    test('서버에 닿지 못하면 토큰을 지우지 않는다', () async {
      final store = MemoryTokenStore('token-abc');
      AuthService.store = store;
      AuthService.client = server(offline: true);

      expect(await AuthService().restore(), isNull);
      expect(store.value, 'token-abc',
          reason: '유효한 토큰을 와이파이 문제로 버리면 다시 로그인해야 한다');
    });

    test('조회가 401 이면 세션을 비우고 알린다', () async {
      AuthService.store = MemoryTokenStore();
      AuthService.client = server();
      await AuthService().login('20240001', 'userPassword123!');
      expect(AuthService().session, isNotNull);

      var notified = 0;
      AuthService().onUnauthorized = () => notified++;

      StudentApiService.client = MockClient((_) async => http.Response('{}', 401));
      await StudentApiService().fetchBalance();

      expect(AuthService().session, isNull);
      expect(notified, 1);

      // 이미 로그아웃된 뒤 또 401 을 받아도 중복으로 알리지 않는다
      await StudentApiService().fetchBalance();
      expect(notified, 1);
    });

    test('로그인하면 조회 요청에 토큰이 붙는다', () async {
      AuthService.store = MemoryTokenStore();
      AuthService.client = server();
      await AuthService().login('20240001', 'userPassword123!');

      final headers = <String, String>{};
      StudentApiService.client = MockClient((req) async {
        headers.addAll(req.headers);
        return http.Response('[]', 200);
      });
      await StudentApiService().fetchEntries();

      expect(headers['Authorization'], 'Bearer token-abc');
    });
  });
}
