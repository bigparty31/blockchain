import 'package:flutter/material.dart';
import '../../core/enums.dart';
import '../../core/app_theme.dart';
import '../../core/format.dart';
import '../../core/hashing.dart';
import '../../services/api_service.dart';
import 'budget_revision_screen.dart';
import 'input_rules.dart';
import 'registration_result.dart';

/// [이승호 담당: app/lib/screens/council/]
/// 1. 지출 등록 화면
class ExpenseCreateScreen extends StatefulWidget {
  const ExpenseCreateScreen({super.key});

  @override
  State<ExpenseCreateScreen> createState() => _ExpenseCreateScreenState();
}

class _ExpenseCreateScreenState extends State<ExpenseCreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _amountController = TextEditingController();
  final _merchantController = TextEditingController();
  final _memoController = TextEditingController();

  String _selectedBudgetCategory = '행사비';
  DateTime _selectedDate = DateTime.now();
  bool _hasReceiptImage = false;
  OcrStatus _ocrStatus = OcrStatus.MATCH;
  bool _submitting = false;

  final List<String> _budgetCategories = ['행사비', '사업비', '운영비'];

  /// 예산 항목별 잔량 (`GET /budgets`). 고르기 전에 남은 예산을 보여 준다 (스토리보드 7 ③).
  Map<String, int> _remaining = const {};

  @override
  void initState() {
    super.initState();
    _loadBudgets();
  }

  /// 예산 잔량을 못 읽었다. 잔량 없이 항목만 보이고, 못 읽었다고 적는다.
  bool _budgetsFailed = false;

  Future<void> _loadBudgets() async {
    try {
      final budgets = await ApiService().fetchBudgets();
      if (!mounted) return;
      setState(() {
        _budgetsFailed = false;
        _remaining = {for (final b in budgets) b.category: b.remainingAmount};
      });
    } on ApiUnavailable {
      if (mounted) setState(() => _budgetsFailed = true);
    }
  }

  String _budgetLabel(String category) {
    final left = _remaining[category];
    return left == null ? category : '$category · 잔량 ${Fmt.won(left)}';
  }

  @override
  void dispose() {
    _titleController.dispose();
    _amountController.dispose();
    _merchantController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2026, 1, 1),
      lastDate: DateTime(2026, 12, 31),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(primary: AppTheme.primary),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  void _simulatePickReceipt() {
    setState(() {
      _hasReceiptImage = true;
      if (_titleController.text.isEmpty) _titleController.text = '신입생 오리엔테이션 다과 구매';
      if (_merchantController.text.isEmpty) _merchantController.text = '한결문구점';
      if (_amountController.text.isEmpty) _amountController.text = '35000';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
            SizedBox(width: 10),
            Expanded(child: Text('영수증 첨부 완료 (목업: 예시 값을 채웠어요)')),
          ],
        ),
        backgroundColor: AppTheme.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  /// 사용일 → `occurred_at`. **KST 자정** Unix 초 (HASHING §1.3).
  /// 기기 로컬 시간대를 쓰지 않고 선택한 연·월·일만 쓴다.
  int get _occurredAt => Hashing.kstMidnightOf(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
      );

  /// ① 초안 저장 — 서버에만 저장한다. 체인 검사(BLOCKED)도 서명도 하지 않는다.
  Future<void> _saveDraft() async {
    if (_submitting || !_formKey.currentState!.validate()) return;
    await _showResult(const RegistrationResult.draft());
  }

  /// ② 제출 — 서명해 체인에 올린다. 결과는 `PENDING` 또는 `BLOCKED`.
  Future<void> _submitExpense() async {
    if (_submitting || !_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);

    // 목업: 서버 연동 전에는 예산 잔량으로 BLOCKED 를 흉내 낸다.
    final RegistrationResult result;
    try {
      result = await simulateExpenseRegistration(
        category: _selectedBudgetCategory,
        amount: int.parse(_amountController.text),
      );
    } on ApiUnavailable catch (e) {
      // 예산을 확인하지 못했으면 제출하지 않는다 — 통과로 간주하지 않는다.
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${e.message} 제출하지 않았어요.'), behavior: SnackBarBehavior.floating),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _submitting = false);
    await _showResult(result);
  }

  Future<void> _showResult(RegistrationResult result) async {
    final done = await showRegistrationResultDialog(
      context,
      kindLabel: '지출',
      rows: [
        ('목적', _titleController.text),
        ('사용처', _merchantController.text),
        ('금액', '${int.parse(_amountController.text)}원'),
        ('예산 항목', _selectedBudgetCategory),
      ],
      result: result,
      occurredAtNote: '전송값 occurred_at: $_occurredAt (사용일 KST 00:00)',
      onBudgetRevision: _openBudgetRevision,
    );
    if (done && mounted) Navigator.pop(context);
  }

  /// 차단 안내 → 예산 개정 요청. 차단된 지출이 근거로 붙고 예산 항목이 골라져 넘어간다.
  void _openBudgetRevision() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BudgetRevisionScreen(
          initialCategory: _selectedBudgetCategory,
          basisTitle: _titleController.text,
          basisAmount: int.tryParse(_amountController.text),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: const Text('지출 등록', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        flexibleSpace: Container(decoration: const BoxDecoration(gradient: AppTheme.primaryGradient)),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 영수증 첨부 영역
              GestureDetector(
                onTap: _simulatePickReceipt,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  // 고정 height 대신 최소 높이 — 큰 글자에서 내용이 커져도 세로로 넘치지 않는다
                  constraints: const BoxConstraints(minHeight: 160),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _hasReceiptImage ? AppTheme.primary : AppTheme.divider,
                      width: _hasReceiptImage ? 2 : 1.5,
                    ),
                    boxShadow: AppTheme.softShadow,
                  ),
                  child: _hasReceiptImage
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: const BoxDecoration(
                                color: AppTheme.primaryLight,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.check_rounded, color: AppTheme.primary, size: 28),
                            ),
                            const SizedBox(height: 10),
                            const Text('영수증 첨부 완료',
                              style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.primary, fontSize: 15),
                            ),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(colors: [AppTheme.primary, Color(0xFF9B59D6)]),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                'OCR: ${_ocrStatus.label} ✓',
                                style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text('탭하여 다른 사진으로 변경',
                              style: TextStyle(fontSize: 11, color: AppTheme.textSub.withOpacity(0.7)),
                            ),
                          ],
                        )
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: AppTheme.primaryLight,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: const Icon(Icons.camera_alt_rounded, color: AppTheme.primary, size: 26),
                            ),
                            const SizedBox(height: 10),
                            const Text('영수증 촬영 또는 사진 첨부',
                              style: TextStyle(fontSize: 14, color: AppTheme.textMain, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                            // OCR 은 값을 채워 주지 않는다 — 판독값을 입력값과 대조해 경고만 한다 (PRD §6)
                            const Text('OCR이 영수증 금액을 입력값과 대조해요',
                              style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 20),

              _SectionLabel(label: '지출 정보'),
              const SizedBox(height: 12),

              TextFormField(
                controller: _titleController,
                decoration: AppTheme.inputDecoration(
                  label: '목적 *',
                  hint: '예: 신입생 오리엔테이션 다과 구매',
                  icon: Icons.description_rounded,
                ),
                validator: (v) => InputRules.singleLine(v, fieldName: '목적'),
              ),
              const SizedBox(height: 14),

              TextFormField(
                controller: _merchantController,
                decoration: AppTheme.inputDecoration(
                  label: '사용처(상호명) *',
                  hint: '예: 한결문구점',
                  icon: Icons.storefront_rounded,
                ),
                validator: (v) => InputRules.singleLine(v, fieldName: '사용처'),
              ),
              const SizedBox(height: 14),

              TextFormField(
                controller: _amountController,
                keyboardType: TextInputType.number,
                decoration: AppTheme.inputDecoration(
                  label: '지출 금액(원) *',
                  hint: '예: 35000',
                  icon: Icons.monetization_on_rounded,
                ),
                validator: (v) => InputRules.positiveAmount(v, fieldName: '금액'),
              ),
              const SizedBox(height: 14),

              // 예산 항목 (잔량 표시)
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFFAF9FF),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.divider, width: 1.5),
                ),
                child: DropdownButtonFormField<String>(
                  value: _selectedBudgetCategory,
                  isExpanded: true,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded, color: AppTheme.primary),
                  decoration: InputDecoration(
                    labelText: '예산 항목 *',
                    labelStyle: const TextStyle(color: AppTheme.textSub, fontSize: 14),
                    border: InputBorder.none,
                    prefixIcon: const Icon(Icons.category_rounded, color: AppTheme.primary, size: 20),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                  items: _budgetCategories
                      .map((c) => DropdownMenuItem(value: c, child: Text(_budgetLabel(c), overflow: TextOverflow.ellipsis)))
                      .toList(),
                  onChanged: (val) => setState(() => _selectedBudgetCategory = val!),
                ),
              ),
              if (_budgetsFailed)
                const Padding(
                  padding: EdgeInsets.only(top: 6, left: 4),
                  child: Text('예산 잔량을 불러오지 못했어요.',
                      key: Key('budgets_failed'), style: TextStyle(fontSize: 12, color: AppTheme.expense)),
                ),
              const SizedBox(height: 14),

              // 날짜 선택
              GestureDetector(
                onTap: _pickDate,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFAF9FF),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppTheme.divider, width: 1.5),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.calendar_today_rounded, color: AppTheme.primary, size: 20),
                      const SizedBox(width: 12),
                      // Expanded: 좁은 화면·큰 글자에서 날짜가 넘치지 않고 줄바꿈된다 (Spacer 대신)
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('지출 일자 *',
                              style: TextStyle(color: AppTheme.textSub, fontSize: 12),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${_selectedDate.year}년 ${_selectedDate.month}월 ${_selectedDate.day}일',
                              style: const TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w600, fontSize: 15),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.edit_calendar_rounded, color: AppTheme.textSub, size: 18),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              TextFormField(
                controller: _memoController,
                maxLines: 2,
                decoration: AppTheme.inputDecoration(
                  label: '지출 메모 (선택)',
                  hint: '행사 참석 인원 등 세부 내역 기재',
                  icon: Icons.notes_rounded,
                ),
              ),
              const SizedBox(height: 28),

              // 스토리보드 7: ⑦ 초안 저장 → ⑧ 제출 순서
              OutlinedButton.icon(
                onPressed: _submitting ? null : _saveDraft,
                icon: const Icon(Icons.save_outlined),
                label: const Text('초안으로 저장'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primary,
                  minimumSize: const Size.fromHeight(48),
                  side: const BorderSide(color: AppTheme.primary),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 10),
              GradientButton(
                onPressed: _submitExpense,
                label: _submitting ? '제출 중...' : '제출하기',
                icon: Icons.upload_rounded,
              ),
              const SizedBox(height: 8),
              const Center(
                child: Text('초안 저장은 체인에 올리지 않아요. 제출하면 감사/회장 승인 대기(PENDING)로 기록됩니다',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(width: 3, height: 16, decoration: BoxDecoration(
          gradient: AppTheme.primaryGradient,
          borderRadius: BorderRadius.circular(2),
        )),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textMain)),
      ],
    );
  }
}
