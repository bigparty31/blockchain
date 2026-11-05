import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/services/auth_service.dart';

/// 가짜 서버로 로그인해 [AuthService.session] 을 [role] 로 채운다
/// (`council_guard_test.dart` 의 `loginAs` 와 같은 방식).
///
/// 부른 테스트는 `tearDown` 에서 [signOutForTest] 를 불러 다음 테스트에 세션을 남기지 않는다.
Future<void> signInAs(UserRole role, {int userId = 2}) async {
  AuthService.store = MemoryTokenStore();
  AuthService().resetAttempts();
  http.Response json(Object body) => http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
  AuthService.client = MockClient((req) async {
    if (req.url.path == '/auth/login') {
      return json({'access_token': 'token-$userId', 'token_type': 'bearer', 'role': role.code, 'name': '테스트'});
    }
    if (req.url.path == '/auth/me') {
      return json({'id': userId, 'student_no': '2024000$userId', 'name': '테스트', 'role': role.code});
    }
    return http.Response('{}', 404);
  });
  await AuthService().login('2024000$userId', 'userPassword123!');
}

/// 세션과 가짜 서버를 비운다.
///
/// 저장소를 먼저 메모리로 바꾼다. 기본 저장소(flutter_secure_storage)는 위젯 테스트에서
/// 응답이 오지 않아, 로그인한 적 없는 테스트에서 `logout()` 이 끝나지 않는다.
Future<void> signOutForTest() async {
  AuthService.store = MemoryTokenStore();
  await AuthService().logout();
  AuthService.client = http.Client();
}
