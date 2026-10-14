import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/app_theme.dart';
import '../../core/budget_plan.dart';
import '../../core/enums.dart';
import '../../core/format.dart';
import '../../core/term_info.dart';
import '../../services/budget_issuer.dart';
import 'budget_plan_controller.dart';

/// [문승준 담당: app/lib/screens/president/]
/// 15. 예산 편성 — 회장 전용 (스토리보드 15번)
///
/// 학기 초에 회장이 항목별 예산을 편성하고 확정하면 온체인에 예산 토큰이 발행된다.
/// **예산이 없으면 모든 지출 등록이 `BUDGET_NOT_FOUND` 로 차단된다** — 데모는 여기서 시작한다.
///
/// 상태·규칙은 [BudgetPlanController] 와 `core/budget_plan.dart` 에 있고, 이 파일은 그리기만 한다.
class BudgetPlanScreen extends StatefulWidget {
  const BudgetPlanScreen({
    super.key,
    required this.role,
    this.issuer,
    this.termId = 1,
    this.onConnectWallet,
    this.clock,
  });

  /// 로그인한 역할. **회장이 아니면 편성 화면 대신 안내만 보여준다.**
  /// 감사 계정에는 이 화면으로 들어가는 메뉴 자체를 보이지 않는 게 원칙이고(스토리보드 15),
  /// 이 검사는 접근 제어가 뚫렸을 때를 위한 마지막 방어선이다.
  final UserRole role;

  /// 예산 발행기. 비우면 [FakeBudgetIssuer] 를 쓴다 — 실제 발행은 아직 연결 전이다
  /// (`services/budget_issuer.dart` 설명 참고).
  final BudgetIssuer? issuer;

  /// 편성할 학기. 서버에 학기 조회 API 가 생기면 그 값을 받는다 (`core/term_info.dart`).
  final int termId;

  /// 「지갑 연결하기」를 눌렀을 때. 지갑 모듈이 없어서 비우면 준비 중이라고 알려준다.
  final VoidCallback? onConnectWallet;

  /// 현재 시각. 마감일이 지났는지 비교할 때 쓰며, 테스트에서 고정한다.
  final DateTime Function()? clock;

  @override
  State<BudgetPlanScreen> createState() => _BudgetPlanScreenState();
}

class _BudgetPlanScreenState extends State<BudgetPlanScreen> {
  late final BudgetIssuer _issuer;
  late final BudgetPlanController _c;

  // 줄마다 편성액 입력란의 컨트롤러가 하나씩 필요하다. 줄 수와 항상 같게 유지한다
  // (_addLine / _removeLine 에서만 늘리고 줄인다).
  final List<TextEditingController> _amountCtrls = [];

  bool get _isPresident => widget.role == UserRole.PRESIDENT;

