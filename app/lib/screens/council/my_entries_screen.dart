import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/enums.dart';
import '../../core/format.dart';
import '../../models/budget_model.dart';
import '../../models/entry_model.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../../services/entry_registration_service.dart';
import 'budget_revision_screen.dart';
import 'correction_screen.dart';
import 'expense_create_screen.dart';
import 'income_create_screen.dart';

/// 내 등록 건의 단계. 초안·처리 중은 서버 상태값(`status`)이 아니라 등록 단계라서 따로 둔다.
enum MyEntryState {
  draft('초안', Color(0xFF64748B)),
  processing('처리 중', AppTheme.info),
  pending('대기', AppTheme.pending),
  confirmed('확정', AppTheme.success),
  rejected('반려', AppTheme.expense),
  blocked('차단', Color(0xFF6B7280));

  final String label;
  final Color color;
  const MyEntryState(this.label, this.color);
}

/// 서버 항목의 단계. 대기(`PENDING`)인데 `tx_confirm` 이 있으면 확정·반려가 체인에 나가는 중이다 (API §4).
MyEntryState myEntryStateOf(EntryModel e) => switch (e.status) {
      EntryStatus.PENDING => e.txConfirm != null ? MyEntryState.processing : MyEntryState.pending,
      EntryStatus.CONFIRMED => MyEntryState.confirmed,
      EntryStatus.REJECTED => MyEntryState.rejected,
      EntryStatus.BLOCKED => MyEntryState.blocked,
    };

class MyEntryItem {
  final int id;
  final String title;
  final String category;
  final int amount;
  final String date;
  final bool isIncome;
  final MyEntryState state;

  /// 반려 사유 또는 차단 사유.
  final String? note;

  /// 서버에서 읽은 항목 (서버 목록일 때만). 다시 등록·정정·개정 요청에 넘긴다.
  final EntryModel? entry;

  const MyEntryItem({
    required this.id,
    required this.title,
    required this.category,
    required this.amount,
    required this.date,
    required this.state,
    this.isIncome = false,
    this.note,
    this.entry,
  });

  bool get isCorrection => entry?.correctsEntryId != null;

  /// 서버 항목 → 카드. 예산 이름은 [budgets] 에서 찾고, 없으면 번호로 적는다.
  factory MyEntryItem.fromEntry(EntryModel e, List<BudgetModel> budgets) {
    final income = e.kind == EntryKind.INCOME;
    String category = '수입';
    if (!income) {
      category = '예산 #${e.budgetId ?? '-'}';
      for (final b in budgets) {
        if (b.id == e.budgetId) category = b.category;
      }
    }
    final state = myEntryStateOf(e);
    return MyEntryItem(
      id: e.id,
      title: e.correctsEntryId != null
          ? '#${e.correctsEntryId} 정정 · ${e.counterparty} · ${e.purpose}'
          : '${e.counterparty} · ${e.purpose}',
      category: category,
      amount: e.amount,
      date: Fmt.date(e.occurredAt),
      state: state,
      isIncome: income,
      // 차단 사유는 서버가 `block_reason` 으로 준다. 못 받았으면(옛 서버) 일반 안내로 둔다
      note: switch (state) {
        MyEntryState.rejected => e.rejectReason,
        MyEntryState.blocked => _blockedNote(e.blockReason),
        _ => null,
      },
      entry: e,
    );
  }
}

/// 차단 건 안내. 사유를 알면 사유를 적고, 증액이 해법인 잔량 부족에만 증액을 권한다.
String _blockedNote(BlockReason? reason) => switch (reason) {
      BlockReason.BUDGET_EXCEEDED => '${reason!.label} — 증액이 승인되면 다시 등록할 수 있어요.',
      BlockReason.BUDGET_EXPIRED || BlockReason.BUDGET_NOT_FOUND => '${reason!.label} — 예산을 확인해 주세요.',
      null => '예산 검사에서 차단됐어요 (잔량 부족·마감). 증액이 승인되면 다시 등록할 수 있어요.',
    };

