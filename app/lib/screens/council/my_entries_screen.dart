import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/format.dart';
import 'budget_revision_screen.dart';
import 'correction_screen.dart';
import 'expense_create_screen.dart';

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

  const MyEntryItem({
    required this.id,
    required this.title,
    required this.category,
    required this.amount,
    required this.date,
    required this.state,
    this.isIncome = false,
    this.note,
  });
}

/// **목업** 내 등록 건. 서버가 붙으면 `GET /entries` 에서 내가 등록한 건으로 바꾼다.
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

/// [이승호 담당: app/lib/screens/council/]
/// 내 등록 현황 화면 (스토리보드 9) — 총무가 올린 건을 상태별로 보고 다음 행동으로 넘어간다.
///
/// 상태에 따라 갈 곳이 다르다. 초안은 이어서 제출, 대기는 수정(새 기록), 확정은 정정 등록,
/// 반려는 사유를 보고 다시 제출, 차단은 예산 개정 요청. 처리 중인 건은 다시 보낼 수 없다.
class MyEntriesScreen extends StatefulWidget {
  /// 목록 재료. 주지 않으면 목업 목록을 쓴다 (테스트·화면 캡처용).
  final List<MyEntryItem>? items;
  const MyEntriesScreen({super.key, this.items});

  @override
  State<MyEntriesScreen> createState() => _MyEntriesScreenState();
}

class _MyEntriesScreenState extends State<MyEntriesScreen> {
  late final List<MyEntryItem> _items = widget.items ?? buildMyEntryMockItems();
  MyEntryState? _filter; // null = 전체

  void _go(Widget screen) => Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  (String, IconData, VoidCallback?) _action(MyEntryItem e) {
    switch (e.state) {
      case MyEntryState.draft:
        return ('이어서 제출', Icons.play_arrow_rounded, () => _go(const ExpenseCreateScreen()));
      case MyEntryState.processing:
        return ('처리 중 — 다시 보낼 수 없어요', Icons.hourglass_top_rounded, null);
      case MyEntryState.pending:
        return ('수정 (새 기록으로 등록)', Icons.edit_rounded, () => _go(const ExpenseCreateScreen()));
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
                for (final s in MyEntryState.values) chip('${s.label} ${count(s)}', s, s.color),
              ],
            ),
          ),
          Expanded(
            child: shown.isEmpty
                ? const Center(child: Text('해당 상태의 등록 건이 없어요', style: TextStyle(color: AppTheme.textSub)))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: shown.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (_, i) => _card(shown[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _card(MyEntryItem e) {
    final (label, icon, onTap) = _action(e);
    return Container(
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
                child: Text('${e.isIncome ? '수입' : '지출'} · ${e.category} · ${e.date}',
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
          Text('${e.isIncome ? '+' : '-'}${Fmt.won(e.amount)}',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: e.isIncome ? AppTheme.income : AppTheme.expense),
          ),
          if (e.note != null) ...[
            const SizedBox(height: 8),
            Text(e.state == MyEntryState.rejected ? '반려 사유: ${e.note}' : '차단 사유: ${e.note}',
              style: const TextStyle(fontSize: 12, height: 1.4, color: AppTheme.textSub),
            ),
          ],
          const SizedBox(height: 12),
          if (onTap == null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: const Color(0xFFE5E7EB), borderRadius: BorderRadius.circular(10)),
              child: Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
            )
          else
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onTap,
                icon: Icon(icon, size: 18),
                label: Text(label),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primary,
                  side: const BorderSide(color: AppTheme.primary),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
