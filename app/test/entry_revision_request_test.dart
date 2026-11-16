import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/screens/council/my_entries_screen.dart';
import 'package:student_council_app/services/api_service.dart';
import 'package:student_council_app/services/entry_decision_service.dart';
import 'package:student_council_app/services/entry_revision_service.dart';

/// 승인 대기 건의 「수정 요청」 (PRD §4.3 T4, `POST /entries/{id}/request-revision`, 서버 #76).
///
/// 대기 건은 여기서 고칠 수 없다 — 새로 올리면 두 건이 함께 대기하다 둘 다 확정될 수 있다. 수정을 요청하면
/// 승인권자는 확정할 수 없고 반려만 할 수 있다. 반려되면 「고쳐서 다시 제출」로 새 건을 올린다.
EntryModel pending(int id, {int? txConfirm, int? revisionRequestedAt}) => EntryModel(
      id: id,
      termId: 1,
      kind: EntryKind.EXPENSE,
      amount: 50000,
      counterparty: '거래처$id',
      purpose: '목적$id',
      budgetId: 1,
      occurredAt: 1788793200,
      metaHash: '0x${'0' * 64}',
      status: EntryStatus.PENDING,
      createdBy: 2,
      txConfirm: txConfirm == null ? null : '0x${'a' * 64}',
      revisionRequestedAt: revisionRequestedAt,
    );

Map<String, Object?> entryJson(int id, {Object? revisionRequestedAt}) => {
      'id': id,
      'term_id': 1,
      'kind': 'EXPENSE',
      'amount': 50000,
      'counterparty': '거래처$id',
      'purpose': '목적$id',
      'budget_id': 1,
      'occurred_at': 1788793200,
      'meta_hash': '0x${'0' * 64}',
      'status': 'PENDING',
      'created_by': 2,
      'revision_requested_at': revisionRequestedAt,
    };

