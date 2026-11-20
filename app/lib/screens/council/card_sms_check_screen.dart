import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/format.dart';
import '../../models/bank_reconcile_model.dart';
import '../../services/api_service.dart';
import '../../services/bank_reconcile_service.dart';

/// 카드 승인 문자 대조 (PRD §4.6, 데모 7번) — 총무만.
///
/// 카드사 승인 문자를 여러 건 한꺼번에 붙여 넣으면 서버가 한 건씩 읽어 원장과 맞춰 본다.
/// - 카드로 결제됐는데 장부에 없는 건(**미등록 의심**)을 먼저 보인다.
/// - 서버는 문자를 **저장하지 않는다**. 이 화면을 닫으면 결과도 사라진다.
/// - 대조 중에는 버튼을 잠가 두 번 보내지 않는다.
class CardSmsCheckScreen extends StatefulWidget {
  final int termId;
  final BankReconcileService? service;

  const CardSmsCheckScreen({super.key, required this.termId, this.service});

  @override
  State<CardSmsCheckScreen> createState() => _CardSmsCheckScreenState();
}

class _CardSmsCheckScreenState extends State<CardSmsCheckScreen> {
  late final BankReconcileService _service = widget.service ?? BankReconcileService();
  final _text = TextEditingController();

  CardSmsCheckResult? _result;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (_busy) return;
    // await 전에 같은 동기 구간에서 잠근다 — 두 번째 탭이 이 검사를 통과하지 못하게
    setState(() => _busy = true);
    try {
      final result = await _service.checkCardSms(termId: widget.termId, text: _text.text);
      if (!mounted) return;
      setState(() => _result = result);
    } on BankActionFailed catch (e) {
      _toast(e.message);
    } on ApiUnavailable catch (e) {
      // 401·403
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
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
    final result = _result;
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(title: const Text('카드 승인 문자 대조')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _input(),
          if (result != null) ...[
            const SizedBox(height: 12),
            _summary(result),
            const SizedBox(height: 12),
            for (final item in _ordered(result.items)) _ItemTile(item: item),
          ],
        ],
      ),
    );
  }

  Widget _input() {
    return Card(
      color: AppTheme.bgCard,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '카드사(NH·KB) 승인 문자를 여러 건 한꺼번에 붙여 넣어 주세요.\n'
              '문자는 서버에 저장하지 않고, 장부와 맞는지 검사하는 데만 써요.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSub),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('card_sms_text'),
              controller: _text,
              enabled: !_busy,
              minLines: 6,
              maxLines: 12,
              maxLength: BankReconcileService.maxSmsChars,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                hintText: '[Web발신]\nKB국민카드 승인 …',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('card_sms_check'),
              onPressed: _busy ? null : _check,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.fact_check_rounded),
              label: Text(_busy ? '대조하는 중…' : '대조하기'),
            ),
          ],
        ),
      ),
    );
  }

  /// 요약 한 줄. **미등록 0건이 곧 「모두 맞음」은 아니다** — 못 읽었거나 학기 밖이라 대조하지 못한 문자가
  /// 있으면 그 사실을 먼저 말한다. 전부 못 읽었는데 녹색 「맞아요」가 뜨면 안 된다 (#135 리뷰).
  Widget _summary(CardSmsCheckResult result) {
    final s = result.summary;
    final outOfTerm = result.items.where((i) => i.status == CardSmsStatus.outOfTerm).length;
    final notChecked = s.unreadable + outOfTerm;
    final checked = s.matched + s.matchedPending;
    final (String title, Color color) = switch (()) {
      _ when s.unregistered > 0 => ('장부에 없는 카드 사용 ${s.unregistered}건', AppTheme.expense),
      _ when checked == 0 => ('장부와 대조한 문자가 없어요', AppTheme.pending),
      _ when notChecked > 0 => ('읽은 문자는 장부와 맞아요 · $notChecked건은 대조하지 못했어요', AppTheme.pending),
      _ => ('모든 카드 사용이 장부와 맞아요', AppTheme.success),
    };
    return Card(
      key: const Key('card_sms_summary'),
      color: AppTheme.bgCard,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: color)),
            if (s.unregisteredAmount > 0) ...[
              const SizedBox(height: 4),
              Text('미등록 승인 합계 ${Fmt.won(s.unregisteredAmount)}',
                  style: const TextStyle(fontSize: 13, color: AppTheme.expense)),
            ],
            const SizedBox(height: 8),
            Text(
              '문자 ${s.total}건 · 맞음 ${s.matched} · 승인 대기와 맞음 ${s.matchedPending}'
              '${s.unreadable > 0 ? ' · 읽지 못함 ${s.unreadable}' : ''}'
              '${outOfTerm > 0 ? ' · 학기 밖 $outOfTerm' : ''}',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
            ),
          ],
        ),
      ),
    );
  }


  /// 확인이 필요한 것부터: 미등록 → 읽지 못함 → 승인 대기 → 나머지. 같은 상태 안에서는 붙여 넣은 순서.
  static List<CardSmsItem> _ordered(List<CardSmsItem> items) {
    const rank = {
      CardSmsStatus.unregistered: 0,
      CardSmsStatus.unreadable: 1,
      CardSmsStatus.matchedPending: 2,
      CardSmsStatus.matched: 3,
      CardSmsStatus.outOfTerm: 4,
      CardSmsStatus.cancelledPair: 5,
    };
    final out = [...items];
    out.sort((a, b) {
      final r = rank[a.status]!.compareTo(rank[b.status]!);
      return r != 0 ? r : a.msgNo.compareTo(b.msgNo);
    });
    return out;
  }
}

class _ItemTile extends StatelessWidget {
  final CardSmsItem item;
  const _ItemTile({required this.item});

  Color get _color => switch (item.status) {
        CardSmsStatus.unregistered => AppTheme.expense,
        CardSmsStatus.unreadable => AppTheme.pending,
        CardSmsStatus.matchedPending => AppTheme.info,
        CardSmsStatus.matched => AppTheme.success,
        CardSmsStatus.outOfTerm || CardSmsStatus.cancelledPair => AppTheme.textSub,
      };

  @override
  Widget build(BuildContext context) {
    final amount = item.amount;
    final title = item.status == CardSmsStatus.unreadable
        ? '${item.msgNo}번째 문자'
        : '${item.merchant ?? '가맹점 없음'}${item.isCancel ? ' (취소)' : ''}';
    final sub = item.status == CardSmsStatus.unreadable
        ? (item.reason ?? '형식을 알 수 없어요')
        : [
            if (item.company != null) item.company!,
            if (item.tranDate != null) item.tranDate!,
            if (item.tranTime case final t?) t.length >= 5 ? t.substring(0, 5) : t,
            if (item.entryId != null) '장부 #${item.entryId}',
          ].join(' · ');
    return Card(
      key: Key('card_sms_item_${item.msgNo}'),
      color: AppTheme.bgCard,
      child: ListTile(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (amount != null)
              Text('${item.isCancel ? '+' : '-'}${Fmt.won(amount)}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(item.status.label, style: TextStyle(fontSize: 12, color: _color)),
          ],
        ),
      ),
    );
  }
}
