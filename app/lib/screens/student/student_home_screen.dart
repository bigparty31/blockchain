import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/entry_merge.dart';
import '../../core/enums.dart';
import '../../core/format.dart';
import '../../core/term_info.dart';
import '../../models/budget_model.dart';
import '../../models/entry_model.dart';
import '../../models/snapshot_model.dart';
import '../../services/student_api_service.dart';
import 'entry_list_screen.dart';
import 'my_sbt_screen.dart';
import 'widgets/student_badges.dart';

/// [장정아 담당 파트: app/lib/screens/student/]
/// 학생 대시보드 — 잔액·수입·지출(S1), 예산 집행률·개정 이력(S6),
/// 계좌 차액 경고(S11), 미확인 항목 카운트(S12), 카테고리별 차트(S13)
class StudentHomeScreen extends StatefulWidget {
  const StudentHomeScreen({super.key});

  @override
  State<StudentHomeScreen> createState() => _StudentHomeScreenState();
}

class _StudentHomeScreenState extends State<StudentHomeScreen> {
  final _api = StudentApiService();

  bool _loading = true;
  List<EntryModel> _entries = [];
  List<BudgetModel> _budgets = [];
  SnapshotModel? _snapshot;
  int _unseen = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);

    final entries = await _api.fetchEntries();
    final budgets = await _api.fetchBudgets();
    final snapshot = await _api.fetchLatestSnapshot();
    final lastSeen = await _api.lastSeenEntryId();

    if (!mounted) return;
    setState(() {
      _entries = entries;
      _budgets = budgets;
      _snapshot = snapshot;
      _unseen = EntryMerge.unseenCount(entries, lastSeen);
      _loading = false;
    });
  }

  /// 장부 잔액은 항목에서 직접 계산한다 (PRD §7.4).
  /// 서버가 내려주는 합계를 그대로 믿으면, 서버가 숫자를 바꿨을 때
  /// 학생이 그것을 알 방법이 없다.
  ///
  /// 정정 항목의 금액이 증감분이라 확정 항목을 그냥 다 더하면 된다.
  int get _ledgerBalance => EntryMerge.ledgerBalance(_entries);
  int get _totalIncome => EntryMerge.totalIncome(_entries);
  int get _totalExpense => EntryMerge.totalExpense(_entries);

  Future<void> _openEntries() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const EntryListScreen()),
    );
    if (mounted) _load(); // 목록에서 읽음 처리했을 수 있으니 뱃지 갱신
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          slivers: [
            _buildAppBar(),
            if (_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    // 예시 데이터를 보고 있다면 숫자보다 먼저 알려야 한다.
                    if (_api.usingDemoData) ...[
                      const DemoDataBanner(),
                      const SizedBox(height: 14),
                    ],
                    _buildBalanceCard(),
                    const SizedBox(height: 14),
                    _buildIncomeExpenseRow(),
                    const SizedBox(height: 20),
                    if (_snapshot != null) ...[
                      _BankDiffCard(
                        snapshot: _snapshot!,
                        ledgerBalance: _ledgerBalance,
                      ),
                      const SizedBox(height: 20),
                    ],
                    _buildQuickActions(),
                    const SizedBox(height: 24),
                    _sectionTitle('예산 집행 현황', '항목별 잔량과 집행률'),
                    const SizedBox(height: 12),
                    ..._budgets.map((b) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _BudgetCard(budget: b),
                        )),
                    const SizedBox(height: 12),
                    _buildCategoryChart(),
                  ]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    // 높이는 상태바 높이를 뺀 나머지를 나눠 쓰므로 여유를 둔다.
    // 빠듯하게 맞추면 기기·폰트 설정에 따라 몇 픽셀씩 넘쳐 오버플로가 난다.
    return SliverAppBar(
      expandedHeight: 190,
      pinned: true,
      backgroundColor: AppTheme.primary,
      foregroundColor: Colors.white,
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: const BoxDecoration(gradient: AppTheme.headerGradient),
          child: SafeArea(
            child: Padding(
              // 위쪽 48 은 뒤로가기·새로고침 아이콘 줄을 비켜 가기 위한 것이다.
              padding: const EdgeInsets.fromLTRB(20, 48, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      '학생 모드',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '학생회비 열람',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    TermInfo.headline,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.85),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        IconButton(
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded),
          tooltip: '새로고침',
        ),
      ],
    );
  }

  Widget _buildBalanceCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: AppTheme.gradientDecoration(AppTheme.primaryGradient),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_balance_wallet_rounded,
                  color: Colors.white, size: 18),
              const SizedBox(width: 6),
              Text(
                '장부 잔액',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.9),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              Fmt.won(_ledgerBalance),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 32,
                fontWeight: FontWeight.bold,
                letterSpacing: -1,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded,
                  color: Colors.white.withOpacity(0.7), size: 12),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '확정된 수입에서 확정된 지출을 뺀 값입니다. 승인대기 건은 빠져 있습니다.',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.75),
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildIncomeExpenseRow() {
    return Row(
      children: [
        Expanded(
          child: _MiniStatCard(
            label: '학기 총수입',
            amount: _totalIncome,
            color: AppTheme.income,
            icon: Icons.south_west_rounded,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _MiniStatCard(
            label: '학기 총지출',
            amount: _totalExpense,
            color: AppTheme.expense,
            icon: Icons.north_east_rounded,
          ),
        ),
      ],
    );
  }

  Widget _buildQuickActions() {
    return Row(
      children: [
        Expanded(
          child: _ActionTile(
            icon: Icons.receipt_long_rounded,
            label: '수입·지출 내역',
            sublabel: '${_entries.length}건',
            badgeCount: _unseen,
            onTap: _openEntries,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ActionTile(
            icon: Icons.qr_code_2_rounded,
            label: '내 SBT · QR',
            sublabel: '행사 입장용',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const MySbtScreen()),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
            color: AppTheme.textMain,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
        ),
      ],
    );
  }

  /// 카테고리별 지출 차트 (S13)
  Widget _buildCategoryChart() {
    // 예산 카테고리별로 확정 지출을 모은다.
    // 정정 항목은 증감분이므로 그대로 더하면 최종값이 된다.
    final byCategory = <String, int>{};
    for (final e in _entries) {
      if (e.status != EntryStatus.CONFIRMED || e.kind != EntryKind.EXPENSE) continue;
      final matched = _budgets.where((b) => b.id == e.budgetId);
      final name = matched.isEmpty ? '미분류' : matched.first.category;
      byCategory[name] = (byCategory[name] ?? 0) + e.amount;
    }

    if (byCategory.isEmpty) return const SizedBox.shrink();

    final total = byCategory.values.fold(0, (a, b) => a + b);
    final palette = [AppTheme.primary, AppTheme.income, AppTheme.pending, AppTheme.info];
    final items = byCategory.entries.toList();

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '카테고리별 지출',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppTheme.textMain,
            ),
          ),
          const SizedBox(height: 14),
          // 한 줄 누적 막대
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 12,
              child: Row(
                children: List.generate(items.length, (i) {
                  return Expanded(
                    flex: (items[i].value * 1000 ~/ total).clamp(1, 1000),
                    child: Container(color: palette[i % palette.length]),
                  );
                }),
              ),
            ),
          ),
          const SizedBox(height: 14),
          ...List.generate(items.length, (i) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: palette[i % palette.length],
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      items[i].key,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textMain),
                    ),
                  ),
                  Text(
                    Fmt.won(items[i].value),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textMain,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

/// 총수입·총지출 작은 카드
class _MiniStatCard extends StatelessWidget {
  final String label;
  final int amount;
  final Color color;
  final IconData icon;

  const _MiniStatCard({
    required this.label,
    required this.amount,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 14, color: color),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              Fmt.won(amount),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: color,
                letterSpacing: -0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 대시보드 바로가기 타일
class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final int badgeCount;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.sublabel,
    this.badgeCount = 0,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: AppTheme.cardDecoration,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UnseenCountBadge(
                count: badgeCount,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryLight,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, size: 20, color: AppTheme.primary),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textMain,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                sublabel,
                style: const TextStyle(fontSize: 11, color: AppTheme.textSub),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 장부-계좌 차액 경고와 미등록 건 (S11)
///
/// 계좌 조회 결과는 원장에 자동 반영하지 않는다 — 자동으로 맞춰버리면
/// 대조 대상 자체가 사라져서 미등록 지출을 영영 못 찾는다.
class _BankDiffCard extends StatelessWidget {
  final SnapshotModel snapshot;
  final int ledgerBalance;

  const _BankDiffCard({required this.snapshot, required this.ledgerBalance});

  @override
  Widget build(BuildContext context) {
    final diff = snapshot.diffAgainst(ledgerBalance);
    final hasIssue = diff != 0 || snapshot.unrecorded.isNotEmpty;
    final color = hasIssue ? AppTheme.pending : AppTheme.success;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                hasIssue
                    ? Icons.error_outline_rounded
                    : Icons.check_circle_outline_rounded,
                size: 18,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hasIssue ? '장부와 계좌가 맞지 않습니다' : '장부와 계좌가 일치합니다',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _row('장부 잔액', Fmt.won(ledgerBalance)),
          const SizedBox(height: 6),
          _row('계좌 잔액', Fmt.won(snapshot.bankBalance)),
          const SizedBox(height: 6),
          _row(
            '차액',
            diff > 0 ? '+${Fmt.won(diff)}' : Fmt.won(diff),
            emphasize: true,
            color: diff == 0 ? AppTheme.textMain : color,
          ),
          if (snapshot.unrecorded.isNotEmpty) ...[
            const Divider(height: 24),
            Text(
              '원장에 없는 계좌 거래 ${snapshot.unrecorded.length}건',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: AppTheme.textMain,
              ),
            ),
            const SizedBox(height: 8),
            ...snapshot.unrecorded.map(
              (t) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    const Icon(Icons.remove_circle_outline_rounded,
                        size: 13, color: AppTheme.textSub),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${Fmt.date(t.occurredAt)} · ${t.counterparty}',
                        style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
                      ),
                    ),
                    Text(
                      Fmt.won(t.amount),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textMain,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            '${Fmt.dateTime(snapshot.snapshotAt)} 기준 조회. 계좌 내역은 참고용이며 '
            '원장에 자동 반영되지 않습니다.',
            style: TextStyle(
              fontSize: 10,
              color: AppTheme.textSub.withOpacity(0.9),
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool emphasize = false, Color? color}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSub)),
        Text(
          value,
          style: TextStyle(
            fontSize: emphasize ? 14 : 13,
            fontWeight: emphasize ? FontWeight.bold : FontWeight.w600,
            color: color ?? AppTheme.textMain,
          ),
        ),
      ],
    );
  }
}

