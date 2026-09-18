import 'package:flutter/material.dart';
import '../../../core/app_theme.dart';
import '../../../core/entry_verifier.dart';
import '../../../core/enums.dart';

/// 학생 화면에서 반복되는 뱃지들.
///
/// 배지 색은 **판단을 대신하지 않는다.** 초록은 「등록 이후 바뀌지 않았다」는
/// 뜻이지 「이 지출이 정당하다」는 뜻이 아니다. 문구를 그렇게 읽히게 쓰지 말 것.

/// 검증이 아직 끝나지 않았을 때. 초록도 빨강도 아닌 상태를 명시한다.
///
/// 검증은 온체인 조회와 영수증 내려받기가 끝나야 완성되므로, 그 전까지 배지
/// 자리를 비워 두면 「아무 문제 없음」으로 읽힌다. 목록과 정정 이력이 함께 쓴다.
class VerifyingChip extends StatelessWidget {
  const VerifyingChip({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.divider.withOpacity(0.6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.6),
          ),
          SizedBox(width: 6),
          Text(
            '검증 중',
            style: TextStyle(
              color: AppTheme.textSub,
              fontWeight: FontWeight.bold,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

/// 검증 배지 (S4) — 앱이 직접 재계산한 해시와 온체인 값의 대조 결과.
class VerificationBadge extends StatelessWidget {
  final VerificationStatus status;
  final bool compact;

  const VerificationBadge({super.key, required this.status, this.compact = false});

  @override
  Widget build(BuildContext context) {
    late final Color color;
    late final IconData icon;
    late final String label;

    switch (status) {
      case VerificationStatus.verified:
        color = AppTheme.success;
        icon = Icons.verified_rounded;
        label = compact ? '검증됨' : '검증됨 · 기록 변경 없음';
      case VerificationStatus.tampered:
        color = AppTheme.expense;
        icon = Icons.gpp_bad_rounded;
        label = compact ? '변조 감지' : '변조 감지 · 등록 후 내용이 바뀜';
      // 통과한 것만 보면 이상 없지만 세 단계를 다 못 돌린 상태다.
      // 초록으로 보여주면 확인하지 못한 것을 확인했다고 말하는 셈이 된다.
      case VerificationStatus.partial:
        color = AppTheme.info;
        icon = Icons.pending_outlined;
        label = compact ? '부분 검증' : '부분 검증 · 일부 항목을 대조하지 못함';
      case VerificationStatus.unavailable:
        color = AppTheme.textSub;
        icon = Icons.help_outline_rounded;
        label = compact ? '검증 불가' : '검증 불가 · 대조할 기록 없음';
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: compact ? 4 : 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 12 : 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: compact ? 11 : 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「OCR 불일치 상태로 승인됨」 뱃지 (S7)
///
/// 경고 승인은 **즉시** 학생에게 노출되어야 한다 — 결산에만 집계하면
/// 4개월 뒤에야 보이므로 억지력이 없다 (PRD §285).
class OcrWarningBadge extends StatelessWidget {
  final OcrStatus? ocrStatus;
  final bool categoryWarning;
  final bool compact;

  const OcrWarningBadge({
    super.key,
    required this.ocrStatus,
    this.categoryWarning = false,
    this.compact = false,
  });

  /// 경고로 취급할 상태인지. NO_NUMBER·UNREADABLE 은 정상 경로이므로
  /// 경고 뱃지를 띄우지 않는다 (PRD §6).
  static bool isWarning(OcrStatus? s, bool categoryWarning) =>
      categoryWarning || s == OcrStatus.MISMATCH || s == OcrStatus.DUPLICATE;

  @override
  Widget build(BuildContext context) {
    if (!isWarning(ocrStatus, categoryWarning)) return const SizedBox.shrink();

    final String label;
    if (categoryWarning && ocrStatus == null) {
      label = compact ? '용도 경고' : '용도 불일치 상태로 승인됨';
    } else if (ocrStatus == OcrStatus.DUPLICATE) {
      label = compact ? 'OCR 중복' : 'OCR 중복 상태로 승인됨';
    } else {
      label = compact ? 'OCR 불일치' : 'OCR 불일치 상태로 승인됨';
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: compact ? 4 : 6),
      decoration: BoxDecoration(
        color: AppTheme.pending.withOpacity(0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.pending.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: compact ? 12 : 14, color: AppTheme.pending),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: AppTheme.pending,
              fontWeight: FontWeight.bold,
              fontSize: compact ? 11 : 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// 항목 상태 뱃지 — PENDING / CONFIRMED / REJECTED / BLOCKED
class EntryStatusBadge extends StatelessWidget {
  final EntryStatus status;
  const EntryStatusBadge({super.key, required this.status});

  static Color colorOf(EntryStatus status) {
    switch (status) {
      case EntryStatus.CONFIRMED:
        return AppTheme.success;
      case EntryStatus.PENDING:
        return AppTheme.pending;
      case EntryStatus.REJECTED:
        return AppTheme.expense;
      case EntryStatus.BLOCKED:
        return AppTheme.textMain;
    }
  }

  /// 학생에게 보이는 문구는 내부 상태명보다 풀어 쓴다.
  static String labelOf(EntryStatus status) {
    switch (status) {
      case EntryStatus.CONFIRMED:
        return '확정';
      case EntryStatus.PENDING:
        return '승인대기';
      case EntryStatus.REJECTED:
        return '반려';
      case EntryStatus.BLOCKED:
        return '예산초과 차단';
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = colorOf(status);
    return StatusBadge(label: labelOf(status), color: color);
  }
}

/// 정정 뱃지 (S9) — `정정 (입력오류)`
class CorrectionBadge extends StatelessWidget {
  final CorrectionReason reason;
  const CorrectionBadge({super.key, required this.reason});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.info.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.info.withOpacity(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.edit_note_rounded, size: 14, color: AppTheme.info),
          const SizedBox(width: 4),
          Text(
            '정정 (${reason.label})',
            style: const TextStyle(
              color: AppTheme.info,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「예시 데이터」 배너.
///
/// 서버에 연결되지 않아 개발용 예시 데이터를 보여주고 있을 때 띄운다.
/// **조용히 폴백하면 안 된다** — 보고 있는 것이 실제 원장인지 예시인지
/// 구분되지 않으면 이 앱의 검증 배지는 아무 의미가 없다.
class DemoDataBanner extends StatelessWidget {
  const DemoDataBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.pending.withOpacity(0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.pending.withOpacity(0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.science_outlined, size: 18, color: AppTheme.pending),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '예시 데이터입니다',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.pending,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '서버에 연결되지 않아 개발용 예시를 보여주고 있습니다. '
                  '실제 학생회 회계 내역이 아닙니다.',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.textMain.withOpacity(0.85),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 미확인 항목 카운트 뱃지 (S12) — 아이콘 위에 겹쳐 쓴다.
class UnseenCountBadge extends StatelessWidget {
  final int count;
  final Widget child;

  const UnseenCountBadge({super.key, required this.count, required this.child});

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return child;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          right: -6,
          top: -6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            constraints: const BoxConstraints(minWidth: 20),
            decoration: BoxDecoration(
              color: AppTheme.expense,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white, width: 1.5),
            ),
            child: Text(
              count > 99 ? '99+' : '$count',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
