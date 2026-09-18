import '../core/enums.dart';
import '../models/entry_model.dart';

/// 정정 이력 병합 (S9) 및 합계 산출 (PRD §7.4)
///
/// 확정된 기록은 **수정하지 않는다.** 잘못된 항목은 고치는 대신
/// `corrects_entry_id` 로 원본을 참조하는 새 항목을 등록한다.
///
/// **정정 항목의 `amount` 는 새 총액이 아니라 증감분이다.**
/// 50,000원을 30,000원으로 바로잡으면 정정 항목의 금액은 `-20,000` 이다.
/// `HASHING.md` §5 가 "음수는 `corrects_entry_id` 가 있을 때만 허용" 이라고
/// 못박은 것이 이 뜻이며, 샘플 3(`amount: -20000`, `purpose: "입력 오류 정정"`)이
/// 같은 형태다.
///
/// 덕분에 합계는 **확정 항목을 그냥 다 더하면 된다** — 원본 50,000 과 정정
/// -20,000 을 더하면 자연히 최종값 30,000 이 나온다. 원본을 빼거나 골라낼
/// 필요가 없다.
///
/// > 김경윤 확인 대기 — 정정 항목이 증감분이 아니라 새 총액을 담는다면
/// > [EntryChain.finalAmount] 와 [EntryMerge._sumOf] 를 함께 바꿔야 한다.
class EntryChain {
  /// 정정의 출발점이 된 원본 항목.
  final EntryModel original;

  /// 원본을 참조하는 정정 항목들. 등록 순서(id 오름차순).
  final List<EntryModel> corrections;

  const EntryChain({required this.original, this.corrections = const []});

  bool get hasCorrection => corrections.isNotEmpty;

  /// 화면 대표로 쓸 항목 — 가장 마지막 정정, 없으면 원본.
  ///
  /// 정정 항목은 금액이 증감분이므로 **금액 표시에는 쓰지 말 것.**
  /// 상태·일시 등을 볼 때만 쓴다.
  EntryModel get latest => corrections.isNotEmpty ? corrections.last : original;

  /// 확정된 정정만 모은다. 대기 중인 정정은 아직 승인 전이라
  /// 금액에 반영하지 않는다.
  List<EntryModel> get confirmedCorrections =>
      corrections.where((c) => c.status == EntryStatus.CONFIRMED).toList();

  /// 원본이 확정된 항목인지.
  bool get isConfirmed => original.status == EntryStatus.CONFIRMED;

  /// 정정을 모두 반영한 최종 금액.
  ///
  /// `원본 + Σ확정정정`. 원본이 확정되지 않았으면 원본 금액을 그대로 쓴다
  /// (대기 중인 항목도 금액은 보여줘야 한다).
  int get finalAmount {
    var sum = original.amount;
    for (final c in confirmedCorrections) {
      sum += c.amount;
    }
    return sum;
  }

  /// 합계에 실제로 반영되는 금액. 확정되지 않았으면 0.
  int get effectiveAmount => isConfirmed ? finalAmount : 0;

  /// `50,000원 → 30,000원` 의 화살표 앞 금액. 정정이 없으면 null.
  int? get supersededAmount => hasCorrection ? original.amount : null;

  /// 가장 마지막 정정의 사유. 정정이 없으면 null.
  CorrectionReason? get latestReason =>
      corrections.isNotEmpty ? corrections.last.correctionReason : null;

  /// 화면에 쓸 대표 상태. 정정이 있으면 마지막 정정의 상태를 따른다.
  EntryStatus get displayStatus => latest.status;
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

    final correctionsOf = <int, List<EntryModel>>{};
    final isCorrection = <int>{};

    for (final e in entries) {
      final target = e.correctsEntryId;
      // id 0 은 「없음」으로 예약되어 있다 (HASHING.md §2.1).
      if (target != null && target != 0 && byId.containsKey(target)) {
        correctionsOf.putIfAbsent(target, () => []).add(e);
        isCorrection.add(e.id);
      }
    }

    final heads = entries.where((e) => !isCorrection.contains(e.id)).toList()
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

    return heads.map((head) {
      final chain = <EntryModel>[];
      var cursor = head;

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

  /// 확정 수입 합계.
  ///
  /// 정정이 증감분이므로 **확정 항목을 전부 더하면 된다.**
  /// 원본을 골라내거나 빼는 처리가 필요 없다.
  static int totalIncome(List<EntryModel> entries) =>
      _sumOf(entries, EntryKind.INCOME);

  /// 확정 지출 합계.
  static int totalExpense(List<EntryModel> entries) =>
      _sumOf(entries, EntryKind.EXPENSE);

  /// 장부 잔액 = Σ확정수입 − Σ확정지출 (PRD §7.4)
  ///
  /// 서버가 내려준 합계를 그대로 쓰지 않고 항목에서 직접 계산한다.
  /// 서버 값을 믿으면, 서버가 숫자를 바꿨을 때 학생이 알 방법이 없다.
  static int ledgerBalance(List<EntryModel> entries) =>
      totalIncome(entries) - totalExpense(entries);

  /// 확정(CONFIRMED)된 항목만 더한다.
  ///
  /// 대기 건을 미리 반영하면 승인되지 않은 수치가 학생 화면 합계에 섞인다.
  static int _sumOf(List<EntryModel> entries, EntryKind kind) {
    var sum = 0;
    for (final e in entries) {
      if (e.status == EntryStatus.CONFIRMED && e.kind == kind) {
        sum += e.amount;
      }
    }
    return sum;
  }

  /// 아직 확인하지 않은 신규 항목 수 (S12).
  static int unseenCount(List<EntryModel> entries, int lastSeenEntryId) =>
      entries.where((e) => e.id > lastSeenEntryId).length;
}
