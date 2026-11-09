import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../core/app_theme.dart';
import '../../core/format.dart';
import '../../core/settlement_pdf.dart';
import '../../models/settlement_model.dart';
import '../../services/api_service.dart';
import '../../services/settlement_service.dart';

/// 학기 결산 (A11, PRD §4.7) — 감사·회장.
///
/// 폰에서는 **요약 카드 + 메타지표 카드**로 보여 주고, 상세는 **PDF 로 내보내 공유**한다 (PRD §3 모바일 대응 방침).
/// PDF 는 화면과 같은 응답([SettlementModel])으로만 만든다 — 숫자를 따로 계산하지 않는다.
///
/// 읽지 못하면 숫자 대신 오류와 「다시 시도」를 보여 준다. 결산에 가짜 합계가 보이면 안 된다.
class SettlementScreen extends StatefulWidget {
  /// 테스트에서 가짜 HTTP 와 함께 넣는다.
  final SettlementService? service;

  /// 결산으로 PDF 바이트를 만든다. 테스트에서 갈아끼운다.
  final Future<Uint8List> Function(SettlementModel) buildPdf;

  /// 만든 PDF 를 기기 공유 시트로 넘긴다 (카톡·메일·파일 저장). 테스트에서 갈아끼운다.
  final Future<void> Function(Uint8List bytes, String fileName) sharePdf;

  const SettlementScreen({
    super.key,
    this.service,
    this.buildPdf = _buildPdf,
    this.sharePdf = _sharePdf,
  });

  static Future<Uint8List> _buildPdf(SettlementModel s) async =>
      SettlementPdf.build(s, fonts: await SettlementPdfFonts.load(), generatedAt: DateTime.now());

  static Future<void> _sharePdf(Uint8List bytes, String fileName) async {
    await Printing.sharePdf(bytes: bytes, filename: fileName);
  }

  @override
  State<SettlementScreen> createState() => _SettlementScreenState();
}

class _SettlementScreenState extends State<SettlementScreen> {
  late final SettlementService _service = widget.service ?? SettlementService();

  SettlementModel? _data;
  String? _error;
  bool _loading = true;
  int _seq = 0;

  /// PDF 를 만드는 중. 두 번 누르기를 막는다.
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final seq = ++_seq; // 겹친 읽기는 마지막 응답만 반영한다
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _service.fetch();
      if (!mounted || seq != _seq) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } on ApiUnavailable catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _data = null; // 지난 숫자를 남기지 않는다
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// 지금 보이는 결산을 PDF 로 만들어 공유한다. 결산을 못 읽었으면 버튼이 없다 — 빈 PDF 를 만들지 않는다.
  Future<void> _exportPdf() async {
    final data = _data;
    if (data == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      final bytes = await widget.buildPdf(data);
      await widget.sharePdf(bytes, SettlementPdf.fileName(data));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PDF 를 만들지 못했어요. 다시 시도해 주세요.')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: Text(_data == null ? '결산' : '결산 · ${_data!.termName}'),
        actions: [
          if (_data != null)
            IconButton(
              key: const Key('settlement_pdf'),
              tooltip: 'PDF 로 내보내기·공유',
              onPressed: _exporting ? null : _exportPdf,
              icon: _exporting
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.picture_as_pdf_rounded),
            ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    final data = _data;
    if (_loading && data == null) return const Center(child: CircularProgressIndicator());
    if (data == null) {
      return ListView(
        key: const Key('settlement_error'),
        padding: const EdgeInsets.all(32),
        children: [
          const SizedBox(height: 80),
          const Icon(Icons.cloud_off_rounded, size: 48, color: AppTheme.textSub),
          const SizedBox(height: 12),
          Text(_error ?? '결산을 불러오지 못했어요.',
              textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textSub)),
          Center(child: TextButton(onPressed: _load, child: const Text('다시 시도'))),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SummaryCard(data),
        const SizedBox(height: 12),
        _BudgetCard(data.budgets),
        const SizedBox(height: 12),
        _MetricsCard(data.metrics),
      ],
    );
  }
}

// ───────────────────────────────────────── 공통

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  final Key? cardKey;
  const _Section({required this.title, required this.child, this.cardKey});

  @override
  Widget build(BuildContext context) {
    return Card(
      key: cardKey,
      color: AppTheme.bgCard,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textMain)),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  final bool strong;
  const _Row(this.label, this.value, {this.color, this.strong = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: const TextStyle(color: AppTheme.textSub))),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: color ?? AppTheme.textMain,
                fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _percent(double rate) => '${(rate * 100).toStringAsFixed(1)}%';

// ───────────────────────────────────────── 요약

class _SummaryCard extends StatelessWidget {
  final SettlementModel data;
  const _SummaryCard(this.data);

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: '요약',
      cardKey: const Key('settlement_summary'),
      child: Column(
        children: [
          _Row('확정 수입', Fmt.won(data.income), color: AppTheme.income),
          _Row('확정 지출', Fmt.won(data.expense), color: AppTheme.expense),
          _Row('장부 잔액', Fmt.won(data.ledgerBalance), strong: true),
          const Divider(height: 20),
          ..._bank(),
        ],
      ),
    );
  }

  /// 통장 잔액과 차액. 차액 = 장부 잔액 − 통장 잔액 (서버 정의).
  List<Widget> _bank() {
    final bank = data.bankBalance;
    final gap = data.balanceGap;
    if (bank == null || gap == null) {
      return const [
        _Row('통장 잔액', '계좌 대조 전'),
        Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            '은행 거래내역을 올리면 장부와 통장의 차액이 계산돼요.',
            key: Key('settlement_no_bank'),
            style: TextStyle(fontSize: 12, color: AppTheme.textSub),
          ),
        ),
      ];
    }
    final at = data.bankSnapshotAt;
    return [
      _Row('통장 잔액${at == null ? '' : ' (${Fmt.dateTime(at.millisecondsSinceEpoch ~/ 1000)})'}', Fmt.won(bank)),
      if (gap == 0)
        const _Row('차액', '일치', color: AppTheme.success, strong: true)
      else ...[
        _Row('차액', Fmt.won(gap.abs()), color: AppTheme.expense, strong: true),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${balanceGapMeaning(gap)} 계좌 대조에서 확인해 주세요.',
            key: const Key('settlement_gap_note'),
            style: const TextStyle(fontSize: 12, color: AppTheme.expense),
          ),
        ),
      ],
    ];
  }
}

