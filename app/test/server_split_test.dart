import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/api_config.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/services/auth_service.dart';

/// 역할별 서버 주소 분기 (PRD v0.14 §9.1).
///
/// 학생 서버는 **학생 토큰만**, 학생회 서버는 **임원 토큰만** 받는다. 역할과
/// 주소가 어긋나면 요청이 전부 거부되므로, 세션이 바뀔 때마다 주소도 같이
/// 바뀌어야 한다. 눈으로는 안 보이는 회귀라 여기서 못박는다.
///
/// **두 주소를 일부러 다르게 준다.** 기본값은 둘 다 같은 주소라서
/// (`ApiConfig` — 저장소에 진입점이 하나뿐이다) 그대로 두면 분기를 통째로
/// 지워도 `baseUrl == studentBaseUrl == councilBaseUrl` 이 되어 모든 단정이
/// 통과한다. 즉 **실패할 수 없는 테스트**였고, 그래서 로그인 경로의 주소
/// 버그를 잡지 못했다. 주소를 갈라 두면 비로소 「어느 서버로 갔는가」를
/// 물을 수 있다.
void main() {
  const student = 'http://student.test:9001';
  const council = 'http://council.test:9002';

  /// 요청이 간 주소를 모아 두는 가짜 서버.
  ///
  /// 두 서버를 **역할로 구분한다** — 토큰의 역할과 주소가 어긋나면 실제 서버가
  /// 하듯 401 을 준다. 그래야 「임원이 학생 서버로 로그인하면 막힌다」가
  /// 테스트에서도 실제로 막힌다.
  ({MockClient client, List<Uri> seen}) strictServers(UserRole role) {
    final seen = <Uri>[];
    final client = MockClient((req) async {
      seen.add(req.url);
      final origin = '${req.url.scheme}://${req.url.host}:${req.url.port}';
      final wantsCouncil = role != UserRole.STUDENT;
      final atCouncil = origin == council;

      // `/auth/login` 은 양쪽에 다 있다 (PRD §9.1).
      if (req.url.path == '/auth/login') {
        return http.Response(
          jsonEncode({
            'access_token': 'token-abc',
            'token_type': 'bearer',
            'role': role.code,
            'name': '아무개',
            'wallet_address': null,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }

      // 그 밖의 요청은 **자기 롤의 서버만** 받는다.
      if (wantsCouncil != atCouncil) {
        return http.Response('{"detail":"wrong server"}', 401);
      }

      if (req.url.path == '/auth/me') {
        return http.Response(
          jsonEncode({'id': 1, 'student_no': '20240001', 'name': '아무개', 'role': role.code}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 404);
    });
    return (client: client, seen: seen);
  }

  setUp(() async {
    ApiConfig.studentBaseUrlOverride = student;
    ApiConfig.councilBaseUrlOverride = council;
    AuthService.store = MemoryTokenStore();
    AuthService.lockStore = MemoryLoginLockStore();
    await AuthService().resetAttempts();
    ApiConfig.activeRole = null;
  });

  tearDown(() async {
    await AuthService().logout();
    AuthService.client = http.Client();
    ApiConfig.activeRole = null;
    ApiConfig.resetOverrides();
  });

  group('주소 선택', () {
    test('두 주소는 실제로 다르다 — 이 group 의 단정이 의미를 갖는 전제', () {
      expect(ApiConfig.studentBaseUrl, isNot(ApiConfig.councilBaseUrl));
    });

    test('로그인 전에는 학생 서버로 간다', () {
      // 로그인은 양쪽 서버에 다 있다. 역할을 모르는 동안에는 바깥에 가장 넓게
      // 열려 있는 학생 서버로 보낸다.
      expect(ApiConfig.activeRole, isNull);
      expect(ApiConfig.baseUrl, student);
    });

    test('학생은 학생 서버, 임원 셋은 학생회 서버', () {
      ApiConfig.activeRole = UserRole.STUDENT;
      expect(ApiConfig.baseUrl, student);

      for (final role in [UserRole.TREASURER, UserRole.AUDITOR, UserRole.PRESIDENT]) {
        ApiConfig.activeRole = role;
        expect(
          ApiConfig.baseUrl,
          council,
          reason: '${role.label} 요청이 학생 서버로 가면 토큰이 거부된다',
        );
      }
    });

    test('baseUrlFor 는 활성 역할과 무관하게 넘긴 역할로 고른다', () {
      // 로그인 **도중**에 쓰는 경로다. 그때 activeRole 은 아직 비어 있다.
      ApiConfig.activeRole = null;
      expect(ApiConfig.baseUrlFor(UserRole.STUDENT), student);
      expect(ApiConfig.baseUrlFor(UserRole.TREASURER), council);
      expect(ApiConfig.baseUrlFor(UserRole.AUDITOR), council);
      expect(ApiConfig.baseUrlFor(UserRole.PRESIDENT), council);
      expect(ApiConfig.baseUrlFor(null), student, reason: '역할을 모르면 학생 서버');
    });

    test('엔드포인트 주소가 선택된 서버를 따라간다', () {
      ApiConfig.activeRole = UserRole.TREASURER;
      expect(ApiConfig.entries, startsWith(council));
      expect(ApiConfig.balance, startsWith(council));
      expect(ApiConfig.budgets, startsWith(council));
    });
  });

  group('isOwnOrigin — 토큰을 붙일 주소인가', () {
    test('두 서버는 우리 것이다', () {
      expect(ApiConfig.isOwnOrigin('$student/receipts/1.jpg'), isTrue);
      expect(ApiConfig.isOwnOrigin('$council/receipts/1.jpg'), isTrue);
    });

    test('다른 host·port·scheme 는 남의 것이다', () {
      expect(ApiConfig.isOwnOrigin('https://evil.example.com/r.jpg'), isFalse);
      expect(ApiConfig.isOwnOrigin('http://student.test:9999/r.jpg'), isFalse);
      expect(ApiConfig.isOwnOrigin('https://student.test:9001/r.jpg'), isFalse);
      expect(ApiConfig.isOwnOrigin('https://my-bucket.s3.amazonaws.com/r.jpg'), isFalse);
    });

    test('주소가 아니면 남의 것으로 본다', () {
      expect(ApiConfig.isOwnOrigin('/receipts/1.jpg'), isFalse);
      expect(ApiConfig.isOwnOrigin(''), isFalse);
    });

    test('기본 포트는 생략형과 같다고 본다', () {
      ApiConfig.studentBaseUrlOverride = 'http://only.test';
      expect(ApiConfig.isOwnOrigin('http://only.test:80/r.jpg'), isTrue);
    });
  });

  group('세션과 주소가 같이 움직인다', () {
    test('로그인하면 역할이 반영된다 — 학생', () async {
      final s = strictServers(UserRole.STUDENT);
      AuthService.client = s.client;
      await AuthService().login('20240001', 'pw');
      expect(ApiConfig.activeRole, UserRole.STUDENT);
      expect(ApiConfig.baseUrl, student);
    });

    test('로그인하면 역할이 반영된다 — 총무', () async {
      final s = strictServers(UserRole.TREASURER);
      AuthService.client = s.client;
      await AuthService().login('20240002', 'pw');
      expect(ApiConfig.activeRole, UserRole.TREASURER);
      expect(ApiConfig.baseUrl, council);
    });

    /// 이 테스트가 잡으려는 결함: `login` 이 `/auth/me` 를 **역할 반영 전에**
    /// 부르면서 `ApiConfig.baseUrl`(= 학생 서버)로 보내고 있었다. 학생 서버가
    /// 임원 토큰을 받지 않으므로 총무·감사·회장은 로그인 자체가 막힌다.
    /// 두 주소가 같던 예전 테스트로는 드러나지 않았다.
    for (final role in [UserRole.TREASURER, UserRole.AUDITOR, UserRole.PRESIDENT]) {
      test('${role.label} 로그인의 /auth/me 는 학생회 서버로 간다', () async {
        final s = strictServers(role);
        AuthService.client = s.client;

        final session = await AuthService().login('20240002', 'pw');
        expect(session.role, role);

        final me = s.seen.where((u) => u.path == '/auth/me');
        expect(me, isNotEmpty, reason: '/auth/me 를 부르지 않았다');
        for (final u in me) {
          expect(
            '${u.scheme}://${u.host}:${u.port}',
            council,
            reason: '${role.label} 의 /auth/me 가 학생 서버로 가면 로그인이 막힌다',
          );
        }
      });
    }

    test('학생 로그인의 /auth/me 는 학생 서버로 간다', () async {
      final s = strictServers(UserRole.STUDENT);
      AuthService.client = s.client;
      await AuthService().login('20240001', 'pw');

      for (final u in s.seen.where((u) => u.path == '/auth/me')) {
        expect('${u.scheme}://${u.host}:${u.port}', student);
      }
    });

    test('로그아웃하면 학생 서버로 돌아간다', () async {
      final s = strictServers(UserRole.AUDITOR);
      AuthService.client = s.client;
      await AuthService().login('20240003', 'pw');
      expect(ApiConfig.baseUrl, council);

      await AuthService().logout();
      // 남겨 두면 다음 사람이 로그인하기 전에 보내는 요청이 학생회 서버로 간다.
      expect(ApiConfig.activeRole, isNull);
      expect(ApiConfig.baseUrl, student);
    });

    test('세션 복원도 역할을 반영한다', () async {
      final s = strictServers(UserRole.PRESIDENT);
      AuthService.store = MemoryTokenStore('token-abc', UserRole.PRESIDENT);
      AuthService.client = s.client;

      expect(await AuthService().restore(), isNotNull);
      expect(ApiConfig.activeRole, UserRole.PRESIDENT,
          reason: '앱을 다시 켰을 때 주소가 안 바뀌면 임원 요청이 전부 거부된다');
    });

    /// 복원이 잡으려는 결함: 역할을 모른 채 `/auth/me` 를 학생 서버로 보내면
    /// 임원 토큰이 401 을 맞고, 그 401 이 `store.clear()` 로 **유효한 토큰을
    /// 지운다.** 임원은 앱을 켤 때마다 다시 로그인해야 한다.
    for (final role in [UserRole.TREASURER, UserRole.AUDITOR, UserRole.PRESIDENT]) {
      test('${role.label} 복원은 학생회 서버로 묻고 토큰을 지우지 않는다', () async {
        final s = strictServers(role);
        final store = MemoryTokenStore('token-abc', role);
        AuthService.store = store;
        AuthService.client = s.client;

        final session = await AuthService().restore();
        expect(session, isNotNull, reason: '${role.label} 세션이 복원되지 않았다');
        expect(session!.role, role);
        expect(store.value?.token, 'token-abc', reason: '유효한 토큰이 지워졌다');

        for (final u in s.seen.where((u) => u.path == '/auth/me')) {
          expect('${u.scheme}://${u.host}:${u.port}', council);
        }
      });
    }

    test('역할을 저장해 두지 않은 옛 토큰도 읽는다 — 다시 로그인만 하면 된다', () async {
      // 업데이트 전에 저장된 세션은 `ROLE|token` 형식이 아니라 토큰뿐이다.
      // 전부 무효로 만들면 사용자 전원이 이유 없이 다시 로그인해야 한다.
      final decoded = StoredSession.decode('bare-token-only');
      expect(decoded, isNotNull);
      expect(decoded!.token, 'bare-token-only');
      expect(decoded.role, isNull, reason: '모르는 역할은 null — STUDENT 로 단정하지 않는다');
    });

    test('저장 형식은 역할과 토큰을 함께 담는다', () {
      final encoded = const StoredSession('tok', UserRole.AUDITOR).encode();
      final back = StoredSession.decode(encoded);
      expect(back!.token, 'tok');
      expect(back.role, UserRole.AUDITOR);
    });

    test('로그인하면 역할도 함께 저장된다', () async {
      final s = strictServers(UserRole.TREASURER);
      final store = MemoryTokenStore();
      AuthService.store = store;
      AuthService.client = s.client;

      await AuthService().login('20240002', 'pw');
      expect(store.value?.role, UserRole.TREASURER,
          reason: '역할을 저장하지 않으면 다음 복원이 주소를 고를 수 없다');
    });

    test('만료된 토큰으로 복원 실패하면 역할이 비워진다', () async {
      AuthService.store = MemoryTokenStore('expired', UserRole.STUDENT);
      AuthService.client = MockClient((_) async => http.Response('{}', 401));

      expect(await AuthService().restore(), isNull);
      expect(ApiConfig.activeRole, isNull);
    });

    test('401 로 세션이 끊기면 역할도 비워진다', () async {
      final s = strictServers(UserRole.TREASURER);
      AuthService.client = s.client;
      await AuthService().login('20240002', 'pw');
      expect(ApiConfig.activeRole, UserRole.TREASURER);

      await AuthService().reportUnauthorized();
      expect(ApiConfig.activeRole, isNull);
      expect(AuthService().session, isNull);
    });
  });
}
