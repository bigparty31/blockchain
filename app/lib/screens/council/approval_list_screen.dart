import 'package:flutter/material.dart';
import '../../core/enums.dart';
import '../../core/app_theme.dart';
import 'reason_dialog.dart';

/// 경고가 있는 항목인가 — OCR 이 일치하지 않으면(`MATCH` 가 아니면) 경고다.
/// 경고를 무시하고 승인하려면 사유가 필수다 (`hadWarning` + `warningReasonHash`).
/// 카테고리 경고(`category_warning`)는 서버 연동 후 함께 본다.
bool _hasWarning(Map<String, dynamic> item) => item['ocrStatus'] != OcrStatus.MATCH;

/// 확정이 예산 문제로 실패했을 때 반려 흐름으로 넘기는 `fail_reason` (RELAY §9).
const _budgetFailReasons = {
  'InsufficientBudget': '예산 잔량이 부족해요',
  'BudgetExpired': '예산 집행 기간이 지났어요',
};

/// [이승호 담당: app/lib/screens/council/]
/// 3. 승인 대기 목록 화면 (감사 / 회장)
class ApprovalListScreen extends StatefulWidget {
  const ApprovalListScreen({super.key});

  @override
  State<ApprovalListScreen> createState() => _ApprovalListScreenState();
}

