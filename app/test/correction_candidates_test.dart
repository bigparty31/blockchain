import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/screens/council/correction_screen.dart';
import 'package:student_council_app/services/api_service.dart';

import 'support/registration.dart';
import 'support/session.dart';

/// 정정 대상 후보 목록 — ID 를 외우지 않아도 `id:1 | 사용처:농협 | 금액:800원` 을 눌러 고른다.
void main() {
  const occurredAt = 1790694000;

  Map<String, dynamic> entryJson(
    int id, {
    int amount = 800,
    String counterparty = '농협',
    String status = 'CONFIRMED',
    String kind = 'EXPENSE',
    int? corrects,
  }) =>
      {
        'id': id,
        'term_id': 1,
        'term_code': 20262,
        'kind': kind,
        'amount': amount,
        'counterparty': counterparty,
        'purpose': '시험 내역',
        'budget_id': 1,
        'occurred_at': occurredAt,
        'receipt_hash': null,
        'receipt_path': null,
        'meta_hash': Hashing.metaHash(
            amount: amount, counterparty: counterparty, purpose: '시험 내역', occurredAt: occurredAt, receiptHash: null),
        'ocr_status': null,
        'category_warning': false,
        'status': status,
        'created_by': 2,
        'corrects_entry_id': corrects,
        'correction_reason': corrects == null ? null : 'INPUT_ERROR',
      };

  EntryModel model(Map<String, dynamic> j) => EntryModel.fromJson(j);

  group('correctableChains · correctableLabel', () {
    test('확정된 원본만, 승인 대기 정정이 없는 것만, 최신이 위', () {
      final list = [
        model(entryJson(1)),
        model(entryJson(2, status: 'PENDING')), // 아직 확정 전
        model(entryJson(3, status: 'REJECTED')),
        model(entryJson(4, counterparty: '한결문구', amount: 35000)),
        model(entryJson(5, amount: -100, corrects: 4, status: 'PENDING')), // 4 는 정정 대기 중
        model(entryJson(6, amount: 500000, counterparty: '학생회비', kind: 'INCOME')),
        model(entryJson(7, amount: -50, corrects: 1)), // 1 의 확정된 정정
      ];
      final chains = correctableChains(list);
      expect(chains.map((c) => c.original.id), [6, 1], reason: '정정 항목(7)·대기(2)·반려(3)·정정 대기 중(4)은 후보가 아니다');
    });

    test('한 줄은 id | 사용처 | 금액, 수입은 출처이고 확정된 정정이 반영된 현재 금액이다', () {
      final list = [
        model(entryJson(1, amount: 800, counterparty: '농협')),
        model(entryJson(7, amount: -300, corrects: 1)),
        model(entryJson(6, amount: 500000, counterparty: '학생회비', kind: 'INCOME')),
      ];
      final labels = correctableChains(list).map(correctableLabel).toList();
      expect(labels, ['id:6 | 출처:학생회비 | 금액:500,000원', 'id:1 | 사용처:농협 | 금액:500원']);
    });
  });

  group('정정 화면의 후보 목록', () {
    late List<Map<String, dynamic>> server;
    late FakeRegistrar reg;

    setUp(() async {
      await signInAs(UserRole.TREASURER);
      ApiService.useDemoData = false;
      server = [
        entryJson(1, amount: 800, counterparty: '농협'),
        entryJson(2, amount: 60000, counterparty: '한결문구'),
        entryJson(3, amount: 9000, counterparty: '대학마트', status: 'PENDING'),
      ];
      ApiService.client = MockClient((req) async {
        if (req.url.path == '/entries') {
          return http.Response(jsonEncode(server), 200, headers: {'content-type': 'application/json; charset=utf-8'});
        }
        if (req.url.path == '/budgets') return http.Response('[]', 200);
        return http.Response('{}', 404);
      });
    });

    tearDown(() async {
      ApiService.client = http.Client();
      await signOutForTest();
    });

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(411, 2800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      reg = FakeRegistrar();
      await tester.pumpWidget(MaterialApp(home: CorrectionScreen(registrar: reg, pickReceipt: fakeReceipt)));
      await tester.pumpAndSettle();
    }

    testWidgets('입력칸 아래에 정정할 수 있는 내역이 한 줄씩 보인다 (확정된 것만)', (tester) async {
      await pump(tester);
      expect(find.text('id:2 | 사용처:한결문구 | 금액:60,000원'), findsOneWidget);
      expect(find.text('id:1 | 사용처:농협 | 금액:800원'), findsOneWidget);
      expect(find.textContaining('대학마트'), findsNothing, reason: '승인 대기 중인 건은 정정할 수 없다');
    });

    testWidgets('한 줄을 누르면 ID 가 채워지고 바로 조회된다', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('correctable_1')));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextFormField, '1'), findsOneWidget, reason: 'ID 입력칸에 1 이 들어갔다');
      expect(find.text('#1 농협'), findsOneWidget, reason: '조회 결과 카드가 떴다');
      expect(find.text('id:1 | 사용처:농협 | 금액:800원'), findsNothing, reason: '고른 뒤에는 후보 목록을 접는다');
    });

    testWidgets('ID 를 입력하면 그 숫자가 들어간 내역만 남는다', (tester) async {
      await pump(tester);
      await tester.enterText(find.widgetWithText(TextFormField, '').first, '2');
      await tester.pumpAndSettle();
      expect(find.text('id:2 | 사용처:한결문구 | 금액:60,000원'), findsOneWidget);
      expect(find.text('id:1 | 사용처:농협 | 금액:800원'), findsNothing);
    });

    testWidgets('내역을 못 읽어도 화면은 그대로 쓰고, 조회가 이유를 보인다', (tester) async {
      ApiService.client = MockClient((req) async => http.Response('{}', 503));
      await pump(tester);
      expect(find.textContaining('사용처:'), findsNothing);

      await tester.enterText(find.widgetWithText(TextFormField, '').first, '1');
      await tester.tap(find.text('내역 조회'));
      await tester.pumpAndSettle();
      expect(find.textContaining('찾을 수 없어요'), findsNothing, reason: '못 읽은 것을 「없는 내역」이라고 적으면 안 된다');
    });
  });
}
