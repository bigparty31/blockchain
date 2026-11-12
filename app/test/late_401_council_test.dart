import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/services/api_service.dart';
import 'package:student_council_app/services/auth_service.dart';
import 'package:student_council_app/services/notification_service.dart';

/// 늦게 돌아온 401 이 **방금 다시 로그인해 만든 세션**을 지우지 않는다 (PR #38 리뷰 — 정아).
///
/// 홈·알림함은 15초마다 조회한다. 세션이 만료된 뒤에도 날아다니는 요청이 상시 있고, 그 401 이 사용자가 막 다시
/// 만든 세션을 로그아웃시키면 「로그인했는데 바로 튕겼다」로만 보이고 원인이 화면에 남지 않는다. 토큰은 **보내기
/// 직전에** 잡아 그 요청의 401 에 넘겨야 한다 — 응답이 돌아온 뒤에 다시 읽으면 새 토큰을 보게 된다.
void main() {
  setUp(() async {
    AuthService.store = MemoryTokenStore();
    AuthService.lockStore = MemoryLoginLockStore();
    await AuthService().resetAttempts();
    AuthService().onUnauthorized = null;
  });

  tearDown(() async {
    AuthService().onUnauthorized = null;
    AuthService.store = MemoryTokenStore();
    await AuthService().logout();
    AuthService.client = http.Client();
    ApiService.client = http.Client();
    NotificationService.client = http.Client();
  });

  Future<void> loginWith(String token) async {
    AuthService.client = MockClient((req) async {
      final body = switch (req.url.path) {
        '/auth/login' => {'access_token': token, 'token_type': 'bearer', 'role': 'AUDITOR', 'name': '감사'},
        '/auth/me' => {'id': 3, 'student_no': '20240003', 'name': '감사', 'role': 'AUDITOR'},
        _ => null,
      };
      if (body == null) return http.Response('{}', 404);
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await AuthService().login('20240003', 'pw');
  }

  /// 만료된 토큰으로 요청이 나간 뒤, 응답을 잡아 둔 채 로그아웃 → 새로 로그인하고, 그다음에 401 을 돌려준다.
  Future<void> lateUnauthorizedAfterRelogin({
    required void Function(http.Client) install,
    required Future<void> Function() call,
    required List<String?> sentAuth,
  }) async {
    await loginWith('token-old');
    final held = Completer<http.Response>();
    install(MockClient((req) {
      sentAuth.add(req.headers['Authorization']);
      return held.future;
    }));

    final inFlight = call();
    await Future<void>.delayed(Duration.zero); // 요청이 나갔다

    await AuthService().logout();
    await loginWith('token-new');
    var notified = 0;
    AuthService().onUnauthorized = () => notified++;

    held.complete(http.Response('{"detail":"expired"}', 401));
    try {
      await inFlight;
    } catch (_) {}

    expect(sentAuth.single, 'Bearer token-old', reason: '요청은 그때의 토큰으로 나갔다');
    expect(AuthService().session, isNotNull, reason: '늦게 온 401 이 방금 만든 세션을 지웠다 — 「로그인했는데 바로 튕김」');
    expect(AuthService().session!.token, 'token-new');
    expect(notified, 0, reason: '로그인 화면으로 보내지도 않는다');
  }

  group('조회 서비스', () {
    test('ApiService 조회 — 늦게 온 401 은 새 세션을 지우지 않는다', () async {
      await lateUnauthorizedAfterRelogin(
        install: (c) => ApiService.client = c,
        call: () => ApiService().fetchBalance(),
        sentAuth: [],
      );
    });

    test('알림 조회 — 늦게 온 401 은 새 세션을 지우지 않는다', () async {
      await lateUnauthorizedAfterRelogin(
        install: (c) => NotificationService.client = c,
        call: () => NotificationService.unreadCount(),
        sentAuth: [],
      );
    });

    test('지금 세션의 401 은 로그아웃시킨다 — 가드가 정상 만료까지 막지 않는다', () async {
      await loginWith('token-now');
      ApiService.client = MockClient((_) async => http.Response('{}', 401));
      NotificationService.client = MockClient((_) async => http.Response('{}', 401));
      var notified = 0;
      AuthService().onUnauthorized = () => notified++;

      await expectLater(ApiService().fetchBalance(), throwsA(isA<ApiUnauthorized>()));
      expect(AuthService().session, isNull);
      expect(notified, 1);

      await loginWith('token-now');
      expect(await NotificationService.unreadCount(), isNull);
      expect(AuthService().session, isNull);
      expect(notified, 2);
    });
  });
}
