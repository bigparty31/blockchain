import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/models/draft_entry.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/screens/council/my_entries_screen.dart';
import 'package:student_council_app/services/api_service.dart';

import 'support/registration.dart';

/// 초안 목록 (PRD §4.3 T5, `GET /entries/drafts`, 서버 #76).
///
/// 초안은 **체인에 올리지 않은** 건이라 `status` 가 없다(null). `EntryModel` 은 `status` 없는 응답을 계약 위반으로
/// 던지게 해 두었으므로(초안을 「승인대기」로 바꿔 보이지 않으려고) 초안은 따로 읽는다 ([DraftEntry]).
Map<String, Object?> draftJson(
  int id, {
  String kind = 'EXPENSE',
  int? corrects,
  String? receiptHash,
  String? receiptPath,
  Object? status,
}) =>
    {
      'id': id,
      'term_id': 1,
      'term_code': 20262,
      'kind': kind,
      'amount': 12000,
      'counterparty': '거래처$id',
      'purpose': '목적$id',
      'budget_id': kind == 'INCOME' ? null : 1,
      'occurred_at': 1788793200,
      'receipt_hash': receiptHash,
      'receipt_path': receiptPath,
      'meta_hash': '0x${'0' * 64}',
      'status': status,
      'created_by': 2,
      'corrects_entry_id': corrects,
      'correction_reason': corrects == null ? null : 'INPUT_ERROR',
    };

DraftEntry draft(int id, {String kind = 'EXPENSE', int? corrects, String? receiptHash, String? receiptPath}) =>
    DraftEntry.fromJson(draftJson(id, kind: kind, corrects: corrects, receiptHash: receiptHash, receiptPath: receiptPath));

EntryModel pending(int id) => EntryModel(
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
    );