  /// 가짜 발행기를 쓰는 중인가 — 그러면 배너로 알려야 한다
  bool get _isDemoIssuer => _issuer is FakeBudgetIssuer;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _issuer = widget.issuer ?? FakeBudgetIssuer(delay: const Duration(milliseconds: 900));
    _c = BudgetPlanController(issuer: _issuer, termId: widget.termId, clock: _now);
  }

  @override
  void dispose() {
    _c.dispose();
    for (final ctrl in _amountCtrls) {
      ctrl.dispose();
    }
    super.dispose();
  }

  void _addLine() {
    final before = _c.lines.length;
    _c.addLine();
    if (_c.lines.length > before) _amountCtrls.add(TextEditingController());
  }

  void _removeLine(int index) {
    final before = _c.lines.length;
    _c.removeLine(index);
    if (_c.lines.length < before) _amountCtrls.removeAt(index).dispose();
  }

  Future<void> _pickExpiry(int index) async {
    final today = BudgetPlanRules.kstDate(_now());
    final first = DateTime(2026, 1, 1);
    final last = DateTime(2027, 12, 31);
    final fallback = DateTime(today.year, today.month, today.day).add(const Duration(days: 30));
    final initial = _c.lines[index].item.expiresOn ?? fallback;

    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(first) ? first : (initial.isAfter(last) ? last : initial),
      firstDate: first,
      lastDate: last,
    );
    if (picked != null && mounted) _c.setExpiresOn(index, picked);
  }

  Future<void> _confirmRemove(int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('이 항목을 삭제할까요?'),
        content: const Text('입력한 내용이 사라져요.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('삭제')),
        ],
      ),
    );
    if (ok == true && mounted) _removeLine(index);
  }

  /// 편성 확정 — 확인 팝업을 한 번 거친다. 발행하면 되돌릴 수 없어서다.
  Future<void> _onConfirmPressed() async {
    if (!_c.canConfirm) return;

    // 마감일이 이미 지난 항목은 막지 않고 여기서 한 번 더 알린다 (BudgetItemProblem.expiryInPast)
    final pastLabels = <String>[
      for (var i = 0; i < _c.lines.length; i++)
        if (!_c.lines[i].isIssued && _c.problemsOf(i).contains(BudgetItemProblem.expiryInPast))
          _c.lines[i].item.category!.label,
    ];

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('확정하면 수정할 수 없어요'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('온체인에 예산 토큰이 발행돼요. 확정한 항목은 고치거나 지울 수 없어요.'),
            if (pastLabels.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '마감일이 이미 지난 항목이 있어요: ${pastLabels.join(', ')}\n'
                '이 항목으로는 지출을 등록할 수 없어요.',
                style: const TextStyle(color: AppTheme.pending, fontWeight: FontWeight.bold),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('확정')),
        ],
      ),
    );
    if (ok == true && mounted) await _c.confirm();
  }

  void _connectWallet() {
    final callback = widget.onConnectWallet;
    if (callback != null) {
      callback();
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('지갑 연결 기능은 아직 준비 중이에요')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => PopScope(
        // 발행 중에는 화면을 나가지 못하게 한다 — 응답이 돌아올 곳이 사라진다
        canPop: _c.phase != BudgetPlanPhase.processing,
        child: Scaffold(
          backgroundColor: AppTheme.bgPage,
          appBar: AppTheme.gradientAppBar(title: '예산 편성'),
          body: _isPresident ? _buildBody() : const _NotPresidentNotice(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final readOnly = _c.phase == BudgetPlanPhase.issued;
    final processing = _c.phase == BudgetPlanPhase.processing;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        const _TermHeader(),
        if (_isDemoIssuer) ...[const SizedBox(height: 12), const _DemoIssueBanner()],
        ..._statusBanners(),
        const SizedBox(height: 16),
        if (_c.lines.isEmpty) const _EmptyHint(),
        for (var i = 0; i < _c.lines.length; i++) ...[
          _buildLineCard(i),
          const SizedBox(height: 12),
        ],
        if (!readOnly) ...[
          OutlinedButton.icon(
            onPressed: _c.canAddLine ? _addLine : null,
            icon: const Icon(Icons.add_rounded),
            label: const Text('항목 추가'),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _c.canConfirm ? _onConfirmPressed : null,
            icon: processing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.verified_rounded),
            label: Text(processing ? '처리 중...' : '편성 확정'),
          ),
        ],
      ],
    );
  }

  /// 지금 상태에 맞는 안내 배너들. 정상일 때 「이상 없음」 같은 걸 띄우지 않는다 —
  /// 늘 켜져 있으면 진짜 경고가 묻힌다.
  List<Widget> _statusBanners() {
    final banners = <Widget>[];

    void add(_InfoBanner banner) => banners.addAll([const SizedBox(height: 12), banner]);

    if (_c.phase == BudgetPlanPhase.processing) {
      add(const _InfoBanner(
        icon: Icons.hourglass_top_rounded,
        color: AppTheme.pending,
        title: '온체인에 기록하는 중이에요',
        body: '다시 누르지 마세요.',
      ));
    }

    if (_c.phase == BudgetPlanPhase.issued) {
      add(const _InfoBanner(
        icon: Icons.lock_rounded,
        color: AppTheme.success,
        title: '예산이 확정됐어요',
        body: '확정 후에는 수정할 수 없어요.',
      ));
    } else if (_c.phase == BudgetPlanPhase.editing && _c.lines.any((l) => l.isIssued)) {
      add(const _InfoBanner(
        icon: Icons.info_rounded,
        color: AppTheme.info,
        title: '일부만 발행됐어요',
        body: '발행된 항목은 잠겼어요. 나머지는 고쳐서 다시 확정할 수 있어요.',
      ));
    }

    if (_c.hasPendingResponse) {
      add(const _InfoBanner(
        icon: Icons.sync_problem_rounded,
        color: AppTheme.pending,
        title: '응답이 없는 항목이 있어요',
        body: '체인에 기록됐는지 아직 알 수 없어요. 확인되기 전에는 다시 보낼 수 없어요.',
      ));
    }

    switch (_c.blockedBy) {
      case BudgetIssueFailure.walletNotConnected:
        add(_InfoBanner(
          icon: Icons.account_balance_wallet_outlined,
          color: AppTheme.expense,
          title: '회장 지갑이 연결되지 않았어요',
          body: '지갑을 연결한 뒤 다시 확정해 주세요.',
          actionLabel: '지갑 연결하기',
          onAction: _connectWallet,
        ));
      case BudgetIssueFailure.notPresident:
        add(const _InfoBanner(
          icon: Icons.block_rounded,
          color: AppTheme.expense,
          title: '회장 계정이 아니라서 편성할 수 없어요',
        ));
      case null:
        break;
    }
    return banners;
  }

  Widget _buildLineCard(int i) {
    final line = _c.lines[i];
    final editable = _c.isEditable(i);

    // 「비어 있어요」 류는 카드마다 빨갛게 띄우지 않는다 — 확정 버튼이 회색인 것으로 충분하다.
    // 값을 넣은 뒤에 생기는 문제(한도 초과·중복·지난 마감일)만 알린다.
    final problems = _c.problemsOf(i).where((p) =>
        p != BudgetItemProblem.categoryMissing &&
        p != BudgetItemProblem.amountMissing &&
        p != BudgetItemProblem.expiryMissing);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.cardDecoration.copyWith(
        border: line.isIssued ? Border.all(color: AppTheme.success.withValues(alpha: 0.5), width: 1.5) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _categoryField(i, line, editable)),
              if (line.isIssued)
                const Padding(
                  padding: EdgeInsets.only(left: 8, top: 14),
                  child: Icon(Icons.lock_rounded, color: AppTheme.success),
                )
              else if (editable)
                IconButton(
                  tooltip: '항목 삭제',
                  onPressed: () => _confirmRemove(i),
                  icon: const Icon(Icons.close_rounded, color: AppTheme.expense),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _amountField(i, line, editable),
          const SizedBox(height: 12),
          _expiryField(i, line, editable),
          for (final p in problems) ...[
            const SizedBox(height: 8),
            Text(
              p.message,
              style: TextStyle(
                fontSize: 12,
                color: p.blocking ? AppTheme.expense : AppTheme.pending,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (line.state != BudgetLineState.draft) ...[
            const SizedBox(height: 8),
            _lineStatus(line),
          ],
        ],
      ),
    );
  }

  /// 세 입력 칸(카테고리·편성액·마감일)이 같은 잠금 모양을 쓰게 하는 공용 데코레이션.
  ///
  /// 잠긴 칸(`enabled: false`)의 기본 테두리는 훨씬 진해서 칸마다 모양이 달라 보인다.
  /// 공용 [AppTheme.inputDecoration] 은 다른 화면도 쓰는 파일이라 여기서만 덧씌운다.
  InputDecoration _fieldDecoration({
    required String label,
    String? hint,
    required IconData icon,
    required bool enabled,
  }) {
    return AppTheme.inputDecoration(label: label, hint: hint, icon: icon).copyWith(
      enabled: enabled,
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFFE0DEFF), width: 1.5),
      ),
    );
  }

  Widget _categoryField(int i, BudgetLine line, bool editable) {
    return InputDecorator(
      decoration: _fieldDecoration(label: '카테고리', icon: Icons.category_rounded, enabled: editable),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<BudgetCategory>(
          value: line.item.category,
          isExpanded: true,
          isDense: true,
          hint: const Text('카테고리 선택'),
          // 다른 줄이 이미 쓴 카테고리는 목록에서 뺀다 — 한 학기·한 항목에 예산은 하나뿐이다
          items: [
            for (final c in _c.availableCategories(i)) DropdownMenuItem(value: c, child: Text(c.label)),
          ],
          onChanged: editable ? (v) => _c.setCategory(i, v) : null,
        ),
      ),
    );
  }

  Widget _amountField(int i, BudgetLine line, bool editable) {
    final amount = line.item.amount;
    return TextField(
      controller: _amountCtrls[i],
      enabled: editable,
      keyboardType: TextInputType.number,
      // 원 단위 정수만 받는다. 16자리면 컨트랙트 한도(1e15)를 넘는 값까지 입력할 수 있어
      // 한도 초과는 규칙 검사가 알린다.
      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(16)],
      decoration: _fieldDecoration(
        label: '편성액 (원)',
        hint: '예: 2500000',
        icon: Icons.payments_rounded,
        enabled: editable,
      ).copyWith(helperText: amount != null && amount > 0 ? Fmt.won(amount) : null),
      onChanged: (text) => _c.setAmount(i, text.isEmpty ? null : int.tryParse(text)),
    );
  }

  Widget _expiryField(int i, BudgetLine line, bool editable) {
    final date = line.item.expiresOn;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: editable ? () => _pickExpiry(i) : null,
      child: InputDecorator(
        decoration: _fieldDecoration(label: '집행 마감일', icon: Icons.event_rounded, enabled: editable),
        child: Text(
          // 연·월·일 필드를 그대로 찍는다 — epoch 로 바꿨다가 기기 시간대로 되돌리면 날짜가 하루 밀릴 수 있다
          date == null ? '마감일 선택' : DateFormat('yyyy.MM.dd').format(date),
          style: TextStyle(color: date == null ? AppTheme.textSub : AppTheme.textMain),
        ),
      ),
    );
  }

  Widget _lineStatus(BudgetLine line) {
    switch (line.state) {
      case BudgetLineState.issued:
        return Text(
          line.message == null ? '발행됨' : '발행됨 · ${line.message}',
          style: const TextStyle(fontSize: 12, color: AppTheme.success, fontWeight: FontWeight.bold),
        );
      case BudgetLineState.rejected:
        return Text(
          '${line.message ?? '체인이 거부했어요'} · 고쳐서 다시 확정할 수 있어요',
          style: const TextStyle(fontSize: 12, color: AppTheme.expense, fontWeight: FontWeight.bold),
        );
      case BudgetLineState.noResponse:
        return const Text(
          '응답 없음 · 체인에 기록됐는지 확인 중',
          style: TextStyle(fontSize: 12, color: AppTheme.pending, fontWeight: FontWeight.bold),
        );
      case BudgetLineState.draft:
        return const SizedBox.shrink();
    }
  }
}

