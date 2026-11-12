import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/screens/council/correction_screen.dart';
import 'package:student_council_app/screens/council/input_rules.dart';
import 'package:student_council_app/screens/council/inquiry_response_screen.dart';
import 'package:student_council_app/services/api_service.dart';
import 'package:student_council_app/services/entry_registration_service.dart';

import 'support/registration.dart';

/// 정정 화면은 **증감분**을 기록하고, 이의 답변은 **다시 답변할 수 없다**.
///
/// - 정정 항목의 `amount` 는 새 총액이 아니라 `올바른 금액 − 현재 금액` 이다.
///   컨트랙트는 음수를 정정 항목에만 허용하고, 장부 합계는 확정 항목을 그냥 더한다
///   (`core/entry_merge.dart`, HASHING 샘플 3 `-20000`). 새 총액을 보내면 금액이 두 배가 된다.
/// - `IObjectionRegistry.answer` 는 이미 답변된 이의를 `ObjectionAlreadyAnswered` 로 거부한다.
void main() {
  // 목업 화면 테스트 — 서버 없이 시연용 더미로 돈다. 실패 표시는 api_unavailable_test.dart 가 본다 (PRD v0.14 §7.3).
  setUp(() => ApiService.useDemoData = true);
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
    // 서버·체인 대신 받은 초안을 기록하는 등록기 (support/registration.dart)
    late FakeRegistrar reg;

    Future<void> pumpScreen(WidgetTester tester, {int? initialTargetId}) async {
      tester.view.physicalSize = const Size(411, 2800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      reg = FakeRegistrar();
      await tester.pumpWidget(MaterialApp(
        home: CorrectionScreen(registrar: reg, pickReceipt: fakeReceipt, initialTargetId: initialTargetId),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('상세 사유는 한 줄이다 — purpose 로 저장되므로 줄바꿈을 받지 않는다 (PRD §4.4)', (tester) async {
      await pumpScreen(tester);
      final field = find.widgetWithText(TextFormField, '정정 상세 사유 *');
      final textField = find.descendant(of: field, matching: find.byType(TextField));
      expect(tester.widget<TextField>(textField).maxLines, 1);

      await tester.enterText(field, '첫 줄\n둘째 줄');
      expect(tester.widget<TextField>(textField).controller!.text, isNot(contains('\n')));
    });

    testWidgets('HEIC 사진은 서버가 받지 않으므로 고르는 자리에서 안내하고 첨부하지 않는다 (#71 리뷰)', (tester) async {
      tester.view.physicalSize = const Size(411, 2800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final heic = [0, 0, 0, 0x18, ...'ftypheic'.codeUnits];
      await tester.pumpWidget(MaterialApp(home: CorrectionScreen(registrar: FakeRegistrar(), pickReceipt: (_) async => heic)));
      await tester.pumpAndSettle();
      final attach = find.text('수정 증빙 자료 재첨부 (영수증, 선택)');
      await tester.ensureVisible(attach);
      await tester.tap(attach);
      await tester.pumpAndSettle();
      expect(find.textContaining('HEIC'), findsOneWidget);
      expect(find.text('수정 증빙 자료 재첨부 (영수증, 선택)'), findsOneWidget, reason: '첨부되지 않았다');
    });

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
    Finder detailField() => find.widgetWithText(TextFormField, '정정 상세 사유 *');

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

      await tester.tap(find.text('정정 제출하기'));
      await tester.pumpAndSettle();

      expect(find.textContaining('현재 금액과 같아요'), findsOneWidget);
      expect(find.text('정정 등록 완료!'), findsNothing);
    });

    testWidgets('정정 상세 사유는 비거나 공백만 있으면 안 된다', (tester) async {
      await pumpScreen(tester);
      await lookup(tester, '1');
      await tester.enterText(amountField(), '30000');

      for (final blank in ['', '   ']) {
        await tester.enterText(detailField(), blank);
        await tester.tap(find.text('정정 제출하기'));
        await tester.pumpAndSettle();
        expect(find.textContaining('상세 사유를 입력해 주세요'), findsOneWidget, reason: '"$blank"');
        expect(find.text('정정 등록 완료!'), findsNothing);
      }

      // purpose 는 한 줄 텍스트라 탭도 제어문자로 거부한다 (HASHING §1.1).
      await tester.enterText(detailField(), ' \t ');
      await tester.tap(find.text('정정 제출하기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('제어문자는 쓸 수 없어요'), findsOneWidget);
      expect(find.text('정정 등록 완료!'), findsNothing);
    });

    testWidgets('정상 입력이면 증감분으로 접수된다', (tester) async {
      await pumpScreen(tester);
      await lookup(tester, '1');
      await tester.enterText(amountField(), '30000');
      await tester.enterText(detailField(), '실제 영수증 확인 결과 금액 정정');

      await tester.tap(find.text('정정 제출하기'));
      await tester.pumpAndSettle();

      expect(find.text('정정 등록 완료!'), findsOneWidget);
      expect(find.text('금액 변경: ₩ 35,000 → ₩ 30,000'), findsOneWidget);
      expect(find.text('기록되는 정정 금액: -₩ 5,000'), findsOneWidget, reason: '기록되는 정정 금액은 증감분');
      expect(find.text('정정 번호: #100 · 승인 대기'), findsOneWidget);

      // 체인에 올라간 것은 원본을 가리키는 증감분 한 건 — 원본의 종류·학기·거래처·사용일·예산 그대로 (HASHING 샘플 3)
      expect(reg.submits, hasLength(1));
      final d = reg.submits.single.$2;
      expect(d.correctsEntryId, 1);
      expect(d.correctionReason, CorrectionReason.INPUT_ERROR);
      expect(d.amount, -5000);
      expect(d.kind, EntryKind.EXPENSE);
      expect(d.termId, 1);
      expect(d.budgetId, 2);
      expect(d.counterparty, '한결문구');
      expect(d.purpose, '실제 영수증 확인 결과 금액 정정');
      expect(d.occurredAt, 1788793200);
      expect(d.receiptHash, isNull, reason: '증빙을 붙이지 않았다');
      expect(d.toCreateJson()['corrects_entry_id'], 1);
      expect(d.toCreateJson()['correction_reason'], 'INPUT_ERROR');
      // 서명의 correctsId 는 원본 id — 0 이면 체인이 정정이 아닌 음수 금액으로 보고 거부한다
      final msg = EntryRegistrationService.recordMessage(id: 100, draft: d, term: 20262, deadline: 1);
      expect(msg.values['correctsId'], 1);
      expect(msg.values['amount'], -5000);
    });

    testWidgets('증빙 영수증을 붙이면 원본을 먼저 올리고 그 해시·경로를 싣는다', (tester) async {
      await pumpScreen(tester);
      await lookup(tester, '1');
      await tester.enterText(amountField(), '30000');
      await tester.enterText(detailField(), '실제 영수증 확인 결과 금액 정정');
      await tester.ensureVisible(find.text('수정 증빙 자료 재첨부 (영수증, 선택)'));
      await tester.tap(find.text('수정 증빙 자료 재첨부 (영수증, 선택)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('수정 증빙 첨부 완료됨'), findsOneWidget);

      await tester.ensureVisible(find.text('정정 제출하기'));
      await tester.tap(find.text('정정 제출하기'));
      await tester.pumpAndSettle();
      expect(reg.uploads, hasLength(1));
      final d = reg.submits.single.$2;
      expect(d.receiptHash, Hashing.fileHash(fakeReceiptBytes));
      expect(d.receiptPath, FakeRegistrar.pathOf(fakeReceiptBytes));
    });

    testWidgets('기타(OTHER) 사유도 고를 수 있다 — 상세 사유가 목적 칸에 들어간다', (tester) async {
      await pumpScreen(tester);
      await lookup(tester, '1');
      await tester.ensureVisible(find.text('기타'));
      await tester.tap(find.text('기타'));
      await tester.pumpAndSettle();
      await tester.enterText(amountField(), '30000');
      await tester.enterText(detailField(), '부가세 별도 표기 착오');
      await tester.ensureVisible(find.text('정정 제출하기'));
      await tester.tap(find.text('정정 제출하기'));
      await tester.pumpAndSettle();
      final d = reg.submits.single.$2;
      expect(d.correctionReason, CorrectionReason.OTHER);
      expect(d.purpose, '부가세 별도 표기 착오');
    });

    testWidgets('제출이 실패하면 알리고, 다시 제출할 때 같은 초안 번호를 쓴다', (tester) async {
      await pumpScreen(tester);
      await lookup(tester, '1');
      await tester.enterText(amountField(), '30000');
      await tester.enterText(detailField(), '실제 영수증 확인 결과 금액 정정');
      reg.failNextSubmit = const EntryDecisionException(EntryDecisionFailure.signing, '서명을 취소했어요.');
      await tester.ensureVisible(find.text('정정 제출하기'));
      await tester.tap(find.text('정정 제출하기'));
      await tester.pumpAndSettle();
      expect(find.text('서명을 취소했어요.'), findsOneWidget);
      expect(find.text('정정 등록 완료!'), findsNothing);

      await tester.tap(find.text('정정 제출하기'));
      await tester.pumpAndSettle();
      expect(find.text('정정 등록 완료!'), findsOneWidget);
      expect(reg.drafts, hasLength(1), reason: '초안은 한 번만 저장한다');
      expect(reg.submits.map((s) => s.$1), [100, 100]);
    });

    testWidgets('내 등록 현황에서 넘어오면 원본 번호가 채워진 채 바로 조회된다', (tester) async {
      await pumpScreen(tester, initialTargetId: 1);
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        if (find.textContaining('현재 금액').evaluate().isNotEmpty) break;
      }
      await tester.pumpAndSettle();
      expect(find.textContaining('현재 금액 ₩ 35,000'), findsOneWidget);
    });

    Future<void> chooseReclassify(WidgetTester tester) async {
      // 예산 목록(GET /budgets → 서버가 없으면 예시 데이터)이 실제 시간으로 도착할 때까지 기다린다
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
        if (find.textContaining('예산 #').evaluate().isEmpty) break;
      }
      await tester.ensureVisible(find.textContaining('재분류'));
      await tester.tap(find.textContaining('재분류'));
      await tester.pumpAndSettle();
    }

    testWidgets('재분류를 고르면 금액 대신 새 예산 항목을 고르고, 정정 2건이 미리 보인다', (tester) async {
      await pumpScreen(tester);
      await lookup(tester, '1'); // #1 은 사업비 35,000원
      await chooseReclassify(tester);
      expect(find.text('수정 후 올바른 금액(원) *'), findsNothing);
      expect(find.text('새 예산 항목 *'), findsOneWidget);
      expect(find.textContaining('① 새 예산 +₩ 35,000 (먼저)'), findsOneWidget);
      expect(find.textContaining('② 사업비 -₩ 35,000 (나중)'), findsOneWidget);
    });

    // 조회 전에 고른 새 예산이 다른 학기 것이면, 조회 뒤 후보에서 빠지는데 선택값만 남아 드롭다운이 깨졌다 (#72 리뷰).
    testWidgets('조회 전에 고른 다른 학기 예산은 조회 뒤 후보에서 빠지며 선택도 비워진다', (tester) async {
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
      ApiService.client = MockClient((req) async {
        if (req.url.path == '/budgets') {
          return http.Response(
              jsonEncode([
                budget(1, 1, '행사비', 2470000),
                budget(2, 1, '사업비', 1465000),
                budget(3, 1, '운영비', 1000000),
                budget(11, 2, '행사비', 900000),
                budget(12, 2, '사업비', 800000),
              ]),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }
        return http.Response('{}', 404); // 내역은 더미로 폴백 — #1 은 학기 1 의 사업비
      });
      addTearDown(() => ApiService.client = http.Client());
      await pumpScreen(tester);
      await chooseReclassify(tester);

      await tester.ensureVisible(find.byType(DropdownButtonFormField<int>));
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('행사비 · 잔량 ₩ 900,000').last); // 학기 2 의 행사비
      await tester.pumpAndSettle();
      expect(find.textContaining('행사비 · 잔량 ₩ 900,000'), findsWidgets);

      await lookup(tester, '1'); // 학기 1 의 사업비 — 후보는 학기 1 의 다른 예산뿐
      expect(tester.takeException(), isNull, reason: '후보에 없는 값이 남으면 드롭다운이 깨진다');
      expect(find.textContaining('행사비 · 잔량 ₩ 900,000'), findsNothing, reason: '다른 학기 예산 선택은 비워진다');
      expect(find.text('옮겨 갈 예산 항목을 고르세요'), findsOneWidget);
    });

    // 영수증 업로드를 기다리는 사이 금액을 비우면, 업로드 뒤에 입력을 다시 읽다 던졌고
    // 그 예외를 아무도 받지 않아 「제출 중」이 풀리지 않았다 (#72 리뷰).
    testWidgets('업로드를 기다리는 사이 금액을 비워도 제출한 값으로 끝까지 가고, 제출 중 상태가 풀린다', (tester) async {
      tester.view.physicalSize = const Size(411, 2800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final gated = _UploadGateRegistrar();
      await tester.pumpWidget(MaterialApp(home: CorrectionScreen(registrar: gated, pickReceipt: fakeReceipt)));
      await tester.pumpAndSettle();
      await lookup(tester, '1');
      final attach = find.text('수정 증빙 자료 재첨부 (영수증, 선택)');
      await tester.ensureVisible(attach);
      await tester.tap(attach);
      await tester.pumpAndSettle();
      await tester.enterText(amountField(), '30000');
      await tester.enterText(detailField(), '실제 영수증 확인 결과 금액 정정');
      await tester.ensureVisible(find.text('정정 제출하기'));
      await tester.tap(find.text('정정 제출하기')); // 업로드 대기 중 — 아직 끝내지 않는다
      await tester.pump();

      await tester.enterText(amountField(), ''); // 기다리는 사이 지움
      gated.uploadGate.complete();
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: '비운 금액을 다시 읽다 예외가 나면 안 된다');
      expect(find.text('정정 등록 완료!'), findsOneWidget);
      expect(gated.drafts.single.amount, -5000, reason: '제출 버튼을 누른 때의 값(35,000 → 30,000)');
      expect(find.text('제출 중...'), findsNothing, reason: '제출 중 상태가 풀려야 한다');
    });

    testWidgets('새 예산 항목을 고르지 않으면 제출되지 않는다', (tester) async {
      await pumpScreen(tester);
      await lookup(tester, '1');
      await chooseReclassify(tester);
      await tester.enterText(detailField(), '예산 항목을 잘못 골랐어요');
      await tester.ensureVisible(find.text('정정 제출하기'));
      await tester.tap(find.text('정정 제출하기'));
      await tester.pumpAndSettle();
      expect(find.text('옮겨 갈 예산 항목을 골라 주세요'), findsOneWidget);
      expect(find.text('재분류 정정 2건 등록 완료!'), findsNothing);
    });

    testWidgets('새 예산을 고르면 +/− 정정 2건이 등록되고, 원래 예산은 후보에서 빠진다', (tester) async {
      await pumpScreen(tester);
      await lookup(tester, '1');
      await chooseReclassify(tester);
      await tester.ensureVisible(find.byType(DropdownButtonFormField<int>));
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      expect(find.textContaining('사업비 · 잔량'), findsNothing, reason: '원래 예산(사업비)은 고를 수 없다');
      await tester.tap(find.textContaining('행사비 · 잔량').last);
      await tester.pumpAndSettle();
      await tester.enterText(detailField(), '예산 항목을 잘못 골랐어요');
      await tester.ensureVisible(find.text('정정 제출하기'));
      await tester.tap(find.text('정정 제출하기'));
      await tester.pumpAndSettle();
      expect(find.text('재분류 정정 2건 등록 완료!'), findsOneWidget);
      expect(find.textContaining('행사비 +₩ 35,000'), findsNWidgets(2), reason: '미리보기 + 완료 다이얼로그');
      expect(find.textContaining('사업비 -₩ 35,000'), findsNWidgets(2));
      expect(find.text('정정 등록 완료!'), findsNothing, reason: '1건짜리 정정으로 올라가면 안 된다');

      // 새 예산(+)이 먼저, 원래 예산(−)이 나중 — 둘 다 원본을 가리킨다
      expect(reg.submits.map((s) => (s.$2.budgetId, s.$2.amount, s.$2.correctsEntryId)).toList(), [
        (1, 35000, 1),
        (2, -35000, 1),
      ]);
    });

    testWidgets('재분류의 증액(+)이 차단되면 감액(−)은 올리지 않는다', (tester) async {
      await pumpScreen(tester);
      reg.remaining[1] = 10000; // 새 예산(행사비)에 35,000원이 없다
      await lookup(tester, '1');
      await chooseReclassify(tester);
      await tester.ensureVisible(find.byType(DropdownButtonFormField<int>));
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('행사비 · 잔량').last);
      await tester.pumpAndSettle();
      await tester.enterText(detailField(), '예산 항목을 잘못 골랐어요');
      await tester.ensureVisible(find.text('정정 제출하기'));
      await tester.tap(find.text('정정 제출하기'));
      await tester.pumpAndSettle();
      expect(find.text('정정이 예산 검사에서 차단됐어요'), findsOneWidget);
      expect(reg.submits, hasLength(1), reason: '감액만 확정되면 원래 예산만 돌려받고 지출이 사라진다');
      expect(reg.submits.single.$2.amount, 35000);
    });

    testWidgets('조회 전에 고른 새 예산이 조회한 내역의 원래 예산이면 선택을 비운다 — 화면이 깨지지 않고 제출도 막힌다',
        (tester) async {
      await pumpScreen(tester);
      await chooseReclassify(tester); // 대상 조회 전이라 모든 예산이 후보다
      await tester.ensureVisible(find.byType(DropdownButtonFormField<int>));
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('사업비 · 잔량').last);
      await tester.pumpAndSettle();

      await lookup(tester, '1'); // #1 의 원래 예산이 사업비 — 후보에서 빠진다
      expect(tester.takeException(), isNull, reason: '후보에 없는 값을 드롭다운에 두면 디버그 빌드가 assertion 으로 깨진다');
      expect(find.textContaining('① 새 예산 +₩ 35,000 (먼저)'), findsOneWidget, reason: '선택이 비워졌다');

      await tester.enterText(detailField(), '예산 항목을 잘못 골랐어요');
      await tester.ensureVisible(find.text('정정 제출하기'));
      await tester.tap(find.text('정정 제출하기'));
      await tester.pumpAndSettle();
      expect(find.text('옮겨 갈 예산 항목을 골라 주세요'), findsOneWidget);
      expect(find.text('재분류 정정 2건 등록 완료!'), findsNothing);
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
      await tester.tap(find.text('정정 제출하기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('먼저 [내역 조회]'), findsOneWidget);
      expect(find.text('정정 등록 완료!'), findsNothing);

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
      expect(find.textContaining('답변이 등록되었습니다'), findsNothing);
    });

    testWidgets('답변하면 완료로 바뀌고 다시 답변할 수 없다', (tester) async {
      await pumpScreen(tester);
      await tester.tap(find.text('답변 작성하기'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField), '세부 품목 내역서를 증빙에 추가했습니다.');
      await tester.tap(find.text('답변 등록'));
      await tester.pumpAndSettle();

      expect(find.textContaining('답변이 등록되었습니다'), findsOneWidget);
      expect(find.text('답변 작성하기'), findsNothing, reason: '답변한 이의에는 다시 답변할 수 없다');
      expect(find.text('답변은 블록체인에 기록되어 수정할 수 없어요'), findsNWidgets(2));
    });
  });
}

/// 영수증 업로드를 시험이 풀어 줄 때까지 붙잡아 두는 등록기 — 업로드를 기다리는 사이의 화면을 본다.
class _UploadGateRegistrar extends FakeRegistrar {
  final uploadGate = Completer<void>();

  @override
  Future<ReceiptUpload> uploadReceipt(List<int> bytes, {required String filename}) async {
    await uploadGate.future;
    return super.uploadReceipt(bytes, filename: filename);
  }
}
