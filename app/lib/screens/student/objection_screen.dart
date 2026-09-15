import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/format.dart';
import '../../models/entry_model.dart';
import '../../services/student_api_service.dart';

/// 이의 제기 (S8)
///
/// 학생이 확정 지출에 사유를 묻고 학생회가 답변한다.
/// **원장은 고치지 않고 설명만 쌓인다.** 이 화면은 금액이나 상태를
/// 바꾸지 않으며, 미답변 사실이 감사 화면에 카운트로 남는다.
class ObjectionScreen extends StatefulWidget {
  final EntryModel entry;
  const ObjectionScreen({super.key, required this.entry});

  @override
  State<ObjectionScreen> createState() => _ObjectionScreenState();
}

class _ObjectionScreenState extends State<ObjectionScreen> {
  final _api = StudentApiService();
  final _controller = TextEditingController();
  bool _submitting = false;

  static const _minLength = 10;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final content = _controller.text.trim();
    if (content.length < _minLength) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$_minLength자 이상 구체적으로 작성해 주세요'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _submitting = true);
    await _api.raiseObjection(entryId: widget.entry.id, content: content);
    if (!mounted) return;

    setState(() => _submitting = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('이의가 등록되었습니다. 답변이 달리면 상세 화면에서 확인할 수 있습니다.'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 3),
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppTheme.gradientAppBar(title: '이의 제기'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          _buildTargetCard(),
          const SizedBox(height: 20),
          const Text(
            '무엇이 궁금한가요?',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: AppTheme.textMain,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '어느 부분이 왜 이상한지 구체적으로 적을수록 답변이 정확해집니다.',
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.textSub.withOpacity(0.95),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: AppTheme.softShadow,
            ),
            child: TextField(
              controller: _controller,
              maxLines: 7,
              maxLength: 500,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                hintText: '예) 영수증에 적힌 품목과 지출 목적이 맞지 않는 것 같습니다. '
                    '세부 내역서를 확인할 수 있을까요?',
                hintStyle: TextStyle(
                  color: AppTheme.textSub,
                  fontSize: 13,
                  height: 1.5,
                ),
                contentPadding: EdgeInsets.all(16),
                border: InputBorder.none,
                counterStyle: TextStyle(fontSize: 11, color: AppTheme.textSub),
              ),
              style: const TextStyle(
                fontSize: 14,
                color: AppTheme.textMain,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 16),
          _buildNotice(),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: _submitting
                ? Container(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: AppTheme.divider,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : GradientButton(
                    onPressed: _submit,
                    label: '이의 제출',
                    icon: Icons.send_rounded,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTargetCard() {
    final e = widget.entry;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.description_outlined, size: 15, color: AppTheme.textSub),
              const SizedBox(width: 6),
              Text(
                '대상 내역 #${e.id}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            e.counterparty,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: AppTheme.textMain,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            e.purpose,
            style: const TextStyle(fontSize: 12, color: AppTheme.textSub, height: 1.4),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                Fmt.won(e.amount),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.expense,
                ),
              ),
              const Spacer(),
              Text(
                Fmt.date(e.occurredAt),
                style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNotice() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.primaryLight.withOpacity(0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, size: 16, color: AppTheme.primaryDark),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '이의를 제기해도 이미 확정된 기록은 수정되지 않습니다. 학생회의 답변이 '
              '기록으로 쌓이며, 답변하지 않으면 미답변 건으로 남습니다.',
              style: TextStyle(
                fontSize: 11,
                color: AppTheme.primaryDark.withOpacity(0.95),
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
