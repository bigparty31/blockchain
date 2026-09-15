import '../core/enums.dart';
import '../models/entry_model.dart';

/// 정정 이력 병합 (S9) 및 합계 산출 (PRD §7.4)
///
/// 확정된 기록은 **수정하지 않는다.** 잘못된 항목은 고치는 대신
/// `corrects_entry_id` 로 원본을 참조하는 새 항목을 등록한다.
/// 따라서 화면에는 원본이 그대로 남고, 그 아래에 정정이 붙는다:
///
///   50,000원 → 30,000원 정정 (입력오류)
///
/// **합계에는 최종값만 반영한다.** 원본과 정정을 둘 다 더하면 이중 계상된다.
class EntryChain {
  /// 정정의 출발점이 된 원본 항목.
  final EntryModel original;

  /// 원본을 참조하는 정정 항목들. 등록 순서(id 오름차순).
  final List<EntryModel> corrections;

  const EntryChain({required this.original, this.corrections = const []});

  bool get hasCorrection => corrections.isNotEmpty;

  /// 화면 대표로 쓸 항목 — 가장 마지막 정정, 없으면 원본.
  EntryModel get latest => corrections.isNotEmpty ? corrections.last : original;

  /// 합계에 반영할 항목.
  ///
  /// 확정(CONFIRMED)된 것만 값으로 인정한다. 대기 중인 정정은 아직
  /// 승인 전이므로 원본 값이 유효하다 — PENDING 을 미리 반영하면
  /// 승인되지 않은 수치가 학생 화면 합계에 섞인다.
  EntryModel? get effective {
    for (final c in corrections.reversed) {
      if (c.status == EntryStatus.CONFIRMED) return c;
    }
    return original.status == EntryStatus.CONFIRMED ? original : null;
  }

  /// 합계에 반영되는 금액. 확정된 것이 없으면 0.
  int get effectiveAmount => effective?.amount ?? 0;

  /// `50,000원 → 30,000원` 형태로 보여줄 때 필요한 이전 금액.
  /// 정정이 없으면 null.
  int? get supersededAmount => hasCorrection ? original.amount : null;

  /// 가장 마지막 정정의 사유. 정정이 없으면 null.
  CorrectionReason? get latestReason =>
      corrections.isNotEmpty ? corrections.last.correctionReason : null;
}

/// 항목 목록을 정정 체인으로 묶고, 합계를 낸다.
class EntryMerge {
  EntryMerge._();

  /// 평평한 항목 목록을 정정 체인 목록으로 접는다.
  ///
  /// 정정의 정정(A ← B ← C)도 하나의 체인으로 이어 붙인다.
  /// 원본이 목록에 없는 고아 정정은 그 자체를 원본으로 취급한다
  /// (기간 필터로 원본이 잘려나간 경우 화면에서 사라지면 안 된다).
  static List<EntryChain> fold(List<EntryModel> entries) {
    final byId = {for (final e in entries) e.id: e};

    // 각 항목이 어떤 정정들에게 참조되는지 모은다.
    final correctionsOf = <int, List<EntryModel>>{};
    final isCorrection = <int>{};

    for (final e in entries) {
      final target = e.correctsEntryId;
      if (target != null && byId.containsKey(target)) {
        correctionsOf.putIfAbsent(target, () => []).add(e);
        isCorrection.add(e.id);
      }
    }

    // 정정이 아닌 항목들이 각 체인의 머리가 된다.
    final heads = entries.where((e) => !isCorrection.contains(e.id)).toList()
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

    return heads.map((head) {
      final chain = <EntryModel>[];
      var cursor = head;

      // 정정의 정정을 끝까지 따라간다.
      while (true) {
        final next = correctionsOf[cursor.id];
        if (next == null || next.isEmpty) break;
        next.sort((a, b) => a.id.compareTo(b.id));
        chain.addAll(next);
        cursor = next.last;
      }

      return EntryChain(original: head, corrections: chain);
    }).toList();
  }

  /// 확정 수입 합계 — 정정 반영 후 최종값 기준.
  static int totalIncome(List<EntryChain> chains) => _sumOf(chains, EntryKind.INCOME);

  /// 확정 지출 합계 — 정정 반영 후 최종값 기준.
  static int totalExpense(List<EntryChain> chains) => _sumOf(chains, EntryKind.EXPENSE);

  /// 장부 잔액 = Σ확정수입 − Σ확정지출 (PRD §7.4)
  static int ledgerBalance(List<EntryChain> chains) =>
      totalIncome(chains) - totalExpense(chains);

  static int _sumOf(List<EntryChain> chains, EntryKind kind) {
    var sum = 0;
    for (final c in chains) {
      final e = c.effective;
      if (e != null && e.kind == kind) sum += e.amount;
    }
    return sum;
  }

  /// 아직 확인하지 않은 신규 항목 수 (S12).
  /// [lastSeenEntryId] 보다 id 가 큰 항목의 개수.
  static int unseenCount(List<EntryModel> entries, int lastSeenEntryId) =>
      entries.where((e) => e.id > lastSeenEntryId).length;
}