/// 학기 안내 머리말
class _TermHeader extends StatelessWidget {
  const _TermHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.gradientDecoration(AppTheme.primaryGradient),
      child: const Row(
        children: [
          Icon(Icons.account_balance_rounded, color: Colors.white, size: 28),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  TermInfo.currentTerm,
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 2),
                Text(
                  '항목별 예산을 편성하고 확정하면 온체인에 예산 토큰이 발행돼요',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text('항목을 추가하세요', style: TextStyle(color: AppTheme.textSub, fontSize: 14)),
      ),
    );
  }
}

class _NotPresidentNotice extends StatelessWidget {
  const _NotPresidentNotice();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block_rounded, size: 40, color: AppTheme.textSub),
            SizedBox(height: 12),
            Text('예산 편성은 학생회장만 할 수 있어요', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// 「가짜 발행」 배너.
///
/// 가짜 발행기를 쓰는 동안은 확정해도 **체인에 아무것도 기록되지 않는다**.
/// 조용히 넘어가면 발행된 줄 알고 지출 등록을 시도하다 `BUDGET_NOT_FOUND` 로 막힌다.
/// (학생 화면의 [DemoDataBanner] 와 같은 이유·같은 모양이다)
class _DemoIssueBanner extends StatelessWidget {
  const _DemoIssueBanner();

  @override
  Widget build(BuildContext context) {
    return const _InfoBanner(
      icon: Icons.science_outlined,
      color: AppTheme.pending,
      title: '가짜 발행입니다',
      body: '확정해도 체인에는 아무것도 기록되지 않아요. '
          '실제 발행은 서명 모듈과 서버 연동이 끝난 뒤 연결돼요.',
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({
    required this.icon,
    required this.color,
    required this.title,
    this.body,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
                if (body != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    body!,
                    style: TextStyle(fontSize: 11, color: AppTheme.textMain.withValues(alpha: 0.85), height: 1.4),
                  ),
                ],
                if (actionLabel != null) ...[
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
