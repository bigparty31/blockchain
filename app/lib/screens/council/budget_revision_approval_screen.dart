import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/enums.dart';
import '../../core/format.dart';
import '../../models/budget_revision_model.dart';
import '../../services/api_service.dart';
import '../../services/budget_revision_decision_service.dart';
import 'reason_dialog.dart';

/// 예산 증액 승인 화면 (A7) — 회장은 요청 서명, 감사는 승인 서명. 반려는 둘 다.
///
/// 한 화면이 [role] 로 단계를 고른다.
/// - 회장: `PENDING` 목록 → 「서명」 → `IncreaseRequest` 서명 → `PRESIDENT_SIGNED`
/// - 감사: `PRESIDENT_SIGNED` 목록 → 「승인 서명」 → 체인 증액 → `APPROVED`
///
/// 역할은 라우터가 로그인 세션에서 넣는다 (`AppRoutes.councilBudgetRevisions`). 인자로 받은 역할을 믿지 않는다.
class BudgetRevisionApprovalScreen extends StatefulWidget {
  final UserRole role;

  /// 테스트에서 가짜 서명·가짜 HTTP 를 넣는다.
  final BudgetRevisionDecisionService? service;

  const BudgetRevisionApprovalScreen({super.key, required this.role, this.service});

  @override
  State<BudgetRevisionApprovalScreen> createState() => _BudgetRevisionApprovalScreenState();
}

class _BudgetRevisionApprovalScreenState extends State<BudgetRevisionApprovalScreen> {
  late final BudgetRevisionDecisionService _service = widget.service ?? BudgetRevisionDecisionService();

  List<BudgetRevisionModel>? _items;
  String? _loadError;
  bool _loading = true;

  /// 처리 중인 요청 id. 서명 중에 같은 건을 두 번 누르지 못하게 한다.
  int? _busyId;

  bool get _isPresident => widget.role == UserRole.PRESIDENT;
  BudgetRevisionStatus get _stage =>
      _isPresident ? BudgetRevisionStatus.PENDING : BudgetRevisionStatus.PRESIDENT_SIGNED;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 겹친 읽기는 마지막 응답만 반영한다.
  int _loadSeq = 0;

  Future<void> _load() async {
    final seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final items = await _service.list(_stage);
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } on ApiUnavailable catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _items = null; // 지난 목록을 남기지 않는다 — 오래된 건에 서명하지 않게
        _loadError = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _sign(BudgetRevisionModel rev) async {
    if (!await _confirmSign(rev) || !mounted) return;
    await _run(rev, () => _isPresident ? _service.presidentSign(rev) : _service.auditorApprove(rev),
        done: _isPresident ? '서명했어요. 감사의 승인을 기다립니다.' : '승인했어요. 예산이 증액됐습니다.');
  }

  Future<void> _reject(BudgetRevisionModel rev) async {
    final reason = await showReasonDialog(
      context,
      title: '증액 요청 반려',
      description: '${rev.category} +${Fmt.won(rev.requestedAmount)} 요청을 반려합니다. 사유는 총무에게 전달돼요.',
      confirmLabel: '반려',
    );
    if (reason == null || !mounted) return;
    await _run(rev, () => _service.reject(rev, reason), done: '반려했어요.');
  }