void main() {
  setUp(() => ApiService.useDemoData = true);

  group('DraftEntry', () {
    test('status 가 null 인 응답을 읽고, 이어서 제출할 초안(EntryDraft)으로 바꾼다', () {
      final d = draft(7, receiptHash: '0xABC', receiptPath: '/receipts/abc.jpg');
      expect((d.id, d.termId, d.kind, d.amount, d.budgetId), (7, 1, EntryKind.EXPENSE, 12000, 1));
      final e = d.toEntryDraft();
      expect(e.kind, EntryKind.EXPENSE);
      expect((e.termId, e.amount, e.counterparty, e.purpose, e.budgetId, e.occurredAt), (1, 12000, '거래처7', '목적7', 1, 1788793200));
      expect(e.receiptHash, '0xabc', reason: '해시는 소문자로 — 화면이 만드는 초안과 같은 값이어야 번호를 다시 쓴다');
      expect(e.receiptPath, '/receipts/abc.jpg');
      expect(e.correctsEntryId, isNull);
    });

    test('정정 초안은 원본 번호와 사유를 가진다', () {
      final e = draft(8, corrects: 1).toEntryDraft();
      expect(e.correctsEntryId, 1);
      expect(e.correctionReason, CorrectionReason.INPUT_ERROR);
    });

    test('status 가 있는 응답은 초안이 아니다 — 계약 위반으로 던진다', () {
      expect(() => DraftEntry.fromJson(draftJson(9, status: 'PENDING')), throwsFormatException);
    });
  });

  group('ApiService.fetchDrafts', () {
    late List<http.Request> sent;
    setUp(() => sent = []);
    tearDown(() => ApiService.client = http.Client());

    http.Response json(int status, Object body) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

    test('초안 목록을 읽는다 — 읽을 수 없는 항목은 건너뛴다', () async {
      ApiService.client = MockClient((req) async {
        sent.add(req);
        return json(200, [draftJson(5), 'garbage', draftJson(6, status: 'PENDING'), draftJson(7, kind: 'INCOME')]);
      });
      final drafts = await ApiService().fetchDrafts();
      expect(sent.single.url.path, '/entries/drafts');
      expect(drafts.map((d) => d.id), [5, 7], reason: '문자열·status 있는 항목은 초안이 아니다');
    });

    test('서버가 이 API 를 모르거나(404) 고장나면(500) 지어내지 않고 못 읽었다고 한다 — 시연 모드에서도', () async {
      for (final code in [404, 500]) {
        ApiService.client = MockClient((_) async => json(code, {'detail': 'x'}));
        await expectLater(ApiService().fetchDrafts(), throwsA(isA<ApiUnavailable>()), reason: '$code');
      }
    });

    test('총무가 아니면(403) 권한 없음이다', () async {
      ApiService.client = MockClient((_) async => json(403, {'detail': 'x'}));
      await expectLater(ApiService().fetchDrafts(), throwsA(isA<ApiForbidden>()));
    });
  });

  group('내 등록 현황 — 초안', () {
    late FakeRegistrar reg;
    setUp(() => reg = FakeRegistrar());

    Future<void> waitFor(WidgetTester tester, Finder f) async {
      for (var i = 0; i < 60; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        if (f.evaluate().isNotEmpty) break;
      }
    }

    Future<void> open(
      WidgetTester tester, {
      List<EntryModel>? entries,
      Future<List<DraftEntry>> Function()? drafts,
    }) async {
      tester.view.physicalSize = const Size(411, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: MyEntriesScreen(
          currentUserId: 2,
          registrar: reg,
          loadEntries: () async => entries ?? [pending(5)],
          loadDrafts: drafts ?? () async => [draft(7), draft(3, kind: 'INCOME')],
        ),
      ));
      await waitFor(tester, find.textContaining('전체'));
      await tester.pumpAndSettle();
    }

    testWidgets('초안 칸이 생기고 초안은 「이어서 제출」을 가진다 — 번호 순으로 섞여 보인다', (tester) async {
      await open(tester);
      for (final t in ['전체 3', '초안 2', '대기 1']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.text('이어서 제출'), findsNWidgets(2));
    });

    testWidgets('초안이 없으면 초안 칸을 보이지 않는다', (tester) async {
      await open(tester, drafts: () async => const []);
      expect(find.textContaining('초안'), findsNothing);
    });

    testWidgets('초안 목록을 못 읽어도 등록 건 목록은 보이고, 이유를 적는다', (tester) async {
      await open(tester, drafts: () async => throw const ApiUnavailable('초안 목록'));
      expect(find.text('전체 1'), findsOneWidget);
      expect(find.byKey(const Key('drafts_failed')), findsOneWidget);
      expect(find.textContaining('초안'), findsWidgets);
    });

    testWidgets('지출 초안을 이어서 열면 저장해 둔 값이 채워지고 초안 안내가 보인다', (tester) async {
      await open(tester);
      await tester.tap(find.text('이어서 제출').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('draft_banner')), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '목적7'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '거래처7'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '12000'), findsOneWidget);
    });

    testWidgets('수입 초안은 수입 등록 화면을 연다', (tester) async {
      await open(tester);
      await tester.tap(find.text('이어서 제출').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('draft_banner')), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '거래처3'), findsOneWidget);
    });

    testWidgets('정정 초안은 정정 화면을 원본 번호로 연다', (tester) async {
      await open(tester, drafts: () async => [draft(8, corrects: 1)]);
      await tester.tap(find.text('이어서 제출'));
      await tester.pumpAndSettle();
      await waitFor(tester, find.textContaining('#1 한결문구'));
      expect(find.textContaining('#1 한결문구'), findsWidgets);
    });

    Future<void> resumeAndSubmit(WidgetTester tester, {String? newAmount}) async {
      final bytes = fakeReceiptBytes;
      final path = FakeRegistrar.pathOf(bytes);
      reg.stored[path] = bytes;
      await open(
        tester,
        drafts: () async => [draft(7, receiptHash: Hashing.fileHash(bytes), receiptPath: path)],
      );
      await tester.tap(find.text('이어서 제출'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 60 && reg.downloads.isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      if (newAmount != null) {
        await tester.enterText(find.widgetWithText(TextFormField, '12000'), newAmount);
      }
      await tester.ensureVisible(find.text('제출하기'));
      await tester.tap(find.text('제출하기'));
      await tester.pumpAndSettle();
    }

    testWidgets('바꾸지 않고 제출하면 저장해 둔 초안 번호를 그대로 쓴다 — 새 초안이 생기지 않는다', (tester) async {
      await resumeAndSubmit(tester);
      expect(reg.drafts, isEmpty, reason: '초안을 다시 저장하면 옛 초안이 목록에 남는다');
      expect(reg.submits.single.$1, 7);
      expect(reg.submits.single.$2.receiptHash, Hashing.fileHash(fakeReceiptBytes));
    });

    testWidgets('수입 초안도 바꾸지 않고 제출하면 저장해 둔 번호를 그대로 쓴다', (tester) async {
      await open(tester, drafts: () async => [draft(3, kind: 'INCOME')]);
      await tester.tap(find.text('이어서 제출'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('제출하기'));
      await tester.tap(find.text('제출하기'));
      await tester.pumpAndSettle();
      expect(reg.drafts, isEmpty);
      expect(reg.submits.single.$1, 3);
    });

    testWidgets('값을 고치면 새 초안으로 저장해 제출한다', (tester) async {
      await resumeAndSubmit(tester, newAmount: '15000');
      expect(reg.drafts.single.amount, 15000);
      expect(reg.submits.single.$1, 100, reason: '새로 발급된 번호');
    });
  });
}
