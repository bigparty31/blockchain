import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/src/pdf/font/ttf_parser.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/settlement_pdf.dart';
import 'package:student_council_app/models/settlement_model.dart';
import 'package:student_council_app/screens/council/settlement_screen.dart';
import 'package:student_council_app/services/api_service.dart';
import 'package:student_council_app/services/settlement_service.dart';

import 'support/session.dart';

/// 결산 화면 (A11) — docs/API.md 「결산」 응답을 그대로 보여 주는가, 못 읽으면 숫자를 지어내지 않는가.
void main() {
  Map<String, dynamic> settlement({int? bank = 4500000, int? gap = 60000, int revisions = 2}) => {
        'term_id': 7,
        'term_code': 20262,
        'term_name': '2026-2학기',
        'income': 5000000,
        'expense': 440000,
        'ledger_balance': 4560000,
        'bank_balance': bank,
        'bank_snapshot_at': bank == null ? null : '2026-12-01T00:00:00Z',
        'balance_gap': gap,
        'budgets': [
          {
            'budget_id': 1,
            'category': '행사비',
            'initial_amount': 2000000,
            'planned_amount': 2500000,
            'version': 2,
            'spent': 310000,
            'remaining': 2190000,
            'execution_rate': 0.124,
          },
          {
            'budget_id': 2,
            'category': '운영비',
            'initial_amount': 1000000,
            'planned_amount': 1000000,
            'version': 1,
            'spent': 130000,
            'remaining': 870000,
            'execution_rate': 0.13,
          },
        ],
        'metrics': {
          'ocr_warning_approved': 1,
          'category_warning_approved': 0,
          'corrections': 3,
          'corrections_by_reason': {'INPUT_ERROR': 1, 'RECEIPT_RECHECK': 0, 'REFUND': 1, 'RECLASSIFY': 0, 'OTHER': 1},
          'corrections_before_audit': 1,
          'audit_at': '2026-12-20T00:00:00Z',
          'budget_revisions': revisions,
          'budget_revisions_after_block': revisions == 0 ? 0 : 1,
          'revision_after_block_rate': revisions == 0 ? null : 0.5,
        },
      };

  http.Response json(Object body, [int code = 200]) =>
      http.Response(jsonEncode(body), code, headers: {'content-type': 'application/json; charset=utf-8'});

  final terms = [
    {'id': 6, 'term_code': 20261, 'name': '2026-1학기'},
    {'id': 7, 'term_code': 20262, 'name': '2026-2학기'},
  ];

  /// 가짜 서버. 결산을 부른 경로를 [asked] 에 남긴다.
  late List<String> asked;
  MockClient server({Object? body, int code = 200, Object? termList}) {
    asked = [];
    return MockClient((req) async {
      asked.add(req.url.path);
      if (req.url.path == '/terms') return json(termList ?? terms);
      if (req.url.path.startsWith('/settlement/')) return json(body ?? settlement(), code);
      return json({}, 404);
    });
  }

  setUp(() async => signInAs(UserRole.AUDITOR, userId: 3));
  tearDown(() async {
    SettlementService.client = http.Client();
    await signOutForTest();
  });

  group('서비스', () {
    test('현재 학기 코드(20262)로 학기 id 를 찾아 그 id 로 결산을 읽는다', () async {
      SettlementService.client = server();
      final s = await SettlementService().fetch();
      expect(asked, ['/terms', '/settlement/7'], reason: '학기 코드(20262)가 아니라 학기 id(7)로 부른다');
      expect(s.ledgerBalance, 4560000);
      expect(s.balanceGap, 60000);
      expect(s.budgets.first.revised, isTrue);
      expect(s.metrics.correctionsByReason['OTHER'], 1);
    });

    test('서버에 현재 학기가 없으면 다른 학기를 대신 읽지 않는다', () async {
      SettlementService.client = server(termList: [terms.first]);
      await expectLater(SettlementService().fetch(), throwsA(isA<ApiUnavailable>()));
      expect(asked, ['/terms'], reason: '결산을 부르지 않는다');
    });

    test('숫자 필드가 비었거나 형식이 틀리면 0 으로 메우지 않고 실패한다', () async {
      for (final broken in <Map<String, dynamic> Function()>[
        () => settlement()..remove('income'),
        () => settlement()..['expense'] = '440000',
        () => settlement()..['budgets'] = null,
        () => settlement()..['metrics'] = (Map<String, dynamic>.from(settlement()['metrics'])..remove('corrections')),
        () => settlement()..['metrics'] = (Map<String, dynamic>.from(settlement()['metrics'])..['audit_at'] = 'not-a-date'),
      ]) {
        SettlementService.client = server(body: broken());
        await expectLater(SettlementService().fetch(), throwsA(isA<ApiUnavailable>()));
      }
    });

    test('서버가 null 로 주는 자리(계좌 스냅샷 없음·개정 0회)는 받아들인다', () {
      final s = SettlementModel.fromJson(settlement(bank: null, gap: null, revisions: 0));
      expect(s.bankBalance, isNull);
      expect(s.balanceGap, isNull);
      expect(s.metrics.revisionAfterBlockRate, isNull);
    });

    test('403·500 은 ApiForbidden·ApiUnavailable', () async {
      SettlementService.client = server(body: {'detail': 'x'}, code: 403);
      await expectLater(SettlementService().fetch(), throwsA(isA<ApiForbidden>()));
      SettlementService.client = server(body: {'detail': 'x'}, code: 500);
      await expectLater(SettlementService().fetch(), throwsA(isA<ApiUnavailable>()));
    });
  });

  group('화면', () {
    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SettlementScreen()));
      await tester.pumpAndSettle();
    }

    testWidgets('요약·예산 집행·메타지표 카드를 보여 준다', (tester) async {
      SettlementService.client = server();
      await open(tester);

      expect(find.text('결산 · 2026-2학기'), findsOneWidget);
      expect(find.text('₩ 4,560,000'), findsOneWidget, reason: '장부 잔액');
      expect(find.byKey(const Key('settlement_gap_note')), findsOneWidget);
      expect(find.textContaining('장부에는 있는데 통장에 없는'), findsOneWidget, reason: '차액 양수 = 장부 − 통장 > 0');

      await tester.scrollUntilVisible(find.byKey(const Key('settlement_metrics')), 200);
      expect(find.byKey(const Key('settlement_budget_revised_1')), findsOneWidget, reason: '행사비 v2 개정');
      expect(find.byKey(const Key('settlement_budget_revised_2')), findsNothing, reason: '운영비는 개정 없음');
      expect(find.text('입력 오류 1 · 환불 1 · 기타 1'), findsOneWidget, reason: '0건 사유는 빼고, OTHER 는 「기타」');
      expect(find.text('2회, 그중 초과 집행 이후 1회 (50.0%)'), findsOneWidget);
    });

    testWidgets('차액이 음수면 「통장에는 있는데 장부에 없는 돈」, 0 이면 「일치」', (tester) async {
      SettlementService.client = server(body: settlement(gap: -20000));
      await open(tester);
      expect(find.textContaining('통장에는 있는데 장부에 없는'), findsOneWidget);
      expect(find.text('₩ 20,000'), findsOneWidget, reason: '차액은 절댓값으로 보이고 방향은 문장으로');

      SettlementService.client = server(body: settlement(gap: 0));
      await tester.pumpWidget(const MaterialApp(home: SettlementScreen(key: Key('again'))));
      await tester.pumpAndSettle();
      expect(find.text('일치'), findsOneWidget);
      expect(find.byKey(const Key('settlement_gap_note')), findsNothing);
    });

    testWidgets('계좌 스냅샷이 없으면 차액 대신 「계좌 대조 전」', (tester) async {
      SettlementService.client = server(body: settlement(bank: null, gap: null));
      await open(tester);
      expect(find.text('계좌 대조 전'), findsOneWidget);
      expect(find.byKey(const Key('settlement_no_bank')), findsOneWidget);
      expect(find.byKey(const Key('settlement_gap_note')), findsNothing);
    });

    testWidgets('못 읽으면 숫자 없이 오류와 다시 시도를 보여 주고, 다시 시도하면 읽는다', (tester) async {
      SettlementService.client = server(body: {'detail': 'db'}, code: 503);
      await open(tester);
      expect(find.byKey(const Key('settlement_error')), findsOneWidget);
      expect(find.byKey(const Key('settlement_summary')), findsNothing);

      SettlementService.client = server();
      await tester.tap(find.text('다시 시도'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settlement_summary')), findsOneWidget);
    });
  });

  group('PDF', () {
    /// 앱 에셋 폰트를 파일로 읽는다 (flutter test 는 app/ 에서 돈다).
    SettlementPdfFonts fonts() {
      pw.Font load(String path) => pw.Font.ttf(ByteData.sublistView(File(path).readAsBytesSync()));
      return SettlementPdfFonts(
        regular: load(SettlementPdfFonts.regularAsset),
        bold: load(SettlementPdfFonts.boldAsset),
      );
    }

    test('에셋 폰트에 한글 글리프가 있다 — 없으면 PDF 의 한글이 빈칸이 된다', () {
      for (final path in [SettlementPdfFonts.regularAsset, SettlementPdfFonts.boldAsset]) {
        final ttf = TtfParser(ByteData.sublistView(File(path).readAsBytesSync()));
        for (final ch in '결산보고서장부잔액통장차액'.runes) {
          expect(ttf.charToGlyphIndexMap[ch], isNotNull, reason: '$path 에 ${String.fromCharCode(ch)} 가 없다');
        }
      }
    });

    test('PDF 에 찍는 모든 글자가 폰트에 있다 — 없으면 그 자리가 깨진다 (예: 빼기 기호 U+2212)', () {
      // 표 내용 (여러 경우) + settlement_pdf.dart 의 문자열 리터럴 (제목·각주·표 머리)
      final texts = <String>[
        for (final data in [settlement(), settlement(bank: null, gap: null, revisions: 0), settlement(gap: -20000), settlement(gap: 0)])
          for (final row in [
            ...SettlementPdf.summaryRows(SettlementModel.fromJson(data)),
            ...SettlementPdf.metricRows(SettlementModel.fromJson(data).metrics),
            ...SettlementPdf.budgetRows(SettlementModel.fromJson(data).budgets),
          ])
            ...row,
        for (final line in File('lib/core/settlement_pdf.dart').readAsLinesSync())
          if (!line.trimLeft().startsWith('//'))
            for (final m in RegExp(r"'([^'\\]|\\.)*'").allMatches(line)) m.group(0)!,
      ];
      for (final path in [SettlementPdfFonts.regularAsset, SettlementPdfFonts.boldAsset]) {
        final ttf = TtfParser(ByteData.sublistView(File(path).readAsBytesSync()));
        final missing = <String>{
          for (final t in texts)
            for (final ch in t.runes)
              if (ch > 0x20 && ttf.charToGlyphIndexMap[ch] == null)
                'U+${ch.toRadixString(16).toUpperCase().padLeft(4, '0')} ${String.fromCharCode(ch)}',
        };
        expect(missing, isEmpty, reason: '$path 에 없는 글자');
      }
    });

    test('결산 응답으로 PDF 를 만든다 (계좌 대조 전·개정 0회도)', () async {
      for (final data in [settlement(), settlement(bank: null, gap: null, revisions: 0), settlement(gap: -20000)]) {
        final bytes = await SettlementPdf.build(
          SettlementModel.fromJson(data),
          fonts: fonts(),
          generatedAt: DateTime(2026, 12, 21, 10),
        );
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        expect(String.fromCharCodes(bytes.skip(bytes.length - 6)).trim(), '%%EOF');
      }
    });

    test('요약 표는 화면과 같은 숫자를 쓴다 — 차액은 부호로 방향, 스냅샷 없으면 「계좌 대조 전」', () {
      final rows = SettlementPdf.summaryRows(SettlementModel.fromJson(settlement()));
      expect(rows[2], ['장부 잔액 (수입 - 지출)', '₩ 4,560,000']);
      expect(rows.last, ['차액 (장부 - 통장)', '+₩ 60,000']);
      expect(SettlementPdf.summaryRows(SettlementModel.fromJson(settlement(gap: -20000))).last.last, '-₩ 20,000');
      expect(SettlementPdf.summaryRows(SettlementModel.fromJson(settlement(gap: 0))).last.last, '일치');
      final none = SettlementPdf.summaryRows(SettlementModel.fromJson(settlement(bank: null, gap: null)));
      expect(none.skip(3).map((r) => r.last), ['계좌 대조 전', '계좌 대조 전']);
    });

    test('예산 표 — 개정된 예산은 개정 횟수(버전 − 1)를, 개정 없으면 아무것도 붙이지 않는다', () {
      final rows = SettlementPdf.budgetRows(SettlementModel.fromJson(settlement()).budgets);
      expect(rows[0], ['행사비', '₩ 2,000,000', '₩ 2,500,000 (개정 1회)', '₩ 310,000', '₩ 2,190,000', '12.4%']);
      expect(rows[1][2], '₩ 1,000,000', reason: '운영비는 v1 — 최초 편성 그대로');
    });

    test('메타지표 표 — 0건 사유는 빼고, 이의 제기는 범위 밖으로 적는다', () {
      final rows = SettlementPdf.metricRows(SettlementModel.fromJson(settlement()).metrics);
      expect(rows[2], ['정정', '3건 (입력 오류 1, 환불 1, 기타 1)']);
      expect(rows[4].last, '2회 / 1회 (50.0%)');
      expect(rows.last, ['이의 제기 / 미답변', '이번 범위 밖']);
    });

    Future<void> openWith(
      WidgetTester tester, {
      required Future<Uint8List> Function(SettlementModel) build,
      required Future<void> Function(Uint8List, String) share,
    }) async {
      await tester.pumpWidget(MaterialApp(home: SettlementScreen(buildPdf: build, sharePdf: share)));
      await tester.pumpAndSettle();
    }

    testWidgets('PDF 버튼은 보이는 결산으로 PDF 를 만들어 settlement_20262.pdf 로 공유한다', (tester) async {
      SettlementService.client = server();
      SettlementModel? built;
      String? sharedName;
      Uint8List? sharedBytes;
      await openWith(
        tester,
        build: (s) async {
          built = s;
          return Uint8List.fromList([1, 2, 3]);
        },
        share: (bytes, name) async {
          sharedBytes = bytes;
          sharedName = name;
        },
      );
      await tester.tap(find.byKey(const Key('settlement_pdf')));
      await tester.pumpAndSettle();
      expect(built?.ledgerBalance, 4560000);
      expect(sharedBytes, [1, 2, 3]);
      expect(sharedName, 'settlement_20262.pdf');
    });

    testWidgets('결산을 못 읽었으면 PDF 버튼이 없다 — 빈 보고서를 만들지 않는다', (tester) async {
      SettlementService.client = server(body: {'detail': 'db'}, code: 503);
      await openWith(tester, build: (_) async => fail('만들면 안 된다'), share: (_, __) async {});
      expect(find.byKey(const Key('settlement_error')), findsOneWidget);
      expect(find.byKey(const Key('settlement_pdf')), findsNothing);
    });

    testWidgets('PDF 를 못 만들면 알려 주고, 다시 누를 수 있다', (tester) async {
      SettlementService.client = server();
      var calls = 0;
      await openWith(
        tester,
        build: (_) async {
          calls++;
          throw StateError('font');
        },
        share: (_, __) async => fail('공유하면 안 된다'),
      );
      await tester.tap(find.byKey(const Key('settlement_pdf')));
      await tester.pumpAndSettle();
      expect(find.textContaining('PDF 를 만들지 못했어요'), findsOneWidget);
      await tester.tap(find.byKey(const Key('settlement_pdf')));
      await tester.pumpAndSettle();
      expect(calls, 2);
    });
  });
}
