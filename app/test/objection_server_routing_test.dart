import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/api_config.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/services/student_api_service.dart';

/// 이의 제기는 **쓰기라서 학생회 서버로 간다** (PR #128 · PRD §9.1).
///
/// 학생 서버는 읽기 전용 DB 에 릴레이어 키가 없어 `POST /objections` 를 싣지 않는다.
/// 조회는 양쪽에 있고 쓰기만 학생회 서버에 있으므로, 둘을 같은 주소로 보내면
/// **학생이 이의를 제기할 때만 404** 가 된다 — 조회가 멀쩡해서 더 안 보이는 회귀다.
///
/// 두 주소를 일부러 다르게 준다. 기본값은 둘 다 같은 주소라, 그대로 두면 분기를
/// 통째로 지워도 모든 단정이 통과한다.
void main() {
  const student = 'http://student.test:9001';
  const council = 'http://council.test:9002';

  late List<Uri> seen;

  setUp(() {
    seen = [];
    ApiConfig.studentBaseUrlOverride = student;
    ApiConfig.councilBaseUrlOverride = council;
    ApiConfig.activeRole = UserRole.STUDENT;
    StudentApiService.client = MockClient((req) async {
      seen.add(req.url);
      if (req.method == 'POST') {
        return http.Response(
          jsonEncode({
            'id': 1,
            'entry_id': 2,
            'user_id': 1,
            'content': '영수증 미첨부 사유가 궁금합니다',
            'status': 'OPEN',
            'raised_at': 1794841200,
          }),
          201,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('[]', 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
  });

  tearDown(() {
    ApiConfig.resetOverrides();
    ApiConfig.activeRole = null;
  });

  String originOf(Uri u) => '${u.scheme}://${u.host}:${u.port}';

  test('POST /objections 는 학생회 서버로 간다 — 학생 서버에는 경로가 없다', () async {
    await StudentApiService().raiseObjection(
      entryId: 2,
      content: '영수증 미첨부 사유가 궁금합니다',
    );

    final post = seen.firstWhere((u) => u.path == '/objections');
    expect(originOf(post), council,
        reason: '학생 서버로 보내면 404 라 이의가 접수되지 않는다');
  });

  test('GET /objections 는 학생 서버로 간다 — 조회는 양쪽에 있다', () async {
    await StudentApiService().fetchObjections(entryId: 2);

    final get = seen.firstWhere((u) => u.path == '/objections');
    expect(originOf(get), student);
  });

  test('조회와 쓰기가 서로 다른 서버로 갈라진다', () async {
    await StudentApiService().fetchObjections(entryId: 2);
    await StudentApiService().raiseObjection(entryId: 2, content: '질문');

    final origins = seen.where((u) => u.path == '/objections').map(originOf).toSet();
    expect(origins, {student, council});
  });
}
