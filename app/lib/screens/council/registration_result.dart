import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/enums.dart';
import '../../services/api_service.dart';

/// 등록(제출) 결과 — 온체인에 기록된 뒤의 상태.
///
/// 예산 초과·마감·미존재는 revert 가 아니라 **`BLOCKED` 로 저장**된다
/// (`IAccountingLedger`). 서버는 제출 응답에 `status` 와 `block_reason` 을 담아 준다.
class RegistrationResult {
  final EntryStatus status; // PENDING | BLOCKED
  final BlockReason? blockReason; // BLOCKED 일 때만

  const RegistrationResult.pending()
      : status = EntryStatus.PENDING,
        blockReason = null;

  const RegistrationResult.blocked(BlockReason reason)
      : status = EntryStatus.BLOCKED,
        blockReason = reason;

  bool get isBlocked => status == EntryStatus.BLOCKED;
}

/// **목업** — 서버 연동 전 예산 검사를 흉내 낸다.
///
/// 실제 판정은 컨트랙트가 등록 시점에 한다. 서버가 붙으면 이 함수 대신
/// 제출 응답(`status`, `block_reason`)을 [RegistrationResult] 로 바꿔 쓴다.
/// 수입은 예산 검사 대상이 아니라 항상 `PENDING` 이다 (INCOME 은 `budgetId = 0`).
Future<RegistrationResult> simulateExpenseRegistration({
  required String category,
  required int amount,
}) async {
  final budgets = await ApiService().fetchBudgets();
  final matched = budgets.where((b) => b.category == category);
  if (matched.isEmpty) {
    return const RegistrationResult.blocked(BlockReason.BUDGET_NOT_FOUND);
  }
  final budget = matched.first;
  // BUDGET_EXPIRED 는 흉내 내지 않는다 — 목업 예산의 expires_at 이 지난 값이라 전부 차단돼 버린다.
  if (amount > budget.remainingAmount) {
    return const RegistrationResult.blocked(BlockReason.BUDGET_EXCEEDED);
  }
  return const RegistrationResult.pending();
}

/// 등록 결과 다이얼로그. `PENDING` 이면 true(화면을 닫아도 됨), `BLOCKED` 면 false(입력 화면에 남음).
Future<bool> showRegistrationResultDialog(
  BuildContext context, {
  required String kindLabel, // '지출' | '수입'
  required List<(String, String)> rows,
  required RegistrationResult result,
  String? occurredAtNote,
  LinearGradient gradient = AppTheme.primaryGradient,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final blocked = result.isBlocked;
      final accent = blocked ? AppTheme.expense : gradient.colors.first;
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(color: accent.withOpacity(0.12), shape: BoxShape.circle),
                child: Icon(blocked ? Icons.block_rounded : Icons.check_rounded, color: accent, size: 30),
              ),
              const SizedBox(height: 16),
              Text(blocked ? '$kindLabel 등록이 차단되었어요' : '$kindLabel 등록 완료!',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textMain),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: AppTheme.bgPage, borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (label, value) in rows)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Text('$label: ', style: const TextStyle(color: AppTheme.textSub, fontSize: 13)),
                            Expanded(
                              child: Text(value,
                                style: const TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w600, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (blocked) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.expense.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFFCDD2)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('차단 사유: ${result.blockReason!.label}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppTheme.expense),
                      ),
                      const SizedBox(height: 4),
                      Text(result.blockReason!.code,
                        style: const TextStyle(fontSize: 11, color: AppTheme.textSub),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '이 내역은 BLOCKED 로 장부에 기록되어 확정·반려할 수 없어요. '
                        '금액이나 예산 항목을 확인한 뒤 새로 등록해 주세요.',
                        style: TextStyle(fontSize: 12, height: 1.4, color: AppTheme.textMain),
                      ),
                    ],
                  ),
                ),
              ] else
                const Text('PENDING 상태로 등록되었습니다',
                  style: TextStyle(color: AppTheme.textSub, fontSize: 13),
                ),
              if (occurredAtNote != null) ...[
                const SizedBox(height: 8),
                Text(occurredAtNote, style: const TextStyle(color: AppTheme.textSub, fontSize: 11)),
              ],
              const SizedBox(height: 4),
              const Text('※ 서버 연동 전 목업 결과예요',
                style: TextStyle(color: AppTheme.textSub, fontSize: 11),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: GradientButton(
                  onPressed: () => Navigator.pop(ctx),
                  label: blocked ? '입력으로 돌아가기' : '확인',
                  icon: blocked ? Icons.edit_rounded : Icons.check_rounded,
                  gradient: blocked
                      ? const LinearGradient(colors: [AppTheme.expense, Color(0xFFFB7185)])
                      : gradient,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  return !result.isBlocked;
}
