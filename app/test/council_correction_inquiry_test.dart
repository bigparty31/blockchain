import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/screens/council/correction_screen.dart';
import 'package:student_council_app/screens/council/input_rules.dart';
import 'package:student_council_app/screens/council/inquiry_response_screen.dart';

/// 정정 화면은 **증감분**을 기록하고, 이의 답변은 **다시 답변할 수 없다**.
///
/// - 정정 항목의 `amount` 는 새 총액이 아니라 `올바른 금액 − 현재 금액` 이다.
///   컨트랙트는 음수를 정정 항목에만 허용하고, 장부 합계는 확정 항목을 그냥 더한다
///   (`core/entry_merge.dart`, HASHING 샘플 3 `-20000`). 새 총액을 보내면 금액이 두 배가 된다.
/// - `IObjectionRegistry.answer` 는 이미 답변된 이의를 `ObjectionAlreadyAnswered` 로 거부한다.
void main() {
  group('InputRules — 내역 ID · 올바른 금액', () {
    test('내역 ID 는 1 이상의 정수다 (0 은 「없음」으로 예약)', () {
      expect(InputRules.entryId('1'), isNull);
      expect(InputRules.entryId('120'), isNull);
      for (final bad in ['', '0', '00', '-1', '1.5', 'abc', '1,000']) {
        expect(InputRules.entryId(bad), isNotNull, reason: bad);
      }
      expect(InputRules.entryId(null), isNotNull);
    });

    test('올바른 금액은 0 이상의 정수다 — 전액 취소는 0원이 될 수 있다', () {
      expect(InputRules.nonNegativeAmount('30000', fieldName: '금액'), isNull);
      expect(InputRules.nonNegativeAmount('0', fieldName: '금액'), isNull);
      for (final bad in ['', '-100', '35,000', '3.5', '+1', '3만']) {
        expect(InputRules.nonNegativeAmount(bad, fieldName: '금액'), isNotNull, reason: bad);
      }
    });
  });

  group('정정 화면', () {
    Future<void> pumpScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(411, 2800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: CorrectionScreen()));
      await tester.pumpAndSettle();
    }

    // 서버가 없어 ApiService 가 더미(#1 확정 지출 35,000원, #2 대기, #3 확정 수입)로 폴백한다.
    Future<void> lookup(WidgetTester tester, String id) async {
      await tester.enterText(find.widgetWithText(TextFormField, '정정 대상 내역 ID (Entry ID) *'), id);
      await tester.tap(find.text('내역 조회'));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        if (find.text('조회 중...').evaluate().isEmpty) break;
      }
      await tester.pumpAndSettle();
    }

    Finder amountField() => find.widgetWithText(TextFormField, '수정 후 올바른 금액(원) *');
    Finder detailField() => find.widgetWithText(TextFormField, '정정 상세 사유 및 소명 내용 *');

    testWidgets('조회하면 현재 금액을 보여 주고, 올바른 금액을 넣으면 증감분을 계산한다', (tester) async {
      await pumpScreen(tester);
      await lookup(tester, '1');

      expect(find.textContaining('#1 한결문구'), findsWidgets);
      expect(find.textContaining('현재 금액 ₩ 35,000'), findsOneWidget);

      // 35,000 → 30,000 이면 정정 항목은 새 총액(30,000)이 아니라 -5,000 이다.
      await tester.enterText(amountField(), '30000');
      await tester.pumpAndSettle();
      expect(find.textContaining('기록되는 정정 금액: -₩ 5,000'), findsOneWidget);

      // 올리는 정정은 양수 증감분
      await tester.enterText(amountField(), '40000');
      await tester.pumpAndSettle();
      expect(find.textContaining('기록되는 정정 금액: +₩ 5,000'), findsOneWidget);
    });

    testWidgets('현재 금액과 같으면 제출할 수 없다 (증감분 0 은 컨트랙트가 거부)', (tester) async {
      await pumpScreen(tester);
      await lookup(tester, '1');
      await tester.enterText(amountField(), '35000');
      await tester.enterText(detailField(), '영수증 재확인 결과 금액 그대로');

      await tester.tap(find.text('정정 신청 제출하기'));
      await tester.pumpAndSettle();

      expect(find.textContaining('현재 금액과 같아요'), findsOneWidget);
      expect(find.text('정정 신청 접수 완료!'), findsNothing);
    });

    testWidgets('정정 상세 사유는 비거나 공백만 있으면 안 된다', (tester) async {
      await pumpScreen(tester);
      await lookup(tester, '1');
      await tester.enterText(amountField(), '30000');

      for (final blank in ['', '  \n\t ']) {
        await tester.enterText(detailField(), blank);
        await tester.tap(find.text('정정 신청 제출하기'));
        await tester.pumpAndSettle();
        expect(find.textContaining('상세 사유를 입력해 주세요'), findsOneWidget, reason: '"$blank"');
        expect(find.text('정정 신청 접수 완료!'), findsNothing);
      }
    });

    testWidgets('정상 입력이면 증감분으로 접수된다', (tester) async {
      await pumpScreen(tester);
      await lookup(tester, '1');
      await tester.enterText(amountField(), '30000');
      await tester.enterText(detailField(), '실제 영수증 확인 결과 금액 정정');

      await tester.tap(find.text('정정 신청 제출하기'));
      await tester.pumpAndSettle();

      expect(find.text('정정 신청 접수 완료!'), findsOneWidget);
      expect(find.text('₩ 35,000 → ₩ 30,000'), findsOneWidget);
      expect(find.text('-₩ 5,000'), findsOneWidget, reason: '기록되는 정정 금액은 증감분');
    });

    testWidgets('확정되지 않은 내역·없는 내역은 정정 대상이 될 수 없다', (tester) async {
      await pumpScreen(tester);

      await lookup(tester, '2'); // 더미 #2 는 승인 대기
      expect(find.textContaining('확정(CONFIRMED)된 내역만 정정할 수 있어요'), findsOneWidget);
      expect(find.textContaining('현재 금액 ₩'), findsNothing);

      await lookup(tester, '99');
      expect(find.text('#99 내역을 찾을 수 없어요.'), findsOneWidget);
    });

    testWidgets('조회 없이 제출하거나 ID 를 바꾸면 조회부터 다시 해야 한다', (tester) async {
      await pumpScreen(tester);

      await tester.enterText(find.widgetWithText(TextFormField, '정정 대상 내역 ID (Entry ID) *'), '1');
      await tester.enterText(amountField(), '30000');
      await tester.enterText(detailField(), '금액 정정');
      await tester.tap(find.text('정정 신청 제출하기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('먼저 [내역 조회]'), findsOneWidget);
      expect(find.text('정정 신청 접수 완료!'), findsNothing);

      await lookup(tester, '1');
      expect(find.textContaining('현재 금액 ₩ 35,000'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextFormField, '정정 대상 내역 ID (Entry ID) *'), '3');
      await tester.pumpAndSettle();
      expect(find.textContaining('현재 금액 ₩'), findsNothing, reason: 'ID 가 바뀌면 이전 조회 결과는 버린다');
    });
  });

  group('이의 답변 화면', () {
    Future<void> pumpScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(411, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: InquiryResponseScreen()));
      await tester.pumpAndSettle();
    }

    testWidgets('답변 완료 건에는 수정 버튼이 없고 수정할 수 없다고 알린다', (tester) async {
      await pumpScreen(tester);

      expect(find.text('답변 수정'), findsNothing);
      expect(find.text('답변은 블록체인에 기록되어 수정할 수 없어요'), findsOneWidget);
      expect(find.text('답변 작성하기'), findsOneWidget, reason: '답변 대기 건(#101)만 작성 버튼이 있다');
    });

    testWidgets('빈 답변은 등록되지 않고 이유를 알려 준다', (tester) async {
      await pumpScreen(tester);
      await tester.tap(find.text('답변 작성하기'));
      await tester.pumpAndSettle();

      // 빈 값 — 예전에는 아무 반응 없이 넘어갔다
      await tester.tap(find.text('답변 등록'));
      await tester.pumpAndSettle();
      expect(find.text('답변을 입력해 주세요'), findsOneWidget);

      // 공백·탭·개행만
      await tester.enterText(find.byType(TextFormField), '  \n\t ');
      await tester.tap(find.text('답변 등록'));
      await tester.pumpAndSettle();
      expect(find.text('답변을 입력해 주세요'), findsOneWidget);
      expect(find.textContaining('소명 답변이 등록되었습니다'), findsNothing);
    });

    testWidgets('답변하면 완료로 바뀌고 다시 답변할 수 없다', (tester) async {
      await pumpScreen(tester);
      await tester.tap(find.text('답변 작성하기'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField), '세부 품목 내역서를 증빙에 추가했습니다.');
      await tester.tap(find.text('답변 등록'));
      await tester.pumpAndSettle();

      expect(find.textContaining('소명 답변이 등록되었습니다'), findsOneWidget);
      expect(find.text('답변 작성하기'), findsNothing, reason: '답변한 이의에는 다시 답변할 수 없다');
      expect(find.text('답변은 블록체인에 기록되어 수정할 수 없어요'), findsNWidgets(2));
    });
  });
}
