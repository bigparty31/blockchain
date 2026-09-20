import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/screens/council/approval_list_screen.dart';

/// 승인 목록 → 승인 서명 흐름에서 픽셀이 넘치지(RenderFlex overflow) 않는지 본다.
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
}
