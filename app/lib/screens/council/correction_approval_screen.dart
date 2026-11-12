import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/enums.dart';
import '../../core/format.dart';
import '../../services/auth_service.dart';
import 'reason_dialog.dart';

/// 정정 승인 대상 한 건. 원본은 그대로 두고 증감분만 새 기록으로 올라온 것이다.
class CorrectionItem {
  final int id;
  final int createdBy;
  final String title; // 원본 내역 이름
  final String category;
  final CorrectionReason reason;
  final int original; // 원본 금액
  final int delta; // 정정 증감분 (±)
  final int budgetRemaining; // 해당 예산의 남은 금액
  final String status; // 대기 | 확정 | 반려 | 재분류 진행 중
  final String? pairNote; // 재분류의 짝 정보

  const CorrectionItem({
    required this.id,
    required this.createdBy,
    required this.title,
    required this.category,
    required this.reason,
    required this.original,
    required this.delta,
    required this.budgetRemaining,
    this.status = '대기',
    this.pairNote,
  });

  int get finalAmount => original + delta;

  /// 증액 정정인데 예산 잔량이 모자라면 확정할 수 없다 — 승인해도 대기로 남는다.
  bool get insufficient => delta > 0 && delta > budgetRemaining;

  CorrectionItem copyWith({String? status}) => CorrectionItem(
        id: id,
        createdBy: createdBy,
        title: title,
        category: category,
        reason: reason,
        original: original,
        delta: delta,
        budgetRemaining: budgetRemaining,
        status: status ?? this.status,
        pairNote: pairNote,
      );
}

/// **목업** 정정 승인 대상. 서버가 붙으면 `corrects_entry_id` 가 있는 `PENDING` 항목으로 바꾼다.
List<CorrectionItem> buildCorrectionMockItems() => const [
      CorrectionItem(
        id: 21,
        createdBy: 2,
        title: '한결문구 신입생 환영회 물품 구매',
        category: '행사비',
        reason: CorrectionReason.INPUT_ERROR,
        original: 35000,
        delta: 5000,
        budgetRemaining: 2470000,
      ),
      CorrectionItem(
        id: 22,
        createdBy: 2,
        title: '청년피자 개강총회 다과 주문',
        category: '행사비',
        reason: CorrectionReason.REFUND,
        original: 120000,
        delta: -20000,
        budgetRemaining: 2470000,
      ),
      CorrectionItem(
        id: 23,
        createdBy: 2,
        title: '학과 MT 레크리에이션 소품',
        category: '운영비',
        reason: CorrectionReason.RECLASSIFY,
        original: 22000,
        delta: -22000,
        budgetRemaining: 1000000,
        status: '재분류 진행 중',
        pairNote: '사업비 +22,000 확정 · 운영비 −22,000 대기 (짝 1/2)',
      ),
      CorrectionItem(
        id: 24,
        createdBy: 2,
        title: '동아리 연합 행사 현수막 제작',
        category: '사업비',
        reason: CorrectionReason.RECEIPT_RECHECK,
        original: 85000,
        delta: 1600000,
        budgetRemaining: 1465000,
      ),
      CorrectionItem(
        id: 25,
        createdBy: 3,
        title: '학교 지원금 입금 확인',
        category: '지원금',
        reason: CorrectionReason.INPUT_ERROR,
        original: 2000000,
        delta: -50000,
        budgetRemaining: 0,
      ),
    ];

/// 홈 배너·메뉴에 쓰는 정정 승인 대기 건수 (확정·반려는 세지 않는다).
int correctionMockPendingCount() =>
    buildCorrectionMockItems().where((e) => e.status == '대기' || e.status == '재분류 진행 중').length;

/// [이승호 담당: app/lib/screens/council/]
/// 정정 승인 화면 (스토리보드 13) — 감사·회장이 정정 건을 원본과 대조해 승인·반려한다.
///
/// - 원본 금액 · 정정 증감분 · 정정 후 금액을 나란히 보여 준다.
/// - 등록자와 승인자가 같으면 승인·반려할 수 없다.
/// - 증액 정정이 예산 잔량을 넘으면 승인해도 확정되지 않고 대기로 남는다.
/// - 재분류는 짝이 되는 두 건이 모두 확정될 때까지 「재분류 진행 중」이다.
class CorrectionApprovalScreen extends StatefulWidget {
  final UserRole? role;
  final int? currentUserId;
  final List<CorrectionItem>? items;

  /// **로그인했으면 세션([AuthService.session])의 역할·id 만 믿는다** — [role]·[currentUserId] 인자로
  /// 다른 역할을 주장할 수 없다. 인자는 로그인 없이 화면을 그리는 위젯 테스트용이다.
  const CorrectionApprovalScreen({super.key, this.role, this.currentUserId, this.items});

  UserRole? get effectiveRole => AuthService().session?.role ?? role;
  int? get effectiveUserId => AuthService().session?.userId ?? currentUserId;

  bool get allowed => effectiveRole == UserRole.AUDITOR || effectiveRole == UserRole.PRESIDENT;

  @override
  State<CorrectionApprovalScreen> createState() => _CorrectionApprovalScreenState();
}

class _CorrectionApprovalScreenState extends State<CorrectionApprovalScreen> {
  late final List<CorrectionItem> _items = List.of(widget.items ?? buildCorrectionMockItems());

  void _replace(CorrectionItem old, CorrectionItem next) {
    setState(() => _items[_items.indexOf(old)] = next);
  }

