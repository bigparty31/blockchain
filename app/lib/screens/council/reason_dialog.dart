import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import 'input_rules.dart';

/// 사유 입력 다이얼로그 — 반려·경고 무시 승인처럼 **사유가 필수**인 자리에서 쓴다.
///
/// 비어 있거나 다듬은 뒤 빈 값이면 [InputRules.requiredReason] 이 막는다
/// (서버는 400, 그 값의 해시를 올리면 `bytes32(0)` 과 달라 위조로 판정된다 — HASHING §3).
///
/// 확인하면 **입력 원문 그대로** 돌려주고, 취소하면 null.
/// 서명용 `reasonHash` / `warningReasonHash` 를 만들 때는 이 값을
/// `Hashing.canonicalText` 로 정본화한 뒤 `Hashing.textHash` 에 넣는다.
Future<String?> showReasonDialog(
  BuildContext context, {
  required String title,
  required String description,
  required String confirmLabel,
  String? initialText,
  Color accent = AppTheme.expense,
  IconData icon = Icons.edit_note_rounded,
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _ReasonDialog(
      title: title,
      description: description,
      confirmLabel: confirmLabel,
      initialText: initialText,
      accent: accent,
      icon: icon,
    ),
  );
}

class _ReasonDialog extends StatefulWidget {
  final String title, description, confirmLabel;
  final String? initialText;
  final Color accent;
  final IconData icon;

  const _ReasonDialog({
    required this.title,
    required this.description,
    required this.confirmLabel,
    required this.initialText,
    required this.accent,
    required this.icon,
  });

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    if (_formKey.currentState!.validate()) {
      Navigator.pop(context, _controller.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: widget.accent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(widget.icon, color: widget.accent, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: AppTheme.textMain),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                widget.description,
                style: const TextStyle(
                    fontSize: 13, height: 1.4, color: AppTheme.textSub),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _controller,
                autofocus: true,
                minLines: 3,
                maxLines: 5,
                decoration: AppTheme.inputDecoration(
                  label: '사유 *',
                  hint: '사유를 적어 주세요',
                  icon: Icons.notes_rounded,
                ),
                validator: (v) => InputRules.requiredReason(v),
              ),
              const SizedBox(height: 6),
              const Text(
                '사유는 블록체인에 해시로 영구 기록되어 수정할 수 없어요.',
                style: TextStyle(fontSize: 11, color: AppTheme.textSub),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppTheme.divider),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text('취소',
                          style: TextStyle(color: AppTheme.textSub)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: GradientButton(
                      onPressed: _confirm,
                      label: widget.confirmLabel,
                      gradient: LinearGradient(colors: [
                        widget.accent,
                        widget.accent.withOpacity(0.8)
                      ]),
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
}
