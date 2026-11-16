import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/services/budget_revision_service.dart';

import 'support/session.dart';

/// 총무의 예산 증액 요청 (T9) — `POST /budget-revisions` (API §3.1).
void main() {
  late List<http.Request> sent;
  late http.Response Function() onPost;

  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

  const draft = IncreaseRequestDraft(
    termId: 1,
    category: '행사비',
    budgetId: 1,
    amount: 530000,
    reason: '무대 장비 대여료 인상\n견적서 첨부',
    blockedEntryId: 12,
  );

  setUp(() async {
    await signInAs(UserRole.TREASURER, userId: 2);
    sent = [];
    onPost = () => json({'id': 4, 'status': 'PENDING', 'budget_id': 1, 'blocked_entry_id': 12}, 201);
    BudgetRevisionService.client = MockClient((req) async {
      if ('${req.method} ${req.url.path}' == 'POST /budget-revisions') {
        sent.add(req);
        return onPost();
      }
      return http.Response('{}', 404);
    });
  });

  tearDown(() async {
    BudgetRevisionService.client = http.Client();
    await signOutForTest();
  });

  test('증액분·사유 원문·근거 차단 지출을 총무 토큰으로 보내고 요청 번호를 돌려준다', () async {
    expect(await BudgetRevisionService().requestIncrease(draft), 4);
    final req = sent.single;
    expect(req.headers['Authorization'], 'Bearer token-2');
    expect(jsonDecode(req.body), {
      'term_id': 1,
      'category': '행사비',
      'budget_id': 1,
      'requested_amount': 530000,
      'reason': '무대 장비 대여료 인상\n견적서 첨부', // 정본화는 서버가 한다 (canonical_text)
      'blocked_entry_id': 12,
    });
  });

  test('근거 지출이 없으면 blocked_entry_id 를 보내지 않는다', () {
    const plain = IncreaseRequestDraft(termId: 1, category: '행사비', budgetId: 1, amount: 1, reason: 'r');
    expect(plain.toJson().containsKey('blocked_entry_id'), isFalse);
  });

  test('서버가 거부하면(400) 서버 설명을 보여 준다', () async {
    onPost = () => json({'detail': '차단 지출의 예산과 증액 요청 대상 예산이 일치하지 않습니다.'}, 400);
    await expectLater(
      BudgetRevisionService().requestIncrease(draft),
      throwsA(isA<EntryDecisionException>()
          .having((e) => e.failure, 'failure', EntryDecisionFailure.refused)
          .having((e) => e.message, 'message', contains('일치하지 않습니다'))),
    );
  });

  test('응답에 요청 번호가 없으면 결과를 모른다고 한다', () async {
    onPost = () => json({'status': 'PENDING'}, 201);
    await expectLater(
      BudgetRevisionService().requestIncrease(draft),
      throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.unknownOutcome)),
    );
  });
}
