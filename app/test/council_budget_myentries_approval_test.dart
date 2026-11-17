import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/screens/council/approval_list_screen.dart';
import 'package:student_council_app/screens/council/budget_revision_screen.dart';
import 'package:student_council_app/screens/council/correction_approval_screen.dart';
import 'package:student_council_app/screens/council/correction_screen.dart';
import 'package:student_council_app/screens/council/expense_create_screen.dart';
import 'package:student_council_app/screens/council/my_entries_screen.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/services/api_service.dart';
import 'package:student_council_app/services/budget_revision_service.dart';

import 'support/registration.dart';

/// 증액 요청을 기록하는 가짜 — 서버 없이 요청 번호만 돌려준다.
class FakeRequester implements BudgetRevisionRequester {
  final List<IncreaseRequestDraft> requests = [];
  EntryDecisionException? failNext;

  @override
  Future<int> requestIncrease(IncreaseRequestDraft draft) async {
    final fail = failNext;
    if (fail != null) {
      failNext = null;
      throw fail;
    }
    requests.add(draft);
    return 7;
  }
}

/// 서버 항목 — 내 등록 현황 테스트용. 총무(#2)가 올린 건과 다른 사람이 올린 건.
EntryModel entry(int id, EntryStatus status,
        {int createdBy = 2,
        EntryKind kind = EntryKind.EXPENSE,
        int amount = 50000,
        int? budgetId = 1,
        String? txConfirm,
        String? rejectReason,
        int? correctsEntryId}) =>
    EntryModel(
      id: id,
      termId: 1,
      kind: kind,
      amount: amount,
      counterparty: '거래처$id',
      purpose: '목적$id',
      budgetId: kind == EntryKind.INCOME ? null : budgetId,
      occurredAt: 1788793200,
      metaHash: '0x${'0' * 64}',
      status: status,
      createdBy: createdBy,
      txConfirm: txConfirm,
      rejectReason: rejectReason,
      correctsEntryId: correctsEntryId,
    );

