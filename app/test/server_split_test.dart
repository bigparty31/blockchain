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
void main() {
  MockClient authServer(String role) {
    return MockClient((req) async {
      if (req.url.path == '/auth/login') {
        return http.Response(
          jsonEncode({
            'access_token': 'token-abc',
            'token_type': 'bearer',
            'role': role,
            'name': '아무개',
            'wallet_address': null,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (req.url.path == '/auth/me') {
        return http.Response(
          jsonEncode({'id': 1, 'student_no': '20240001', 'name': '아무개', 'role': role}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 404);
    });
  }

  setUp(() {
    AuthService.store = MemoryTokenStore();
    AuthService().resetAttempts();
    ApiConfig.activeRole = null;
  });

  tearDown(() async {
    await AuthService().logout();
    AuthService.client = http.Client();
    ApiConfig.activeRole = null;
  });

  group('주소 선택', () {
    test('로그인 전에는 학생 서버로 간다', () {
      // 로그인은 양쪽 서버에 다 있다. 역할을 모르는 동안에는 바깥에 가장 넓게
      // 열려 있는 학생 서버로 보낸다.
      expect(ApiConfig.activeRole, isNull);
      expect(ApiConfig.baseUrl, ApiConfig.studentBaseUrl);
    });

    test('학생은 학생 서버, 임원 셋은 학생회 서버', () {
      ApiConfig.activeRole = UserRole.STUDENT;
      expect(ApiConfig.baseUrl, ApiConfig.studentBaseUrl);

      for (final role in [UserRole.TREASURER, UserRole.AUDITOR, UserRole.PRESIDENT]) {
        ApiConfig.activeRole = role;
        expect(
          ApiConfig.baseUrl,
          ApiConfig.councilBaseUrl,
          reason: '${role.label} 요청이 학생 서버로 가면 토큰이 거부된다',
        );
      }
    });

    test('엔드포인트 주소가 선택된 서버를 따라간다', () {
      ApiConfig.activeRole = UserRole.TREASURER;
      expect(ApiConfig.entries, startsWith(ApiConfig.councilBaseUrl));
      expect(ApiConfig.balance, startsWith(ApiConfig.councilBaseUrl));
      expect(ApiConfig.budgets, startsWith(ApiConfig.councilBaseUrl));
    });
  });

  group('세션과 주소가 같이 움직인다', () {
    test('로그인하면 역할이 반영된다 — 학생', () async {
      AuthService.client = authServer('STUDENT');
      await AuthService().login('20240001', 'pw');
      expect(ApiConfig.activeRole, UserRole.STUDENT);
      expect(ApiConfig.baseUrl, ApiConfig.studentBaseUrl);
    });

    test('로그인하면 역할이 반영된다 — 총무', () async {
      AuthService.client = authServer('TREASURER');
      await AuthService().login('20240002', 'pw');
      expect(ApiConfig.activeRole, UserRole.TREASURER);
      expect(ApiConfig.baseUrl, ApiConfig.councilBaseUrl);
    });

    test('로그아웃하면 학생 서버로 돌아간다', () async {
      AuthService.client = authServer('AUDITOR');
      await AuthService().login('20240003', 'pw');
      expect(ApiConfig.baseUrl, ApiConfig.councilBaseUrl);

      await AuthService().logout();
      // 남겨 두면 다음 사람이 로그인하기 전에 보내는 요청이 학생회 서버로 간다.
      expect(ApiConfig.activeRole, isNull);
      expect(ApiConfig.baseUrl, ApiConfig.studentBaseUrl);
    });

    test('세션 복원도 역할을 반영한다', () async {
      AuthService.store = MemoryTokenStore('token-abc');
      AuthService.client = authServer('PRESIDENT');

      expect(await AuthService().restore(), isNotNull);
      expect(ApiConfig.activeRole, UserRole.PRESIDENT,
          reason: '앱을 다시 켰을 때 주소가 안 바뀌면 임원 요청이 전부 거부된다');
    });

    test('만료된 토큰으로 복원 실패하면 역할이 비워진다', () async {
      AuthService.store = MemoryTokenStore('expired');
      AuthService.client = MockClient((_) async => http.Response('{}', 401));

      expect(await AuthService().restore(), isNull);
      expect(ApiConfig.activeRole, isNull);
    });

    test('401 로 세션이 끊기면 역할도 비워진다', () async {
      AuthService.client = authServer('TREASURER');
      await AuthService().login('20240002', 'pw');
      expect(ApiConfig.activeRole, UserRole.TREASURER);

      await AuthService().reportUnauthorized();
      expect(ApiConfig.activeRole, isNull);
      expect(AuthService().session, isNull);
    });
  });
}
