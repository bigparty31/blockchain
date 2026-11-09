import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/format.dart';
import '../../models/bank_reconcile_model.dart';
import '../../services/api_service.dart';
import '../../services/bank_reconcile_service.dart';

/// CSV 파일을 골라 **원본 바이트**를 돌려준다. 고르지 않고 닫으면 null.
typedef CsvPicker = Future<List<int>?> Function();

/// 기기 파일 선택기로 CSV 를 고른다. 해시는 바이트 그대로 계산하므로 내용을 손대지 않는다.
Future<List<int>?> pickCsvFile() async {
  final picked = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['csv'],
    withData: true, // 경로 대신 바이트 — 안드로이드 콘텐츠 URI 도 같은 방식으로 읽힌다
  );
  if (picked == null || picked.files.isEmpty) return null;
  final bytes = picked.files.single.bytes;
  if (bytes == null) throw const BankActionFailed('고른 파일을 읽지 못했어요. 다시 골라 주세요.');
  return bytes;
}

/// 계좌 대조 (A9, PRD §4.6) — 임원 모두 조회, 총무만 업로드·재대조.
///
/// 은행 거래내역 CSV 를 원장과 1:1 로 맞춘 결과를 보여 준다.
/// - **미등록 거래** (계좌에는 있는데 원장에 없음)와 **대응 거래 없는 원장** (가짜 등록 의심)을 먼저 보인다.
/// - 승인 대기 항목과의 짝은 판단 보류라 따로 묶는다.
/// - 이전에 올린 파일(`superseded`)은 거래 줄만 보인다 — 대조 결과는 최신 파일에서 본다.
///
/// 읽지 못하면 결과 대신 오류와 「다시 시도」. 미등록 0건이 가짜로 보이면 안 된다.
class BankReconcileScreen extends StatefulWidget {
  /// 총무면 true — 업로드·재대조 버튼을 보인다. 서버도 총무만 받는다.
  final bool canUpload;

  final BankReconcileService? service;

  /// 테스트에서 가짜 파일을 넣는다.
  final CsvPicker picker;

  const BankReconcileScreen({super.key, required this.canUpload, this.service, this.picker = pickCsvFile});

  @override
  State<BankReconcileScreen> createState() => _BankReconcileScreenState();
}

class _BankReconcileScreenState extends State<BankReconcileScreen> {
  late final BankReconcileService _service = widget.service ?? BankReconcileService();

  int? _termId;
  List<BankSnapshotItem> _snapshots = const [];
  BankReconcileReport? _report;
  String? _error;
  bool _loading = true;

  /// 업로드·재대조 중. 두 번 누르기를 막는다.
  bool _busy = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 목록을 읽고 [showId] (없으면 최신) 스냅샷의 결과를 연다.
  Future<void> _load({int? showId}) async {
    final seq = ++_seq; // 겹친 읽기는 마지막 것만 반영한다
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final termId = _termId ?? await _service.termId();
      final list = await _service.snapshots(termId);
      final id = showId ?? _latest(list)?.id;
      final report = id == null ? null : await _service.report(id);
      if (!mounted || seq != _seq) return;
      setState(() {
        _termId = termId;
        _snapshots = list;
        _report = report;
        _loading = false;
      });
    } on ApiUnavailable catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _snapshots = const [];
        _report = null; // 지난 결과를 남기지 않는다
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// 대조 결과를 볼 스냅샷 — 대체되지 않은 최신 것. 목록은 최신순이다.
  static BankSnapshotItem? _latest(List<BankSnapshotItem> list) {
    for (final s in list) {
      if (!s.superseded) return s;
    }
    return list.isEmpty ? null : list.first;
  }

  Future<void> _upload() async {
    final termId = _termId;
    if (_busy || termId == null) return;
    final List<int>? bytes;
    try {
      bytes = await widget.picker();
    } on BankActionFailed catch (e) {
      _toast(e.message);
      return;
    }
    if (bytes == null || !mounted) return;
    final file = bytes;
    await _write(() => _service.upload(termId: termId, bytes: file), '대조했어요.');
  }

  Future<void> _rematch(int snapshotId) =>
      _write(() => _service.rematch(snapshotId), '다시 대조했어요.');