/// **목업** 내 등록 건 — 테스트·화면 캡처용 ([MyEntriesScreen.items]). 서버 목록은 `GET /entries` 에서 내가 등록한 건이다.
List<MyEntryItem> buildMyEntryMockItems() => const [
      MyEntryItem(
        id: 11,
        title: 'MT 장소 대관 계약금',
        category: '운영비',
        amount: 150000,
        date: '2026-09-17',
        state: MyEntryState.draft,
      ),
      MyEntryItem(
        id: 10,
        title: '학생회 단체복 제작',
        category: '행사비',
        amount: 300000,
        date: '2026-09-16',
        state: MyEntryState.processing,
      ),
      MyEntryItem(
        id: 2,
        title: '청년피자 개강총회 다과 주문',
        category: '행사비',
        amount: 120000,
        date: '2026-09-10',
        state: MyEntryState.pending,
      ),
      MyEntryItem(
        id: 6,
        title: '동아리 연합 행사 현수막 제작',
        category: '행사비',
        amount: 85000,
        date: '2026-09-13',
        state: MyEntryState.rejected,
        note: '영수증 금액(80,000원)과 달라요. 확인 후 다시 올려 주세요.',
      ),
      MyEntryItem(
        id: 12,
        title: '행사 무대 장비 대여',
        category: '행사비',
        amount: 2600000,
        date: '2026-09-15',
        state: MyEntryState.blocked,
        note: '잔량 부족 (BUDGET_EXCEEDED)',
      ),
      MyEntryItem(
        id: 1,
        title: '한결문구 신입생 환영회 물품 구매',
        category: '행사비',
        amount: 35000,
        date: '2026-09-08',
        state: MyEntryState.confirmed,
      ),
      MyEntryItem(
        id: 3,
        title: '컴퓨터공학과 학생회비 수납',
        category: '수입',
        amount: 5000000,
        date: '2026-09-06',
        state: MyEntryState.confirmed,
        isIncome: true,
      ),
    ];

/// 카드의 행동 한 개 — 누를 수 없으면 [onTap] 이 null 이고 [label] 이 이유다.
typedef _Action = (String label, IconData icon, VoidCallback? onTap);

/// [이승호 담당: app/lib/screens/council/]
/// 내 등록 현황 화면 (스토리보드 9, T5) — 총무가 올린 건을 상태별로 보고 다음 행동으로 넘어간다.
///
/// 상태에 따라 갈 곳이 다르다. 확정은 정정 등록, 반려는 고쳐서 새로 등록, 차단은 예산 개정 요청(승인 뒤 다시 등록).
/// **대기 건은 여기서 고칠 수 없다** — 새로 올리면 두 건이 함께 대기하다 둘 다 확정될 수 있다(PRD §4.3). 「수정 요청 →
/// 반려」를 거쳐야 하고, 수정 요청 API 가 생기면 버튼을 붙인다. 처리 중인 건은 다시 보낼 수 없다.
class MyEntriesScreen extends StatefulWidget {
  /// 목록 재료. 주면 서버를 읽지 않는다 (테스트·화면 캡처용).
  final List<MyEntryItem>? items;

  /// 로그인 세션이 없을 때(테스트) 내 사용자 id. 로그인했으면 세션 id 만 믿는다.
  final int? currentUserId;

  /// 서버 목록 읽기. 주지 않으면 `GET /entries` ([ApiService.fetchEntries]).
  final Future<List<EntryModel>> Function()? loadEntries;

  /// 다시 등록·정정 화면에 넘길 등록기 (테스트용). 주지 않으면 각 화면이 서버를 쓴다.
  final EntryRegistrar? registrar;

  const MyEntriesScreen({super.key, this.items, this.currentUserId, this.loadEntries, this.registrar});

  @override
  State<MyEntriesScreen> createState() => _MyEntriesScreenState();
}

class _MyEntriesScreenState extends State<MyEntriesScreen> {
  late List<MyEntryItem> _items = widget.items ?? const [];
  MyEntryState? _filter; // null = 전체

  bool get _fromServer => widget.items == null;
  bool _loading = false;

