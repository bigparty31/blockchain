import 'package:flutter/material.dart';
import '../../core/app_theme.dart';

/// [이승호 담당: app/lib/screens/council/]
/// 2. 수입 등록 화면
class IncomeCreateScreen extends StatefulWidget {
  const IncomeCreateScreen({super.key});

  @override
  State<IncomeCreateScreen> createState() => _IncomeCreateScreenState();
}

class _IncomeCreateScreenState extends State<IncomeCreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _sourceController = TextEditingController();
  final _amountController = TextEditingController();
  final _memoController = TextEditingController();

  DateTime _selectedDate = DateTime.now();
  String _incomeType = '학생회비 수납';

  final List<Map<String, dynamic>> _incomeTypeInfos = [
    {'label': '학생회비 수납', 'icon': Icons.people_rounded, 'color': const Color(0xFF06B6D4)},
    {'label': '단과대/학교 지원금', 'icon': Icons.account_balance_rounded, 'color': const Color(0xFF3B82F6)},
    {'label': '동문회 찬조금', 'icon': Icons.handshake_rounded, 'color': const Color(0xFF8B5CF6)},
    {'label': '행사 부스 수익금', 'icon': Icons.storefront_rounded, 'color': const Color(0xFF10B981)},
    {'label': '기타', 'icon': Icons.more_horiz_rounded, 'color': const Color(0xFF64748B)},
  ];

  @override
  void dispose() {
    _sourceController.dispose();
    _amountController.dispose();
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
          colorScheme: const ColorScheme.light(primary: AppTheme.income),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  void _submitIncome() {
    if (_formKey.currentState!.validate()) {
      showDialog(
        context: context,
        builder: (ctx) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: AppTheme.income.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check_rounded, color: AppTheme.income, size: 30),
                ),
                const SizedBox(height: 16),
                const Text('수입 등록 완료!',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textMain),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppTheme.bgPage,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _InfoRow(label: '분류', value: _incomeType),
                      _InfoRow(label: '출처', value: _sourceController.text),
                      _InfoRow(label: '금액', value: '${_amountController.text}원'),
                      _InfoRow(
                        label: '일자',
                        value: '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Text('장부에 수입(INCOME)으로 등록되었습니다',
                  style: TextStyle(color: AppTheme.textSub, fontSize: 13),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: GradientButton(
                    onPressed: () { Navigator.pop(ctx); Navigator.pop(context); },
                    label: '확인',
                    icon: Icons.check_rounded,
                    gradient: AppTheme.incomeGradient,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentInfo = _incomeTypeInfos.firstWhere(
      (e) => e['label'] == _incomeType,
      orElse: () => _incomeTypeInfos.last,
    );

    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: const Text('수입 등록', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        flexibleSpace: Container(decoration: const BoxDecoration(gradient: AppTheme.incomeGradient)),
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
              // 수입 유형 선택 카드 (가로 스크롤)
              SizedBox(
                height: 94,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _incomeTypeInfos.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final info = _incomeTypeInfos[index];
                    final isSelected = _incomeType == info['label'];
                    return GestureDetector(
                      onTap: () => setState(() => _incomeType = info['label'] as String),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 100,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                        decoration: BoxDecoration(
                          color: isSelected ? (info['color'] as Color).withOpacity(0.12) : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isSelected ? info['color'] as Color : AppTheme.divider,
                            width: isSelected ? 2 : 1.5,
                          ),
                          boxShadow: isSelected ? [] : AppTheme.softShadow,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(info['icon'] as IconData,
                              color: isSelected ? info['color'] as Color : AppTheme.textSub,
                              size: 24,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              (info['label'] as String).replaceAll('/', '\n'),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                color: isSelected ? info['color'] as Color : AppTheme.textSub,
                                height: 1.2,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 20),

              // 선택된 수입 유형 표시 배너
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [(currentInfo['color'] as Color).withOpacity(0.15), (currentInfo['color'] as Color).withOpacity(0.05)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: (currentInfo['color'] as Color).withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: (currentInfo['color'] as Color).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(currentInfo['icon'] as IconData, color: currentInfo['color'] as Color, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('선택된 수입 유형', style: TextStyle(color: AppTheme.textSub, fontSize: 11)),
                        Text(_incomeType,
                          style: TextStyle(color: currentInfo['color'] as Color, fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              TextFormField(
                controller: _sourceController,
                decoration: AppTheme.inputDecoration(
                  label: '상세 출처 / 내용 *',
                  hint: '예: 2026학년도 2학기 학생회비 일괄 수납',
                  icon: Icons.edit_note_rounded,
                ),
                validator: (v) => (v == null || v.isEmpty) ? '수입 상세 내용을 입력해 주세요' : null,
              ),
              const SizedBox(height: 14),

              TextFormField(
                controller: _amountController,
                keyboardType: TextInputType.number,
                decoration: AppTheme.inputDecoration(
                  label: '입금 금액(원) *',
                  hint: '예: 5000000',
                  icon: Icons.monetization_on_rounded,
                ),
                validator: (v) => (v == null || v.isEmpty) ? '입금 금액을 입력해 주세요' : null,
              ),
              const SizedBox(height: 14),

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
                      Icon(Icons.calendar_today_rounded, color: currentInfo['color'] as Color, size: 20),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('입금 확인 일자 *', style: TextStyle(color: AppTheme.textSub, fontSize: 12)),
                          const SizedBox(height: 2),
                          Text(
                            '${_selectedDate.year}년 ${_selectedDate.month}월 ${_selectedDate.day}일',
                            style: const TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w600, fontSize: 15),
                          ),
                        ],
                      ),
                      const Spacer(),
                      const Icon(Icons.edit_calendar_rounded, color: AppTheme.textSub, size: 18),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              TextFormField(
                controller: _memoController,
                maxLines: 3,
                decoration: AppTheme.inputDecoration(
                  label: '통장 입금 메모 및 확인 정보',
                  hint: '예: 신한은행 학생회 계좌 거래내역 확인 완료',
                  icon: Icons.notes_rounded,
                ),
              ),
              const SizedBox(height: 28),

              GradientButton(
                onPressed: _submitIncome,
                label: '수입 내역 등록하기',
                icon: Icons.add_circle_rounded,
                gradient: AppTheme.incomeGradient,
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label, value;
  const _InfoRow({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(color: AppTheme.textSub, fontSize: 13)),
          Expanded(child: Text(value, style: const TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w600, fontSize: 13))),
        ],
      ),
    );
  }
}
