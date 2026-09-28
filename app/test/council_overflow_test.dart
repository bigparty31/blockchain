import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/screens/council/approval_list_screen.dart';
import 'package:student_council_app/screens/council/correction_screen.dart';
import 'package:student_council_app/screens/council/expense_create_screen.dart';
import 'package:student_council_app/screens/council/income_create_screen.dart';
import 'package:student_council_app/screens/council/inquiry_response_screen.dart';

/// 총무·감사 화면이 좁은 폰·큰 글자에서 픽셀이 넘치지(RenderFlex overflow) 않는지 본다.
///
/// 승인 목록 → 승인 서명 흐름과, 지출·수입 등록, 정정 신청, 이의 답변 화면을 확인한다.
///
/// 기기마다 화면 폭과 글자 크기가 달라서 411dp·기본 글자로만 보면 놓친다.
/// 좁은 폰(320·360dp)과 큰 글자(시스템 글자 크기 130%·150%)에서도 확인한다.
/// 넘침은 Flutter 가 예외로 던지므로 `takeException` 으로 잡는다.
void main() {
  const widths = [320.0, 360.0, 411.0];
  const scales = [1.0, 1.3, 1.5];

  for (final width in widths) {
    for (final scale in scales) {
      group('폭 ${width.toInt()}dp · 글자 ${(scale * 100).toInt()}%', () {
        Future<void> pumpScreen(WidgetTester tester) async {
          tester.view.physicalSize = Size(width, 1400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: const ApprovalListScreen(),
            ),
          );
          await tester.pumpAndSettle();
        }

        void expectNoOverflow(WidgetTester tester, String where) {
          final e = tester.takeException();
          expect(e, isNull, reason: '$where 에서 넘침: $e');
        }

        testWidgets('승인 목록 화면', (tester) async {
          await pumpScreen(tester);
          expectNoOverflow(tester, '승인 목록');
        });

        testWidgets('승인 서명 → 생체인증 다이얼로그', (tester) async {
          await pumpScreen(tester);
          await tester.tap(find.text('승인 서명').first);
          await tester.pumpAndSettle();
          expect(find.text('집행 최종 승인'), findsOneWidget);
          expectNoOverflow(tester, '생체인증 다이얼로그');
        });

        testWidgets('경고 항목: 경고 무시 사유 다이얼로그 → 생체인증', (tester) async {
          await pumpScreen(tester);
          await tester.tap(find.text('승인 서명').at(2));
          await tester.pumpAndSettle();
          expectNoOverflow(tester, '경고 무시 사유 다이얼로그');

          await tester.enterText(find.byType(TextFormField), 'OCR 금액 불일치, 영수증 원본 확인함');
          await tester.tap(find.text('다음'));
          await tester.pumpAndSettle();
          expect(find.text('집행 최종 승인'), findsOneWidget);
          expectNoOverflow(tester, '경고 항목의 생체인증 다이얼로그');
        });

        testWidgets('승인 실패 다이얼로그 → 반려 사유 다이얼로그', (tester) async {
          await pumpScreen(tester);
          await tester.tap(find.text('승인 서명').at(1));
          await tester.pumpAndSettle();
          await tester.tap(find.text('생체인증 승인'));
          await tester.pumpAndSettle();
          expect(find.text('승인에 실패했어요'), findsOneWidget);
          expectNoOverflow(tester, '승인 실패 다이얼로그');

          await tester.tap(find.text('반려로 처리'));
          await tester.pumpAndSettle();
          expect(find.text('반려 사유'), findsOneWidget);
          expectNoOverflow(tester, '반려 사유 다이얼로그');
        });
      });
    }
  }

  // 다른 화면: 처음 화면과, 다이얼로그가 뜨는 흐름
  final screens = <String, Widget>{
    '지출 등록': const ExpenseCreateScreen(),
    '수입 등록': const IncomeCreateScreen(),
    '정정 신청': const CorrectionScreen(),
    '이의 답변': const InquiryResponseScreen(),
  };
  for (final e in screens.entries) {
    for (final width in widths) {
      for (final scale in scales) {
        testWidgets('${e.key} · 폭 ${width.toInt()}dp · 글자 ${(scale * 100).toInt()}%', (tester) async {
          tester.view.physicalSize = Size(width, 1600);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: e.value,
            ),
          );
          await tester.pumpAndSettle();
          final ex = tester.takeException();
          expect(ex, isNull, reason: '${e.key} 에서 넘침: $ex');
        });
      }
    }
  }

  // 결과·입력 다이얼로그: 화면 위에 뜨는 다이얼로그도 좁은 폰·큰 글자에서 넘치지 않아야 한다.
  for (final width in widths) {
    for (final scale in scales) {
      final label = '폭 ${width.toInt()}dp · 글자 ${(scale * 100).toInt()}%';

      Future<void> pump(WidgetTester tester, Widget home) async {
        tester.view.physicalSize = Size(width, 2000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: home,
          ),
        );
        await tester.pumpAndSettle();
      }

      // 서버가 없어 더미로 폴백하는 비동기 호출을 기다린다.
      Future<void> waitFor(WidgetTester tester, Finder f) async {
        for (var i = 0; i < 40 && f.evaluate().isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump();
        }
        await tester.pumpAndSettle();
      }

      testWidgets('지출 등록 결과(PENDING) 다이얼로그 · $label', (tester) async {
        await pump(tester, const ExpenseCreateScreen());
        await tester.tap(find.text('영수증 촬영 또는 사진 첨부')); // 목업 자동 입력: 35,000원 · 행사비
        await tester.pumpAndSettle();
        await tester.tap(find.text('지출 등록 신청하기'));
        await waitFor(tester, find.text('지출 등록 완료!'));
        expect(find.text('지출 등록 완료!'), findsOneWidget);
        final ex = tester.takeException();
        expect(ex, isNull, reason: '넘침: $ex');
      });

      testWidgets('지출 등록 결과(BLOCKED) 다이얼로그 · $label', (tester) async {
        await pump(tester, const ExpenseCreateScreen());
        await tester.tap(find.text('영수증 촬영 또는 사진 첨부'));
        await tester.pumpAndSettle();
        await tester.enterText(find.widgetWithText(TextFormField, '지출 금액(원) *'), '3000000000');
        await tester.tap(find.text('지출 등록 신청하기'));
        await waitFor(tester, find.text('지출 등록이 차단되었어요'));
        expect(find.text('지출 등록이 차단되었어요'), findsOneWidget);
        final ex = tester.takeException();
        expect(ex, isNull, reason: '넘침: $ex');
      });

      testWidgets('정정 접수 결과 다이얼로그 · $label', (tester) async {
        await pump(tester, const CorrectionScreen());
        await tester.enterText(find.widgetWithText(TextFormField, '정정 대상 내역 ID (Entry ID) *'), '1');
        await tester.tap(find.text('내역 조회'));
        await waitFor(tester, find.textContaining('현재 금액 ₩'));
        await tester.enterText(find.widgetWithText(TextFormField, '수정 후 올바른 금액(원) *'), '30000');
        await tester.enterText(find.widgetWithText(TextFormField, '정정 상세 사유 및 소명 내용 *'), '실제 영수증 확인 결과 금액 정정');
        await tester.tap(find.text('정정 신청 제출하기'));
        await tester.pumpAndSettle();
        expect(find.text('정정 신청 접수 완료!'), findsOneWidget);
        final ex = tester.takeException();
        expect(ex, isNull, reason: '넘침: $ex');
      });

      testWidgets('이의 답변 다이얼로그 · $label', (tester) async {
        await pump(tester, const InquiryResponseScreen());
        await tester.tap(find.text('답변 작성하기'));
        await tester.pumpAndSettle();
        expect(find.text('답변 등록'), findsOneWidget);
        await tester.tap(find.text('답변 등록')); // 빈 값 오류 문구까지 그린다
        await tester.pumpAndSettle();
        final ex = tester.takeException();
        expect(ex, isNull, reason: '넘침: $ex');
      });
    }
  }
}