  void _toast(String text, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  Future<void> _approve(CorrectionItem e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFF6C63FF)]),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.fingerprint_rounded, color: Colors.white, size: 44),
              ),
              const SizedBox(height: 16),
              const Text('정정 승인', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textMain)),
              const SizedBox(height: 4),
              const Text('생체인증으로 블록체인 서명', style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: AppTheme.bgPage, borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv('대상', e.title),
                    _kv('증감분', _signed(e.delta)),
                    _kv('정정 후', Fmt.won(e.finalAmount)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppTheme.divider),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text('취소', style: TextStyle(color: AppTheme.textSub)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: GradientButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      label: '생체인증 승인',
                      icon: Icons.fingerprint_rounded,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;

    // 증액 정정이 잔량을 넘으면 확정이 되지 않는다 — 대기 그대로.
    if (e.insufficient) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('확정할 수 없어요', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          content: Text('${e.category} 예산 잔량(${Fmt.won(e.budgetRemaining)})이 증액분(${Fmt.won(e.delta)})보다 적어요. '
              '이 건은 대기로 남아 있어요. 예산을 늘리거나 반려해 주세요.'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('확인'))],
        ),
      );
      return;
    }

    if (e.reason == CorrectionReason.RECLASSIFY) {
      // 짝이 모두 확정되면 완료. 이 목업에서는 이 건이 마지막 짝이다.
      _replace(e, e.copyWith(status: '확정'));
      _toast('[${e.title}] 재분류 정정 2건이 모두 확정되었습니다.', AppTheme.success);
      return;
    }
    _replace(e, e.copyWith(status: '확정'));
    _toast('[${e.title}] 정정 승인 완료!', AppTheme.success);
  }

  Future<void> _reject(CorrectionItem e) async {
    final reason = await showReasonDialog(
      context,
      title: '정정 반려 사유',
      description: '[${e.title}] 정정을 반려합니다. 반려하면 되돌릴 수 없어요.',
      confirmLabel: '반려하기',
    );
    if (reason == null || !mounted) return;
    _replace(e, e.copyWith(status: '반려'));
    _toast('[${e.title}] 정정이 반려되었습니다.', AppTheme.expense);
  }

  String _signed(int v) => v >= 0 ? '+${Fmt.won(v)}' : Fmt.won(v);

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: '$k: ', style: const TextStyle(color: AppTheme.textSub, fontSize: 13)),
            TextSpan(text: v, style: const TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w600, fontSize: 13)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (!widget.allowed) return const _NoAccess();
    final waiting = _items.where((e) => e.status == '대기' || e.status == '재분류 진행 중').length;
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: Column(
          children: [
            const Text('정정 승인', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 16)),
            Text('대기 $waiting건', style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
        backgroundColor: const Color(0xFF8B5CF6),
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, i) => _card(_items[i]),
      ),
    );
  }

  Widget _card(CorrectionItem e) {
    final own = widget.effectiveUserId != null && e.createdBy == widget.effectiveUserId;
    final done = e.status == '확정' || e.status == '반려';
    final statusColor = switch (e.status) {
      '확정' => AppTheme.success,
      '반려' => AppTheme.expense,
      '재분류 진행 중' => AppTheme.info,
      _ => AppTheme.pending,
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: AppTheme.softShadow),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: statusColor.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
                child: Text(e.status, style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${e.reason.label} · ${e.category}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSub), overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(e.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppTheme.textMain)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppTheme.bgPage, borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                _amountCol('원본', Fmt.won(e.original), AppTheme.textMain),
                _amountCol('증감분', _signed(e.delta), e.delta >= 0 ? AppTheme.income : AppTheme.expense),
                _amountCol('정정 후', Fmt.won(e.finalAmount), AppTheme.primary),
              ],
            ),
          ),
          if (e.pairNote != null) ...[
            const SizedBox(height: 8),
            Text('재분류 · ${e.pairNote}', style: const TextStyle(fontSize: 12, height: 1.4, color: AppTheme.info)),
          ],
          if (e.insufficient && !done) ...[
            const SizedBox(height: 8),
            Text('${e.category} 잔량(${Fmt.won(e.budgetRemaining)}) 부족 — 승인해도 대기로 남아요',
              style: const TextStyle(fontSize: 12, height: 1.4, color: AppTheme.expense)),
          ],
          const SizedBox(height: 12),
          if (done)
            const SizedBox.shrink()
          else if (own)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: const Color(0xFFE5E7EB), borderRadius: BorderRadius.circular(10)),
              child: const Text('본인이 등록한 건은 승인·반려할 수 없어요', style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _reject(e),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.expense,
                      side: const BorderSide(color: AppTheme.expense),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('반려'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: GradientButton(
                    onPressed: () => _approve(e),
                    label: '승인',
                    icon: Icons.fingerprint_rounded,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _amountCol(String label, String value, Color color) => Expanded(
        child: Column(
          children: [
            Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSub)),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
            ),
          ],
        ),
      );
}

/// 정정 승인 권한이 없는 사람이 들어왔을 때.
class _NoAccess extends StatelessWidget {
  const _NoAccess();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: const Text('정정 승인', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: const Color(0xFF8B5CF6),
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_rounded, size: 40, color: AppTheme.textSub),
              SizedBox(height: 12),
              Text('이 작업을 할 권한이 없습니다.',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.textMain)),
              SizedBox(height: 6),
              Text('정정 승인·반려는 감사·회장만 할 수 있어요.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSub), textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
