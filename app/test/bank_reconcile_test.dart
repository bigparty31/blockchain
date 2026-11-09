import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/models/bank_reconcile_model.dart';
import 'package:student_council_app/screens/council/bank_reconcile_screen.dart';
import 'package:student_council_app/services/api_service.dart';
import 'package:student_council_app/services/bank_reconcile_service.dart';

import 'support/session.dart';

/// 계좌 대조 (A9) — docs/API.md 「계좌 대조」 응답을 그대로 보이는가, 못 읽으면 「미등록 0건」을 지어내지 않는가,
/// 총무 업로드가 원본 바이트·해시를 보내고 서버 거절을 알아듣는가.
void main() {
  Map<String, dynamic> tran(int id, String status, {String dir = 'OUT', int amount = 35000, int? entry}) => {
        'id': id,
        'tran_date': '2026-03-1$id',
        'tran_time': '14:03:11',
        'description': '카드출금 가게$id',
        'direction': dir,
        'amount': amount,
        'balance_after': 1200000,
        'status': status,
        'entry_id': entry,
      };

  Map<String, dynamic> report({
    int id = 2,
    bool superseded = false,
    bool clean = false,
  }) =>
      {
        'snapshot_id': id,
        'term_id': 7,
        'file_hash': '0x${'a' * 64}',
        'bank_balance': 1171000,
        'snapshot_at': '2026-11-07T05:00:00Z',
        'period_start': '2026-03-05',
        'period_end': '2026-03-18',
        'superseded': superseded,
        'summary': superseded
            ? null
            : {
                'total': clean ? 2 : 4,
                'matched': 1,
                'matched_pending': clean ? 1 : 1,
                'unregistered': clean ? 0 : 2,
                'unregistered_out_amount': clean ? 0 : 12000,
                'unregistered_in_amount': clean ? 0 : 5000,
                'unbacked': clean ? 0 : 1,
              },
        'transactions': [
          tran(1, 'MATCHED', entry: 2),
          tran(2, 'MATCHED_PENDING', entry: 3),
          if (!clean) tran(3, 'UNREGISTERED', amount: 12000),
          if (!clean) tran(4, 'UNREGISTERED', dir: 'IN', amount: 5000),
        ].map((t) => superseded ? (t..['status'] = null) : t).toList(),
        'unbacked_entries': clean
            ? []
            : [
                {
                  'entry_id': 9,
                  'kind': 'EXPENSE',
                  'amount': 40000,
                  'date': '2026-03-12',
                  'counterparty': '유령상회',
                  'purpose': '간식',
                },
              ],
      };

  Map<String, dynamic> item(int id, {bool superseded = false}) => {
        'id': id,
        'term_id': 7,
        'file_hash': '0x${'a' * 64}',
        'bank_balance': 1171000,
        'snapshot_at': '2026-11-07T0$id:00:00Z',
        'uploaded_by': 2,
        'superseded': superseded,
      };

  http.Response json(Object body, [int code = 200]) =>
      http.Response(jsonEncode(body), code, headers: {'content-type': 'application/json; charset=utf-8'});

  final terms = [
    {'id': 6, 'term_code': 20261, 'name': '2026-1학기'},
    {'id': 7, 'term_code': 20262, 'name': '2026-2학기'},
  ];

  /// 가짜 서버. 부른 `메서드 경로` 를 [asked] 에, 마지막 POST 본문을 [posted] 에 남긴다.
  late List<String> asked;
  Map<String, dynamic>? posted;
  MockClient server({
    List<Map<String, dynamic>>? list,
    Map<int, Map<String, dynamic>>? reports,
    http.Response Function(http.Request)? onPost,
    int reportCode = 200,
  }) {
    asked = [];
    posted = null;
    final snapshots = list ?? [item(2), item(1, superseded: true)];
    final byId = reports ?? {2: report(), 1: report(id: 1, superseded: true)};
    return MockClient((req) async {
      final path = req.url.path;
      asked.add('${req.method} $path${req.url.query.isEmpty ? '' : '?${req.url.query}'}');
      if (req.method == 'POST') {
        posted = jsonDecode(req.body) as Map<String, dynamic>;
        return onPost == null ? json({}, 500) : onPost(req);
      }
      if (path == '/terms') return json(terms);
      if (path == '/bank/snapshots') return json(snapshots);
      final m = RegExp(r'^/bank/snapshots/(\d+)$').firstMatch(path);
      if (m != null) {
        final r = byId[int.parse(m.group(1)!)];
        return r == null ? json({'detail': 'x'}, 404) : json(r, reportCode);
      }
      return json({}, 404);
    });
  }

  setUp(() async => signInAs(UserRole.TREASURER));
  tearDown(() async {
    BankReconcileService.client = http.Client();
    await signOutForTest();
  });

  group('모델', () {
    test('최신 결과는 상태별로 나뉘고 요약이 있다', () {
      final r = BankReconcileReport.fromJson(report());
      expect(r.summary!.clean, isFalse);
      expect(r.rows(BankRowStatus.unregistered).map((t) => t.id), [3, 4]);
      expect(r.rows(BankRowStatus.matchedPending).single.entryId, 3);
      expect(r.unbackedEntries.single.expense, isTrue);
    });

    test('이전 스냅샷은 요약·상태가 null 이어도 받아들인다', () {
      final r = BankReconcileReport.fromJson(report(superseded: true));
      expect(r.summary, isNull);
      expect(r.transactions.every((t) => t.status == null), isTrue);
    });

    test('최신 결과인데 요약이 없거나 숫자가 깨지면 0 으로 메우지 않고 실패한다', () {
      for (final broken in <Map<String, dynamic> Function()>[
        () => report()..['summary'] = null,
        () => report()..['summary'] = (Map<String, dynamic>.from(report()['summary'])..remove('unregistered')),
        () => report()..['summary'] = (Map<String, dynamic>.from(report()['summary'])..['unbacked'] = '1'),
        () => report()..['bank_balance'] = null,
        () => report()..['transactions'] = null,
        () => report()..['transactions'] = [tran(1, 'WHAT')],
        () => report()..['transactions'] = [tran(1, 'MATCHED', dir: 'SIDEWAYS')],
        () => report()..['superseded'] = 'false',
      ]) {
        expect(() => BankReconcileReport.fromJson(broken()), throwsFormatException);
      }
    });
  });

  group('서비스', () {
    test('현재 학기 id(7)로 목록을 읽는다 — 학기 코드(20262)가 아니다', () async {
      BankReconcileService.client = server();
      final s = BankReconcileService();
      final list = await s.snapshots(await s.termId());
      expect(asked, ['GET /terms', 'GET /bank/snapshots?term_id=7']);
      expect(list.map((e) => e.superseded), [false, true]);
    });

    test('서버에 현재 학기가 없으면 다른 학기를 대신 쓰지 않는다', () async {
      BankReconcileService.client = MockClient((req) async => json([terms.first]));
      await expectLater(BankReconcileService().termId(), throwsA(isA<ApiUnavailable>()));
    });

    test('업로드는 원본 바이트의 base64 와 그 바이트의 해시를 보낸다', () async {
      final bytes = utf8.encode('거래일시,적요,출금,입금,잔액\n'); // 한글 — 바이트 그대로여야 한다
      BankReconcileService.client = server(onPost: (_) => json(report(id: 3), 201));
      final r = await BankReconcileService().upload(termId: 7, bytes: bytes);
      expect(asked.last, 'POST /bank/snapshots');
      expect(posted!['term_id'], 7);
      expect(base64Decode(posted!['file_base64'] as String), bytes);
      expect(posted!['file_hash'], Hashing.fileHash(bytes));
      expect(r.snapshotId, 3);
    });

    test('빈 파일·2MB 초과는 보내기 전에 막는다', () async {
      BankReconcileService.client = server();
      await expectLater(BankReconcileService().upload(termId: 7, bytes: const []), throwsA(isA<BankActionFailed>()));
      await expectLater(
        BankReconcileService().upload(termId: 7, bytes: List.filled(BankReconcileService.maxFileBytes + 1, 0)),
        throwsA(isA<BankActionFailed>()),
      );
      expect(asked, isEmpty);
    });

    test('업로드 거절: 400 은 서버가 적은 줄 번호를 보이고, 409 는 재대조를 안내하며 목록을 다시 읽게 한다', () async {
      BankReconcileService.client = server(onPost: (_) => json({'detail': '3번째 거래의 금액을 읽지 못했습니다'}, 400));
      await expectLater(
        BankReconcileService().upload(termId: 7, bytes: [1]),
        throwsA(isA<BankActionFailed>()
            .having((e) => e.message, 'message', contains('3번째 거래'))
            .having((e) => e.reload, 'reload', isFalse)),
      );
      BankReconcileService.client = server(onPost: (_) => json({'detail': 'dup'}, 409));
      await expectLater(
        BankReconcileService().upload(termId: 7, bytes: [1]),
        throwsA(isA<BankActionFailed>()
            .having((e) => e.message, 'message', contains('재대조'))
            .having((e) => e.reload, 'reload', isTrue)),
      );
    });

    test('업로드 응답을 못 받으면 결과를 모른다 — 목록을 다시 읽게 한다', () async {
      BankReconcileService.client = MockClient((req) async => throw http.ClientException('끊김'));
      await expectLater(
        BankReconcileService().upload(termId: 7, bytes: [1]),
        throwsA(isA<BankActionFailed>().having((e) => e.reload, 'reload', isTrue)),
      );
    });

    test('재대조 409 (더 최근 업로드) 는 목록을 다시 읽게 한다, 403 은 ApiForbidden', () async {
      BankReconcileService.client = server(onPost: (_) => json({'detail': 'x'}, 409));
      await expectLater(
        BankReconcileService().rematch(1),
        throwsA(isA<BankActionFailed>().having((e) => e.reload, 'reload', isTrue)),
      );
      expect(asked.last, 'POST /bank/snapshots/1/rematch');
      BankReconcileService.client = server(onPost: (_) => json({'detail': 'x'}, 403));
      await expectLater(BankReconcileService().rematch(1), throwsA(isA<ApiForbidden>()));
    });
  });

  group('화면', () {
    Future<void> open(WidgetTester tester, {bool canUpload = true, CsvPicker? picker}) async {
      await tester.pumpWidget(MaterialApp(
        home: BankReconcileScreen(canUpload: canUpload, picker: picker ?? () async => null),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('최신 파일의 결과를 연다 — 장부에 없는 거래·통장에 없는 장부 항목을 먼저 보인다', (tester) async {
      BankReconcileService.client = server();
      await open(tester);
      expect(asked, contains('GET /bank/snapshots/2'), reason: '이전 파일(1)이 아니라 최신(2)');
      expect(find.text('₩ 12,000'), findsOneWidget, reason: '장부에 없이 나간 돈');
      expect(find.text('₩ 5,000'), findsOneWidget, reason: '장부에 없이 들어온 돈');
      expect(find.byKey(const Key('bank_clean')), findsNothing);
      expect(find.byKey(const Key('bank_unregistered')), findsOneWidget);
      expect(find.byKey(const Key('bank_tran_3')), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('bank_unbacked_9')), 200);
      expect(find.byKey(const Key('bank_unbacked_9')), findsOneWidget);
      expect(find.byKey(const Key('bank_rematch')), findsOneWidget);
    });

    testWidgets('어긋난 곳이 없으면 「장부와 계좌가 맞아요」', (tester) async {
      BankReconcileService.client = server(reports: {2: report(clean: true)}, list: [item(2)]);
      await open(tester);
      expect(find.byKey(const Key('bank_clean')), findsOneWidget);
      expect(find.byKey(const Key('bank_unregistered')), findsNothing);
      expect(find.byKey(const Key('bank_pending')), findsOneWidget, reason: '승인 대기와의 짝은 따로 보인다');
    });

    testWidgets('감사·회장에게는 업로드·재대조 버튼이 없다', (tester) async {
      BankReconcileService.client = server();
      await open(tester, canUpload: false);
      expect(find.byKey(const Key('bank_upload')), findsNothing);
      expect(find.byKey(const Key('bank_rematch')), findsNothing);
      expect(find.byKey(const Key('bank_summary')), findsOneWidget);
    });

    testWidgets('이전 파일을 열면 요약 없이 거래 줄과 안내만, 재대조 버튼도 없다', (tester) async {
      BankReconcileService.client = server();
      await open(tester);
      await tester.scrollUntilVisible(find.byKey(const Key('bank_history')), 200);
      await tester.tap(find.byKey(const Key('bank_history')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('bank_snapshot_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bank_snapshot_1')));
      await tester.pumpAndSettle();
      expect(asked.last, 'GET /bank/snapshots/1');
      await tester.scrollUntilVisible(find.byKey(const Key('bank_superseded')), -200);
      expect(find.byKey(const Key('bank_superseded')), findsOneWidget);
      expect(find.byKey(const Key('bank_counts')), findsNothing);
      expect(find.byKey(const Key('bank_rematch')), findsNothing);
    });

    testWidgets('올린 거래내역이 없으면 빈 안내, 업로드 버튼은 보인다', (tester) async {
      BankReconcileService.client = server(list: []);
      await open(tester);
      expect(find.byKey(const Key('bank_empty')), findsOneWidget);
      expect(find.byKey(const Key('bank_upload')), findsOneWidget);
      expect(asked.where((a) => a.startsWith('GET /bank/snapshots/')), isEmpty);
    });

    testWidgets('고른 파일을 올리면 새 결과를 연다', (tester) async {
      BankReconcileService.client = server(
        list: [item(3), item(2, superseded: true)],
        reports: {3: report(id: 3, clean: true), 2: report(superseded: true)},
        onPost: (_) => json(report(id: 3, clean: true), 201),
      );
      await open(tester, picker: () async => utf8.encode('csv'));
      await tester.tap(find.byKey(const Key('bank_upload')));
      await tester.pumpAndSettle();
      expect(posted!['file_hash'], Hashing.fileHash(utf8.encode('csv')));
      expect(asked.last, 'GET /bank/snapshots/3');
      expect(find.byKey(const Key('bank_clean')), findsOneWidget);
    });

    testWidgets('같은 파일을 다시 올리면(409) 재대조를 안내한다', (tester) async {
      BankReconcileService.client = server(onPost: (_) => json({'detail': 'dup'}, 409));
      await open(tester, picker: () async => [1, 2, 3]);
      await tester.tap(find.byKey(const Key('bank_upload')));
      await tester.pumpAndSettle();
      expect(find.textContaining('이미 올렸거나'), findsOneWidget);
      expect(find.byKey(const Key('bank_summary')), findsOneWidget, reason: '목록을 다시 읽어 최신 결과를 계속 보인다');
    });

    testWidgets('못 읽으면 결과 없이 오류와 다시 시도, 다시 시도하면 읽는다', (tester) async {
      BankReconcileService.client = server(reportCode: 503);
      await open(tester);
      expect(find.byKey(const Key('bank_error')), findsOneWidget);
      expect(find.byKey(const Key('bank_summary')), findsNothing);
      expect(find.byKey(const Key('bank_clean')), findsNothing);

      BankReconcileService.client = server();
      await tester.tap(find.text('다시 시도'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bank_summary')), findsOneWidget);
    });
  });
}
