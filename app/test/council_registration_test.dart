import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/screens/council/expense_create_screen.dart';
import 'package:student_council_app/screens/council/income_create_screen.dart';
import 'package:student_council_app/screens/council/receipt_picker.dart';
import 'package:student_council_app/services/api_service.dart';
import 'package:student_council_app/services/entry_registration_service.dart';

import 'support/registration.dart';

/// 지출·수입 등록 화면 — 입력값으로 초안을 만들어 등록기([EntryRegistrar])에 넘긴다.
/// 서명·서버 전송은 `entry_registration_service_test.dart`, 실체인은 `e2e/` 가 본다.
void main() {
  // 서버 없이 시연용 예산(행사비 #1 · 사업비 #2 · 운영비 #3, 학기 1)으로 돈다.
  setUp(() => ApiService.useDemoData = true);

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

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> fillExpense(WidgetTester tester, {String amount = '35000'}) async {
    await tester.enterText(find.widgetWithText(TextFormField, '목적 *'), '  신입생 환영회 명찰 ');
    await tester.enterText(find.widgetWithText(TextFormField, '사용처(상호명) *'), '한결문구');
    await tester.enterText(find.widgetWithText(TextFormField, '지출 금액(원) *'), amount);
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.tap(find.text(text));
    await settle(tester);
  }

  group('지출 등록', () {
    testWidgets('영수증을 고르면 원본 바이트의 해시를 싣고, 예산 id·학기는 고른 예산에서 가져와 제출한다', (tester) async {
      final registrar = FakeRegistrar();
      await pump(tester, ExpenseCreateScreen(registrar: registrar, pickReceipt: fakeReceipt));

      await tapText(tester, '영수증 촬영 또는 사진 첨부');
      expect(find.text('영수증 첨부 완료'), findsOneWidget);
      await fillExpense(tester);
      await tapText(tester, '제출하기');

      expect(find.text('지출 제출 완료!'), findsOneWidget);
      final (id, draft) = registrar.submits.single;
      expect(id, 100, reason: '저장한 초안 번호로 제출한다');
      expect(draft.kind, EntryKind.EXPENSE);
      expect(draft.budgetId, 1); // 기본 예산 항목 행사비
      expect(draft.termId, 1);
      expect(draft.amount, 35000);
      expect(draft.canonicalPurpose, '신입생 환영회 명찰');
      expect(draft.receiptHash, Hashing.fileHash(fakeReceiptBytes));
      expect(registrar.uploads.single, fakeReceiptBytes, reason: '초안보다 먼저 원본을 올린다');
      expect(draft.receiptPath, FakeRegistrar.pathOf(fakeReceiptBytes), reason: '서버는 파일 없는 해시를 막는다 (#66)');
      expect(find.textContaining('목업'), findsNothing);
    });

    testWidgets('영수증 업로드가 실패하면 알리고 초안을 만들지 않는다', (tester) async {
      final registrar = FakeRegistrar()
        ..failNextUpload = const EntryDecisionException(EntryDecisionFailure.mismatch, '서버에 저장된 영수증이 고른 사진과 달라요.');
      await pump(tester, ExpenseCreateScreen(registrar: registrar, pickReceipt: fakeReceipt));
      await tapText(tester, '영수증 촬영 또는 사진 첨부');
      await fillExpense(tester);
      await tapText(tester, '제출하기');
      expect(find.textContaining('서버에 저장된 영수증이 고른 사진과 달라요.'), findsOneWidget);
      expect(registrar.drafts, isEmpty);
      expect(registrar.submits, isEmpty);
    });

    testWidgets('영수증 없이는 제출하지 않는다 — 초안 저장은 된다', (tester) async {
      final registrar = FakeRegistrar();
      await pump(tester, ExpenseCreateScreen(registrar: registrar, pickReceipt: fakeReceipt));
      await fillExpense(tester);

      await tapText(tester, '제출하기');
      expect(find.textContaining('영수증을 첨부해야 제출할 수 있어요'), findsOneWidget);
      expect(registrar.submits, isEmpty);

      await tapText(tester, '초안으로 저장');
      expect(find.text('지출 초안 저장 완료'), findsOneWidget);
      expect(registrar.drafts.single.receiptHash, isNull);
    });

    testWidgets('제출이 실패하면 알리고, 다시 제출할 때 같은 초안 번호를 쓴다 (서명 시한 안 재제출)', (tester) async {
      final registrar = FakeRegistrar()
        ..failNextSubmit = const EntryDecisionException(EntryDecisionFailure.unknownOutcome, '등록 제출 결과를 확인하지 못했어요.');
      await pump(tester, ExpenseCreateScreen(registrar: registrar, pickReceipt: fakeReceipt));
      await tapText(tester, '영수증 촬영 또는 사진 첨부');
      await fillExpense(tester);

      await tapText(tester, '제출하기');
      expect(find.textContaining('등록 제출 결과를 확인하지 못했어요.'), findsOneWidget);

      await tapText(tester, '제출하기');
      expect(find.text('지출 제출 완료!'), findsOneWidget);
      expect(registrar.drafts, hasLength(1), reason: '초안은 한 번만 만든다');
      expect(registrar.uploads, hasLength(1), reason: '같은 사진은 다시 올리지 않는다');
      expect(registrar.submits.map((s) => s.$1).toSet(), {100});
    });

    testWidgets('예산을 넘으면 BLOCKED 로 기록됐다고 알린다', (tester) async {
      final registrar = FakeRegistrar();
      await pump(tester, ExpenseCreateScreen(registrar: registrar, pickReceipt: fakeReceipt));
      await tapText(tester, '영수증 촬영 또는 사진 첨부');
      await fillExpense(tester, amount: '3000000');
      await tapText(tester, '제출하기');
      expect(find.text('지출 등록이 차단되었어요'), findsOneWidget);
    });

    testWidgets('예산 목록을 못 읽으면 예산 id 를 알 수 없어 제출하지 않는다', (tester) async {
      ApiService.useDemoData = false; // 서버 없음 → 예산 목록 실패
      final registrar = FakeRegistrar();
      await pump(tester, ExpenseCreateScreen(registrar: registrar, pickReceipt: fakeReceipt));
      await tapText(tester, '영수증 촬영 또는 사진 첨부');
      await fillExpense(tester);
      await tapText(tester, '제출하기');
      expect(find.textContaining('예산 목록을 불러오지 못해'), findsOneWidget);
      expect(registrar.drafts, isEmpty);
    });
  });

  test('업로드 파일 이름은 내용의 앞 바이트로 형식을 정한다 — 서버가 확장자로 내려줄 형식을 고른다', () {
    expect(receiptFilename([0xFF, 0xD8, 0xFF, 0xE0]), 'receipt.jpg');
    expect(receiptFilename([0x89, 0x50, 0x4E, 0x47, 0x0D]), 'receipt.png');
    expect(receiptFilename('%PDF-1.7'.codeUnits), 'receipt.pdf');
    expect(receiptFilename([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits]), 'receipt.webp');
  });

  test('알아보지 못한 형식은 .jpg 라고 지어 붙이지 않고 막는다 — 서버는 확장자만 보고 저장·제공한다 (#71 리뷰)', () {
    expect(() => receiptFilename([1, 2]), throwsArgumentError);
    expect(() => receiptFilename('GIF89a'.codeUnits), throwsArgumentError);
    expect(() => receiptFilename(const []), throwsArgumentError);
    expect(receiptFormatProblem([1, 2]), contains('JPEG'));
    expect(receiptFormatProblem(const []), isNotNull);
  });

  group('HEIC 사진 — 서버가 받지 않는 형식이라 고를 때 막는다 (#71 리뷰)', () {
    final heic = [0, 0, 0, 0x18, ...'ftypheic'.codeUnits];
    final heif = [0, 0, 0, 0x18, ...'ftypmif1'.codeUnits];

    test('HEIC·HEIF 는 안내 문구가 나오고, JPEG·PNG·WebP·PDF 는 문제가 없다', () {
      expect(receiptFormatProblem(heic), contains('HEIC'));
      expect(receiptFormatProblem(heif), contains('HEIC'));
      expect(receiptFormatProblem([0xFF, 0xD8, 0xFF, 0xE0]), isNull);
      expect(receiptFormatProblem([0x89, 0x50, 0x4E, 0x47]), isNull);
      expect(receiptFormatProblem('%PDF-1.7'.codeUnits), isNull);
      expect(receiptFormatProblem([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits]), isNull);
    });

    test('이름을 만들 때도 HEIC 는 서버가 거부할 .heic 를 만들지 않고 던진다', () {
      expect(() => receiptFilename(heic), throwsArgumentError);
      expect(() => receiptFilename(heif), throwsArgumentError);
    });

    testWidgets('지출 등록에서 HEIC 를 고르면 첨부하지 않고 안내한다 — 영수증이 없어 제출도 못 한다', (tester) async {
      final registrar = FakeRegistrar();
      await pump(tester, ExpenseCreateScreen(registrar: registrar, pickReceipt: (_) async => heic));
      await tapText(tester, '영수증 촬영 또는 사진 첨부');
      expect(find.textContaining('HEIC'), findsOneWidget);
      await fillExpense(tester);
      await tapText(tester, '제출하기');
      expect(registrar.drafts, isEmpty);
    });

    testWidgets('수입 등록에서도 HEIC 는 첨부하지 않고 안내한다', (tester) async {
      final registrar = FakeRegistrar();
      await pump(tester, IncomeCreateScreen(registrar: registrar, pickReceipt: (_) async => heic));
      await tapText(tester, '영수증 첨부 (선택)');
      expect(find.textContaining('HEIC'), findsOneWidget);
    });
  });

  group('현재 학기', () {
    tearDown(() => ApiService.client = http.Client());

    test('시작·종료 사이인 학기를 고른다 — 없으면 가장 최근 학기', () async {
      ApiService.client = MockClient((req) async => http.Response(
            jsonEncode([
              {'id': 1, 'term_code': 20261, 'name': '1학기', 'started_at': '2026-02-28T15:00:00Z', 'ended_at': '2026-08-30T14:59:59Z'},
              {'id': 2, 'term_code': 20262, 'name': '2학기', 'started_at': '2026-08-31T15:00:00Z', 'ended_at': '2027-02-28T14:59:59Z'},
            ]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));
      expect(await ApiService().fetchCurrentTermId(now: DateTime.utc(2026, 5, 1)), 1);
      expect(await ApiService().fetchCurrentTermId(now: DateTime.utc(2026, 11, 6)), 2);
      expect(await ApiService().fetchCurrentTermId(now: DateTime.utc(2028, 1, 1)), 2);
    });
  });

  /// 서버 응답을 기다리는 동안 입력을 바꿀 수 있어도, 완료 안내는 **제출한 값**으로 만든다 (#69 리뷰).
  /// 응답 뒤에 입력칸을 다시 읽으면 금액을 비웠을 때 예외가 나 안내가 뜨지 않거나, 서버에 기록된 것과 다른 값을 보인다.
  group('제출 중 입력을 바꿔도 안내는 제출한 값이다', () {
    Future<void> pressWithoutSettling(WidgetTester tester, String text) async {
      await tester.ensureVisible(find.text(text));
      await tester.tap(find.text(text));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(); // 제출은 응답 대기 중
    }

    testWidgets('지출 — 금액을 비워도 안내가 뜨고 제출한 금액을 보인다', (tester) async {
      final registrar = _GatedRegistrar();
      await pump(tester, ExpenseCreateScreen(registrar: registrar, pickReceipt: fakeReceipt));
      await tapText(tester, '영수증 촬영 또는 사진 첨부');
      await fillExpense(tester, amount: '35000');
      await pressWithoutSettling(tester, '제출하기');
      expect(registrar.gate.isCompleted, isFalse);

      await tester.enterText(find.widgetWithText(TextFormField, '지출 금액(원) *'), ''); // 응답을 기다리는 사이 지움
      registrar.gate.complete();
      await settle(tester);

      expect(tester.takeException(), isNull, reason: '비운 금액을 다시 읽다 예외가 나면 안 된다');
      expect(find.text('지출 제출 완료!'), findsOneWidget);
      expect(find.textContaining('금액: 35000원', findRichText: true), findsOneWidget, reason: '서버에 기록된 금액');
    });

    testWidgets('수입 — 금액·출처를 바꿔도 제출한 값을 보인다', (tester) async {
      final registrar = _GatedRegistrar();
      await pump(tester, IncomeCreateScreen(registrar: registrar, pickReceipt: fakeReceipt));
      await tester.enterText(find.widgetWithText(TextFormField, '상세 출처 / 내용 *'), '학생회비 수납');
      await tester.enterText(find.widgetWithText(TextFormField, '입금 금액(원) *'), '1000000');
      await pressWithoutSettling(tester, '제출하기');

      await tester.enterText(find.widgetWithText(TextFormField, '입금 금액(원) *'), '5');
      await tester.enterText(find.widgetWithText(TextFormField, '상세 출처 / 내용 *'), '다른 출처');
      registrar.gate.complete();
      await settle(tester);

      expect(find.text('수입 제출 완료!'), findsOneWidget);
      expect(find.textContaining('금액: 1000000원', findRichText: true), findsOneWidget, reason: '서버에 기록된 금액');
      expect(find.textContaining('출처: 학생회비 수납', findRichText: true), findsOneWidget);
      expect(find.descendant(of: find.byType(Dialog), matching: find.textContaining('다른 출처', findRichText: true)), findsNothing,
          reason: '안내는 입력칸이 아니라 제출한 값이다');
    });
  });

  group('수입 등록', () {
    testWidgets('예산 없이 현재 학기로 제출하고, 영수증은 골랐을 때만 해시를 싣는다', (tester) async {
      final registrar = FakeRegistrar();
      await pump(tester, IncomeCreateScreen(registrar: registrar, pickReceipt: fakeReceipt));
      await tester.enterText(find.widgetWithText(TextFormField, '상세 출처 / 내용 *'), '학생회비 수납');
      await tester.enterText(find.widgetWithText(TextFormField, '입금 금액(원) *'), '1000000');
      await tapText(tester, '제출하기');

      expect(find.text('수입 제출 완료!'), findsOneWidget);
      final draft = registrar.submits.single.$2;
      expect(draft.kind, EntryKind.INCOME);
      expect(draft.budgetId, isNull);
      expect(draft.termId, 1);
      expect(draft.receiptHash, isNull);
    });

    testWidgets('영수증을 고르면 해시를 싣고, 다시 탭하면 첨부를 해제한다', (tester) async {
      final registrar = FakeRegistrar();
      await pump(tester, IncomeCreateScreen(registrar: registrar, pickReceipt: fakeReceipt));
      await tapText(tester, '영수증 첨부 (선택)');
      expect(find.text('영수증 첨부 완료 (탭하여 해제)'), findsOneWidget);
      await tapText(tester, '영수증 첨부 완료 (탭하여 해제)');
      expect(find.text('영수증 첨부 (선택)'), findsOneWidget);

      await tapText(tester, '영수증 첨부 (선택)');
      await tester.enterText(find.widgetWithText(TextFormField, '상세 출처 / 내용 *'), '학교 지원금');
      await tester.enterText(find.widgetWithText(TextFormField, '입금 금액(원) *'), '500000');
      await tapText(tester, '제출하기');
      expect(registrar.submits.single.$2.receiptHash, Hashing.fileHash(fakeReceiptBytes));
      expect(registrar.submits.single.$2.receiptPath, FakeRegistrar.pathOf(fakeReceiptBytes));
    });
  });
}

/// 제출 응답을 시험이 풀어 줄 때까지 붙잡아 두는 등록기 — 응답을 기다리는 사이의 화면을 본다.
class _GatedRegistrar extends FakeRegistrar {
  final gate = Completer<void>();

  @override
  Future<SubmitOutcome> submit(int id, EntryDraft draft) async {
    await gate.future;
    return super.submit(id, draft);
  }
}
