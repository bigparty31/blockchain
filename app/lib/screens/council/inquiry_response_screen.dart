import 'package:flutter/material.dart';
import '../../core/app_theme.dart';

/// [이승호 담당: app/lib/screens/council/]
/// 5. 학생 이의 제기 답변 화면
class InquiryResponseScreen extends StatefulWidget {
  const InquiryResponseScreen({super.key});

  @override
  State<InquiryResponseScreen> createState() => _InquiryResponseScreenState();
}

class _InquiryResponseScreenState extends State<InquiryResponseScreen> {
  int _selectedFilterIndex = 0;

  final List<Map<String, dynamic>> _inquiries = [
    {
      'id': 101,
      'entryId': 1,
      'studentName': '익명의 재학생',
      'category': '행사비',
      'question': '한결문구 신입생 환영회 물품 35,000원 건 세부 품목 내역서가 누락되어 있습니다.',
      'date': '2026-09-11',
      'isAnswered': false,
      'answer': null,
    },
    {
      'id': 102,
      'entryId': 2,
      'studentName': '익명의 재학생',
      'category': '행사비',
      'question': '청년피자 다과 주문 건 참석자 명단 증빙이 첨부되어 있나요?',
      'date': '2026-09-12',
      'isAnswered': true,
      'answer': '네, 개강총회 당일 출석 서명부 스캔본을 증빙에 추가 업로드 완료하였습니다.',
    },
  ];