/// 차단 안내 → 예산 개정 요청, 내 등록 현황, 정정 승인.
void main() {
  // 목업 화면 테스트 — 서버 없이 시연용 더미로 돈다. 실패 표시는 api_unavailable_test.dart 가 본다 (PRD v0.14 §7.3).
  setUp(() => ApiService.useDemoData = true);
  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(411, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: home));
    await tester.pumpAndSettle();
  }

  Future<void> waitFor(WidgetTester tester, Finder f) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      if (f.evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  /// 가짜 등록기·영수증으로 지출을 채운다 (서버·카메라 없음). 행사비 잔량은 시연용 2,470,000원.
  Future<void> fillExpense(WidgetTester tester, String amount) async {
    await pump(tester, ExpenseCreateScreen(registrar: FakeRegistrar(), pickReceipt: fakeReceipt));
    await waitFor(tester, find.textContaining('행사비 · 잔량'));
    await tester.tap(find.text('영수증 촬영 또는 사진 첨부'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '목적 *'), '신입생 오리엔테이션 다과 구매');
    await tester.enterText(find.widgetWithText(TextFormField, '사용처(상호명) *'), '한결문구점');
    await tester.enterText(find.widgetWithText(TextFormField, '지출 금액(원) *'), amount);
    await tester.ensureVisible(find.text('제출하기'));
  }

  Future<void> submitBlockedExpense(WidgetTester tester) async {
    await fillExpense(tester, '3000000');
    await tester.tap(find.text('제출하기'));
    await waitFor(tester, find.text('지출 등록이 차단되었어요'));
  }

  group('차단 안내 → 예산 개정 요청', () {
    testWidgets('차단되면 「예산 개정 요청」과 「입력으로 돌아가기」가 같이 나온다', (tester) async {
      await submitBlockedExpense(tester);
      expect(find.text('예산 개정 요청'), findsOneWidget);
      expect(find.text('입력으로 돌아가기'), findsOneWidget);
    });

    testWidgets('「예산 개정 요청」을 누르면 항목이 골라지고 차단 지출이 근거로 붙는다', (tester) async {
      await submitBlockedExpense(tester);
      await tester.tap(find.text('예산 개정 요청'));
      await tester.pumpAndSettle();
      await waitFor(tester, find.text('근거: 차단된 지출'));
      expect(find.text('근거: 차단된 지출'), findsOneWidget);
      expect(find.textContaining('신입생 오리엔테이션 다과 구매'), findsOneWidget);
      // 모자란 금액(3,000,000 − 2,470,000)이 증액분에 미리 채워진다
      expect(find.widgetWithText(TextFormField, '530000'), findsOneWidget);
    });

    testWidgets('예산이 충분하면 개정 요청 버튼이 없다', (tester) async {
      await fillExpense(tester, '35000');
      await tester.tap(find.text('제출하기'));
      await waitFor(tester, find.text('지출 제출 완료!'));
      expect(find.text('예산 개정 요청'), findsNothing);
    });
  });

  group('예산 개정 요청 화면', () {
    late FakeRequester requester;
    Future<void> open(WidgetTester tester, {int? blockedEntryId}) async {
      requester = FakeRequester();
      await pump(
        tester,
        BudgetRevisionScreen(
          initialCategory: '행사비',
          requester: requester,
          blockedEntryId: blockedEntryId,
          basisTitle: blockedEntryId == null ? null : '행사 무대 장비 대여',
          basisAmount: blockedEntryId == null ? null : 2600000,
        ),
      );
      await waitFor(tester, find.textContaining('편성'));
    }

    testWidgets('사유가 비어 있으면 제출할 수 없다', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextFormField).first, '100000');
      await tester.tap(find.text('예산 개정 요청하기'));
      await tester.pumpAndSettle();
      expect(find.text('사유를 입력해 주세요'), findsOneWidget);
      expect(find.text('예산 개정 요청 완료!'), findsNothing);
    });

    testWidgets('증액 금액은 양수만 받는다', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextFormField).first, '-5000');
      await tester.enterText(find.byType(TextFormField).last, '행사 인원 증가');
      await tester.tap(find.text('예산 개정 요청하기'));
      await tester.pumpAndSettle();
      expect(find.text('예산 개정 요청 완료!'), findsNothing);
    });

    testWidgets('금액과 사유가 있으면 요청이 접수되고 결재 순서를 안내한다', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextFormField).first, '300000');
      await tester.enterText(find.byType(TextFormField).last, '행사 인원 증가');
      await tester.tap(find.text('예산 개정 요청하기'));
      await tester.pumpAndSettle();
      expect(find.text('예산 개정 요청 완료!'), findsOneWidget);
      expect(find.textContaining('회장 요청 서명 → 감사 승인 서명'), findsWidgets);
      expect(find.text('요청 번호: #7'), findsOneWidget);

      // 서버에 보낸 값 — 고른 예산의 학기·id, 증액분(총액 아님), 사유 원문
      final r = requester.requests.single;
      expect(r.toJson(), {
        'term_id': 1,
        'category': '행사비',
        'budget_id': 1,
        'requested_amount': 300000,
        'reason': '행사 인원 증가',
      });
    });

    testWidgets('차단 지출에서 왔으면 그 번호를 근거로 붙이고, 항목은 바꿀 수 없다', (tester) async {
      await open(tester, blockedEntryId: 12);
      final dropdown = tester.widget<DropdownButtonFormField<String>>(find.byType(DropdownButtonFormField<String>));
      expect(dropdown.onChanged, isNull, reason: '서버는 차단 지출의 예산과 다르면 400');
      await tester.enterText(find.byType(TextFormField).last, '무대 장비 대여료 인상');
      await tester.tap(find.text('예산 개정 요청하기'));
      await tester.pumpAndSettle();
      expect(requester.requests.single.toJson()['blocked_entry_id'], 12);
      expect(find.text('근거 지출: #12 행사 무대 장비 대여'), findsOneWidget);
    });

    testWidgets('서버가 거부하면 이유를 알리고 화면에 남는다', (tester) async {
      await open(tester);
      requester.failNext = const EntryDecisionException(
          EntryDecisionFailure.refused, '증액 요청 요청이 거부되었어요: 마감일이 지난 예산입니다.');
      await tester.enterText(find.byType(TextFormField).first, '300000');
      await tester.enterText(find.byType(TextFormField).last, '행사 인원 증가');
      await tester.tap(find.text('예산 개정 요청하기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('마감일이 지난 예산입니다'), findsOneWidget);
      expect(find.text('예산 개정 요청 완료!'), findsNothing);
      expect(find.text('예산 개정 요청하기'), findsOneWidget);
    });
  });

  group('내 등록 현황', () {
    testWidgets('여섯 상태로 센다', (tester) async {
      await pump(tester, MyEntriesScreen(items: buildMyEntryMockItems()));
      for (final t in ['전체 7', '초안 1', '처리 중 1', '대기 1', '확정 2', '반려 1', '차단 1']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
    });

    testWidgets('처리 중인 건은 다시 보낼 수 없다', (tester) async {
      await pump(tester, MyEntriesScreen(items: buildMyEntryMockItems()));
      expect(find.text('처리 중 — 다시 보낼 수 없어요'), findsOneWidget);
    });

    testWidgets('상태마다 다음 행동이 다르다', (tester) async {
      await pump(tester, MyEntriesScreen(items: buildMyEntryMockItems()));
      for (final t in ['이어서 제출', '정정 등록', '고쳐서 다시 제출', '예산 개정 요청']) {
        expect(find.text(t), findsWidgets, reason: t);
      }
      // 대기 건은 고쳐서 새로 올리지 않는다 — 두 건이 함께 대기하다 둘 다 확정될 수 있다 (PRD §4.3)
      expect(find.text('수정 (새 기록으로 등록)'), findsNothing);
      expect(find.text('승인 대기 중 — 고치려면 수정 요청이 필요해요 (준비 중)'), findsOneWidget);
    });

    testWidgets('차단 건의 「예산 개정 요청」은 근거와 함께 넘어간다', (tester) async {
      await pump(tester, MyEntriesScreen(items: buildMyEntryMockItems()));
      await tester.ensureVisible(find.text('차단 1'));
      await tester.tap(find.text('차단 1'));
      await tester.pumpAndSettle();
      expect(find.text('예산 개정 요청'), findsOneWidget, reason: '차단 건만 남는다');
      expect(find.text('정정 등록'), findsNothing);
      await tester.tap(find.text('예산 개정 요청'));
      await tester.pumpAndSettle();
      await waitFor(tester, find.text('근거: 차단된 지출'));
      expect(find.textContaining('행사 무대 장비 대여'), findsOneWidget);
    });
  });

  group('내 등록 현황 — 서버', () {
    final serverEntries = [
      entry(1, EntryStatus.CONFIRMED),
      entry(2, EntryStatus.PENDING),
      entry(3, EntryStatus.PENDING, txConfirm: '0x${'a' * 64}'),
      entry(4, EntryStatus.REJECTED, rejectReason: '영수증 금액과 달라요'),
      entry(5, EntryStatus.BLOCKED, amount: 3000000),
      entry(6, EntryStatus.CONFIRMED, kind: EntryKind.INCOME, amount: 5000000),
      entry(7, EntryStatus.PENDING, correctsEntryId: 1, amount: -5000),
      entry(8, EntryStatus.CONFIRMED, createdBy: 9), // 다른 사람
    ];

    Future<void> open(WidgetTester tester, {List<EntryModel>? entries}) async {
      // 초안은 따로 읽는다 (GET /entries/drafts) — 이 그룹은 초안이 없는 서버를 본다
      await pump(
          tester,
          MyEntriesScreen(
              currentUserId: 2, loadEntries: () async => entries ?? serverEntries, loadDrafts: () async => const []));
      await waitFor(tester, find.textContaining('전체'));
    }

    testWidgets('내가 등록한 건만 상태별로 센다 — 초안이 없으면 초안 칸도 없다', (tester) async {
      await open(tester);
      for (final t in ['전체 7', '처리 중 1', '대기 2', '확정 2', '반려 1', '차단 1']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.textContaining('초안'), findsNothing);
      expect(find.byKey(const ValueKey('my_entry_8')), findsNothing, reason: '다른 사람이 올린 건');
    });

    testWidgets('정정은 원본 번호와 부호 있는 증감분으로 보인다', (tester) async {
      await open(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('my_entry_7')));
      expect(find.text('#1 정정 · 거래처7 · 목적7'), findsOneWidget);
      expect(find.text('-₩ 5,000'), findsOneWidget);
    });

    testWidgets('반려 건은 사유를 보여 주고 「고쳐서 다시 제출」로 이전 값이 채워진 지출 등록을 연다', (tester) async {
      await open(tester);
      await tester.tap(find.text('반려 1'));
      await tester.pumpAndSettle();
      expect(find.text('반려 사유: 영수증 금액과 달라요'), findsOneWidget);
      await tester.tap(find.text('고쳐서 다시 제출'));
      await tester.pumpAndSettle();
      await waitFor(tester, find.byKey(const Key('resubmit_banner')));
      expect(find.text('반려된 #4 을 고쳐 새로 등록해요'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '목적4'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '50000'), findsOneWidget);
    });

    testWidgets('반려·차단된 정정 건은 일반 등록이 아니라 정정 화면으로 다시 간다 — 정정 대상을 잃고 새 지출로 올라가지 않게 (#72 리뷰)', (tester) async {
      final entries = [
        entry(1, EntryStatus.CONFIRMED),
        entry(9, EntryStatus.REJECTED, correctsEntryId: 1, amount: 4000, rejectReason: '금액이 달라요'),
        entry(10, EntryStatus.BLOCKED, correctsEntryId: 1, amount: 3000000),
      ];
      await open(tester, entries: entries);
      for (final filter in ['반려 1', '차단 1']) {
        await tester.tap(find.text(filter));
        await tester.pumpAndSettle();
        await tester.tap(find.text(filter == '반려 1' ? '고쳐서 다시 제출' : '증액 승인 뒤 다시 등록'));
        await tester.pumpAndSettle();
        expect(find.byType(CorrectionScreen), findsOneWidget, reason: filter);
        expect(find.byType(ExpenseCreateScreen), findsNothing, reason: filter);
        expect(find.byKey(const Key('resubmit_banner')), findsNothing, reason: filter);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('차단 건은 근거 번호와 함께 예산 개정 요청을 열고, 다시 등록도 할 수 있다', (tester) async {
      await open(tester);
      await tester.tap(find.text('차단 1'));
      await tester.pumpAndSettle();
      expect(find.text('증액 승인 뒤 다시 등록'), findsOneWidget);
      await tester.tap(find.text('예산 개정 요청'));
      await tester.pumpAndSettle();
      await waitFor(tester, find.text('근거: 차단된 지출'));
      expect(find.textContaining('거래처5 · 목적5'), findsOneWidget);
    });

    testWidgets('대기 건은 고칠 수 없어 「수정 요청」만 열리고, 처리 중인 건은 다시 보낼 수 없다', (tester) async {
      await open(tester);
      expect(find.text('수정 요청'), findsNWidgets(2));
      expect(find.textContaining('(준비 중)'), findsNothing);
      expect(find.text('처리 중 — 다시 보낼 수 없어요'), findsOneWidget);
    });

    testWidgets('목록을 못 읽으면 「등록 건 없음」이 아니라 이유와 다시 시도를 보인다', (tester) async {
      await pump(
        tester,
        MyEntriesScreen(currentUserId: 2, loadEntries: () async => throw const ApiUnavailable('내역')),
      );
      await waitFor(tester, find.byKey(const Key('my_entries_failed')));
      expect(find.text('다시 시도'), findsOneWidget);
      expect(find.text('해당 상태의 등록 건이 없어요'), findsNothing);
    });

    testWidgets('로그인 정보가 없으면 다른 사람 건을 보여 주지 않는다', (tester) async {
      await pump(tester, MyEntriesScreen(loadEntries: () async => serverEntries));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('my_entries_failed')), findsOneWidget);
      expect(find.byKey(const ValueKey('my_entry_1')), findsNothing);
    });
  });

  group('정정 승인', () {
    CorrectionApprovalScreen screen({UserRole role = UserRole.AUDITOR, int uid = 4}) =>
        CorrectionApprovalScreen(role: role, currentUserId: uid, items: buildCorrectionMockItems());

    testWidgets('총무는 들어올 수 없다', (tester) async {
      await pump(tester, screen(role: UserRole.TREASURER, uid: 2));
      expect(find.text('이 작업을 할 권한이 없습니다.'), findsOneWidget);
    });

    testWidgets('원본·증감분·정정 후 금액을 나란히 보여 준다', (tester) async {
      await pump(tester, screen());
      expect(find.text('원본'), findsWidgets);
      expect(find.text('증감분'), findsWidgets);
      expect(find.text('정정 후'), findsWidgets);
      expect(find.text('₩ 40,000'), findsOneWidget, reason: '35,000 + 5,000');
      expect(find.text('+₩ 5,000'), findsOneWidget);
      expect(find.text('-₩ 20,000'), findsOneWidget);
    });

    testWidgets('본인이 등록한 건은 승인·반려할 수 없다', (tester) async {
      await pump(tester, screen(uid: 3));
      await tester.scrollUntilVisible(find.text('본인이 등록한 건은 승인·반려할 수 없어요'), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('본인이 등록한 건은 승인·반려할 수 없어요'), findsOneWidget);
    });

    testWidgets('승인하면 확정된다', (tester) async {
      await pump(tester, screen());
      await tester.tap(find.text('승인').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('생체인증 승인'));
      await tester.pumpAndSettle();
      expect(find.textContaining('정정 승인 완료!'), findsOneWidget);
    });

    testWidgets('증액 정정이 잔량을 넘으면 서명을 받기 전에 확정할 수 없다고 알린다', (tester) async {
      await pump(tester, screen());
      expect(find.textContaining('승인해도 대기로 남아요'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('승인').at(3), 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('승인').at(3));
      await tester.pumpAndSettle();
      expect(find.text('확정할 수 없어요'), findsOneWidget);
      expect(find.text('생체인증 승인'), findsNothing, reason: '곧 실패할 건에 지문을 대게 하지 않는다');
    });

    testWidgets('재분류는 짝이 확정될 때까지 「재분류 진행 중」이다', (tester) async {
      await pump(tester, screen());
      expect(find.text('재분류 진행 중'), findsOneWidget);
      expect(find.textContaining('짝 1/2'), findsOneWidget);
    });

    testWidgets('재분류는 새 예산 증액(+)이 먼저 확정되고 원래 예산 감액(−)이 나중이다', (tester) async {
      await pump(tester, screen());
      // 대기 중인 쪽은 감액(−), 확정된 쪽이 증액(+) — 순서는 서버가 강제한다 (PRD §4.4)
      expect(find.textContaining('사업비 +22,000 확정 · 운영비 −22,000 대기'), findsOneWidget);
    });

    testWidgets('정정 사유 라벨은 docs/enums.md 를 그대로 쓴다 (REFUND = 반환)', (tester) async {
      await pump(tester, screen());
      expect(find.textContaining('반환 · 행사비'), findsOneWidget);
    });

    testWidgets('반려는 사유가 있어야 한다', (tester) async {
      await pump(tester, screen());
      await tester.tap(find.text('반려').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('반려하기'));
      await tester.pumpAndSettle();
      expect(find.text('사유를 입력해 주세요'), findsOneWidget);
    });
  });

  group('좁은 화면·큰 글자에서도 넘치지 않는다', () {
    for (final scale in [1.0, 1.5]) {
      testWidgets('세 화면 · 폭 360dp · 글자 ${(scale * 100).toInt()}%', (tester) async {
        for (final home in <Widget>[
          const BudgetRevisionScreen(initialCategory: '행사비', basisTitle: '행사 무대 장비 대여', basisAmount: 2600000),
          MyEntriesScreen(items: buildMyEntryMockItems()),
          CorrectionApprovalScreen(role: UserRole.AUDITOR, currentUserId: 4, items: buildCorrectionMockItems()),
        ]) {
          tester.view.physicalSize = const Size(360, 1400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(MaterialApp(
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: home,
          ));
          await tester.pumpAndSettle();
          await waitFor(tester, find.byType(Scaffold));
          final e = tester.takeException();
          expect(e, isNull, reason: '${home.runtimeType} 넘침: $e');
        }
      });
    }
  });

  group('OCR 경고 판정 (PRD §6)', () {
    Map<String, dynamic> item(OcrStatus? ocr) => {
          'id': 90,
          'createdBy': 2,
          'title': '계좌이체 건',
          'merchant': '업체',
          'amount': 10000,
          'category': '행사비',
          'date': '2026-09-20 10:00',
          'status': EntryStatus.PENDING,
          'ocrStatus': ocr,
          'receiptInfo': '계좌이체',
        };

    Future<void> approve(WidgetTester tester, OcrStatus? ocr) async {
      await pump(tester, ApprovalListScreen(role: UserRole.AUDITOR, currentUserId: 4, items: [item(ocr)]));
      await tester.tap(find.text('승인 서명').first);
      await tester.pumpAndSettle();
    }

    testWidgets('NO_NUMBER(승인번호 없음)는 정상이라 사유 없이 바로 서명한다', (tester) async {
      await approve(tester, OcrStatus.NO_NUMBER);
      expect(find.text('집행 최종 승인'), findsOneWidget);
      expect(find.text('경고 무시 승인 사유'), findsNothing);
    });

    testWidgets('OCR 을 돌리지 않은 건(null — 영수증 없는 수입)은 정상이다', (tester) async {
      // 서버도 null 을 정상으로 본다. 경고로 보고 사유를 보내면 400 이다.
      await approve(tester, null);
      expect(find.text('집행 최종 승인'), findsOneWidget);
      expect(find.text('경고 무시 승인 사유'), findsNothing);
    });

    for (final ocr in [OcrStatus.MISMATCH, OcrStatus.DUPLICATE, OcrStatus.UNREADABLE]) {
      testWidgets('${ocr.code}는 경고라 사유를 먼저 받는다', (tester) async {
        await approve(tester, ocr);
        expect(find.text('경고 무시 승인 사유'), findsOneWidget);
      });
    }
  });
}
