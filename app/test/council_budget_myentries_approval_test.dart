import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/screens/council/approval_list_screen.dart';
import 'package:student_council_app/screens/council/budget_revision_screen.dart';
import 'package:student_council_app/screens/council/correction_approval_screen.dart';
import 'package:student_council_app/screens/council/expense_create_screen.dart';
import 'package:student_council_app/screens/council/my_entries_screen.dart';
import 'package:student_council_app/services/api_service.dart';

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

  Future<void> submitBlockedExpense(WidgetTester tester) async {
    await pump(tester, const ExpenseCreateScreen());
    await tester.tap(find.text('영수증 촬영 또는 사진 첨부'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '지출 금액(원) *'), '3000000');
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
      await pump(tester, const ExpenseCreateScreen());
      await tester.tap(find.text('영수증 촬영 또는 사진 첨부'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('제출하기'));
      await waitFor(tester, find.text('지출 제출 완료!'));
      expect(find.text('예산 개정 요청'), findsNothing);
    });
  });

  group('예산 개정 요청 화면', () {
    Future<void> open(WidgetTester tester) async {
      await pump(tester, const BudgetRevisionScreen(initialCategory: '행사비'));
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
    });
  });

  group('내 등록 현황', () {
    testWidgets('여섯 상태로 센다', (tester) async {
      await pump(tester, const MyEntriesScreen());
      for (final t in ['전체 7', '초안 1', '처리 중 1', '대기 1', '확정 2', '반려 1', '차단 1']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
    });

    testWidgets('처리 중인 건은 다시 보낼 수 없다', (tester) async {
      await pump(tester, const MyEntriesScreen());
      expect(find.text('처리 중 — 다시 보낼 수 없어요'), findsOneWidget);
    });

    testWidgets('상태마다 다음 행동이 다르다', (tester) async {
      await pump(tester, const MyEntriesScreen());
      for (final t in ['이어서 제출', '수정 (새 기록으로 등록)', '정정 등록', '고쳐서 다시 제출', '예산 개정 요청']) {
        expect(find.text(t), findsWidgets, reason: t);
      }
    });

    testWidgets('차단 건의 「예산 개정 요청」은 근거와 함께 넘어간다', (tester) async {
      await pump(tester, const MyEntriesScreen());
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

  group('정정 승인', () {
    CorrectionApprovalScreen screen({UserRole role = UserRole.AUDITOR, int uid = 4}) =>
        CorrectionApprovalScreen(role: role, currentUserId: uid);

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

    testWidgets('증액 정정이 잔량을 넘으면 승인해도 대기로 남는다', (tester) async {
      await pump(tester, screen());
      expect(find.textContaining('승인해도 대기로 남아요'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('승인').at(3), 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('승인').at(3));
      await tester.pumpAndSettle();
      await tester.tap(find.text('생체인증 승인'));
      await tester.pumpAndSettle();
      expect(find.text('확정할 수 없어요'), findsOneWidget);
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

    testWidgets('정정 사유 라벨은 docs/enums.md 를 그대로 쓴다 (REFUND = 환불)', (tester) async {
      await pump(tester, screen());
      expect(find.textContaining('환불 · 행사비'), findsOneWidget);
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
          const MyEntriesScreen(),
          CorrectionApprovalScreen(role: UserRole.AUDITOR, currentUserId: 4),
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
