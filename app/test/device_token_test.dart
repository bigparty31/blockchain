import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/api_config.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/services/auth_service.dart';
import 'package:student_council_app/services/notification_service.dart';
import 'package:student_council_app/services/push_service.dart';

/// 임원 기기 FCM 토큰 등록·해제 — `docs/NOTIFICATION_API.md` §4·§5.
///
/// 지키는 것:
///   - 로그인한 임원만 올린다 (학생은 토픽이라 올리지 않는다)
///   - 푸시는 부가 기능이다 — 못 올려도 던지지 않고, 로그인·로그아웃을 막지 않는다
///   - 로그아웃은 **세션이 비워진 뒤에는 인증 헤더가 없으므로**, 비우기 전의 세션으로 해제를 보낸다
void main() {
  const student = 'http://student.test:9001';
  const council = 'http://council.test:9002';

  http.Response json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  setUp(() async {
    ApiConfig.studentBaseUrlOverride = student;
    ApiConfig.councilBaseUrlOverride = council;
    AuthService.store = MemoryTokenStore();
    AuthService.lockStore = MemoryLoginLockStore();
    await AuthService().resetAttempts();
    AuthService().onSessionEnding = null;
    ApiConfig.activeRole = null;
  });

  tearDown(() async {
    AuthService().onSessionEnding = null;
    AuthService.store = MemoryTokenStore();
    await AuthService().logout();
    AuthService.client = http.Client();
    NotificationService.client = http.Client();
    PushService.backend = FirebasePushBackend();
    PushService().resetForTest();
    ApiConfig.activeRole = null;
    ApiConfig.resetOverrides();
  });

  Future<void> loginTreasurer() async {
    AuthService.client = MockClient((req) async {
      final body = switch (req.url.path) {
        '/auth/login' => {
            'access_token': 'council-token',
            'token_type': 'bearer',
            'role': 'TREASURER',
            'name': '총무',
          },
        '/auth/me' => {'id': 2, 'student_no': '20240002', 'name': '총무', 'role': 'TREASURER'},
        _ => null,
      };
      return body == null ? http.Response('{}', 404) : json(body);
    });
    await AuthService().login('20240002', 'pw');
  }

  group('NotificationService.registerDeviceToken', () {
    test('android 플랫폼과 토큰을 학생회 서버에 올린다', () async {
      await loginTreasurer();
      late http.Request seen;
      NotificationService.client = MockClient((req) async {
        seen = req;
        return json({'id': 5, 'registered_at': 1793548800});
      });

      final ok = await NotificationService.registerDeviceToken('fcm-abc');

      expect(ok, isTrue);
      expect(seen.method, 'POST');
      expect(seen.url.toString(), '$council/notifications/device-tokens');
      expect(seen.headers['Authorization'], 'Bearer council-token');
      expect(jsonDecode(seen.body), {'platform': 'android', 'token': 'fcm-abc'});
    });

    test('서버가 거절하면 false 다 — 던지지 않는다', () async {
      await loginTreasurer();
      NotificationService.client = MockClient((_) async => json({'detail': 'x'}, 400));

      expect(await NotificationService.registerDeviceToken('fcm-abc'), isFalse);
    });

    test('연결이 끊겨도 false 다 — 던지지 않는다', () async {
      await loginTreasurer();
      NotificationService.client = MockClient((_) async => throw http.ClientException('offline'));

      expect(await NotificationService.registerDeviceToken('fcm-abc'), isFalse);
    });

    /// 늦게 온 401 이 새 세션을 지우면 안 된다 — 다른 알림 호출과 같은 규칙(`_send`).
    test('401 이면 세션이 끝난 것으로 알린다', () async {
      await loginTreasurer();
      var unauthorized = 0;
      AuthService().onUnauthorized = () => unauthorized++;
      NotificationService.client = MockClient((_) async => http.Response('{}', 401));

      expect(await NotificationService.registerDeviceToken('fcm-abc'), isFalse);
      expect(unauthorized, 1);
      AuthService().onUnauthorized = null;
    });
  });

  group('NotificationService.revokeDeviceToken', () {
    test('넘겨받은 세션의 토큰으로, 그 역할의 서버에 해제를 보낸다', () async {
      late http.Request seen;
      NotificationService.client = MockClient((req) async {
        seen = req;
        return json({'revoked': true});
      });
      const old = Session(
        userId: 2,
        studentNo: '20240002',
        name: '총무',
        role: UserRole.TREASURER,
        token: 'old-token',
      );

      // 세션은 이미 비워졌고 activeRole 도 없다 — 그래도 학생회 서버로 가야 한다.
      ApiConfig.activeRole = null;
      final ok = await NotificationService.revokeDeviceToken('fcm/abc+def', old);

      expect(ok, isTrue);
      expect(seen.method, 'DELETE');
      expect(seen.url.host, 'council.test');
      expect(seen.url.path, '/notifications/device-tokens/fcm%2Fabc%2Bdef', reason: '토큰의 `/` 가 경로를 갈라 놓으면 안 된다');
      expect(seen.headers['Authorization'], 'Bearer old-token');
    });

    test('못 보내도 던지지 않는다 (로그아웃을 막지 않는다)', () async {
      NotificationService.client = MockClient((_) async => throw http.ClientException('offline'));
      const old = Session(
        userId: 2,
        studentNo: '20240002',
        name: '총무',
        role: UserRole.TREASURER,
        token: 'old-token',
      );

      expect(await NotificationService.revokeDeviceToken('fcm-abc', old), isFalse);
    });

    /// 해제의 401 은 **이미 끝난 세션**의 것이다. 새로 로그인한 사람을 로그아웃시키면 안 된다.
    test('401 이어도 현재 세션을 건드리지 않는다', () async {
      await loginTreasurer();
      var unauthorized = 0;
      AuthService().onUnauthorized = () => unauthorized++;
      NotificationService.client = MockClient((_) async => http.Response('{}', 401));
      const old = Session(
        userId: 9,
        studentNo: '20240009',
        name: '이전 사람',
        role: UserRole.AUDITOR,
        token: 'expired-token',
      );

      expect(await NotificationService.revokeDeviceToken('fcm-abc', old), isFalse);
      expect(unauthorized, 0);
      expect(AuthService().session?.token, 'council-token');
      AuthService().onUnauthorized = null;
    });
  });

  group('AuthService.onSessionEnding', () {
    test('로그아웃이 비우기 전의 세션을 넘긴다', () async {
      await loginTreasurer();
      final seen = <Session>[];
      AuthService().onSessionEnding = seen.add;

      await AuthService().logout();

      expect(seen, hasLength(1));
      expect(seen.single.token, 'council-token');
      expect(seen.single.role, UserRole.TREASURER);
      expect(AuthService().session, isNull);
    });

    test('이미 로그아웃 상태에서는 부르지 않는다', () async {
      var calls = 0;
      AuthService().onSessionEnding = (_) => calls++;

      await AuthService().logout();

      expect(calls, 0);
    });

    test('로그인은 부르지 않는다', () async {
      var calls = 0;
      AuthService().onSessionEnding = (_) => calls++;

      await loginTreasurer();

      expect(calls, 0);
    });
  });

  group('PushService.deviceToken', () {
    test('초기화가 끝나길 기다렸다가 토큰을 준다', () async {
      PushService.backend = _TokenBackend('fcm-1');
      PushService().resetForTest();
      // init 을 아직 부르지 않은 채 요청해도 기다린다 — main() 이 init 을 await 하지 않는다.
      PushService().init();

      expect(await PushService().deviceToken(), 'fcm-1');
    });

    test('초기화가 실패하면 null 이다 — 던지지 않는다', () async {
      PushService.backend = _TokenBackend(null, failInit: true);
      PushService().resetForTest();
      PushService().init();

      expect(await PushService().deviceToken(), isNull);
    });
  });
}

class _TokenBackend implements PushBackend {
  final String? token;
  final bool failInit;
  _TokenBackend(this.token, {this.failInit = false});

  @override
  Future<void> initializeApp() async {
    if (failInit) throw StateError('no firebase');
  }

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<String?> getToken() async => token;

  @override
  Future<void> subscribeToTopic(String topic) async {}

  @override
  Future<void> unsubscribeFromTopic(String topic) async {}

  @override
  Future<PushMessage?> getInitialMessage() async => null;

  @override
  void onMessage(void Function(PushMessage) handler) {}

  @override
  void onMessageOpenedApp(void Function(PushMessage) handler) {}
}