/// 예산 항목 카드 — 잔량·집행률과 개정 이력 (S6)
class _BudgetCard extends StatelessWidget {
  final BudgetModel budget;
  const _BudgetCard({required this.budget});

  @override
  Widget build(BuildContext context) {
    final used = budget.plannedAmount - budget.remainingAmount;
    final rate = budget.plannedAmount == 0
        ? 0.0
        : (used / budget.plannedAmount).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                budget.category,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textMain,
                ),
              ),
              const SizedBox(width: 8),
              // 개정된 예산이면 버전 뱃지. 개정은 덮어쓰기가 아니라 버전 추가다.
              if (budget.version > 1)
                StatusBadge(label: 'v${budget.version}', color: AppTheme.info),
              const Spacer(),
              Text(
                Fmt.percent(rate),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: rate >= 0.9 ? AppTheme.expense : AppTheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: rate,
              minHeight: 8,
              backgroundColor: AppTheme.divider,
              valueColor: AlwaysStoppedAnimation(
                rate >= 0.9 ? AppTheme.expense : AppTheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '잔량 ${Fmt.won(budget.remainingAmount)}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textMain,
                ),
              ),
              Text(
                '편성 ${Fmt.won(budget.plannedAmount)}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
            ],
          ),
          // 예산 개정 이력 — `행사비 250만 (v2, 참가인원 증가)`
          if (budget.version > 1 && budget.revisionReason != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.info.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.history_rounded, size: 14, color: AppTheme.info),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '예산 개정 — ${Fmt.compact(budget.plannedAmount)}원 '
                      '(v${budget.version}, ${budget.revisionReason})',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.info,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
