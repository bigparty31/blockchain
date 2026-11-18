import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/services/auth_service.dart';
import 'package:student_council_app/services/device_token_sync.dart';

/// 로그인 등록 POST 와 로그아웃 해제 DELETE 의 경합 (#122 codex-loop 1차).
/// 해제가 먼저 서버에 닿고 뒤늦은 등록이 토큰을 되살리면, 로그아웃한 기기로 이전 임원의 알림이 간다.
void main() {
  Session session(String token) =>
      Session(userId: 2, studentNo: '20240002', name: '총무', role: UserRole.TREASURER, token: token);

  test('진행 중인 등록이 끝난 뒤에 해제를 보낸다 (순서가 뒤집히지 않는다)', () async {
    final log = <String>[];
    final registerGate = Completer<bool>();
    String? current = 'A';
    final sync = DeviceTokenSync(
      sessionToken: () => current,
      fcmToken: () async => 'fcm',
      cachedToken: () => 'fcm',
      register: (t) {
        log.add('register-start');
        return registerGate.future.whenComplete(() => log.add('register-end'));
      },
      revoke: (t, s) async {
        log.add('revoke');
        return true;
      },
    );

    sync.onStarted('A');
    await Future<void>.delayed(Duration.zero);
    sync.onEnding(session('A'));
    current = null;
    await Future<void>.delayed(Duration.zero);
    expect(log, ['register-start'], reason: '등록이 끝나기 전에는 해제가 나가면 안 된다');

    registerGate.complete(true);
    await sync.idle;
    expect(log, ['register-start', 'register-end', 'revoke']);
  });

  test('토큰을 기다리는 사이 세션이 바뀌면 등록하지 않는다', () async {
    final log = <String>[];
    final tokenGate = Completer<String?>();
    String? current = 'A';
    final sync = DeviceTokenSync(
      sessionToken: () => current,
      fcmToken: () => tokenGate.future,
      cachedToken: () => null,
      register: (t) async {
        log.add('register');
        return true;
      },
      revoke: (t, s) async => true,
    );

    sync.onStarted('A');
    current = 'B'; // 다른 임원이 로그인했다
    tokenGate.complete('fcm');
    await sync.idle;
    expect(log, isEmpty);
  });

  test('세션이 그대로면 등록한다', () async {
    final log = <String>[];
    final sync = DeviceTokenSync(
      sessionToken: () => 'A',
      fcmToken: () async => 'fcm',
      cachedToken: () => 'fcm',
      register: (t) async {
        log.add('register:$t');
        return true;
      },
      revoke: (t, s) async => true,
    );
    sync.onStarted('A');
    await sync.idle;
    expect(log, ['register:fcm']);
  });

  test('등록이 던져도 다음 해제는 나간다', () async {
    final log = <String>[];
    final sync = DeviceTokenSync(
      sessionToken: () => 'A',
      fcmToken: () async => throw StateError('권한 거부'),
      cachedToken: () => 'fcm',
      register: (t) async => true,
      revoke: (t, s) async {
        log.add('revoke:$t');
        return true;
      },
    );
    sync.onStarted('A');
    sync.onEnding(session('A'));
    await sync.idle;
    expect(log, ['revoke:fcm']);
  });
}