  /// 목록을 못 읽은 이유. 빈 목록과 구분한다 — 못 읽은 것을 「등록 건 없음」으로 보이지 않는다.
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_fromServer) _load();
  }

  Future<void> _load() async {
    final me = AuthService().session?.userId ?? widget.currentUserId;
    if (me == null) {
      setState(() => _error = '로그인 정보가 없어 내 등록 건을 찾을 수 없어요. 다시 로그인해 주세요.');
      return;
    }
    setState(() => _loading = true);
    try {
      final entries = await (widget.loadEntries ?? ApiService().fetchEntries)();
      // 예산 이름은 표시용이다 — 못 읽어도 목록은 보여 준다(번호로 적는다)
      List<BudgetModel> budgets = const [];
      try {
        budgets = await ApiService().fetchBudgets();
      } on ApiUnavailable {
        budgets = const [];
      }
      final mine = entries.where((e) => e.createdBy == me).toList()..sort((a, b) => b.id.compareTo(a.id));
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
        _items = [for (final e in mine) MyEntryItem.fromEntry(e, budgets)];
      });
    } on ApiUnavailable catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  /// 다른 화면에 갔다 오면 목록을 다시 읽는다 — 다시 등록·정정·요청의 결과가 바로 보이게.
  Future<void> _go(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    if (mounted && _fromServer) _load();
  }

  /// 주 행동과 (있으면) 보조 행동.
  (_Action, _Action?) _actions(MyEntryItem item) {
    final e = item.entry;
    if (e == null) return (_mockAction(item), null);
    switch (item.state) {
      case MyEntryState.draft: // 서버 목록에는 초안이 없다 (`GET /entries` 가 뺀다)
      case MyEntryState.processing:
        return (('처리 중 — 다시 보낼 수 없어요', Icons.hourglass_top_rounded, null), null);
      case MyEntryState.pending:
        return (('승인 대기 중 — 고치려면 수정 요청이 필요해요 (준비 중)', Icons.hourglass_empty_rounded, null), null);
      case MyEntryState.confirmed:
        return (
          (
            '정정 등록',
            Icons.edit_note_rounded,
            () => _go(CorrectionScreen(initialTargetId: e.correctsEntryId ?? e.id, registrar: widget.registrar)),
          ),
          null,
        );
      case MyEntryState.rejected:
        return (('고쳐서 다시 제출', Icons.refresh_rounded, () => _go(_resubmitScreen(e))), null);
      case MyEntryState.blocked:
        return (
          (
            '예산 개정 요청',
            Icons.trending_up_rounded,
            () => _go(BudgetRevisionScreen(
                  initialCategory: item.category,
                  basisTitle: item.title,
                  basisAmount: e.amount,
                  blockedEntryId: e.id,
                )),
          ),
          ('증액 승인 뒤 다시 등록', Icons.refresh_rounded, () => _go(_resubmitScreen(e))),
        );
    }
  }

  /// 반려·차단된 건을 다시 올리는 화면. **정정 건은 정정 화면으로** 보낸다 — 일반 등록 화면에는 정정 대상·사유가 없어서
  /// 양수 정정이 독립된 새 지출로 올라가고(지출 중복), 음수는 금액 검증에 막힌다 (#72 리뷰).
  /// 정정 화면은 원본 번호만 받는다. 입력했던 값은 다시 적어야 한다.
  Widget _resubmitScreen(EntryModel e) {
    final target = e.correctsEntryId;
    if (target != null) return CorrectionScreen(initialTargetId: target, registrar: widget.registrar);
    return e.kind == EntryKind.INCOME
        ? IncomeCreateScreen(resubmitOf: e, registrar: widget.registrar)
        : ExpenseCreateScreen(resubmitOf: e, registrar: widget.registrar);
  }

  /// 목업 카드의 행동 — 서버 항목이 없어 화면만 연다.
  _Action _mockAction(MyEntryItem e) {
    switch (e.state) {
      case MyEntryState.draft:
        return ('이어서 제출', Icons.play_arrow_rounded, () => _go(const ExpenseCreateScreen()));
      case MyEntryState.processing:
        return ('처리 중 — 다시 보낼 수 없어요', Icons.hourglass_top_rounded, null);
      case MyEntryState.pending:
        return ('승인 대기 중 — 고치려면 수정 요청이 필요해요 (준비 중)', Icons.hourglass_empty_rounded, null);
      case MyEntryState.confirmed:
        return ('정정 등록', Icons.edit_note_rounded, () => _go(const CorrectionScreen()));
      case MyEntryState.rejected:
        return ('고쳐서 다시 제출', Icons.refresh_rounded, () => _go(const ExpenseCreateScreen()));
      case MyEntryState.blocked:
        return (
          '예산 개정 요청',
          Icons.trending_up_rounded,
          () => _go(BudgetRevisionScreen(initialCategory: e.category, basisTitle: e.title, basisAmount: e.amount)),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _filter == null ? _items : _items.where((e) => e.state == _filter).toList();
    int count(MyEntryState s) => _items.where((e) => e.state == s).length;

    Widget chip(String label, MyEntryState? s, Color color) {
      final selected = _filter == s;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          onTap: () => setState(() => _filter = s),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? color.withOpacity(0.15) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: selected ? color : AppTheme.divider),
            ),
            child: Text(label,
              style: TextStyle(color: selected ? color : AppTheme.textSub, fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
        ),
      );
    }

    // 서버 목록에는 초안이 없다 — 0 인 칸을 보이지 않는다 (초안 목록 API 가 생기면 다시 센다)
    final states = _fromServer ? MyEntryState.values.where((s) => s != MyEntryState.draft) : MyEntryState.values;

    Widget body;
    if (_error != null && _items.isEmpty) {
      body = ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                Text(_error!,
                    key: const Key('my_entries_failed'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppTheme.expense, height: 1.4)),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: _load, child: const Text('다시 시도')),
              ],
            ),
          ),
        ],
      );
    } else if (_loading && _items.isEmpty) {
      body = const Center(child: CircularProgressIndicator());
    } else if (shown.isEmpty) {
      body = ListView(
        children: const [
          Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('해당 상태의 등록 건이 없어요', style: TextStyle(color: AppTheme.textSub))),
          ),
        ],
      );
    } else {
      body = ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: shown.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, i) => _card(shown[i]),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: const Text('내 등록 현황', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        flexibleSpace: Container(decoration: const BoxDecoration(gradient: AppTheme.primaryGradient)),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
            child: Row(
              children: [
                chip('전체 ${_items.length}', null, AppTheme.primary),
                for (final s in states) chip('${s.label} ${count(s)}', s, s.color),
              ],
            ),
          ),
          Expanded(
            child: _fromServer ? RefreshIndicator(onRefresh: _load, child: body) : body,
          ),
        ],
      ),
    );
  }

  /// 금액 표기. 정정은 증감분이라 부호를 그대로 붙인다.
  String _amountText(MyEntryItem e) {
    if (e.isCorrection) return e.amount > 0 ? '+${Fmt.won(e.amount)}' : Fmt.won(e.amount);
    return '${e.isIncome ? '+' : '-'}${Fmt.won(e.amount)}';
  }

  Widget _actionButton(_Action a, {bool primary = true}) {
    final (label, icon, onTap) = a;
    if (onTap == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: const Color(0xFFE5E7EB), borderRadius: BorderRadius.circular(10)),
        child: Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
      );
    }
    final color = primary ? AppTheme.primary : AppTheme.textSub;
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    );
  }

  Widget _card(MyEntryItem e) {
    final (primary, secondary) = _actions(e);
    return Container(
      key: ValueKey('my_entry_${e.id}'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppTheme.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: e.state.color.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
                child: Text(e.state.label,
                  style: TextStyle(color: e.state.color, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text('#${e.id} · ${e.isIncome ? '수입' : '지출'} · ${e.category} · ${e.date}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(e.title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppTheme.textMain),
          ),
          const SizedBox(height: 4),
          Text(_amountText(e),
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: e.isIncome ? AppTheme.income : AppTheme.expense),
          ),
          if (e.note != null) ...[
            const SizedBox(height: 8),
            Text(e.state == MyEntryState.rejected ? '반려 사유: ${e.note}' : '차단 사유: ${e.note}',
              style: const TextStyle(fontSize: 12, height: 1.4, color: AppTheme.textSub),
            ),
          ],
          const SizedBox(height: 12),
          _actionButton(primary),
          if (secondary != null) ...[
            const SizedBox(height: 8),
            _actionButton(secondary, primary: false),
          ],
        ],
      ),
    );
  }
}