  Future<void> _run(BudgetRevisionModel rev, Future<BudgetRevisionModel> Function() action, {required String done}) async {
    setState(() => _busyId = rev.id);
    try {
      await action();
      // 처리 중에 화면을 나갔으면 다시 읽지 않는다 — [_load] 가 바로 setState 를 부른다
      if (!mounted) return;
      _snack(done, AppTheme.success);
      await _load();
    } on RevisionDecisionException catch (e) {
      if (!mounted) return;
      _snack(e.message, AppTheme.expense);
      switch (e.failure) {
        // 화면 상태가 서버와 어긋났거나 결과를 모른다 → 새로 읽는다
        case RevisionDecisionFailure.changed:
        case RevisionDecisionFailure.expired:
        case RevisionDecisionFailure.conflict:
        case RevisionDecisionFailure.refused:
        case RevisionDecisionFailure.notFound:
        case RevisionDecisionFailure.unknownOutcome:
          await _load();
        // 로그인 화면 이동은 AuthService 가 한다. 나머지는 목록을 그대로 둔다
        case RevisionDecisionFailure.unauthorized:
        case RevisionDecisionFailure.forbidden:
        case RevisionDecisionFailure.invalidReason:
        case RevisionDecisionFailure.notReady:
        case RevisionDecisionFailure.signing:
          break;
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  /// 서명할 내용을 한 번 더 보여 준다. 금액은 **증액분**이다.
  Future<bool> _confirmSign(BudgetRevisionModel rev) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('revision_sign_confirm'),
        title: Text(_isPresident ? '증액 요청에 서명할까요?' : '증액을 승인할까요?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv('예산', '${rev.category} (#${rev.budgetId})'),
            _kv('증액분', '+${Fmt.won(rev.requestedAmount)}'),
            _kv('사유', rev.reason),
            if (!_isPresident && rev.signatureDeadline != null) _kv('서명 시한', Fmt.dateTime(rev.signatureDeadline!)),
            const SizedBox(height: 8),
            Text(
              _isPresident
                  ? '서명은 ${BudgetRevisionDecisionService.presidentTtl.inHours}시간 동안 유효해요. 그 안에 감사가 승인해야 합니다.'
                  : '승인하면 체인의 예산이 바로 증액돼요. 되돌릴 수 없습니다.',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(
            key: const Key('revision_sign_confirm_ok'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_isPresident ? '서명' : '승인 서명'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _snack(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), backgroundColor: color));
  }

  static Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 64, child: Text(k, style: const TextStyle(color: AppTheme.textSub))),
            Expanded(child: Text(v)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(title: Text(_isPresident ? '예산 증액 서명' : '예산 증액 승인')),
      body: RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    if (_loading && _items == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = _items;
    if (items == null) {
      return _scrollableMessage(
        key: const Key('revision_load_error'),
        icon: Icons.cloud_off_rounded,
        text: _loadError ?? '예산 증액 요청을 불러오지 못했어요.',
        action: TextButton(onPressed: _load, child: const Text('다시 시도')),
      );
    }
    if (items.isEmpty) {
      return _scrollableMessage(
        key: const Key('revision_empty'),
        icon: Icons.inbox_rounded,
        text: _isPresident ? '서명을 기다리는 증액 요청이 없어요.' : '승인을 기다리는 증액 요청이 없어요.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) => _card(items[i]),
    );
  }

  /// 당겨서 새로 고칠 수 있게 메시지도 스크롤 안에 둔다.
  Widget _scrollableMessage({required Key key, required IconData icon, required String text, Widget? action}) {
    return ListView(
      key: key,
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 80),
        Icon(icon, size: 48, color: AppTheme.textSub),
        const SizedBox(height: 12),
        Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textSub)),
        if (action != null) Center(child: action),
      ],
    );
  }

  Widget _card(BudgetRevisionModel rev) {
    final busy = _busyId == rev.id;
    final anyBusy = _busyId != null;
    return Card(
      key: Key('revision_${rev.id}'),
      color: AppTheme.bgCard,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(rev.category,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textMain)),
                ),
                Text('+${Fmt.won(rev.requestedAmount)}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.primary)),
              ],
            ),
            const SizedBox(height: 8),
            Text(rev.reason, style: const TextStyle(color: AppTheme.textMain)),
            const SizedBox(height: 8),
            Text(
              [
                '요청 ${Fmt.dateTime(rev.requestedAt.millisecondsSinceEpoch ~/ 1000)}',
                if (rev.blockedEntryId != null) '차단 지출 #${rev.blockedEntryId}',
                if (!_isPresident && rev.signatureDeadline != null) '서명 시한 ${Fmt.dateTime(rev.signatureDeadline!)}',
              ].join(' · '),
              style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  key: Key('revision_reject_${rev.id}'),
                  onPressed: anyBusy ? null : () => _reject(rev),
                  child: const Text('반려'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: Key('revision_sign_${rev.id}'),
                  onPressed: anyBusy ? null : () => _sign(rev),
                  child: busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_isPresident ? '서명' : '승인 서명'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
