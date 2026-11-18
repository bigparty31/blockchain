import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/budget_plan.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/signing/budget_types.dart';
import 'package:student_council_app/core/signing/eip712.dart';
import 'package:student_council_app/core/signing/signing_service.dart';
import 'package:student_council_app/services/budget_issuer.dart';
import 'package:student_council_app/services/server_budget_issuer.dart';
import 'package:web3dart/web3dart.dart' as web3 show sign;

import 'support/session.dart';

/// 실제 예산 발행기 (A4) — 준비 → 서명 → 제출, 그리고 실패를 「거부」(다시 보낼 수 있음)와
/// 「응답 없음」(보냈는지 모름)으로 제대로 나누는지.
void main() {
  // signing_budget_test 와 같은 도메인 (ethers 로 계산한 domainSeparator)
  final domain = Eip712Domain.fromJson(const {
    'name': 'BudgetToken',
    'version': '1',
    'chainId': 31337,
    'verifyingContract': '0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512',
    'domainSeparator': '0x1f2905a02b6b82de113d21bf22f98674232314b3d02d77ab6f4bdf7e0c252699',
  });

  // Hardhat #1 — 회장 지갑
  const presidentKey = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d';
  const president = '0x70997970c51812dc3a010c7d01b50e0d17dc79c8';
  // Hardhat #2 — 다른 키
  const otherKey = '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a';

  final now = DateTime.utc(2026, 11, 17, 3);
  final deadline = now.add(ServerBudgetIssuer.signatureTtl).millisecondsSinceEpoch ~/ 1000;
  final expiresOn = DateTime(2027, 2, 28);
  final expiresAt = BudgetPlanRules.expiresAtSeconds(expiresOn);

  http.Response json(Object body, [int code = 200]) =>
      http.Response(jsonEncode(body), code, headers: {'content-type': 'application/json; charset=utf-8'});

  BudgetDraftItem item(BudgetCategory c, int amount) =>
      BudgetDraftItem(category: c, amount: amount, expiresOn: expiresOn);

  Map<String, dynamic> draftJson(int id, String category, {String status = 'DRAFT', String? hash}) => {
        'id': id,
        'term_id': 1,
        'term_code': 20262,
        'category': category,
        'category_hash': hash ?? BudgetTypes.categoryHash(category),
        'planned_amount': 1,
        'expires_at': expiresAt,
        'version': 1,
        'status': status,
      };

  late List<http.Request> sent;
  late int signCalls;

  BudgetSigner signerWith(String key) => (d, m, {required reason}) async {
        signCalls++;
        return SigningService.encodeSignature(web3.sign(Eip712.digest(d, m), Eip712.hexToBytes(key)));
      };

  ServerBudgetIssuer issuer({String key = presidentKey, bool hasKey = true, BudgetSigner? sign}) => ServerBudgetIssuer(
        sign: sign ?? signerWith(key),
        domain: () async => domain,
        hasKey: () async => hasKey,
        now: () => now,
      );

  /// 기본 가짜 서버: 학기 1개, 초안은 항목 순서대로 id 11, 12, …, 제출은 ISSUED.
  void server({
    http.Response Function(http.Request req)? prepare,
    FutureOr<http.Response> Function(http.Request req)? submit,
    Object? terms,
  }) {
    var nextId = 11;
    ServerBudgetIssuer.client = MockClient((req) async {
      sent.add(req);
      final p = req.url.path;
      if (p == '/terms') {
        return json(terms ??
            [
              {'id': 3, 'term_code': 20261},
              {'id': 4, 'term_code': 20262},
            ]);
      }
      if (p == '/budgets') {
        if (prepare != null) return prepare(req);
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        return json(draftJson(nextId++, body['category'] as String), 201);
      }
      if (p.endsWith('/submit')) {
        if (submit != null) return submit(req);
        return json({'status': 'ISSUED', 'issue_status': 'issued'});
      }
      return http.Response('{}', 404);
    });
  }

  List<String> paths() => [for (final r in sent) r.url.path];

  setUp(() async {
    await signInAs(UserRole.PRESIDENT, walletAddress: president);
    sent = [];
    signCalls = 0;
  });
  tearDown(() async {
    ServerBudgetIssuer.client = http.Client();
    await signOutForTest();
  });

  test('현재 학기를 찾고, 항목마다 준비 → 회장 서명 → 제출한다', () async {
    server();
    final out = await issuer().issueAll(items: [
      item(BudgetCategory.event, 2470000),
      item(BudgetCategory.project, 1465000),
    ]);

    expect([for (final o in out) o.status], [BudgetIssueStatus.issued, BudgetIssueStatus.issued]);
    expect(paths(), ['/terms', '/budgets', '/budgets/11/submit', '/budgets', '/budgets/12/submit']);

    final prep = jsonDecode(sent[1].body) as Map<String, dynamic>;
    expect(prep, {'term_id': 4, 'category': '행사비', 'planned_amount': 2470000, 'expires_at': expiresAt});
    expect(sent[1].headers['Authorization'], 'Bearer token-2');

    // 서버가 할 검산을 똑같이 해 본다 — 이 값들로 만든 다이제스트에서 회장 주소가 나와야 한다
    final body = jsonDecode(sent[2].body) as Map<String, dynamic>;
    expect(body['planned_amount'], 2470000);
    expect(body['expires_at'], expiresAt);
    expect(body['deadline'], deadline);
    final digest = Eip712.digest(
      domain,
      BudgetTypes.issueRequest(
        budgetId: 11,
        term: 20262,
        category: BudgetTypes.categoryHash('행사비'),
        amount: 2470000,
        expiresAt: expiresAt,
        deadline: deadline,
      ),
    );
    expect(SigningService.recoverSigner(digest, body['signature'] as String), president);
  });

  test('학기 id 를 받으면 학기를 조회하지 않는다', () async {
    server();
    await issuer().issueAll(termId: 7, items: [item(BudgetCategory.event, 1000)]);
    expect(paths(), ['/budgets', '/budgets/11/submit']);
    expect((jsonDecode(sent.first.body) as Map)['term_id'], 7);
  });

  test('준비 단계에서 이미 발행된 항목이면 서명·제출 없이 「이미 발행됨」 + 체인의 실제 값', () async {
    server(prepare: (req) => json({...draftJson(11, '행사비', status: 'ALREADY_ISSUED'), 'planned_amount': 1000000}, 201));
    final out = await issuer().issueAll(termId: 4, items: [item(BudgetCategory.event, 2000000)]);
    expect(out.single.status, BudgetIssueStatus.alreadyIssued);
    expect(out.single.issuedAmount, 1000000);
    expect(out.single.issuedExpiresAt, expiresAt);
    expect(signCalls, 0);
    expect(paths(), ['/budgets']);
  });

  group('서버가 준 발행 값 검산 — 다르면 서명하지 않는다', () {
    test('budgetId 가 0 이면', () async {
      server(prepare: (req) => json(draftJson(0, '행사비'), 201));
      final out = await issuer().issueAll(termId: 4, items: [item(BudgetCategory.event, 1)]);
      expect(out.single.status, BudgetIssueStatus.rejected);
      expect(signCalls, 0);
    });

    test('현재 학기로 보냈는데 다른 학기 코드가 오면', () async {
      server(prepare: (req) => json({...draftJson(11, '행사비'), 'term_code': 20261}, 201));
      final out = await issuer().issueAll(items: [item(BudgetCategory.event, 1)]);
      expect(out.single.status, BudgetIssueStatus.rejected);
      expect(signCalls, 0);
    });

    test('학기 id 를 직접 줬으면 그 학기 코드를 그대로 쓴다', () async {
      server(prepare: (req) => json({...draftJson(11, '행사비'), 'term_code': 20261}, 201));
      final out = await issuer().issueAll(termId: 3, items: [item(BudgetCategory.event, 1)]);
      expect(out.single.status, BudgetIssueStatus.issued);
    });
  });

  group('시작 전에 막힘 (아무것도 보내지 않는다)', () {
    test('서명 키가 없으면 지갑 미연결', () async {
      server();
      await expectLater(
        issuer(hasKey: false).issueAll(items: [item(BudgetCategory.event, 1000)]),
        throwsA(isA<BudgetIssueException>().having((e) => e.failure, 'failure', BudgetIssueFailure.walletNotConnected)),
      );
      expect(sent, isEmpty);
    });

    test('회장이 아니면 회장 아님', () async {
      await signOutForTest();
      await signInAs(UserRole.TREASURER);
      server();
      await expectLater(
        issuer().issueAll(items: [item(BudgetCategory.event, 1000)]),
        throwsA(isA<BudgetIssueException>().having((e) => e.failure, 'failure', BudgetIssueFailure.notPresident)),
      );
      expect(sent, isEmpty);
    });

    test('둘째 줄 준비에서 403 이면 첫 줄 결과는 남기고 나머지는 중단', () async {
      var n = 0;
      server(prepare: (req) {
        n++;
        if (n == 1) return json(draftJson(11, '행사비'), 201);
        return json({'detail': '권한 없음'}, 403);
      });
      final out = await issuer().issueAll(
          termId: 4, items: [item(BudgetCategory.event, 1), item(BudgetCategory.project, 1), item(BudgetCategory.operation, 1)]);
      expect([for (final o in out) o.status],
          [BudgetIssueStatus.issued, BudgetIssueStatus.rejected, BudgetIssueStatus.rejected]);
      expect(paths().where((p) => p == '/budgets').length, 2);
    });

    test('첫 준비에서 403 이면 회장 아님', () async {
      server(prepare: (req) => json({'detail': '권한 없음'}, 403));
      await expectLater(
        issuer().issueAll(termId: 4, items: [item(BudgetCategory.event, 1000)]),
        throwsA(isA<BudgetIssueException>().having((e) => e.failure, 'failure', BudgetIssueFailure.notPresident)),
      );
    });

    test('서버에 현재 학기가 없으면 전부 거부 — 다른 학기로 보내지 않는다', () async {
      server(terms: [
        {'id': 3, 'term_code': 20261},
      ]);
      final out = await issuer().issueAll(items: [item(BudgetCategory.event, 1), item(BudgetCategory.project, 1)]);
      expect([for (final o in out) o.status], everyElement(BudgetIssueStatus.rejected));
      expect(out.first.message, contains('현재 학기가 없어요'));
      expect(paths(), ['/terms']);
    });
  });

  group('보내기 전 실패 → 거부 (고쳐서 다시 확정 가능)', () {
    test('준비가 400 이면 서버 문구를 보인다', () async {
      server(prepare: (req) => json({'detail': '지출 항목만 허용'}, 400));
      final out = await issuer().issueAll(termId: 4, items: [item(BudgetCategory.event, 1000)]);
      expect(out.single.status, BudgetIssueStatus.rejected);
      expect(out.single.message, contains('지출 항목만 허용'));
      expect(signCalls, 0);
    });

    test('준비 요청이 끊기면 거부', () async {
      server(prepare: (req) => throw http.ClientException('끊김'));
      final out = await issuer().issueAll(termId: 4, items: [item(BudgetCategory.event, 1000)]);
      expect(out.single.status, BudgetIssueStatus.rejected);
    });

    test('서버가 준 항목 해시가 다르면 서명하지 않는다', () async {
      server(prepare: (req) => json(draftJson(11, '행사비', hash: BudgetTypes.categoryHash('사업비')), 201));
      final out = await issuer().issueAll(termId: 4, items: [item(BudgetCategory.event, 1000)]);
      expect(out.single.status, BudgetIssueStatus.rejected);
      expect(signCalls, 0);
      expect(paths(), ['/budgets']);
    });

    test('서명을 취소하면 남은 줄도 묻지 않고 거부', () async {
      server();
      final out = await issuer(sign: (d, m, {required reason}) async {
        signCalls++;
        throw const SigningException('본인 확인을 취소했어요');
      }).issueAll(termId: 4, items: [item(BudgetCategory.event, 1), item(BudgetCategory.project, 1)]);
      expect([for (final o in out) o.status], [BudgetIssueStatus.rejected, BudgetIssueStatus.rejected]);
      expect(out.last.message, contains('본인 확인을 취소했어요'));
      expect(signCalls, 1);
      expect(paths().where((p) => p.endsWith('/submit')), isEmpty);
    });

    test('둘째 줄 서명에서 저장소 오류가 나도 첫 줄 결과는 남는다', () async {
      server();
      final ok = signerWith(presidentKey);
      var n = 0;
      final out = await issuer(sign: (d, m, {required reason}) async {
        if (++n == 2) throw Exception('PlatformException(키스토어)');
        return ok(d, m, reason: reason);
      }).issueAll(termId: 4, items: [item(BudgetCategory.event, 1), item(BudgetCategory.project, 1)]);
      expect([for (final o in out) o.status], [BudgetIssueStatus.issued, BudgetIssueStatus.rejected]);
      expect(out.last.message, contains('서명 키를 읽지 못해'));
      expect(paths().where((p) => p.endsWith('/submit')).length, 1);
    });

    test('다른 키로 서명했으면 보내지 않는다', () async {
      server();
      final out = await issuer(key: otherKey).issueAll(termId: 4, items: [item(BudgetCategory.event, 1)]);
      expect(out.single.status, BudgetIssueStatus.rejected);
      expect(out.single.message, contains('회장 지갑과 달라요'));
      expect(paths(), ['/budgets']);
    });

    test('로그인이 끝나면(401) 남은 줄도 같은 이유로 거부', () async {
      server(prepare: (req) => json({'detail': '만료'}, 401));
      final out = await issuer().issueAll(termId: 4, items: [item(BudgetCategory.event, 1), item(BudgetCategory.project, 1)]);
      expect([for (final o in out) o.status], [BudgetIssueStatus.rejected, BudgetIssueStatus.rejected]);
      expect(out.last.message, contains('로그인이 끝났어요'));
      expect(paths(), ['/budgets']);
    });

    test('제출이 400(서명자 불일치)이면 거부', () async {
      server(submit: (req) => json({'detail': '서명자가 요청한 회장의 지갑 주소와 일치하지 않습니다.'}, 400));
      final out = await issuer().issueAll(termId: 4, items: [item(BudgetCategory.event, 1)]);
      expect(out.single.status, BudgetIssueStatus.rejected);
      expect(out.single.message, contains('일치하지 않습니다'));
    });
  });

  group('보낸 뒤 → 결과대로, 모르면 응답 없음', () {
    test('체인이 거부하면 서버 문구와 함께 거부', () async {
      server(submit: (req) => json({'status': 'REJECTED', 'reason': 'BudgetExpired', 'message': '만료일이 지났어요'}));
      final out = await issuer().issueAll(termId: 4, items: [item(BudgetCategory.event, 1)]);
      expect(out.single.status, BudgetIssueStatus.rejected);
      expect(out.single.message, '만료일이 지났어요');
    });

    test('ALREADY_ISSUED 는 이미 발행됨(체인 값 포함), NO_RESPONSE 는 응답 없음', () async {
      final replies = [
        {'status': 'ALREADY_ISSUED', 'planned_amount': 500000, 'expires_at': 1790000000},
        {'status': 'NO_RESPONSE'},
      ];
      server(submit: (req) => json(replies.removeAt(0)));
      final out = await issuer().issueAll(termId: 4, items: [item(BudgetCategory.event, 1), item(BudgetCategory.project, 1)]);
      expect([for (final o in out) o.status], [BudgetIssueStatus.alreadyIssued, BudgetIssueStatus.noResponse]);
      expect((out.first.issuedAmount, out.first.issuedExpiresAt), (500000, 1790000000));
    });

    for (final code in [409, 500, 503]) {
      test('제출이 $code 이면 응답 없음 — 결과를 모른다', () async {
        server(submit: (req) => json({'detail': '이유'}, code));
        final out = await issuer().issueAll(termId: 4, items: [item(BudgetCategory.event, 1)]);
        expect(out.single.status, BudgetIssueStatus.noResponse);
      });
    }

    test('제출 중 연결이 끊기면 응답 없음, 다음 줄은 계속 보낸다', () async {
      var first = true;
      server(submit: (req) {
        if (first) {
          first = false;
          throw http.ClientException('끊김');
        }
        return json({'status': 'ISSUED'});
      });
      final out = await issuer().issueAll(termId: 4, items: [item(BudgetCategory.event, 1), item(BudgetCategory.project, 1)]);
      expect([for (final o in out) o.status], [BudgetIssueStatus.noResponse, BudgetIssueStatus.issued]);
    });

    test('제출 응답을 읽지 못하면 응답 없음', () async {
      server(submit: (req) => http.Response('not json', 200));
      final out = await issuer().issueAll(termId: 4, items: [item(BudgetCategory.event, 1)]);
      expect(out.single.status, BudgetIssueStatus.noResponse);
    });
  });
}