  /// 쓰기 공통 — 성공하면 그 결과를 보이고 목록을 새로 읽는다. 실패는 문구를 띄우고 필요하면 다시 읽는다.
  Future<void> _write(Future<BankReconcileReport> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      final report = await action();
      if (!mounted) return;
      _toast(done);
      setState(() => _busy = false);
      await _load(showId: report.snapshotId);
    } on BankActionFailed catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast(e.message);
      if (e.reload) await _load();
    } on ApiUnavailable catch (e) {
      // 401·403
      if (!mounted) return;
      setState(() => _busy = false);
      _toast(e.message);
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(title: const Text('계좌 대조')),
      body: RefreshIndicator(onRefresh: () => _load(showId: _report?.snapshotId), child: _body()),
    );
  }

  Widget _body() {
    if (_loading && _report == null && _error == null && _snapshots.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        key: const Key('bank_error'),
        padding: const EdgeInsets.all(32),
        children: [
          const SizedBox(height: 80),
          const Icon(Icons.cloud_off_rounded, size: 48, color: AppTheme.textSub),
          const SizedBox(height: 12),
          Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textSub)),
          Center(child: TextButton(onPressed: _load, child: const Text('다시 시도'))),
        ],
      );
    }
    final report = _report;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (widget.canUpload) ...[_uploadCard(), const SizedBox(height: 12)],
        if (report == null)
          const Padding(
            key: Key('bank_empty'),
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Text(
              '아직 올린 거래내역이 없어요.\n총무가 은행에서 받은 거래내역 CSV 를 올리면 장부와 맞춰 볼 수 있어요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSub),
            ),
          )
        else ...[
          if (report.superseded) ...[_supersededNotice(), const SizedBox(height: 12)],
          _SummaryCard(
            report: report,
            onRematch: widget.canUpload && !report.superseded && !_busy ? () => _rematch(report.snapshotId) : null,
          ),
          ..._sections(report),
        ],
        if (_snapshots.isNotEmpty) ...[const SizedBox(height: 12), _history(report?.snapshotId)],
      ],
    );
  }

  Widget _uploadCard() {
    return _Section(
      title: '거래내역 올리기',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '은행 앱·인터넷뱅킹에서 받은 거래내역 CSV 를 그대로 올려 주세요 (NH·KB, 2MB 까지).\n'
            '장부에 자동으로 넣지 않아요. 장부와 맞는지 검사하는 데만 써요.',
            style: TextStyle(fontSize: 12, color: AppTheme.textSub),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('bank_upload'),
            onPressed: _busy || _termId == null ? null : _upload,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.upload_file_rounded),
            label: Text(_busy ? '대조하는 중…' : 'CSV 파일 고르기'),
          ),
        ],
      ),
    );
  }

  Widget _supersededNotice() {
    return Container(
      key: const Key('bank_superseded'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppTheme.primaryLight, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              '더 최근에 올린 파일이 있어요. 이 파일은 거래 줄만 보이고, 대조 결과는 최신 파일에서 봐요.',
              style: TextStyle(fontSize: 13, color: AppTheme.textMain),
            ),
          ),
          TextButton(onPressed: () => _load(), child: const Text('최신 보기')),
        ],
      ),
    );
  }

  List<Widget> _sections(BankReconcileReport report) {
    if (report.summary == null) {
      return [
        const SizedBox(height: 12),
        _Section(
          title: '거래 ${report.transactions.length}건',
          child: Column(children: [for (final t in report.transactions) _TransactionTile(t)]),
        ),
      ];
    }
    final unregistered = report.rows(BankRowStatus.unregistered);
    final pending = report.rows(BankRowStatus.matchedPending);
    final matched = report.rows(BankRowStatus.matched);
    return [
      if (unregistered.isNotEmpty) ...[
        const SizedBox(height: 12),
        _Section(
          title: '장부에 없는 거래 ${unregistered.length}건',
          cardKey: const Key('bank_unregistered'),
          subtitle: '계좌에는 있는데 장부에 없어요. 등록이 빠졌는지 확인해 주세요. 등록·승인 뒤 「재대조」를 누르면 다시 맞춰요.',
          child: Column(children: [for (final t in unregistered) _TransactionTile(t, alert: true)]),
        ),
      ],
      if (report.unbackedEntries.isNotEmpty) ...[
        const SizedBox(height: 12),
        _Section(
          title: '통장에 없는 장부 항목 ${report.unbackedEntries.length}건',
          cardKey: const Key('bank_unbacked'),
          subtitle: '장부에는 확정돼 있는데 이 기간 거래내역에 대응하는 거래가 없어요.',
          child: Column(children: [for (final e in report.unbackedEntries) _UnbackedTile(e)]),
        ),
      ],
      if (pending.isNotEmpty) ...[
        const SizedBox(height: 12),
        _Section(
          title: '승인 대기 항목과 짝 ${pending.length}건',
          cardKey: const Key('bank_pending'),
          subtitle: '아직 승인 전인 항목과 맞았어요. 승인되면 확정 짝이 돼요.',
          child: Column(children: [for (final t in pending) _TransactionTile(t)]),
        ),
      ],
      if (matched.isNotEmpty) ...[
        const SizedBox(height: 12),
        Card(
          key: const Key('bank_matched'),
          color: AppTheme.bgCard,
          child: ExpansionTile(
            title: Text('장부와 맞은 거래 ${matched.length}건', style: const TextStyle(fontWeight: FontWeight.w700)),
            children: [for (final t in matched) _TransactionTile(t)],
          ),
        ),
      ],
    ];
  }

  Widget _history(int? current) {
    return Card(
      key: const Key('bank_history'),
      color: AppTheme.bgCard,
      child: ExpansionTile(
        title: Text('올린 기록 ${_snapshots.length}건', style: const TextStyle(fontWeight: FontWeight.w700)),
        children: [
          for (final s in _snapshots)
            ListTile(
              key: Key('bank_snapshot_${s.id}'),
              dense: true,
              selected: s.id == current,
              title: Text(Fmt.dateTime(s.snapshotAt.millisecondsSinceEpoch ~/ 1000)),
              subtitle: Text('잔액 ${Fmt.won(s.bankBalance)}${s.superseded ? ' · 이전 파일' : ' · 최신'}'),
              trailing: s.id == current ? const Icon(Icons.visibility_rounded, size: 18) : null,
              onTap: s.id == current ? null : () => _load(showId: s.id),
            ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────── 카드·줄

class _Section extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final Key? cardKey;
  const _Section({required this.title, required this.child, this.subtitle, this.cardKey});

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
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!, style: const TextStyle(fontSize: 12, color: AppTheme.textSub)),
            ],
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final BankReconcileReport report;
  final VoidCallback? onRematch;
  const _SummaryCard({required this.report, required this.onRematch});

  @override
  Widget build(BuildContext context) {
    final s = report.summary;
    return _Section(
      title: '대조 요약',
      cardKey: const Key('bank_summary'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('거래 기간', '${report.periodStart} ~ ${report.periodEnd}'),
          _row('통장 잔액', Fmt.won(report.bankBalance)),
          _row('올린 시각', Fmt.dateTime(report.snapshotAt.millisecondsSinceEpoch ~/ 1000)),
          if (s != null) ...[
            const Divider(height: 20),
            if (s.clean)
              const Text('장부와 계좌가 맞아요',
                  key: Key('bank_clean'),
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.success))
            else ...[
              if (s.unregisteredOutAmount > 0)
                _row('장부에 없이 나간 돈', Fmt.won(s.unregisteredOutAmount), color: AppTheme.expense, strong: true),
              if (s.unregisteredInAmount > 0)
                _row('장부에 없이 들어온 돈', Fmt.won(s.unregisteredInAmount), color: AppTheme.expense, strong: true),
              if (s.unbacked > 0) _row('통장에 없는 장부 항목', '${s.unbacked}건', color: AppTheme.expense, strong: true),
            ],
            const SizedBox(height: 8),
            Text(
              '전체 ${s.total}건 · 맞음 ${s.matched} · 승인 대기와 짝 ${s.matchedPending} · 장부에 없음 ${s.unregistered}',
              key: const Key('bank_counts'),
              style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
            ),
          ],
          if (onRematch != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                key: const Key('bank_rematch'),
                onPressed: onRematch,
                icon: const Icon(Icons.sync_rounded, size: 18),
                label: const Text('재대조'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static Widget _row(String label, String value, {Color? color, bool strong = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(color: AppTheme.textSub))),
          Text(value,
              style: TextStyle(
                color: color ?? AppTheme.textMain,
                fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
              )),
        ],
      ),
    );
  }
}

class _TransactionTile extends StatelessWidget {
  final BankTransaction t;
  final bool alert;
  const _TransactionTile(this.t, {this.alert = false});

  @override
  Widget build(BuildContext context) {
    final time = t.tranTime == null ? '' : ' ${t.tranTime!.length >= 5 ? t.tranTime!.substring(0, 5) : t.tranTime}';
    final amountColor = t.outgoing ? AppTheme.expense : AppTheme.income;
    return ListTile(
      key: Key('bank_tran_${t.id}'),
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        t.outgoing ? Icons.north_east_rounded : Icons.south_west_rounded,
        color: alert ? AppTheme.expense : amountColor,
      ),
      title: Text(t.description, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${t.tranDate}$time · 잔액 ${Fmt.won(t.balanceAfter)}${t.entryId == null ? '' : ' · 장부 #${t.entryId}'}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Text(
        '${t.outgoing ? '−' : '+'}${Fmt.won(t.amount)}',
        style: TextStyle(fontWeight: FontWeight.w700, color: amountColor),
      ),
    );
  }
}

class _UnbackedTile extends StatelessWidget {
  final UnbackedEntry e;
  const _UnbackedTile(this.e);

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: Key('bank_unbacked_${e.entryId}'),
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.help_outline_rounded, color: AppTheme.expense),
      title: Text('${e.counterparty} · ${e.purpose}', maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text('${e.date} · 장부 #${e.entryId} · ${e.expense ? '지출' : '수입'}', style: const TextStyle(fontSize: 12)),
      trailing: Text(
        '${e.expense ? '−' : '+'}${Fmt.won(e.amount)}',
        style: TextStyle(fontWeight: FontWeight.w700, color: e.expense ? AppTheme.expense : AppTheme.income),
      ),
    );
  }
}