class _ApprovalListScreenState extends State<ApprovalListScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  final List<Map<String, dynamic>> _items = [
    {
      'id': 2,
      'title': '청년피자 개강총회 다과 주문',
      'merchant': '청년피자',
      'amount': 120000,
      'category': '행사비',
      'date': '2026-09-10 18:30',
      'status': EntryStatus.PENDING,
      'ocrStatus': OcrStatus.MATCH,
      'receiptInfo': '신용카드 매출전표 (승인번호: 83921049)',
    },
    {
      'id': 4,
      'title': '학생회 간담회 음료 구매',
      'merchant': '스타벅스',
      'amount': 45000,
      'category': '운영비',
      'date': '2026-09-12 14:10',
      'status': EntryStatus.PENDING,
      'ocrStatus': OcrStatus.MATCH,
      'receiptInfo': '전자영수증 스캔본 (승인번호: 10492811)',
      // 목업: 등록 땐 잔량이 있었지만 다른 건이 먼저 확정돼 확정이 revert 되는 경우.
      // 서버 연동 후에는 확정 응답의 fail_reason 이 이 자리를 대신한다.
      'mockFailReason': 'InsufficientBudget',
    },
    {
      'id': 6,
      'title': '동아리 연합 행사 현수막 제작',
      'merchant': '한빛인쇄',
      'amount': 85000,
      'category': '행사비',
      'date': '2026-09-13 10:40',
      'status': EntryStatus.PENDING,
      'ocrStatus': OcrStatus.MISMATCH, // 경고 → 승인 시 사유 필수
      'receiptInfo': '카드 매출전표 (OCR 금액 80,000원)',
    },
    {
      'id': 1,
      'title': '한결문구 신입생 환영회 물품 구매',
      'merchant': '한결문구',
      'amount': 35000,
      'category': '행사비',
      'date': '2026-09-08 11:20',
      'status': EntryStatus.CONFIRMED,
      'ocrStatus': OcrStatus.MATCH,
      'receiptInfo': '간이과세 세금계산서',
    },
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _showReceiptDialog(Map<String, dynamic> item) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryLight,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.receipt_long_rounded, color: AppTheme.primary, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Text('영수증 확인 (#${item['id']})',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.textMain),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                height: 160,
                width: double.infinity,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFEDE9FE), Color(0xFFE0F2FE)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.receipt_long_rounded, size: 40, color: AppTheme.primary),
                    ),
                    const SizedBox(height: 8),
                    const Text('영수증 이미지 원본',
                      style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textMain),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _DetailRow(icon: Icons.description_rounded, label: '증빙 종류', value: item['receiptInfo']),
              _DetailRow(
                icon: Icons.document_scanner_rounded,
                label: 'OCR 결과',
                value: (item['ocrStatus'] as OcrStatus).label,
              ),
              _DetailRow(
                icon: Icons.storefront_rounded,
                label: '가맹점',
                value: '${item['merchant']} | ${item['amount']}원',
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppTheme.primary),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('닫기', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 승인 진입점. 경고가 있으면 사유를 먼저 받는다 (빈 값은 서버가 400).
  Future<void> _onApprove(Map<String, dynamic> item) async {
    String? warningReason;
    if (_hasWarning(item)) {
      warningReason = await showReasonDialog(
        context,
        title: '경고 무시 승인 사유',
        description: 'OCR 판독 결과(${(item['ocrStatus'] as OcrStatus).label})가 등록 내용과 다릅니다. '
            '그래도 승인하려면 사유를 남겨 주세요.',
        confirmLabel: '다음',
        accent: AppTheme.pending,
        icon: Icons.warning_amber_rounded,
      );
      if (warningReason == null || !mounted) return;
    }
    _onApproveWithBiometric(item, warningReason);
  }

  void _onApproveWithBiometric(Map<String, dynamic> item, String? warningReason) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 지문 아이콘 애니메이션
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF8B5CF6), Color(0xFF6C63FF)],
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.primary.withOpacity(0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: const Icon(Icons.fingerprint_rounded, color: Colors.white, size: 44),
              ),
              const SizedBox(height: 16),
              const Text('집행 최종 승인',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textMain),
              ),
              const SizedBox(height: 4),
              const Text('생체인증으로 블록체인 서명',
                style: TextStyle(fontSize: 13, color: AppTheme.textSub),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.bgPage,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailRow(icon: Icons.description_rounded, label: '대상', value: item['title']),
                    _DetailRow(icon: Icons.monetization_on_rounded, label: '금액', value: '${item['amount']}원 (${item['category']})'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFFFCC80)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_rounded, color: Colors.orange, size: 18),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '생체인증 완료 시 스마트 컨트랙트에 영구 기록됩니다.',
                        style: TextStyle(fontSize: 12, height: 1.4, color: Color(0xFF7C4700)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
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
                    flex: 3, // 취소 1 : 승인 3 — 1:1 이면 411dp 에서 '생체인증 승인' 버튼이 넘친다
                    child: GradientButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        // 목업: 서버가 붙으면 여기서 서명을 제출하고 응답의 status / fail_reason 을 본다.
                        final failReason = item['mockFailReason'] as String?;
                        if (failReason != null) {
                          _showApprovalFailure(item, failReason);
                          return;
                        }
                        setState(() {
                          item['status'] = EntryStatus.CONFIRMED;
                          if (warningReason != null) item['warningAckReason'] = warningReason;
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Row(
                              children: [
                                const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
                                const SizedBox(width: 10),
                                Expanded(child: Text('[${item['title']}] 승인 완료!')),
                              ],
                            ),
                            backgroundColor: AppTheme.success,
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            margin: const EdgeInsets.all(16),
                          ),
                        );
                      },
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
  }

  /// 확정 실패 안내. 항목은 `PENDING` 그대로다 (컨트랙트: 확정 실패 시 전체 revert).
  /// 예산 문제(`InsufficientBudget`·`BudgetExpired`)면 반려 흐름으로 넘긴다.
  Future<void> _showApprovalFailure(Map<String, dynamic> item, String failReason) async {
    final budgetReason = _budgetFailReasons[failReason];
    final goReject = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.expense.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.error_outline_rounded, color: AppTheme.expense, size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('승인에 실패했어요',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.textMain),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _DetailRow(icon: Icons.description_rounded, label: '대상', value: item['title']),
              _DetailRow(
                icon: Icons.report_gmailerrorred_rounded,
                label: '사유',
                value: budgetReason ?? '체인이 확정을 거부했어요 ($failReason)',
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.bgPage,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  budgetReason != null
                      ? '이 항목은 아직 승인 대기(PENDING) 상태예요. 등록할 때는 잔량이 있었지만 '
                          '다른 건이 먼저 확정되면서 예산이 부족해졌을 수 있어요. '
                          '확정할 수 없으므로 반려로 처리해 주세요.'
                      : '이 항목은 아직 승인 대기(PENDING) 상태예요. 잠시 뒤 다시 서명해 주세요.',
                  style: const TextStyle(fontSize: 12, height: 1.5, color: AppTheme.textMain),
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
                      child: const Text('나중에', style: TextStyle(color: AppTheme.textSub)),
                    ),
                  ),
                  if (budgetReason != null) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: GradientButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        label: '반려로 처리',
                        gradient: const LinearGradient(colors: [AppTheme.expense, Color(0xFFFB7185)]),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (goReject == true && mounted) {
      await _onReject(item, initialReason: '${budgetReason ?? failReason}. 확정할 수 없어 반려합니다.');
    }
  }

  /// 반려 — 사유 필수. 빈 값이면 서버가 400 이므로 입력 단계에서 막는다.
  Future<void> _onReject(Map<String, dynamic> item, {String? initialReason}) async {
    final reason = await showReasonDialog(
      context,
      title: '반려 사유',
      description: '[${item['title']}] 을(를) 반려합니다. 반려하면 되돌릴 수 없어요.',
      confirmLabel: '반려하기',
      initialText: initialReason,
    );
    if (reason == null || !mounted) return;
    setState(() {
      item['status'] = EntryStatus.REJECTED;
      item['rejectReason'] = reason;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('[${item['title']}] 반려 처리되었습니다.'),
        backgroundColor: AppTheme.expense,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pendingCount = _items.where((e) => e['status'] == EntryStatus.PENDING).length;

    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: Column(
          children: [
            const Text('지출 승인 목록',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 16),
            ),
            Text('감사 · 회장 전용',
              style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 11),
            ),
          ],
        ),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF8B5CF6), Color(0xFFEC4899)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          indicatorColor: Colors.white,
          indicatorWeight: 3,
          dividerColor: Colors.white24,
          tabs: [
            Tab(
              child: Row(
                children: [
                  const Text('승인 대기'),
                  if (pendingCount > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('$pendingCount',
                        style: const TextStyle(color: Color(0xFF8B5CF6), fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Tab(text: '승인 완료'),
            const Tab(text: '반려됨'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildListByStatus(EntryStatus.PENDING),
          _buildListByStatus(EntryStatus.CONFIRMED),
          _buildListByStatus(EntryStatus.REJECTED),
        ],
      ),
    );
  }

  Widget _buildListByStatus(EntryStatus status) {
    final filtered = _items.where((e) => e['status'] == status).toList();

    if (filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppTheme.primaryLight,
                shape: BoxShape.circle,
              ),
              child: Icon(
                status == EntryStatus.PENDING
                    ? Icons.hourglass_empty_rounded
                    : status == EntryStatus.CONFIRMED
                        ? Icons.check_circle_rounded
                        : Icons.cancel_rounded,
                color: AppTheme.primary,
                size: 36,
              ),
            ),
            const SizedBox(height: 16),
            Text('${status.label} 항목이 없습니다',
              style: const TextStyle(color: AppTheme.textSub, fontSize: 15),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: filtered.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final item = filtered[index];
        return _ApprovalCard(
          item: item,
          status: status,
          onReceipt: () => _showReceiptDialog(item),
          onApprove: () => _onApprove(item),
          onReject: () => _onReject(item),
        );
      },
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final EntryStatus status;
  final VoidCallback onReceipt, onApprove, onReject;

  const _ApprovalCard({
    required this.item,
    required this.status,
    required this.onReceipt,
    required this.onApprove,
    required this.onReject,
  });

  Color get _categoryColor {
    switch (item['category'] as String) {
      case '행사비': return AppTheme.primary;
      case '운영비': return AppTheme.income;
      default: return AppTheme.success;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppTheme.softShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                StatusBadge(label: item['category'], color: _categoryColor),
                const SizedBox(width: 8),
                // Flexible: 큰 글자·좁은 화면에서 날짜가 넘치지 않고 줄바꿈된다
                Flexible(
                  child: Text(item['date'],
                    textAlign: TextAlign.end,
                    style: const TextStyle(color: AppTheme.textSub, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(item['title'],
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textMain),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.storefront_rounded, size: 14, color: AppTheme.textSub),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(item['merchant'],
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppTheme.textSub, fontSize: 13),
                  ),
                ),
                const SizedBox(width: 12),
                const Icon(Icons.monetization_on_rounded, size: 14, color: AppTheme.textSub),
                const SizedBox(width: 4),
                Text('${item['amount']}원',
                  style: const TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ],
            ),
            if (status == EntryStatus.PENDING && _hasWarning(item)) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFFFCC80)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'OCR ${(item['ocrStatus'] as OcrStatus).label} — 승인하려면 경고 무시 사유가 필요해요',
                        style: const TextStyle(fontSize: 11, height: 1.3, color: Color(0xFF7C4700)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (status == EntryStatus.CONFIRMED && item['warningAckReason'] != null) ...[
              const SizedBox(height: 10),
              Text('경고 무시 사유: ${item['warningAckReason']}',
                style: const TextStyle(fontSize: 11, height: 1.4, color: AppTheme.textSub),
              ),
            ],
            if (status == EntryStatus.REJECTED && item['rejectReason'] != null) ...[
              const SizedBox(height: 10),
              Text('반려 사유: ${item['rejectReason']}',
                style: const TextStyle(fontSize: 11, height: 1.4, color: AppTheme.textSub),
              ),
            ],
            const SizedBox(height: 14),
            const Divider(color: AppTheme.divider, height: 1),
            const SizedBox(height: 12),

            if (status == EntryStatus.PENDING)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onReceipt,
                      icon: const Icon(Icons.receipt_long_rounded, size: 15),
                      label: const Text('영수증', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.primary,
                        side: const BorderSide(color: AppTheme.divider),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onReject,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.expense,
                        side: const BorderSide(color: Color(0xFFFFCDD2)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      child: const Text('반려', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF8B5CF6), Color(0xFF6C63FF)],
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: onApprove,
                          borderRadius: BorderRadius.circular(10),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 10),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.fingerprint_rounded, color: Colors.white, size: 16),
                                SizedBox(width: 6),
                                Text('승인 서명', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              )
            else if (status == EntryStatus.CONFIRMED)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onReceipt,
                      icon: const Icon(Icons.receipt_long_rounded, size: 15),
                      label: const Text('영수증', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.primary,
                        side: const BorderSide(color: AppTheme.divider),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: AppTheme.success.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.link_rounded, size: 16, color: AppTheme.success),
                          SizedBox(width: 6),
                          Text('블록체인 등록 완료', style: TextStyle(color: AppTheme.success, fontWeight: FontWeight.bold, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ],
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.expense.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.cancel_rounded, size: 16, color: AppTheme.expense),
                    SizedBox(width: 6),
                    Text('반려 처리됨', style: TextStyle(color: AppTheme.expense, fontWeight: FontWeight.bold, fontSize: 12)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label, value;
  const _DetailRow({required this.icon, required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 15, color: AppTheme.primary),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(color: AppTheme.textSub, fontSize: 12)),
          Expanded(child: Text(value, style: const TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w600, fontSize: 12))),
        ],
      ),
    );
  }
}
