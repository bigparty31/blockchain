import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/signing/budget_types.dart';
import 'package:student_council_app/core/signing/eip712.dart';
import 'package:student_council_app/core/signing/signing_service.dart';
import 'package:student_council_app/models/budget_revision_model.dart';
import 'package:student_council_app/screens/council/budget_revision_approval_screen.dart';
import 'package:student_council_app/services/budget_revision_decision_service.dart';

import 'support/session.dart';

/// 예산 증액 승인 (A7) — 회장 서명·감사 승인·반려가 docs/API.md §3 대로 나가는가.
void main() {
  final domain = Eip712Domain.fromJson(const {
    'name': 'BudgetToken',
    'version': '1',
    'chainId': 31337,
    'verifyingContract': '0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512',
    'domainSeparator': '0x1f2905a02b6b82de113d21bf22f98674232314b3d02d77ab6f4bdf7e0c252699',
  });

  // 고정 시각: 2026-11-07 00:00:00 UTC
  final now = DateTime.utc(2026, 11, 7);
  final nowSec = now.millisecondsSinceEpoch ~/ 1000;
  const sig = '0xsig';

  Map<String, Object?> row({
    int id = 7,
    String status = 'PENDING',
    int amount = 500000,
    String reason = '신학기 비품 구매로 인한 운영비 부족',
    int? signedVersion,
    int? deadline,
  }) =>
      {
        'id': id,
        'term_id': 1,
        'category': '운영비',
        'budget_id': 3,
        'blocked_entry_id': 10,
        'requested_amount': amount,
        'reason': reason,
        'requested_by': 2,
        'requested_at': '2026-11-06T09:00:00Z',
        'status': status,
        'president_signed_by': signedVersion == null ? null : 4,
        'president_signature': signedVersion == null ? null : '0xpres',
        'president_signed_at': null,
        'signature_deadline': deadline,
        'signed_version': signedVersion,
        'tx_increase': null,
        'resolved_by': null,
        'resolved_at': null,
        'reject_reason': null,
        'created_at': '2026-11-06T09:00:00Z',
      };

  http.Response json(Object body, [int code = 200]) =>
      http.Response(jsonEncode(body), code, headers: {'content-type': 'application/json; charset=utf-8'});

  /// 가짜 학생회 서버. [single] 은 서명 직전 재조회 응답, [budgets] 는 `GET /budgets` 응답,
  /// [onPost] 는 쓰기 요청 응답이다. 받은 요청은 [posts] 에 쌓인다.
  late List<http.Request> posts;
  MockClient server({
    List<Map<String, Object?>> list = const [],
    Map<String, Object?>? single,
    Object? budgets,
    http.Response Function(http.Request req)? onPost,
  }) {
    posts = [];
    return MockClient((req) async {
      if (req.method == 'POST') {
        posts.add(req);
        return onPost?.call(req) ?? json(row(status: 'PRESIDENT_SIGNED', signedVersion: 2, deadline: nowSec + 86400));
      }
      if (req.url.path == '/budgets') {
        return json(budgets ??
            [
              {'id': 1, 'term_id': 1, 'category': '행사비', 'version': 1},
              {'id': 3, 'term_id': 1, 'category': '운영비', 'version': 2},
            ]);
      }
      if (req.url.path == '/budget-revisions') return json(list);
      if (req.url.path.startsWith('/budget-revisions/')) return single == null ? json({}, 404) : json(single);
      return json({}, 404);
    });
  }

  /// 서명 함수가 받은 메시지를 기록하는 가짜 서명.
  late List<Eip712Message> signed;
  BudgetRevisionDecisionService service({Object? signError}) {
    signed = [];
    return BudgetRevisionDecisionService(
      now: () => now,
      budgetDomain: () async => domain,
      sign: (d, m, {required reason}) async {
        if (signError != null) throw signError;
        expect(d, same(domain));
        signed.add(m);
        return sig;
      },
    );
  }

  BudgetRevisionModel model(Map<String, Object?> r) => BudgetRevisionModel.fromJson(r);

  tearDown(() {
    BudgetRevisionDecisionService.client = http.Client();
  });

  group('모델', () {
    test('서명에 들어가는 값이 없으면 기본값으로 메우지 않고 거부한다', () {
      for (final key in ['budget_id', 'requested_amount', 'reason', 'status']) {
        final r = row()..[key] = null;
        expect(() => model(r), throwsFormatException, reason: key);
      }
      expect(() => model(row(status: 'DRAFT')), throwsFormatException);
    });
  });

  group('회장 서명', () {
    test('현재 체인 버전·24시간 시한·증액분·사유 해시로 서명해 /sign 에 보낸다', () async {
      BudgetRevisionDecisionService.client = server(single: row());
      final done = await service().presidentSign(model(row()));

      expect(done.status, BudgetRevisionStatus.PRESIDENT_SIGNED);
      expect(signed, hasLength(1));
      final v = signed.single.values;
      expect(signed.single.primaryType, 'IncreaseRequest');
      expect(v['budgetId'], 3);
      expect(v['amount'], 500000, reason: '증액분 — 변경 후 총액이 아니다');
      expect(v['reasonHash'], BudgetTypes.reasonHashOf('신학기 비품 구매로 인한 운영비 부족'));
      expect(v['version'], 2, reason: 'GET /budgets 의 예산 3 버전');
      expect(v['deadline'], nowSec + 24 * 3600);

      expect(posts.single.url.path, '/budget-revisions/7/sign');
      expect(jsonDecode(posts.single.body), {
        'president_signature': sig,
        'signature_deadline': nowSec + 24 * 3600,
        'signed_version': 2,
      });
    });

    test('예산 버전을 못 읽거나 예산이 목록에 없으면 서명하지 않는다', () async {
      for (final budgets in [
        [
          {'id': 3, 'version': null}
        ],
        [
          {'id': 3, 'version': 0}
        ],
        [
          {'id': 1, 'version': 1}
        ],
        {'not': 'a list'},
      ]) {
        BudgetRevisionDecisionService.client = server(single: row(), budgets: budgets);
        final s = service();
        await expectLater(
          s.presidentSign(model(row())),
          throwsA(isA<RevisionDecisionException>().having((e) => e.failure, 'failure', RevisionDecisionFailure.notReady)),
          reason: '$budgets',
        );
        expect(signed, isEmpty);
        expect(posts, isEmpty);
      }
    });

    test('서명 직전 재조회에서 단계나 내용이 바뀌었으면 서명하지 않는다', () async {
      for (final latest in [
        row(status: 'PRESIDENT_SIGNED', signedVersion: 2, deadline: nowSec + 100),
        row(status: 'REJECTED'),
        row(amount: 900000),
        row(reason: '다른 사유'),
      ]) {
        BudgetRevisionDecisionService.client = server(single: latest);
        final s = service();
        await expectLater(
          s.presidentSign(model(row())),
          throwsA(isA<RevisionDecisionException>().having((e) => e.failure, 'failure', RevisionDecisionFailure.changed)),
        );
        expect(signed, isEmpty);
        expect(posts, isEmpty);
      }
    });

    test('본인 확인을 취소하면 아무것도 보내지 않는다', () async {
      BudgetRevisionDecisionService.client = server(single: row());
      await expectLater(
        service(signError: const SigningException('취소했어요')).presidentSign(model(row())),
        throwsA(isA<RevisionDecisionException>().having((e) => e.failure, 'failure', RevisionDecisionFailure.signing)),
      );
      expect(posts, isEmpty);
    });
  });

  group('감사 승인', () {
    final signedRow = row(status: 'PRESIDENT_SIGNED', signedVersion: 2, deadline: nowSec + 3600);

    test('회장이 정한 버전·시한을 그대로 서명해 /approve 에 보낸다', () async {
      BudgetRevisionDecisionService.client = server(
        single: signedRow,
        // 그새 체인 버전이 3 이 됐어도 감사는 회장 값(2)으로 서명한다 — 서버가 VersionMismatch 를 판정한다
        budgets: [
          {'id': 3, 'version': 3}
        ],
        onPost: (_) => json(row(status: 'APPROVED', signedVersion: 2, deadline: nowSec + 3600)),
      );
      final done = await service().auditorApprove(model(signedRow));

      expect(done.status, BudgetRevisionStatus.APPROVED);
      final v = signed.single.values;
      expect(v['version'], 2);
      expect(v['deadline'], nowSec + 3600);
      expect(v['amount'], 500000);
      expect(posts.single.url.path, '/budget-revisions/7/approve');
      expect(jsonDecode(posts.single.body), {'auditor_signature': sig});
    });

    test('회장 서명 시한이 지났거나 곧 지나면 서명하지 않는다', () async {
      for (final deadline in [nowSec - 1, nowSec, nowSec + 120]) {
        final r = row(status: 'PRESIDENT_SIGNED', signedVersion: 2, deadline: deadline);
        BudgetRevisionDecisionService.client = server(single: r);
        final s = service();
        await expectLater(
          s.auditorApprove(model(r)),
          throwsA(isA<RevisionDecisionException>().having((e) => e.failure, 'failure', RevisionDecisionFailure.expired)),
          reason: 'deadline=$deadline',
        );
        expect(signed, isEmpty);
        expect(posts, isEmpty);
      }
    });

    test('재조회했더니 서버가 PENDING 으로 되돌려 놨으면 서명하지 않는다', () async {
      BudgetRevisionDecisionService.client = server(single: row());
      final s = service();
      await expectLater(
        s.auditorApprove(model(signedRow)),
        throwsA(isA<RevisionDecisionException>().having((e) => e.failure, 'failure', RevisionDecisionFailure.changed)),
      );
      expect(signed, isEmpty);
    });

    test('응답 코드마다 실패 종류가 정해져 있다', () async {
      const cases = {
        400: RevisionDecisionFailure.refused,
        403: RevisionDecisionFailure.forbidden,
        404: RevisionDecisionFailure.notFound,
        409: RevisionDecisionFailure.conflict,
        422: RevisionDecisionFailure.refused,
        503: RevisionDecisionFailure.unknownOutcome,
      };
      for (final c in cases.entries) {
        BudgetRevisionDecisionService.client =
            server(single: signedRow, onPost: (_) => json({'detail': '서명 당시 예산 버전이 다릅니다'}, c.key));
        await expectLater(
          service().auditorApprove(model(signedRow)),
          throwsA(isA<RevisionDecisionException>().having((e) => e.failure, 'failure', c.value)),
          reason: '${c.key}',
        );
      }
    });

    test('400 이면 서버 문구를 같이 보여 준다', () async {
      BudgetRevisionDecisionService.client =
          server(single: signedRow, onPost: (_) => json({'detail': '재서명이 필요합니다'}, 400));
      await expectLater(
        service().auditorApprove(model(signedRow)),
        throwsA(isA<RevisionDecisionException>().having((e) => e.message, 'message', contains('재서명이 필요합니다'))),
      );
    });

    test('연결이 끊기면 결과를 모른다고 한다', () async {
      posts = [];
      BudgetRevisionDecisionService.client = MockClient((req) async {
        if (req.method == 'POST') throw http.ClientException('끊김');
        return json(signedRow);
      });
      await expectLater(
        service().auditorApprove(model(signedRow)),
        throwsA(isA<RevisionDecisionException>()
            .having((e) => e.failure, 'failure', RevisionDecisionFailure.unknownOutcome)),
      );
    });
  });

  group('반려', () {
    test('사유를 정본화해 /reject 에 보낸다 (서명 없음)', () async {
      BudgetRevisionDecisionService.client = server(onPost: (_) => json(row(status: 'REJECTED')));
      final done = await service().reject(model(row()), '  예비비로 대체 가능  ');
      expect(done.status, BudgetRevisionStatus.REJECTED);
      expect(signed, isEmpty);
      expect(posts.single.url.path, '/budget-revisions/7/reject');
      expect(jsonDecode(posts.single.body), {'reject_reason': '예비비로 대체 가능'});
    });

    test('빈 사유는 보내지 않는다', () async {
      BudgetRevisionDecisionService.client = server();
      await expectLater(
        service().reject(model(row()), '   '),
        throwsA(isA<RevisionDecisionException>()
            .having((e) => e.failure, 'failure', RevisionDecisionFailure.invalidReason)),
      );
      expect(posts, isEmpty);
    });
  });

  group('화면', () {
    setUp(() async => signInAs(UserRole.PRESIDENT, userId: 4));
    tearDown(signOutForTest);

    Future<void> open(WidgetTester tester, UserRole role, BudgetRevisionDecisionService s) async {
      // 역할마다 key 를 달리해 새 화면으로 그린다 (같은 key 면 앞 State 를 재사용해 목록을 다시 읽지 않는다)
      await tester.pumpWidget(
          MaterialApp(home: BudgetRevisionApprovalScreen(key: ValueKey(role), role: role, service: s)));
      await tester.pumpAndSettle();
    }

    testWidgets('회장은 PENDING 목록을, 감사는 PRESIDENT_SIGNED 목록을 읽는다', (tester) async {
      final asked = <String?>[];
      BudgetRevisionDecisionService.client = MockClient((req) async {
        asked.add(req.url.queryParameters['status_filter']);
        return json([]);
      });
      await open(tester, UserRole.PRESIDENT, service());
      expect(find.byKey(const Key('revision_empty')), findsOneWidget);
      expect(find.text('예산 증액 서명'), findsOneWidget);

      await open(tester, UserRole.AUDITOR, service());
      expect(find.text('예산 증액 승인'), findsOneWidget);
      expect(asked, ['PENDING', 'PRESIDENT_SIGNED']);
    });

    testWidgets('목록을 못 읽으면 더미 대신 오류와 다시 시도를 보여 준다', (tester) async {
      BudgetRevisionDecisionService.client = MockClient((_) async => json({}, 503));
      await open(tester, UserRole.PRESIDENT, service());
      expect(find.byKey(const Key('revision_load_error')), findsOneWidget);
      expect(find.text('다시 시도'), findsOneWidget);
    });

    testWidgets('서명 → 확인 창 → 보낸 뒤 목록을 새로 읽는다', (tester) async {
      var listed = 0;
      posts = [];
      BudgetRevisionDecisionService.client = MockClient((req) async {
        if (req.method == 'POST') {
          posts.add(req);
          return json(row(status: 'PRESIDENT_SIGNED', signedVersion: 2, deadline: nowSec + 86400));
        }
        if (req.url.path == '/budgets') return json([{'id': 3, 'version': 2}]);
        if (req.url.path == '/budget-revisions') return json(listed++ == 0 ? [row()] : []);
        return json(row());
      });
      await open(tester, UserRole.PRESIDENT, service());
      expect(find.text('+₩ 500,000'), findsOneWidget);

      await tester.tap(find.byKey(const Key('revision_sign_7')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('revision_sign_confirm')), findsOneWidget);
      expect(posts, isEmpty, reason: '확인 전에는 보내지 않는다');

      await tester.tap(find.byKey(const Key('revision_sign_confirm_ok')));
      await tester.pumpAndSettle();
      expect(posts.single.url.path, '/budget-revisions/7/sign');
      expect(find.byKey(const Key('revision_empty')), findsOneWidget);
    });

    testWidgets('확인 창에서 취소하면 서명하지 않는다', (tester) async {
      BudgetRevisionDecisionService.client = server(list: [row()], single: row());
      await open(tester, UserRole.PRESIDENT, service());
      await tester.tap(find.byKey(const Key('revision_sign_7')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(signed, isEmpty);
      expect(posts, isEmpty);
    });
  });
}