// ───────────────────────────────────────── 예산 집행

class _BudgetCard extends StatelessWidget {
  final List<BudgetExecution> budgets;
  const _BudgetCard(this.budgets);

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: '예산 집행',
      cardKey: const Key('settlement_budgets'),
      child: budgets.isEmpty
          ? const Text('체인에 발행된 예산이 없어요.', style: TextStyle(color: AppTheme.textSub))
          : Column(children: [for (final b in budgets) _budget(b)]),
    );
  }

  Widget _budget(BudgetExecution b) {
    final rate = b.executionRate;
    return Padding(
      key: Key('settlement_budget_${b.budgetId}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(b.category, style: const TextStyle(fontWeight: FontWeight.w600))),
              Text(rate == null ? '편성액 0' : _percent(rate),
                  style: TextStyle(fontWeight: FontWeight.w700, color: (rate ?? 0) > 1 ? AppTheme.expense : AppTheme.primary)),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (rate ?? 0).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: AppTheme.primaryLight,
              color: (rate ?? 0) > 1 ? AppTheme.expense : AppTheme.primary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '집행 ${Fmt.won(b.spent)} / 편성 ${Fmt.won(b.plannedAmount)} · 남음 ${Fmt.won(b.remaining)}',
            style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
          ),
          if (b.revised)
            Text(
              '개정 v${b.version} · 최초 편성 ${Fmt.won(b.initialAmount)}',
              key: Key('settlement_budget_revised_${b.budgetId}'),
              style: const TextStyle(fontSize: 12, color: AppTheme.pending),
            ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────── 메타지표

class _MetricsCard extends StatelessWidget {
  final SettlementMetrics m;
  const _MetricsCard(this.m);

  @override
  Widget build(BuildContext context) {
    final reasons = m.correctionsByReason.entries.where((e) => e.value > 0).toList();
    final rate = m.revisionAfterBlockRate;
    return _Section(
      title: '메타지표',
      cardKey: const Key('settlement_metrics'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Row('OCR 경고 상태 승인', '${m.ocrWarningApproved}건', color: m.ocrWarningApproved > 0 ? AppTheme.pending : null),
          _Row('용도 불일치 경고 승인', '${m.categoryWarningApproved}건',
              color: m.categoryWarningApproved > 0 ? AppTheme.pending : null),
          const Divider(height: 20),
          _Row('정정', '${m.corrections}건'),
          if (reasons.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                reasons.map((e) => '${correctionReasonLabel(e.key)} ${e.value}').join(' · '),
                key: const Key('settlement_reasons'),
                style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
            ),
          _Row(
            '감사 D-30 이내 정정 (감사일 ${Fmt.date(m.auditAt.millisecondsSinceEpoch ~/ 1000)})',
            '${m.correctionsBeforeAudit}건',
            color: m.correctionsBeforeAudit > 0 ? AppTheme.pending : null,
          ),
          const Divider(height: 20),
          _Row(
            '예산 개정',
            m.budgetRevisions == 0
                ? '0회'
                : '${m.budgetRevisions}회, 그중 초과 집행 이후 ${m.budgetRevisionsAfterBlock}회'
                    '${rate == null ? '' : ' (${_percent(rate)})'}',
            color: m.budgetRevisionsAfterBlock > 0 ? AppTheme.pending : null,
          ),
          const Divider(height: 20),
          const _Row('이의 제기 / 미답변', '이번 범위 밖', color: AppTheme.textSub),
        ],
      ),
    );
  }
}
