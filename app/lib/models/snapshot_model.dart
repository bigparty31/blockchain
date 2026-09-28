/// PRD §8 Snapshot 모델 — 통장 잔액 스냅샷 (S11)
///
/// 계좌 대조는 **한 방향이다.** 오픈뱅킹 조회 결과는 원장과 대조해
/// 미등록 지출을 드러내는 용도로만 쓰고, 원장에 자동 반영하지 않는다 —
/// 자동 반영하면 대조 대상 자체가 사라진다.
class SnapshotModel {
  final int id;
  final int termId;
  final int bankBalance;
  final int snapshotAt;
  final String? txHash;

  /// 계좌에는 있는데 원장에 없는 거래들. 미등록 지출 후보다.
  final List<UnrecordedTransaction> unrecorded;

  SnapshotModel({
    required this.id,
    required this.termId,
    required this.bankBalance,
    required this.snapshotAt,
    this.txHash,
    this.unrecorded = const [],
  });

  /// 차액 = 장부잔액 − 계좌 조회 잔액 (PRD §7.4)
  int diffAgainst(int ledgerBalance) => ledgerBalance - bankBalance;

  factory SnapshotModel.fromJson(Map<String, dynamic> json) {
    return SnapshotModel(
      id: json['id'] ?? 0,
      termId: json['term_id'] ?? 1,
      bankBalance: json['bank_balance'] ?? 0,
      snapshotAt: json['snapshot_at'] ?? 0,
      txHash: json['tx_hash'],
      unrecorded: (json['unrecorded'] as List<dynamic>? ?? [])
          .map((e) => UnrecordedTransaction.fromJson(e))
          .toList(),
    );
  }
}

/// 원장에 등록되지 않은 계좌 거래 한 건.
class UnrecordedTransaction {
  final int amount;
  final String counterparty;
  final int occurredAt;

  UnrecordedTransaction({
    required this.amount,
    required this.counterparty,
    required this.occurredAt,
  });

  factory UnrecordedTransaction.fromJson(Map<String, dynamic> json) {
    return UnrecordedTransaction(
      amount: json['amount'] ?? 0,
      counterparty: json['counterparty'] ?? '',
      occurredAt: json['occurred_at'] ?? 0,
    );
  }
}
