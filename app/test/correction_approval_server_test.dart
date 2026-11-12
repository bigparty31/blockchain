import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/core/signing/ledger_types.dart';
import 'package:student_council_app/core/signing/signing_service.dart';
import 'package:student_council_app/models/budget_model.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/screens/council/correction_approval_screen.dart';
import 'package:student_council_app/services/api_service.dart';
import 'package:student_council_app/services/chain_domain_service.dart';
import 'package:student_council_app/services/entry_decision_service.dart';

import 'support/registration.dart';
import 'support/session.dart';
import 'support/signing.dart';

/// 정정 승인 화면 — 서버의 정정 건(`corrects_entry_id`)을 원본과 대조해 보여 주고, 승인·반려를 서명해 보낸다.
void main() {
  const occurredAt = 1790694000;

  /// 서버 `EntryResponse` 모양. meta_hash 는 등록 내용으로 계산해 넣는다.
  Map<String, dynamic> entryJson(
    int id, {
    int amount = 35000,
    String purpose = '신입생 환영회 명찰',
    String status = 'CONFIRMED',
    int createdBy = 2,
    int? budgetId = 1,
    String kind = 'EXPENSE',
    int? corrects,
    String? reason,
    String? ocrStatus,
    int? revisionRequestedAt,
    String? receiptHash,
    String? receiptPath,
  }) =>
      {
        'id': id,
        'term_id': 1,
        'term_code': 20262,
        'kind': kind,
        'amount': amount,
        'counterparty': '한결문구',
        'purpose': purpose,
        'budget_id': budgetId,
        'occurred_at': occurredAt,
        'receipt_hash': receiptHash,
        'receipt_path': receiptPath,
        'meta_hash': Hashing.metaHash(
            amount: amount, counterparty: '한결문구', purpose: purpose, occurredAt: occurredAt, receiptHash: receiptHash),
        'ocr_status': ocrStatus,
        'category_warning': false,
        'status': status,
        'created_by': createdBy,
        'corrects_entry_id': corrects,
        'correction_reason': reason,
        'revision_requested_at': revisionRequestedAt,
      };

  EntryModel entry(int id,
          {int amount = 35000,
          String status = 'CONFIRMED',
          int? budgetId = 1,
          String kind = 'EXPENSE',
          int? corrects,
          String? reason,
          String purpose = '신입생 환영회 명찰'}) =>
      EntryModel.fromJson(entryJson(id,
          amount: amount, status: status, budgetId: budgetId, kind: kind, corrects: corrects, reason: reason, purpose: purpose));

  BudgetModel budget(int id, String category, int remaining) => BudgetModel(
        id: id,
        termId: 1,
        category: category,
        plannedAmount: 1000000,
        remainingAmount: remaining,
        executionRate: 0,
        version: 1,
        expiresAt: 1797260399,
      );

  group('correctionItemsFromEntries', () {
    test('정정 건만 골라 원본과 증감분·정정 후 금액을 맞춘다 — 원본 이름은 원본 내역에서 온다', () {
      final items = correctionItemsFromEntries(
        [
          entry(1),
          entry(2, amount: -5000, status: 'PENDING', corrects: 1, reason: 'INPUT_ERROR', purpose: '금액 입력 오류'),
          entry(3, amount: 9000, purpose: '정정과 무관한 다른 내역'),
        ],
        budgets: [budget(1, '행사비', 900000)],
      );
      expect(items, hasLength(1));
      final c = items.single;
      expect(c.id, 2);
      expect(c.title, '신입생 환영회 명찰');
      expect(c.original, 35000);
      expect(c.delta, -5000);
      expect(c.finalAmount, 30000);
      expect(c.category, '행사비');
      expect(c.reason, CorrectionReason.INPUT_ERROR);
      expect(c.note, '금액 입력 오류');
      expect(c.status, '대기');
      expect(c.budgetRemaining, 900000);
      expect(c.entry, isNotNull);
    });

    test('같은 원본의 앞선 확정 정정은 「원본」에 이미 들어 있다 — 대기 정정은 들어가지 않는다', () {
      final items = correctionItemsFromEntries([
        entry(1),
        entry(2, amount: -5000, corrects: 1, reason: 'INPUT_ERROR'),
        entry(3, amount: 2000, status: 'PENDING', corrects: 1, reason: 'INPUT_ERROR'),
        entry(4, amount: 100, status: 'PENDING', corrects: 1, reason: 'INPUT_ERROR'),
      ]);
      final third = items.firstWhere((c) => c.id == 3);
      expect(third.original, 30000, reason: '35,000 + 확정된 −5,000');
      expect(third.finalAmount, 32000);
      final fourth = items.firstWhere((c) => c.id == 4);
      expect(fourth.original, 30000, reason: '#3 은 아직 대기라 반영하지 않는다');
    });

    test('대기가 앞에 등록 순으로, 처리된 건이 뒤에 최근 순으로 온다 — 차단 건은 승인 대상이 아니라 뺀다', () {
      final items = correctionItemsFromEntries([
        entry(1),
        entry(2, amount: -1000, corrects: 1, reason: 'INPUT_ERROR'),
        entry(3, amount: -2000, status: 'PENDING', corrects: 1, reason: 'INPUT_ERROR'),
        entry(4, amount: -3000, status: 'REJECTED', corrects: 1, reason: 'INPUT_ERROR'),
        entry(5, amount: -4000, status: 'PENDING', corrects: 1, reason: 'INPUT_ERROR'),
        entry(6, amount: 9000, status: 'BLOCKED', corrects: 1, reason: 'INPUT_ERROR'),
      ]);
      expect(items.map((c) => c.id), [3, 5, 4, 2]);
      expect(items.map((c) => c.status), ['대기', '대기', '반려', '확정']);
    });

    test('재분류는 짝을 찾아 「재분류 진행 중」으로 적고, 증액(+) 쪽은 새 예산에서 0 으로 시작한다', () {
      final items = correctionItemsFromEntries(
        [
          entry(1, amount: 22000, budgetId: 3),
          entry(2, amount: 22000, budgetId: 2, corrects: 1, reason: 'RECLASSIFY'), // + 확정
          entry(3, amount: -22000, budgetId: 3, status: 'PENDING', corrects: 1, reason: 'RECLASSIFY'), // − 대기
        ],
        budgets: [budget(2, '사업비', 1465000), budget(3, '운영비', 1000000)],
      );
      final minus = items.firstWhere((c) => c.id == 3);
      expect(minus.status, '재분류 진행 중');
      expect(minus.pairNote, '사업비 +22,000 확정 · 운영비 −22,000 대기 (짝 1/2)');
      expect(minus.original, 22000, reason: '확정된 +22,000 은 사업비의 금액이라 운영비의 원본에 더하지 않는다');
      expect(minus.finalAmount, 0);
      final plus = items.firstWhere((c) => c.id == 2);
      expect(plus.original, 0);
      expect(plus.finalAmount, 22000);
      expect(plus.category, '사업비');
    });

    test('재분류로 옮겨 간 증액 건을 다시 정정하면 그 건의 금액에서 시작한다 — 최초 원본에서 시작하지 않는다 (#74 리뷰)', () {
      final items = correctionItemsFromEntries(
        [
          entry(1, amount: 100000, budgetId: 1),
          entry(2, amount: 100000, budgetId: 2, corrects: 1, reason: 'RECLASSIFY'), // A → B 증액, 확정
          entry(3, amount: -100000, budgetId: 1, corrects: 1, reason: 'RECLASSIFY'), // A 감액, 확정
          entry(4, amount: -20000, budgetId: 2, status: 'PENDING', corrects: 2, reason: 'REFUND'), // B 의 증액 건을 대상으로 환불
        ],
        budgets: [budget(1, '운영비', 0), budget(2, '사업비', 500000)],
      );
      final refund = items.firstWhere((c) => c.id == 4);
      expect(refund.original, 100000, reason: 'B 의 현재 금액. 0 이 아니다');
      expect(refund.finalAmount, 80000);
      expect(refund.title, '신입생 환영회 명찰', reason: '이름은 맨 처음 원본에서 온다');
    });

    test('정정 전 금액에는 등록 번호와 상관없이 지금 확정된 같은 대상의 정정이 모두 들어간다 (#74 리뷰)', () {
      final items = correctionItemsFromEntries([
        entry(1, amount: 50000),
        entry(2, amount: -10000, status: 'PENDING', corrects: 1, reason: 'INPUT_ERROR'),
        entry(3, amount: 5000, corrects: 1, reason: 'INPUT_ERROR'), // 번호는 뒤지만 먼저 확정됨
      ]);
      final waiting = items.firstWhere((c) => c.id == 2);
      expect(waiting.original, 55000, reason: '50,000 + 확정된 +5,000');
      expect(waiting.finalAmount, 45000);
    });

    test('이미 처리된 건은 확정 순서를 알 수 없으면 정정 전·후 금액을 비워 둔다 — 지어내지 않는다', () {
      final items = correctionItemsFromEntries([
        entry(1, amount: 50000),
        entry(2, amount: -10000, corrects: 1, reason: 'INPUT_ERROR'),
        entry(3, amount: 5000, corrects: 1, reason: 'INPUT_ERROR'),
        entry(4, amount: 100, corrects: 9, reason: 'INPUT_ERROR'), // 원본 없음(별개)
        entry(5, amount: 70000),
        entry(6, amount: -7000, corrects: 5, reason: 'INPUT_ERROR'), // 같은 대상의 다른 확정 정정이 없다
      ]);
      expect(items.firstWhere((c) => c.id == 2).original, isNull);
      expect(items.firstWhere((c) => c.id == 3).original, isNull);
      expect(items.firstWhere((c) => c.id == 6).original, 70000, reason: '다른 확정 정정이 없으면 정확히 안다');
      expect(items.firstWhere((c) => c.id == 6).finalAmount, 63000);
    });

    test('재분류 짝은 같은 정정 대상·반대 부호·같은 금액으로 고른다 — 과거 재분류의 확정 건과 묶지 않는다 (#74 리뷰)', () {
      final items = correctionItemsFromEntries(
        [
          entry(1, amount: 100000, budgetId: 1),
          entry(2, amount: 100000, budgetId: 2, corrects: 1, reason: 'RECLASSIFY'), // A→B 완료
          entry(3, amount: -100000, budgetId: 1, corrects: 1, reason: 'RECLASSIFY'),
          entry(4, amount: 100000, budgetId: 3, status: 'PENDING', corrects: 2, reason: 'RECLASSIFY'), // B→C 대기
          entry(5, amount: -100000, budgetId: 2, status: 'PENDING', corrects: 2, reason: 'RECLASSIFY'),
        ],
        budgets: [budget(1, '운영비', 0), budget(2, '사업비', 0), budget(3, '홍보비', 0)],
      );
      final minus = items.firstWhere((c) => c.id == 5);
      expect(minus.pairNote, '홍보비 +100,000 대기 · 사업비 −100,000 대기 (짝 0/2)');
      expect(minus.status, '재분류 진행 중');
      final plus = items.firstWhere((c) => c.id == 4);
      expect(plus.pairNote, '홍보비 +100,000 대기 · 사업비 −100,000 대기 (짝 0/2)');
    });

    test('재분류 짝 후보가 하나로 정해지지 않으면 짝 상태를 단정하지 않는다 (#74 리뷰)', () {
      final items = correctionItemsFromEntries(
        [
          entry(1, amount: 100000, budgetId: 1),
          entry(2, amount: -30000, budgetId: 1, status: 'PENDING', corrects: 1, reason: 'RECLASSIFY'),
          entry(3, amount: 30000, budgetId: 2, status: 'PENDING', corrects: 1, reason: 'RECLASSIFY'),
          entry(4, amount: 30000, budgetId: 3, status: 'PENDING', corrects: 1, reason: 'RECLASSIFY'),
        ],
        budgets: [budget(1, '운영비', 0), budget(2, '사업비', 0), budget(3, '홍보비', 0)],
      );
      final minus = items.firstWhere((c) => c.id == 2);
      expect(minus.pairNote, isNull, reason: '+30,000 후보가 둘이라 어느 쪽이 짝인지 모른다');
      expect(minus.status, '대기');
      // 증액 카드 쪽에서 보면 감액 후보는 하나뿐이지만, 그 감액의 짝 후보가 둘이라 어느 쪽도 짝이라 단정할 수 없다 (#74 리뷰 4차)
      for (final id in [3, 4]) {
        final plus = items.firstWhere((c) => c.id == id);
        expect(plus.pairNote, isNull, reason: '두 증액 카드가 같은 감액을 각자의 짝으로 보이면 안 된다');
        expect(plus.status, '대기');
      }
    });

    test('원본이 목록에 없으면 정정 후 금액을 지어내지 않는다', () {
      final items = correctionItemsFromEntries([entry(2, amount: -5000, status: 'PENDING', corrects: 77, reason: 'REFUND')]);
      expect(items.single.original, isNull);
      expect(items.single.finalAmount, isNull);
      expect(items.single.title, contains('#77'));
    });

    test('수입 정정과 예산을 못 읽은 지출은 잔량을 모른다 — 미리 막지 않는다', () {
      final items = correctionItemsFromEntries([
        entry(1, kind: 'INCOME', budgetId: null, amount: 2000000),
        entry(2, kind: 'INCOME', budgetId: null, amount: 50000, status: 'PENDING', corrects: 1, reason: 'INPUT_ERROR'),
        entry(3),
        entry(4, amount: 99999999, status: 'PENDING', corrects: 3, reason: 'INPUT_ERROR'),
      ]);
      final income = items.firstWhere((c) => c.id == 2);
      expect(income.budgetRemaining, isNull);
      expect(income.insufficient, isFalse);
      expect(income.category, '수입');
      final unknown = items.firstWhere((c) => c.id == 4);
      expect(unknown.category, '예산 #1');
      expect(unknown.budgetRemaining, isNull);
      expect(unknown.insufficient, isFalse);
    });

    test('잔량을 읽었고 증액분이 잔량을 넘으면 확정할 수 없다', () {
      final items = correctionItemsFromEntries(
        [entry(1), entry(2, amount: 1600000, status: 'PENDING', corrects: 1, reason: 'RECEIPT_RECHECK')],
        budgets: [budget(1, '행사비', 900000)],
      );
      expect(items.single.insufficient, isTrue);
    });
  });

  group('화면', () {
    final domainJson = loadEip712Vectors()['domain'] as Map<String, dynamic>;

    http.Response json(Object body, [int status = 200]) => http.Response(
          jsonEncode(body),
          status,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );

    late List<Map<String, dynamic>> serverEntries;
    late List<http.Request> confirms;
    late List<http.Request> rejects;
    late http.Response Function() onConfirm;
    late http.Response Function() onEntries;
    late int remaining;

    setUp(() async {
      await signInAs(UserRole.AUDITOR, userId: 3);
      ApiService.useDemoData = false;
      await useAuditorDeviceKey();
      confirms = [];
      rejects = [];
      remaining = 900000;
      serverEntries = [
        entryJson(1),
        entryJson(2, amount: -5000, status: 'PENDING', corrects: 1, reason: 'INPUT_ERROR', purpose: '금액 입력 오류'),
        entryJson(3, amount: 7000, status: 'PENDING', corrects: 1, reason: 'INPUT_ERROR', createdBy: 3, purpose: '감사 본인이 등록한 정정'),
      ];
      onEntries = () => json(serverEntries);
      onConfirm = () => json({'id': 2, 'status': 'CONFIRMED', 'tx_confirm': '0x${'cd' * 32}'});
      final server = MockClient((req) async {
        final single = RegExp(r'^/entries/(\d+)$').firstMatch(req.url.path);
        if (req.method == 'GET' && single != null) {
          final list = onEntries();
          if (list.statusCode != 200) return list;
          final id = int.parse(single.group(1)!);
          for (final e in (jsonDecode(list.body) as List).cast<Map<String, dynamic>>()) {
            if (e['id'] == id) return json(e);
          }
          return json({'detail': 'not found'}, 404);
        }
        switch ('${req.method} ${req.url.path}') {
          case 'GET /entries':
            return onEntries();
          case 'GET /budgets':
            return json([
              {'id': 1, 'term_id': 1, 'category': '행사비', 'planned_amount': 1000000, 'remaining_amount': remaining},
            ]);
          case 'GET /chain/domains':
            return json({'domains': {LedgerTypes.domainName: domainJson}});
          case 'GET /users/wallets':
            return json({treasurerAddress: 2, auditorAddress: 3});
          case 'POST /entries/2/confirm':
            confirms.add(req);
            return onConfirm();
          case 'POST /entries/2/reject':
            rejects.add(req);
            return json({'id': 2, 'status': 'REJECTED'});
        }
        return http.Response('{}', 404);
      });
      ApiService.client = server;
      ChainDomainService.client = server;
      EntryDecisionService.client = server;
    });

    tearDown(() async {
      ApiService.client = http.Client();
      ChainDomainService.client = http.Client();
      EntryDecisionService.client = http.Client();
      await signOutForTest();
    });

    Future<void> waitUntil(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(done(), isTrue, reason: '기다리던 상태가 오지 않았다');
      await tester.pumpAndSettle();
    }

    bool shows(Finder f) => f.evaluate().isNotEmpty;

    Future<void> pump(WidgetTester tester, {FakeRegistrar? registrar}) async {
      tester.view.physicalSize = const Size(411, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: CorrectionApprovalScreen(
          registrar: registrar,
          decisions: EntryDecisionService(
            signer: SigningService(authenticator: FakeAuthenticator()),
            now: () => DateTime.utc(2026, 11, 6, 9),
          ),
        ),
      ));
      await waitUntil(tester, () => shows(find.textContaining('금액 입력 오류')) || shows(find.byKey(const Key('corrections_failed'))));
    }

    testWidgets('서버의 정정 건을 원본과 나란히 보여 준다 — 목업 건은 섞지 않는다', (tester) async {
      await pump(tester);
      expect(find.text('신입생 환영회 명찰'), findsWidgets); // 원본 내역 이름
      expect(find.text('₩ 35,000'), findsWidgets); // 원본
      expect(find.text('-₩ 5,000'), findsOneWidget); // 증감분
      expect(find.text('₩ 30,000'), findsOneWidget); // 정정 후
      expect(find.textContaining('정정 내용 · 금액 입력 오류'), findsOneWidget);
      expect(find.text('청년피자 개강총회 다과 주문'), findsNothing); // 목업 목록
      expect(find.text('대기 2건'), findsOneWidget);
    });

    testWidgets('본인이 등록한 정정은 승인·반려할 수 없다', (tester) async {
      await pump(tester);
      expect(find.text('본인이 등록한 건은 승인·반려할 수 없어요'), findsOneWidget);
      expect(find.text('승인'), findsOneWidget); // 총무가 올린 #2 만
    });

    testWidgets('승인하면 서명해 보내고, 보낸 서명은 그 정정 건(#2)의 것이다', (tester) async {
      await pump(tester);
      await tester.tap(find.text('승인'));
      await tester.pumpAndSettle();
      expect(find.text('정정 승인'), findsWidgets);
      await tester.tap(find.text('생체인증 승인'));
      await waitUntil(tester, () => shows(find.textContaining('정정 승인 완료!')));

      expect(confirms, hasLength(1));
      final body = jsonDecode(confirms.single.body) as Map<String, dynamic>;
      expect(body['signature'], startsWith('0x'));
      expect(body.containsKey('warning_reason'), isFalse, reason: '경고 없는 건에는 사유를 보내지 않는다');
    });

    testWidgets('영수증 판독 경고가 있는 정정은 사유를 먼저 받고 함께 보낸다', (tester) async {
      serverEntries[1] = entryJson(2,
          amount: -5000, status: 'PENDING', corrects: 1, reason: 'INPUT_ERROR', purpose: '금액 입력 오류', ocrStatus: 'MISMATCH');
      await pump(tester);
      await tester.tap(find.text('승인'));
      await tester.pumpAndSettle();
      expect(find.text('경고 무시 승인 사유'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), '영수증 금액을 직접 확인했습니다');
      await tester.tap(find.text('다음'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('생체인증 승인'));
      await waitUntil(tester, () => confirms.isNotEmpty);
      expect((jsonDecode(confirms.single.body) as Map)['warning_reason'], '영수증 금액을 직접 확인했습니다');
    });

    testWidgets('증액 정정이 잔량을 넘으면 서명을 받기 전에 막고, 서버로 아무것도 보내지 않는다', (tester) async {
      serverEntries[1] = entryJson(2, amount: 950000, status: 'PENDING', corrects: 1, reason: 'RECEIPT_RECHECK', purpose: '금액 입력 오류');
      await pump(tester);
      await tester.tap(find.text('승인'));
      await tester.pumpAndSettle();
      expect(find.text('확정할 수 없어요'), findsOneWidget);
      expect(find.text('생체인증 승인'), findsNothing);
      expect(confirms, isEmpty);
    });

    testWidgets('체인이 예산 부족으로 거부하면 반려로 넘길 수 있다 — 항목은 대기 그대로', (tester) async {
      onConfirm = () => json({'detail': '온체인 승인이 거부되었습니다 (InsufficientBudget).', 'fail_reason': 'InsufficientBudget'}, 400);
      await pump(tester);
      await tester.tap(find.text('승인'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('생체인증 승인'));
      await waitUntil(tester, () => shows(find.text('승인에 실패했어요')));
      expect(find.textContaining('예산 잔량이 부족해요'), findsOneWidget);
      expect(find.text('반려로 처리'), findsOneWidget);

      await tester.tap(find.text('반려로 처리'));
      await tester.pumpAndSettle();
      expect(find.text('정정 반려 사유'), findsOneWidget);
      expect(find.textContaining('예산 잔량이 부족해요. 확정할 수 없어 반려합니다.'), findsOneWidget);
    });

    testWidgets('예산과 무관한 거부는 반려를 권하지 않는다', (tester) async {
      onConfirm = () => json({'detail': '온체인 승인이 거부되었습니다 (SignatureExpired).', 'fail_reason': 'SignatureExpired'}, 400);
      await pump(tester);
      await tester.tap(find.text('승인'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('생체인증 승인'));
      await waitUntil(tester, () => shows(find.text('승인에 실패했어요')));
      expect(find.text('반려로 처리'), findsNothing);
      expect(find.text('나중에'), findsOneWidget);
    });

    testWidgets('총무가 수정을 요청한 정정은 승인을 막고 반려만 남긴다 — 서명 단계로 가지 않는다', (tester) async {
      serverEntries[1] = entryJson(2,
          amount: -5000, status: 'PENDING', corrects: 1, reason: 'INPUT_ERROR', purpose: '금액 입력 오류', revisionRequestedAt: 1790700000);
      await pump(tester);
      expect(find.text('총무가 수정을 요청했어요 — 반려만 할 수 있어요'), findsOneWidget);
      expect(find.byKey(const Key('correction_approve_blocked')), findsOneWidget);
      expect(find.text('승인'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, '반려'), findsOneWidget);
      expect(confirms, isEmpty);
    });

    testWidgets('수정 요청이 걸린 정정도 반려는 서명해 보낼 수 있다', (tester) async {
      serverEntries[1] = entryJson(2,
          amount: -5000, status: 'PENDING', corrects: 1, reason: 'INPUT_ERROR', purpose: '금액 입력 오류', revisionRequestedAt: 1790700000);
      await pump(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, '반려'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '다시 올려 주세요');
      await tester.tap(find.text('반려하기'));
      await waitUntil(tester, () => shows(find.textContaining('정정이 반려되었습니다.')));
      expect(rejects, hasLength(1));
    });

    // 정정 승인에도 영수증 해시 대조가 있어야 한다 — 일반 승인에서만 막으면 파일이 바뀐 정정이 이쪽으로 서명·전송된다 (#74 리뷰).
    group('승인 전 영수증 대조', () {
      final original = [1, 2, 3, 4];
      final path = FakeRegistrar.pathOf(original);
      final hash = Hashing.fileHash(original);

      void withReceipt() {
        serverEntries[1] = entryJson(2,
            amount: -5000, status: 'PENDING', corrects: 1, reason: 'INPUT_ERROR', purpose: '금액 입력 오류', receiptHash: hash, receiptPath: path);
      }

      testWidgets('서버의 파일이 등록 때와 다르면 사유·서명 단계로 가지 않고 안내만 한다', (tester) async {
        withReceipt();
        final registrar = FakeRegistrar()..stored[path] = [9, 9, 9];
        await pump(tester, registrar: registrar);
        await tester.tap(find.text('승인'));
        await tester.pumpAndSettle();
        await waitUntil(tester, () => shows(find.byKey(const Key('receipt_blocks_approval'))));
        expect(find.text('영수증이 등록 때와 달라요'), findsOneWidget);
        await tester.tap(find.text('닫기'));
        await tester.pumpAndSettle();
        expect(find.text('생체인증 승인'), findsNothing, reason: '서명 단계로 가지 않는다');
        expect(confirms, isEmpty);
      });

      testWidgets('파일이 같으면 그대로 서명 단계로 간다', (tester) async {
        withReceipt();
        final registrar = FakeRegistrar()..stored[path] = original;
        await pump(tester, registrar: registrar);
        await tester.tap(find.text('승인'));
        await tester.pumpAndSettle();
        await waitUntil(tester, () => shows(find.text('생체인증 승인')));
        await tester.tap(find.text('생체인증 승인'));
        await waitUntil(tester, () => shows(find.textContaining('정정 승인 완료!')));
        expect(confirms, hasLength(1));
      });

      testWidgets('원본을 받지 못하면 대조하지 못했다고 알리고, 취소하면 서명하지 않는다', (tester) async {
        withReceipt();
        final registrar = FakeRegistrar(); // 서버에 파일이 없다
        await pump(tester, registrar: registrar);
        await tester.tap(find.text('승인'));
        await tester.pumpAndSettle();
        await waitUntil(tester, () => shows(find.byKey(const Key('receipt_unavailable_confirm'))));
        await tester.tap(find.text('취소'));
        await tester.pumpAndSettle();
        expect(find.text('생체인증 승인'), findsNothing);
        expect(confirms, isEmpty);
      });
    });

    testWidgets('반려하면 사유를 서명해 보낸다', (tester) async {
      await pump(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, '반려'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '정정할 이유가 없어요');
      await tester.tap(find.text('반려하기'));
      await waitUntil(tester, () => shows(find.textContaining('정정이 반려되었습니다.')));
      expect(rejects, hasLength(1));
      expect((jsonDecode(rejects.single.body) as Map)['reject_reason'], '정정할 이유가 없어요');
    });

    testWidgets('목록을 못 읽으면 목업으로 메우지 않고 이유와 다시 시도를 보인다 — 다시 시도로 회복한다', (tester) async {
      onEntries = () => json({'detail': 'db down'}, 503);
      await pump(tester);
      expect(find.byKey(const Key('corrections_failed')), findsOneWidget);
      expect(find.text('청년피자 개강총회 다과 주문'), findsNothing);

      onEntries = () => json(serverEntries);
      await tester.tap(find.text('다시 시도'));
      await waitUntil(tester, () => shows(find.textContaining('금액 입력 오류')));
    });

    testWidgets('정정 건이 없으면 비었다고 말한다', (tester) async {
      serverEntries = [entryJson(1)];
      tester.view.physicalSize = const Size(411, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: CorrectionApprovalScreen()));
      await waitUntil(tester, () => shows(find.byKey(const Key('corrections_empty'))));
      expect(find.text('정정 건이 없어요'), findsOneWidget);
    });
  });
}
