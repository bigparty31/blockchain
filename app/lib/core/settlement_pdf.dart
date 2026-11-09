import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/settlement_model.dart';
import 'format.dart';

/// 결산 PDF 에 쓰는 한글 폰트 (나눔고딕, OFL). pdf 패키지 기본 폰트에는 한글 글리프가 없다.
class SettlementPdfFonts {
  final pw.Font regular;
  final pw.Font bold;
  const SettlementPdfFonts({required this.regular, required this.bold});

  static const regularAsset = 'assets/fonts/NanumGothic-Regular.ttf';
  static const boldAsset = 'assets/fonts/NanumGothic-Bold.ttf';

  /// 앱 에셋에서 읽는다. 인터넷이 없어도 된다.
  static Future<SettlementPdfFonts> load() async {
    final regular = await rootBundle.load(regularAsset);
    final bold = await rootBundle.load(boldAsset);
    return SettlementPdfFonts(regular: pw.Font.ttf(regular), bold: pw.Font.ttf(bold));
  }
}

/// 학기 결산 PDF (A11, PRD §3 「상세는 PDF 내보내기·공유」, §4.7).
///
/// 화면 카드와 **같은 [SettlementModel]** 만 쓴다. 따로 계산하거나 보태지 않는다 — PDF 와 화면 숫자가 다르면 안 된다.
/// 화면에 없는 것은 표 형태의 상세(예산 항목별 최초·최신 편성액)와 생성 시각뿐이다.
class SettlementPdf {
  /// PDF 바이트. [generatedAt] 은 문서에 찍는 생성 시각 (테스트에서 고정한다).
  static Future<Uint8List> build(
    SettlementModel s, {
    required SettlementPdfFonts fonts,
    required DateTime generatedAt,
  }) {
    final doc = pw.Document(
      title: '${s.termName} 학생회 결산',
      creator: '학생회 회계 투명성 관리 시스템',
      theme: pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold),
    );
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(40),
        footer: (ctx) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('${ctx.pageNumber} / ${ctx.pagesCount}',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
        ),
        build: (_) => [
          pw.Text('${s.termName} 학생회 결산 보고서',
              style: const pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          pw.Text('작성 ${_dateTime(generatedAt)}',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
          pw.SizedBox(height: 16),
          _heading('1. 요약'),
          _table(const ['항목', '금액'], summaryRows(s), numericFrom: 1),
          pw.SizedBox(height: 16),
          _heading('2. 예산 집행'),
          if (s.budgets.isEmpty)
            pw.Text('편성된 예산이 없습니다.')
          else
            _table(
              const ['예산 항목', '최초 편성', '최신 편성', '지출', '남은 금액', '집행률'],
              budgetRows(s.budgets),
              numericFrom: 1,
            ),
          pw.SizedBox(height: 16),
          _heading('3. 메타지표'),
          _table(const ['지표', '값'], metricRows(s.metrics), numericFrom: 1),
        ],
      ),
    );
    return doc.save();
  }

  /// 요약 표의 줄 [항목, 금액].
  @visibleForTesting
  static List<List<String>> summaryRows(SettlementModel s) {
    final at = s.bankSnapshotAt;
    return [
      ['확정 수입', Fmt.won(s.income)],
      ['확정 지출', Fmt.won(s.expense)],
      ['장부 잔액 (수입 - 지출)', Fmt.won(s.ledgerBalance)],
      if (s.bankBalance == null || s.balanceGap == null) ...[
        ['통장 잔액', '계좌 대조 전'],
        ['차액 (장부 - 통장)', '계좌 대조 전'],
      ] else ...[
        ['통장 잔액${at == null ? '' : ' (${_dateTime(at)} 기준)'}', Fmt.won(s.bankBalance!)],
        ['차액 (장부 - 통장)', s.balanceGap == 0 ? '일치' : _signedWon(s.balanceGap!)],
      ],
    ];
  }

  /// 예산 집행 표의 줄. 개정된 예산은 최신 편성액 옆에 개정 횟수를 적는다 — 버전 1 이 최초 편성이라 `version - 1` 회.
  @visibleForTesting
  static List<List<String>> budgetRows(List<BudgetExecution> budgets) => [
        for (final b in budgets)
          [
            b.category,
            Fmt.won(b.initialAmount),
            '${Fmt.won(b.plannedAmount)}${b.revised ? ' (개정 ${b.version - 1}회)' : ''}',
            Fmt.won(b.spent),
            Fmt.won(b.remaining),
            b.executionRate == null ? '편성액 0' : _percent(b.executionRate!),
          ],
      ];

  /// 메타지표 표의 줄 [지표, 값].
  @visibleForTesting
  static List<List<String>> metricRows(SettlementMetrics m) {
    final reasons = [
      for (final e in m.correctionsByReason.entries)
        if (e.value > 0) '${correctionReasonLabel(e.key)} ${e.value}',
    ];
    final rate = m.revisionAfterBlockRate;
    return [
      ['OCR 경고 상태 승인', '${m.ocrWarningApproved}건'],
      ['용도 불일치 경고 승인', '${m.categoryWarningApproved}건'],
      ['정정', '${m.corrections}건${reasons.isEmpty ? '' : ' (${reasons.join(', ')})'}'],
      ['감사 D-30 이내 정정 (감사일 ${_date(m.auditAt)})', '${m.correctionsBeforeAudit}건'],
      [
        '예산 개정 / 초과 집행 이후 개정',
        '${m.budgetRevisions}회 / ${m.budgetRevisionsAfterBlock}회${rate == null ? '' : ' (${_percent(rate)})'}',
      ],
      ['이의 제기 / 미답변', '이번 범위 밖'],
    ];
  }

  static pw.Widget _heading(String text) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 6),
        child: pw.Text(text, style: const pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
      );

  /// [numericFrom] 번째 열부터 오른쪽 정렬 (금액·건수).
  static pw.Widget _table(List<String> header, List<List<String>> rows, {required int numericFrom}) {
    return pw.TableHelper.fromTextArray(
      headers: header,
      data: rows,
      headerStyle: const pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
      cellStyle: const pw.TextStyle(fontSize: 9),
      headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
      border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
      cellAlignments: {
        for (var i = 0; i < header.length; i++) i: i >= numericFrom ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
      },
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    );
  }

  static String _signedWon(int v) => v > 0 ? '+${Fmt.won(v)}' : '-${Fmt.won(-v)}';
  static String _percent(double rate) => '${(rate * 100).toStringAsFixed(1)}%';
  static String _date(DateTime t) => Fmt.date(t.millisecondsSinceEpoch ~/ 1000);
  static String _dateTime(DateTime t) => Fmt.dateTime(t.millisecondsSinceEpoch ~/ 1000);

  /// 공유할 파일 이름. 예: `settlement_20262.pdf`
  static String fileName(SettlementModel s) => 'settlement_${s.termCode}.pdf';
}
