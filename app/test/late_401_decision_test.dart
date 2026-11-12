import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/services/auth_service.dart';
import 'package:student_council_app/services/entry_decision_service.dart';

/// 승인·반려가 보낸 요청의 401 이 **늦게** 돌아와도, 그 사이 다시 로그인해 만든 새 세션을 지우지 않는다 (PR #38 리뷰 — 정아).
///
/// 서명 직전 재조회(`GET /entries/{id}`)와 서명 전송(`POST …/confirm·reject`)이 둘 다 보내기 직전의 토큰을
/// `reportUnauthorized(token:)` 에 넘겨야 한다.
void main() {
  const occurredAt = 1790694000;

  EntryModel entry() => EntryModel(
        id: 7,
        termId: 1,
        termCode: 20262,
        kind: EntryKind.EXPENSE,
        amount: 35000,
        counterparty: '한결문구',
        purpose: '신입생 환영회 명찰',
        budgetId: 1,
        occurredAt: occurredAt,
        metaHash: Hashing.metaHash(amount: 35000, counterparty: '한결문구', purpose: '신입생 환영회 명찰', occurredAt: occurredAt),
        status: EntryStatus.PENDING,
        createdBy: 2,
      );

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
    EntryDecisionService.client = http.Client();
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

  test('서명 직전 재조회의 늦은 401 은 새 세션을 지우지 않는다 — 반려', () async {
    await loginWith('token-old');
    final held = Completer<http.Response>();
    final sentAuth = <String?>[];
    EntryDecisionService.client = MockClient((req) {
      sentAuth.add(req.headers['Authorization']);
      return held.future;
    });

    final inFlight = EntryDecisionService().reject(entry(), '중복 영수증');
    await Future<void>.delayed(Duration.zero); // 재조회가 나갔다

    await AuthService().logout();
    await loginWith('token-new');
    var notified = 0;
    AuthService().onUnauthorized = () => notified++;

    held.complete(http.Response('{"detail":"expired"}', 401));
    await expectLater(inFlight, throwsA(isA<EntryDecisionException>()));

    expect(sentAuth.single, 'Bearer token-old');
    expect(AuthService().session?.token, 'token-new', reason: '늦게 온 401 이 방금 만든 세션을 지웠다');
    expect(notified, 0);
  });

  test('지금 세션의 401 은 로그아웃시킨다 — 가드가 정상 만료까지 막지 않는다', () async {
    await loginWith('token-now');
    EntryDecisionService.client = MockClient((_) async => http.Response('{}', 401));
    var notified = 0;
    AuthService().onUnauthorized = () => notified++;

    await expectLater(
      EntryDecisionService().reject(entry(), '중복 영수증'),
      throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.unauthorized)),
    );
    expect(AuthService().session, isNull);
    expect(notified, 1);
  });
}
