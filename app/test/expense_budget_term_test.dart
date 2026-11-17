import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/models/draft_entry.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/screens/council/budget_revision_screen.dart';
import 'package:student_council_app/screens/council/expense_create_screen.dart';
import 'package:student_council_app/services/api_service.dart';
import 'package:student_council_app/services/budget_revision_service.dart';

import 'support/registration.dart';

/// 같은 분류의 예산이 학기마다 있을 때 — `GET /budgets` 는 전 학기를 준다.
/// 분류 이름만으로 고르면 가장 오래된 학기의 예산에 지출이 올라간다.
void main() {
  late List<String> requested;

  http.Response json(Object body) =>
      http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

  Map<String, dynamic> budget(int id, int termId, String category, int remaining) => {
        'id': id,
        'term_id': termId,
        'category': category,
        'planned_amount': 1000000,
        'remaining_amount': remaining,
        'execution_rate': 0,
        'version': 1,
        'expires_at': 1797260399,
      };

  setUp(() {
    ApiService.useDemoData = false;
    requested = [];
    ApiService.client = MockClient((req) async {
      requested.add('${req.method} ${req.url.path}');
      switch (req.url.path) {
        case '/budgets':
          // 지난 학기(1)가 먼저 나오고 현재 학기(2)가 뒤에 온다
          return json([
            budget(1, 1, '행사비', 100000),
            budget(2, 1, '사업비', 200000),
            budget(3, 1, '운영비', 300000),
            budget(11, 2, '행사비', 900000),
            budget(12, 2, '사업비', 800000),
            budget(13, 2, '운영비', 700000),
          ]);
        case '/terms':
          return json([
            {'id': 1, 'term_code': 20261, 'started_at': '2000-01-01T00:00:00', 'ended_at': '2000-12-31T23:59:59'},
            {'id': 2, 'term_code': 20262, 'started_at': '2001-01-01T00:00:00', 'ended_at': '2999-12-31T23:59:59'},
          ]);
      }
      return http.Response('{}', 404);
    });
  });

  tearDown(() {
    ApiService.client = http.Client();
    ApiService.useDemoData = true;
  });

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(411, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: home));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('예산 항목은 현재 학기의 예산으로 보이고, 그 예산 번호·학기로 제출한다', (tester) async {
    final registrar = FakeRegistrar();
    await pump(tester, ExpenseCreateScreen(registrar: registrar, pickReceipt: fakeReceipt));

    expect(find.textContaining('잔량 ₩ 900,000'), findsOneWidget, reason: '현재 학기(2) 행사비의 잔량');
    expect(find.textContaining('잔량 ₩ 100,000'), findsNothing, reason: '지난 학기 행사비의 잔량이 아니다');

    await tester.tap(find.text('영수증 촬영 또는 사진 첨부'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '목적 *'), '신입생 환영회 명찰');
    await tester.enterText(find.widgetWithText(TextFormField, '사용처(상호명) *'), '한결문구');
    await tester.enterText(find.widgetWithText(TextFormField, '지출 금액(원) *'), '35000');
    await tester.ensureVisible(find.text('제출하기'));
    await tester.tap(find.text('제출하기'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    final draft = registrar.submits.single.$2;
    expect(draft.budgetId, 11, reason: '현재 학기 행사비 — 지난 학기 #1 이 아니다');
    expect(draft.termId, 2);
  });
  testWidgets('현재 학기에 없는 분류는 지난 학기 예산으로 제출하지 않고 막는다', (tester) async {
    ApiService.client = MockClient((req) async {
      switch (req.url.path) {
        case '/budgets':
          return json([budget(1, 1, '행사비', 100000), budget(3, 1, '운영비', 300000), budget(11, 2, '행사비', 900000)]);
        case '/terms':
          return json([
            {'id': 1, 'term_code': 20261, 'started_at': '2000-01-01T00:00:00', 'ended_at': '2000-12-31T23:59:59'},
            {'id': 2, 'term_code': 20262, 'started_at': '2001-01-01T00:00:00', 'ended_at': '2999-12-31T23:59:59'},
          ]);
      }
      return http.Response('{}', 404);
    });
    final registrar = FakeRegistrar();
    await pump(tester, ExpenseCreateScreen(registrar: registrar, pickReceipt: fakeReceipt));
    await tester.tap(find.text('영수증 촬영 또는 사진 첨부'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '목적 *'), '신입생 환영회 명찰');
    await tester.enterText(find.widgetWithText(TextFormField, '사용처(상호명) *'), '한결문구');
    await tester.enterText(find.widgetWithText(TextFormField, '지출 금액(원) *'), '35000');
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('운영비').last); // 현재 학기(2)에는 운영비 예산이 없다
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('제출하기'));
    await tester.tap(find.text('제출하기'));
    await tester.pumpAndSettle();

    expect(registrar.drafts, isEmpty, reason: '아무것도 서버에 보내지 않는다');
    expect(registrar.submits, isEmpty);
    expect(find.textContaining('「운영비」 예산을 찾지 못했어요'), findsOneWidget);
  });

  testWidgets('현재 학기를 확인하지 못하면 예산을 정하지 않고 제출을 막는다', (tester) async {
    ApiService.client = MockClient((req) async {
      if (req.url.path == '/budgets') return json([budget(1, 1, '행사비', 100000), budget(11, 2, '행사비', 900000)]);
      return http.Response('{}', 503); // 학기를 못 읽는다
    });
    final registrar = FakeRegistrar();
    await pump(tester, ExpenseCreateScreen(registrar: registrar, pickReceipt: fakeReceipt));
    await tester.tap(find.text('영수증 촬영 또는 사진 첨부'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '목적 *'), '신입생 환영회 명찰');
    await tester.enterText(find.widgetWithText(TextFormField, '사용처(상호명) *'), '한결문구');
    await tester.enterText(find.widgetWithText(TextFormField, '지출 금액(원) *'), '35000');
    await tester.ensureVisible(find.text('제출하기'));
    await tester.tap(find.text('제출하기'));
    await tester.pumpAndSettle();

    expect(registrar.drafts, isEmpty);
    expect(registrar.submits, isEmpty);
    expect(find.textContaining('현재 학기를 확인하지 못해'), findsOneWidget);
  });

  testWidgets('예산 개정 — 항목은 분류마다 하나씩 현재 학기의 예산으로 보이고, 부족분도 그 잔량으로 센다', (tester) async {
    await pump(tester, const BudgetRevisionScreen(initialCategory: '행사비', basisTitle: '현수막', basisAmount: 950000));

    expect(tester.takeException(), isNull, reason: '같은 분류가 둘이면 드롭다운 항목 값이 겹쳐 화면이 깨졌다');
    expect(find.textContaining('행사비 잔량이 ₩ 50,000 모자라요'), findsOneWidget, reason: '현재 학기 잔량(900,000) 기준 — 지난 학기(100,000)가 아니다');

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.textContaining('행사비 · 잔량'), findsNWidgets(2), reason: '닫힌 칸과 펼친 목록에 하나씩 — 학기마다 둘이 아니다');
    expect(find.textContaining('잔량 ₩ 100,000'), findsNothing);
    expect(find.textContaining('잔량 ₩ 800,000'), findsWidgets);
  });
  // 지난 학기에 반려된 건을 다시 등록하면 그 건의 예산(지난 학기 #1)으로 올라가야 한다 — 현재 학기로 옮기면 건의 학기가 바뀐다.
  testWidgets('지난 학기 건을 다시 등록하면 그 건의 예산·학기 그대로 제출한다', (tester) async {
    final registrar = FakeRegistrar();
    final old = EntryModel(
      id: 6,
      termId: 1,
      kind: EntryKind.EXPENSE,
      amount: 85000,
      counterparty: '현수막나라',
      purpose: '동아리 연합 행사 현수막',
      budgetId: 1,
      occurredAt: 1789225200,
      metaHash: '0x${'ab' * 32}',
      status: EntryStatus.REJECTED,
      createdBy: 2,
    );
    await pump(tester, ExpenseCreateScreen(registrar: registrar, resubmitOf: old, pickReceipt: fakeReceipt));
    expect(find.textContaining('잔량 ₩ 100,000'), findsOneWidget, reason: '그 건의 예산(지난 학기 행사비)의 잔량');

    await tester.tap(find.text('영수증 촬영 또는 사진 첨부'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('제출하기'));
    await tester.tap(find.text('제출하기'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    final draft = registrar.submits.single.$2;
    expect(draft.budgetId, 1);
    expect(draft.termId, 1);
  });

  // 저장해 둔 초안을 이어서 제출할 때도 그 초안의 예산(지난 학기 #1)을 지킨다.
  testWidgets('지난 학기 초안을 이어서 제출하면 그 초안의 예산·학기 그대로 제출한다', (tester) async {
    final registrar = FakeRegistrar();
    const saved = DraftEntry(
      id: 9,
      termId: 1,
      kind: EntryKind.EXPENSE,
      amount: 85000,
      counterparty: '현수막나라',
      purpose: '동아리 연합 행사 현수막',
      occurredAt: 1789225200,
      budgetId: 1,
    );
    await pump(tester, ExpenseCreateScreen(registrar: registrar, resumeDraft: saved, pickReceipt: fakeReceipt));
    expect(find.textContaining('잔량 ₩ 100,000'), findsOneWidget, reason: '그 초안의 예산(지난 학기 행사비)의 잔량');

    await tester.tap(find.text('영수증 촬영 또는 사진 첨부'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('제출하기'));
    await tester.tap(find.text('제출하기'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    final draft = registrar.submits.single.$2;
    expect(draft.budgetId, 1);
    expect(draft.termId, 1);
  });

  // 차단된 지출의 예산이 지난 학기여도 개정 요청은 그 예산으로 가야 한다 — 서버는 근거 지출과 다른 예산이면 400.
  testWidgets('예산 개정 — 근거 지출의 예산(지난 학기)이 현재 학기 예산에 가려지지 않는다', (tester) async {
    final requester = _FakeRequester();
    await pump(
      tester,
      BudgetRevisionScreen(
        initialCategory: '행사비',
        initialBudgetId: 1,
        blockedEntryId: 6,
        basisTitle: '현수막',
        basisAmount: 150000,
        requester: requester,
      ),
    );
    expect(find.textContaining('행사비 잔량이 ₩ 50,000 모자라요'), findsOneWidget, reason: '지난 학기 행사비 잔량(100,000) 기준');

    await tester.enterText(find.byType(TextFormField).first, '50000');
    await tester.enterText(find.byType(TextFormField).last, '행사 인원 증가');
    await tester.ensureVisible(find.text('예산 개정 요청하기'));
    await tester.tap(find.text('예산 개정 요청하기'));
    await tester.pumpAndSettle();

    final req = requester.requests.single;
    expect(req.budgetId, 1);
    expect(req.termId, 1);
    expect(req.blockedEntryId, 6);
  });

  // 학기를 못 읽어도, 건이 이미 가진 예산(다시 등록·근거 지출)은 그대로 쓸 수 있다 — 학기를 정할 필요가 없다.
  void termsDown() {
    ApiService.client = MockClient((req) async {
      if (req.url.path == '/budgets') return json([budget(1, 1, '행사비', 100000), budget(11, 2, '행사비', 900000)]);
      return http.Response('{}', 503);
    });
  }

  testWidgets('학기를 못 읽어도 지난 학기 건을 다시 등록하면 그 건의 예산으로 제출한다', (tester) async {
    termsDown();
    final registrar = FakeRegistrar();
    final old = EntryModel(
      id: 6,
      termId: 1,
      kind: EntryKind.EXPENSE,
      amount: 85000,
      counterparty: '현수막나라',
      purpose: '동아리 연합 행사 현수막',
      budgetId: 1,
      occurredAt: 1789225200,
      metaHash: '0x${'ab' * 32}',
      status: EntryStatus.REJECTED,
      createdBy: 2,
    );
    await pump(tester, ExpenseCreateScreen(registrar: registrar, resubmitOf: old, pickReceipt: fakeReceipt));
    await tester.tap(find.text('영수증 촬영 또는 사진 첨부'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('제출하기'));
    await tester.tap(find.text('제출하기'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(registrar.submits.single.$2.budgetId, 1);
    expect(find.textContaining('현재 학기를 확인하지 못해'), findsNothing);
  });

  testWidgets('예산 개정 — 학기를 못 읽어도 근거 지출의 예산으로는 요청할 수 있다', (tester) async {
    termsDown();
    final requester = _FakeRequester();
    await pump(
      tester,
      BudgetRevisionScreen(
          initialCategory: '행사비', initialBudgetId: 1, blockedEntryId: 6, basisTitle: '현수막', basisAmount: 150000, requester: requester),
    );
    await tester.enterText(find.byType(TextFormField).first, '50000');
    await tester.enterText(find.byType(TextFormField).last, '행사 인원 증가');
    await tester.ensureVisible(find.text('예산 개정 요청하기'));
    await tester.tap(find.text('예산 개정 요청하기'));
    await tester.pumpAndSettle();
    expect(requester.requests.single.budgetId, 1);
  });

  testWidgets('예산 개정 — 학기를 못 읽고 정해 둔 예산도 없으면 요청을 막는다', (tester) async {
    termsDown();
    final requester = _FakeRequester();
    await pump(tester, BudgetRevisionScreen(initialCategory: '행사비', requester: requester));
    await tester.enterText(find.byType(TextFormField).first, '50000');
    await tester.enterText(find.byType(TextFormField).last, '행사 인원 증가');
    await tester.ensureVisible(find.text('예산 개정 요청하기'));
    await tester.tap(find.text('예산 개정 요청하기'));
    await tester.pumpAndSettle();
    expect(requester.requests, isEmpty, reason: '어느 학기 예산인지 정할 수 없다');
    expect(find.textContaining('현재 학기를 확인하지 못해'), findsOneWidget);
  });
}

class _FakeRequester implements BudgetRevisionRequester {
  final List<IncreaseRequestDraft> requests = [];

  @override
  Future<int> requestIncrease(IncreaseRequestDraft draft) async {
    requests.add(draft);
    return 7;
  }
}
