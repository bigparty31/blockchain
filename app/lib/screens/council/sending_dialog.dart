import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../services/entry_decision_service.dart';

/// 확정이 예산 문제로 실패했을 때의 `fail_reason` (#65, RELAY §9) → 사람이 읽는 이유. 이 둘만 반려로 넘긴다.
const budgetFailReasons = {
  'InsufficientBudget': '예산 잔량이 부족해요',
  'BudgetExpired': '예산 집행 기간이 지났어요',
};

/// 서명을 보내는 동안 막음 다이얼로그를 띄우고 [send] 를 돌린다. 실패 이유를, 성공이면 null 을 돌려준다.
///
/// 닫을 때 `pop()` 이 아니라 이 다이얼로그만 지운다. 401 이면 로그인 화면으로 가면서 쌓인 화면이 다 지워져
/// 다이얼로그도 이미 없다 — 그때 `pop()` 하면 방금 연 로그인 화면이 닫혀 빈 화면이 된다.
Future<EntryDecisionException?> sendWithBlocking(
  BuildContext context,
  String label,
  Future<void> Function() send,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final sending = DialogRoute<void>(
    context: context,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    barrierDismissible: false,
    builder: (_) => PopScope(canPop: false, child: SendingDialog(label: label)),
  );
  navigator.push(sending);
  EntryDecisionException? failed;
  try {
    await send();
  } on EntryDecisionException catch (e) {
    failed = e;
  }
  if (sending.isActive) navigator.removeRoute(sending);
  return failed;
}

/// 서명을 보내는 중 — 닫을 수 없다.
class SendingDialog extends StatelessWidget {
  final String label;
  const SendingDialog({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 16),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 14, color: AppTheme.textMain))),
          ],
        ),
      ),
    );
  }
}