void main() {
  setUp(() => ApiService.useDemoData = true);

  group('EntryModel — revision_requested_at', () {
    test('숫자면 읽고, 없거나 숫자가 아니면 null (요청 안 함)', () {
      expect(EntryModel.fromJson(entryJson(1, revisionRequestedAt: 1794187428)).revisionRequestedAt, 1794187428);
      expect(EntryModel.fromJson(entryJson(1)).revisionRequestedAt, isNull);
      expect(EntryModel.fromJson(entryJson(1, revisionRequestedAt: 'yesterday')).revisionRequestedAt, isNull);
    });
  });

  group('EntryRevisionService.requestRevision', () {
    late List<http.Request> sent;

    setUp(() => sent = []);
    tearDown(() => EntryRevisionService.client = http.Client());

    http.Response json(int status, Object body) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

    test('수정 요청 API 를 본문 없이 POST 하고, 요청 시각이 채워진 항목을 돌려준다', () async {
      EntryRevisionService.client = MockClient((req) async {
        sent.add(req);
        return json(200, entryJson(7, revisionRequestedAt: 1794187428));
      });
      final e = await EntryRevisionService.requestRevision(7);
      expect(sent.single.method, 'POST');
      expect(sent.single.url.path, '/entries/7/request-revision');
      expect(sent.single.body, isEmpty);
      expect(e.id, 7);
      expect(e.revisionRequestedAt, 1794187428);
    });

    test('확정이 먼저 처리 중(409)이면 정정 등록으로 안내한다', () async {
      EntryRevisionService.client = MockClient((_) async => json(409, {'detail': 'x'}));
      await expectLater(
        EntryRevisionService.requestRevision(7),
        throwsA(isA<EntryDecisionException>()
            .having((e) => e.failure, 'failure', EntryDecisionFailure.conflict)
            .having((e) => e.message, 'message', contains('정정'))),
      );
    });

    test('대기 건이 아니면(400) 이유를 그대로 전한다', () async {
      EntryRevisionService.client = MockClient((_) async => json(400, {'detail': 'PENDING 상태의 내역만 수정 요청할 수 있습니다.'}));
      await expectLater(
        EntryRevisionService.requestRevision(7),
        throwsA(isA<EntryDecisionException>()
            .having((e) => e.failure, 'failure', EntryDecisionFailure.refused)
            .having((e) => e.message, 'message', contains('PENDING'))),
      );
    });

    test('응답을 읽을 수 없으면 처리됐는지 모른다고 알린다', () async {
      EntryRevisionService.client = MockClient((_) async => http.Response('{}', 200));
      await expectLater(
        EntryRevisionService.requestRevision(7),
        throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.unknownOutcome)),
      );
    });
  });

  group('내 등록 현황 — 대기 건의 수정 요청', () {
    Future<void> pumpScreen(
      WidgetTester tester, {
      required List<EntryModel> Function() entries,
      required Future<EntryModel> Function(int) requestRevision,
      List<int>? loads,
    }) async {
      tester.view.physicalSize = const Size(411, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: MyEntriesScreen(
          currentUserId: 2,
          loadEntries: () async {
            loads?.add(1);
            return entries();
          },
          requestRevision: requestRevision,
        ),
      ));
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        if (find.textContaining('전체').evaluate().isNotEmpty) break;
      }
      await tester.pumpAndSettle();
    }

    final requestLabel = find.text('수정 요청');

    testWidgets('대기 건에는 「수정 요청」 버튼이 있고, 처리 중인 건에는 없다', (tester) async {
      await pumpScreen(
        tester,
        entries: () => [pending(1), pending(2, txConfirm: 1)],
        requestRevision: (_) async => pending(1),
      );
      expect(requestLabel, findsOneWidget);
      expect(find.text('처리 중 — 다시 보낼 수 없어요'), findsOneWidget);
    });

    testWidgets('누르면 반려만 가능해진다고 알리는 확인 창이 뜨고, 취소하면 보내지 않는다', (tester) async {
      var calls = 0;
      await pumpScreen(tester, entries: () => [pending(1)], requestRevision: (_) async {
        calls++;
        return pending(1);
      });
      await tester.tap(requestLabel);
      await tester.pumpAndSettle();
      expect(find.textContaining('반려'), findsWidgets);
      expect(find.text('취소'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(calls, 0);
    });

    testWidgets('확인하면 그 건으로 요청하고, 목록을 다시 읽어 「수정 요청함」으로 바뀐다', (tester) async {
      final asked = <int>[];
      var requested = false;
      final loads = <int>[];
      await pumpScreen(
        tester,
        loads: loads,
        entries: () => [pending(1, revisionRequestedAt: requested ? 1794187428 : null)],
        requestRevision: (id) async {
          asked.add(id);
          requested = true;
          return pending(id, revisionRequestedAt: 1794187428);
        },
      );
      await tester.tap(requestLabel);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('revision_confirm')));
      await tester.pumpAndSettle();

      expect(asked, [1]);
      expect(loads.length, greaterThanOrEqualTo(2), reason: '요청 뒤 목록을 다시 읽는다');
      expect(find.textContaining('수정 요청을 보냈어요'), findsOneWidget);
      expect(requestLabel, findsNothing);
      expect(find.textContaining('수정 요청함'), findsOneWidget);
    });

    testWidgets('이미 수정 요청한 건은 다시 누를 수 없고, 반려되면 다시 제출할 수 있다고 알린다', (tester) async {
      await pumpScreen(
        tester,
        entries: () => [pending(1, revisionRequestedAt: 1794187428)],
        requestRevision: (_) async => throw StateError('호출되면 안 된다'),
      );
      expect(requestLabel, findsNothing);
      expect(find.textContaining('수정 요청함'), findsOneWidget);
      expect(find.textContaining('반려'), findsWidgets);
    });

    testWidgets('요청이 거절되면 이유를 보이고, 버튼은 그대로 남는다', (tester) async {
      await pumpScreen(tester, entries: () => [pending(1)], requestRevision: (_) async {
        throw const EntryDecisionException(EntryDecisionFailure.conflict, '이미 확정 처리 중이에요. 정정 등록으로 진행해 주세요.');
      });
      await tester.tap(requestLabel);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('revision_confirm')));
      await tester.pumpAndSettle();
      expect(find.textContaining('정정 등록으로 진행'), findsOneWidget);
      expect(requestLabel, findsOneWidget);
    });
  });
}
