import 'package:flutter/material.dart';
import '../../core/enums.dart';
import '../../core/app_theme.dart';
import '../../core/hashing.dart';
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
            Expanded(child: Text('영수증 첨부 완료! OCR로 자동 입력되었습니다.')),
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

  Future<void> _submitExpense() async {
    if (_submitting || !_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);

    final amount = int.parse(_amountController.text);
    // 목업: 서버 연동 전에는 예산 잔량으로 BLOCKED 를 흉내 낸다.
    final result = await simulateExpenseRegistration(
      category: _selectedBudgetCategory,
      amount: amount,
    );
    if (!mounted) return;
    setState(() => _submitting = false);

    final done = await showRegistrationResultDialog(
      context,
      kindLabel: '지출',
      rows: [
        ('항목', _titleController.text),
        ('사용처', _merchantController.text),
        ('금액', '$amount원'),
        ('예산분류', _selectedBudgetCategory),
      ],
      result: result,
      occurredAtNote: '전송값 occurred_at: $_occurredAt (사용일 KST 00:00)',
    );
    if (done && mounted) Navigator.pop(context);
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
                            // [개발 연동: image_picker 및 ML Kit OCR]
                            const Text('영수증 촬영 시 금액 및 일자 자동 인식',
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
                  label: '지출 항목명 *',
                  hint: '예: 신입생 오리엔테이션 다과 구매',
                  icon: Icons.description_rounded,
                ),
                validator: (v) => InputRules.singleLine(v, fieldName: '항목명'),
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

              // 예산 카테고리
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
                    labelText: '예산 카테고리 *',
                    labelStyle: const TextStyle(color: AppTheme.textSub, fontSize: 14),
                    border: InputBorder.none,
                    prefixIcon: const Icon(Icons.category_rounded, color: AppTheme.primary, size: 20),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                  items: _budgetCategories.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                  onChanged: (val) => setState(() => _selectedBudgetCategory = val!),
                ),
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

              GradientButton(
                onPressed: _submitExpense,
                label: _submitting ? '확인 중...' : '지출 등록 신청하기',
                icon: Icons.upload_rounded,
              ),
              const SizedBox(height: 8),
              const Center(
                child: Text('등록 후 감사/회장 승인 대기 상태(PENDING)로 저장됩니다',
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
