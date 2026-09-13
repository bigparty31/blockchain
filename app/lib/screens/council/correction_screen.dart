import 'package:flutter/material.dart';
import '../../core/enums.dart';
import '../../core/app_theme.dart';

/// [이승호 담당: app/lib/screens/council/]
/// 4. 정정 신청 화면
class CorrectionScreen extends StatefulWidget {
  const CorrectionScreen({super.key});

  @override
  State<CorrectionScreen> createState() => _CorrectionScreenState();
}

class _CorrectionScreenState extends State<CorrectionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _entryIdController = TextEditingController();
  final _correctedAmountController = TextEditingController();
  final _detailController = TextEditingController();

  CorrectionReason _selectedReason = CorrectionReason.INPUT_ERROR;
  bool _hasCorrectionReceipt = false;

  @override
  void dispose() {
    _entryIdController.dispose();
    _correctedAmountController.dispose();
    _detailController.dispose();
    super.dispose();
  }

  void _submitCorrection() {
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
                    color: AppTheme.pending.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.send_rounded, color: AppTheme.pending, size: 28),
                ),
                const SizedBox(height: 16),
                const Text('정정 신청 접수 완료!',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textMain),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: AppTheme.bgPage, borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _InfoRow(label: '대상 내역', value: '#${_entryIdController.text}'),
                      _InfoRow(
                        label: '정정 사유',
                        value: '${_selectedReason.label} (${_selectedReason.code})',
                      ),
                      _InfoRow(
                        label: '정정 금액',
                        value: _correctedAmountController.text.isEmpty
                            ? '금액 변동 없음'
                            : '${_correctedAmountController.text}원',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Text('감사단 및 회장에게 승인 요청이 전달되었습니다',
                  style: TextStyle(color: AppTheme.textSub, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: GradientButton(
                    onPressed: () { Navigator.pop(ctx); Navigator.pop(context); },
                    label: '확인',
                    icon: Icons.check_rounded,
                    gradient: const LinearGradient(
                      colors: [Color(0xFFF59E0B), Color(0xFFEF4444)],
                    ),
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
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: const Text('장부 정정 신청', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFF59E0B), Color(0xFFEF4444)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
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
              // 안내 배너
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppTheme.pending.withOpacity(0.12), AppTheme.pending.withOpacity(0.04)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.pending.withOpacity(0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppTheme.pending.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.info_rounded, color: AppTheme.pending, size: 18),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        '블록체인에 등록된 내역은 수정·삭제 불가합니다. 정정 사유와 함께 새로운 트랜잭션으로 기록됩니다.',
                        style: TextStyle(fontSize: 13, height: 1.5, color: AppTheme.textMain),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              _SectionLabel(label: '정정 대상'),
              const SizedBox(height: 12),

              TextFormField(
                controller: _entryIdController,
                keyboardType: TextInputType.number,
                decoration: AppTheme.inputDecoration(
                  label: '정정 대상 내역 ID (Entry ID) *',
                  hint: '예: 2',
                  icon: Icons.tag_rounded,
                ),
                validator: (v) => (v == null || v.isEmpty) ? '내역 ID를 입력해 주세요' : null,
              ),
              const SizedBox(height: 20),

              _SectionLabel(label: '정정 사유'),
              const SizedBox(height: 12),

              // 정정 사유 선택 카드
              ...CorrectionReason.values.map((reason) {
                final isSelected = _selectedReason == reason;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GestureDetector(
                    onTap: () => setState(() => _selectedReason = reason),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: isSelected ? const Color(0xFFFFF8E1) : Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isSelected ? AppTheme.pending : AppTheme.divider,
                          width: isSelected ? 2 : 1.5,
                        ),
                        boxShadow: isSelected ? [] : AppTheme.softShadow,
                      ),
                      child: Row(
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isSelected ? AppTheme.pending : Colors.transparent,
                              border: Border.all(
                                color: isSelected ? AppTheme.pending : AppTheme.textSub.withOpacity(0.4),
                                width: 2,
                              ),
                            ),
                            child: isSelected
                                ? const Icon(Icons.check_rounded, color: Colors.white, size: 14)
                                : null,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(reason.label,
                                  style: TextStyle(
                                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                    color: isSelected ? AppTheme.textMain : AppTheme.textMain,
                                    fontSize: 14,
                                  ),
                                ),
                                Text(reason.code,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isSelected ? AppTheme.pending : AppTheme.textSub,
                                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
              const SizedBox(height: 20),

              _SectionLabel(label: '정정 내용'),
              const SizedBox(height: 12),

              TextFormField(
                controller: _correctedAmountController,
                keyboardType: TextInputType.number,
                decoration: AppTheme.inputDecoration(
                  label: '수정 후 올바른 금액(원)',
                  hint: '금액 변동이 있는 경우 입력 (예: 118000)',
                  icon: Icons.price_change_rounded,
                ),
              ),
              const SizedBox(height: 14),

              TextFormField(
                controller: _detailController,
                maxLines: 4,
                decoration: AppTheme.inputDecoration(
                  label: '정정 상세 사유 및 소명 내용 *',
                  hint: '예: 실제 영수증 확인 결과 부가세 포함 금액 정정 요청',
                  icon: Icons.notes_rounded,
                ),
                validator: (v) => (v == null || v.isEmpty) ? '상세 사유를 입력해 주세요' : null,
              ),
              const SizedBox(height: 16),

              // 증빙 첨부
              GestureDetector(
                onTap: () {
                  setState(() => _hasCorrectionReceipt = true);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Row(
                        children: [
                          Icon(Icons.attach_file_rounded, color: Colors.white, size: 18),
                          SizedBox(width: 10),
                          Text('수정 증빙 영수증 첨부 완료'),
                        ],
                      ),
                      backgroundColor: AppTheme.success,
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      margin: const EdgeInsets.all(16),
                    ),
                  );
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _hasCorrectionReceipt
                        ? AppTheme.success.withOpacity(0.08)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _hasCorrectionReceipt ? AppTheme.success : AppTheme.divider,
                      width: _hasCorrectionReceipt ? 2 : 1.5,
                    ),
                    boxShadow: AppTheme.softShadow,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: _hasCorrectionReceipt
                              ? AppTheme.success.withOpacity(0.12)
                              : AppTheme.primaryLight,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          _hasCorrectionReceipt ? Icons.check_circle_rounded : Icons.attach_file_rounded,
                          color: _hasCorrectionReceipt ? AppTheme.success : AppTheme.primary,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _hasCorrectionReceipt ? '수정 증빙 첨부 완료됨 ✓' : '수정 증빙 자료 재첨부 (영수증)',
                        style: TextStyle(
                          color: _hasCorrectionReceipt ? AppTheme.success : AppTheme.primary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 28),

              GradientButton(
                onPressed: _submitCorrection,
                label: '정정 신청 제출하기',
                icon: Icons.send_rounded,
                gradient: const LinearGradient(
                  colors: [Color(0xFFF59E0B), Color(0xFFEF4444)],
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
          gradient: const LinearGradient(colors: [Color(0xFFF59E0B), Color(0xFFEF4444)]),
          borderRadius: BorderRadius.circular(2),
        )),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textMain)),
      ],
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