  void _openAnswerDialog(Map<String, dynamic> item) {
    final textController = TextEditingController(text: item['answer'] ?? '');
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.success.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.rate_review_rounded, color: AppTheme.success, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Text('소명 답변 (내역 #${item['entryId']})',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.textMain),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text('${item['studentName']} · ${item['date']}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.bgPage,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.divider),
                ),
                child: Text(item['question'],
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, color: AppTheme.textMain, height: 1.4),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: textController,
                maxLines: 4,
                decoration: AppTheme.inputDecoration(
                  label: '학생회 공식 소명 답변 *',
                  hint: '투명하고 구체적인 소명 내용을 기재하세요.',
                  icon: Icons.edit_rounded,
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
                    flex: 2,
                    child: GradientButton(
                      onPressed: () {
                        if (textController.text.trim().isNotEmpty) {
                          setState(() {
                            item['answer'] = textController.text.trim();
                            item['isAnswered'] = true;
                          });
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: const Row(
                                children: [
                                  Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
                                  SizedBox(width: 10),
                                  Text('소명 답변이 등록되었습니다.'),
                                ],
                              ),
                              backgroundColor: AppTheme.success,
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              margin: const EdgeInsets.all(16),
                            ),
                          );
                        }
                      },
                      label: '답변 등록',
                      icon: Icons.send_rounded,
                      gradient: const LinearGradient(colors: [AppTheme.success, AppTheme.income]),
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

  @override
  Widget build(BuildContext context) {
    final unansweredCount = _inquiries.where((e) => !e['isAnswered']).length;

    List<Map<String, dynamic>> filteredList = _inquiries;
    if (_selectedFilterIndex == 1) filteredList = _inquiries.where((e) => e['isAnswered'] == false).toList();
    else if (_selectedFilterIndex == 2) filteredList = _inquiries.where((e) => e['isAnswered'] == true).toList();

    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: const Text('학생 이의 답변', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF10B981), Color(0xFF06B6D4)],
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
      body: Column(
        children: [
          // 요약 헤더
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: AppTheme.softShadow,
            ),
            child: Row(
              children: [
                Expanded(
                  child: _StatItem(
                    label: '전체 이의',
                    value: '${_inquiries.length}건',
                    color: AppTheme.primary,
                    icon: Icons.question_answer_rounded,
                  ),
                ),
                Container(width: 1, height: 40, color: AppTheme.divider),
                Expanded(
                  child: _StatItem(
                    label: '답변 대기',
                    value: '$unansweredCount건',
                    color: AppTheme.expense,
                    icon: Icons.pending_rounded,
                  ),
                ),
                Container(width: 1, height: 40, color: AppTheme.divider),
                Expanded(
                  child: _StatItem(
                    label: '답변 완료',
                    value: '${_inquiries.length - unansweredCount}건',
                    color: AppTheme.success,
                    icon: Icons.check_circle_rounded,
                  ),
                ),
              ],
            ),
          ),

          // 필터 칩
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _FilterChip(label: '전체 (${_inquiries.length})', index: 0, selectedIndex: _selectedFilterIndex,
                  onTap: () => setState(() => _selectedFilterIndex = 0)),
                const SizedBox(width: 8),
                _FilterChip(label: '답변 대기 ($unansweredCount)', index: 1, selectedIndex: _selectedFilterIndex,
                  color: AppTheme.expense, onTap: () => setState(() => _selectedFilterIndex = 1)),
                const SizedBox(width: 8),
                _FilterChip(label: '답변 완료', index: 2, selectedIndex: _selectedFilterIndex,
                  color: AppTheme.success, onTap: () => setState(() => _selectedFilterIndex = 2)),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 목록
          Expanded(
            child: filteredList.isEmpty
                ? Center(
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
                          child: const Icon(Icons.inbox_rounded, color: AppTheme.primary, size: 36),
                        ),
                        const SizedBox(height: 16),
                        const Text('해당 이의 내역이 없습니다',
                          style: TextStyle(color: AppTheme.textSub, fontSize: 15),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    itemCount: filteredList.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final item = filteredList[index];
                      final isAnswered = item['isAnswered'] == true;
                      return _InquiryCard(
                        item: item,
                        isAnswered: isAnswered,
                        onAnswer: () => _openAnswerDialog(item),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label, value;
  final Color color;
  final IconData icon;
  const _StatItem({required this.label, required this.value, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: color)),
        Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSub)),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final int index, selectedIndex;
  final Color color;
  final VoidCallback onTap;
  const _FilterChip({
    required this.label,
    required this.index,
    required this.selectedIndex,
    this.color = AppTheme.primary,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = index == selectedIndex;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? color.withOpacity(0.12) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? color : AppTheme.divider,
            width: isSelected ? 2 : 1.5,
          ),
          boxShadow: isSelected ? [] : AppTheme.softShadow,
        ),
        child: Text(label,
          style: TextStyle(
            color: isSelected ? color : AppTheme.textSub,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _InquiryCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool isAnswered;
  final VoidCallback onAnswer;
  const _InquiryCard({required this.item, required this.isAnswered, required this.onAnswer});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppTheme.softShadow,
        border: isAnswered
            ? Border.all(color: AppTheme.success.withOpacity(0.3))
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                StatusBadge(
                  label: isAnswered ? '답변 완료' : '답변 대기',
                  color: isAnswered ? AppTheme.success : AppTheme.expense,
                ),
                Text('지출 #${item['entryId']} · ${item['date']}',
                  style: const TextStyle(color: AppTheme.textSub, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 질문
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.bgPage,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.help_outline_rounded, size: 16, color: AppTheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(item['question'],
                      style: const TextStyle(fontSize: 13.5, color: AppTheme.textMain, height: 1.4, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),

            // 답변 (있는 경우)
            if (isAnswered) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppTheme.success.withOpacity(0.08), AppTheme.income.withOpacity(0.05)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.success.withOpacity(0.2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.rate_review_rounded, size: 14, color: AppTheme.success),
                        SizedBox(width: 6),
                        Text('총무단 공식 소명 답변',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppTheme.success),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(item['answer'] ?? '',
                      style: const TextStyle(fontSize: 13, height: 1.4, color: AppTheme.textMain),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),

            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: onAnswer,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF10B981), Color(0xFF06B6D4)],
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(isAnswered ? Icons.edit_rounded : Icons.reply_rounded, color: Colors.white, size: 15),
                      const SizedBox(width: 6),
                      Text(isAnswered ? '답변 수정' : '답변 작성하기',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
