/// 계좌 대조 — 백엔드 `ReconciliationReport`·`SnapshotItem` 매핑 (docs/API.md 「계좌 대조」, PRD §4.6).
///
/// 결산 모델과 같은 원칙: **숫자는 기본값으로 메우지 않는다.** 미등록 0건은 「깨끗하다」는 뜻이라,
/// 응답이 깨졌을 때 `?? 0` 으로 채우면 문제없는 계좌처럼 보인다. 형식이 틀리면 [FormatException].
/// 서버가 `null` 을 주는 자리(이전 스냅샷의 summary·status, 짝 없는 entry_id, 시각 없는 거래)만 null 을 허용한다.
library;

/// 은행 거래 1줄의 대조 결과.
enum BankRowStatus {
  /// 확정 원장 항목과 짝.
  matched('MATCHED'),

  /// 승인 대기 항목과 짝 — 확정 전이라 판단 보류.
  matchedPending('MATCHED_PENDING'),

  /// 계좌에는 있는데 원장에 없음 — 미등록 의심.
  unregistered('UNREGISTERED');

  final String code;
  const BankRowStatus(this.code);

  static BankRowStatus parse(String code) {
    for (final s in values) {
      if (s.code == code) return s;
    }
    throw FormatException('알 수 없는 대조 상태: $code');
  }
}

/// 업로드 목록의 한 줄 (`GET /bank/snapshots?term_id=`).
class BankSnapshotItem {
  final int id;
  final int termId;
  final String? fileHash;
  final int bankBalance;
  final DateTime snapshotAt;
  final int? uploadedBy;

  /// 같은 학기에 더 최근 업로드가 있다. 대조 결과는 최신 스냅샷에서 본다.
  final bool superseded;

  const BankSnapshotItem({
    required this.id,
    required this.termId,
    required this.fileHash,
    required this.bankBalance,
    required this.snapshotAt,
    required this.uploadedBy,
    required this.superseded,
  });

  factory BankSnapshotItem.fromJson(Map<String, dynamic> json) {
    final r = _Reader(json, '업로드 목록');
    return BankSnapshotItem(
      id: r.integer('id'),
      termId: r.integer('term_id'),
      fileHash: r.maybeText('file_hash'),
      bankBalance: r.integer('bank_balance'),
      snapshotAt: r.time('snapshot_at'),
      uploadedBy: r.maybeInteger('uploaded_by'),
      superseded: r.boolean('superseded'),
    );
  }
}

/// 대조 결과 (`POST /bank/snapshots`, `/rematch`, `GET /bank/snapshots/{id}`).
class BankReconcileReport {
  final int snapshotId;
  final int termId;
  final String? fileHash;

  /// 시간순 마지막 거래의 거래후잔액. 결산의 차액이 최신 스냅샷의 이 값을 쓴다.
  final int bankBalance;
  final DateTime snapshotAt;

  /// 파일에 들어 있는 거래 날짜 범위 (`YYYY-MM-DD`).
  final String periodStart;
  final String periodEnd;

  final bool superseded;

  /// 이전 스냅샷(`superseded`)이면 null — 거래 줄만 보인다.
  final BankReconcileSummary? summary;

  final List<BankTransaction> transactions;

  /// 원장엔 확정돼 있는데 이 파일(기간 안)에 대응 거래가 없는 항목 — 가짜 등록 의심.
  final List<UnbackedEntry> unbackedEntries;

  const BankReconcileReport({
    required this.snapshotId,
    required this.termId,
    required this.fileHash,
    required this.bankBalance,
    required this.snapshotAt,
    required this.periodStart,
    required this.periodEnd,
    required this.superseded,
    required this.summary,
    required this.transactions,
    required this.unbackedEntries,
  });

  /// [status] 인 거래 줄만.
  List<BankTransaction> rows(BankRowStatus status) => [
        for (final t in transactions)
          if (t.status == status) t,
      ];

  factory BankReconcileReport.fromJson(Map<String, dynamic> json) {
    final r = _Reader(json, '대조 결과');
    final superseded = r.boolean('superseded');
    final summaryJson = json['summary'];
    final BankReconcileSummary? summary;
    if (summaryJson == null) {
      // 최신 스냅샷인데 요약이 없으면 「미등록 0건」처럼 보이게 두지 않는다
      if (!superseded) throw const FormatException('최신 대조 결과에 summary 가 없어요');
      summary = null;
    } else if (summaryJson is Map<String, dynamic>) {
      summary = BankReconcileSummary.fromJson(summaryJson);
    } else {
      throw const FormatException('대조 결과의 summary 형식이 올바르지 않아요');
    }
    return BankReconcileReport(
      snapshotId: r.integer('snapshot_id'),
      termId: r.integer('term_id'),
      fileHash: r.maybeText('file_hash'),
      bankBalance: r.integer('bank_balance'),
      snapshotAt: r.time('snapshot_at'),
      periodStart: r.text('period_start'),
      periodEnd: r.text('period_end'),
      superseded: superseded,
      summary: summary,
      transactions: r.list('transactions', BankTransaction.fromJson),
      unbackedEntries: r.list('unbacked_entries', UnbackedEntry.fromJson),
    );
  }
}

class BankReconcileSummary {
  final int total;
  final int matched;
  final int matchedPending;
  final int unregistered;

  /// 미등록 출금 합계 — 장부에 없이 나간 돈.
  final int unregisteredOutAmount;

  /// 미등록 입금 합계 — 장부에 없이 들어온 돈.
  final int unregisteredInAmount;

  /// 대응 거래 없는 확정 원장 건수.
  final int unbacked;

  const BankReconcileSummary({
    required this.total,
    required this.matched,
    required this.matchedPending,
    required this.unregistered,
    required this.unregisteredOutAmount,
    required this.unregisteredInAmount,
    required this.unbacked,
  });

  /// 장부와 계좌가 어긋난 곳이 하나도 없다. 승인 대기와의 짝은 판단 보류라 따로 본다.
  bool get clean => unregistered == 0 && unbacked == 0;

  factory BankReconcileSummary.fromJson(Map<String, dynamic> json) {
    final r = _Reader(json, '대조 요약');
    return BankReconcileSummary(
      total: r.integer('total'),
      matched: r.integer('matched'),
      matchedPending: r.integer('matched_pending'),
      unregistered: r.integer('unregistered'),
      unregisteredOutAmount: r.integer('unregistered_out_amount'),
      unregisteredInAmount: r.integer('unregistered_in_amount'),
      unbacked: r.integer('unbacked'),
    );
  }
}

class BankTransaction {
  final int id;

  /// `YYYY-MM-DD` (KST). 시각은 은행 파일에 없을 수 있다.
  final String tranDate;
  final String? tranTime;

  /// 적요 + 거래점 (예: `카드출금 OO문구점`).
  final String description;

  /// 출금이면 true (`OUT`), 입금이면 false (`IN`).
  final bool outgoing;
  final int amount;
  final int balanceAfter;

  /// 이전 스냅샷이면 null.
  final BankRowStatus? status;

  /// 짝이 된 원장 항목 ID.
  final int? entryId;

  const BankTransaction({
    required this.id,
    required this.tranDate,
    required this.tranTime,
    required this.description,
    required this.outgoing,
    required this.amount,
    required this.balanceAfter,
    required this.status,
    required this.entryId,
  });

  factory BankTransaction.fromJson(Map<String, dynamic> json) {
    final r = _Reader(json, '거래 줄');
    final direction = r.text('direction');
    if (direction != 'IN' && direction != 'OUT') throw FormatException('알 수 없는 거래 방향: $direction');
    final status = r.maybeText('status');
    return BankTransaction(
      id: r.integer('id'),
      tranDate: r.text('tran_date'),
      tranTime: r.maybeText('tran_time'),
      description: r.text('description'),
      outgoing: direction == 'OUT',
      amount: r.integer('amount'),
      balanceAfter: r.integer('balance_after'),
      status: status == null ? null : BankRowStatus.parse(status),
      entryId: r.maybeInteger('entry_id'),
    );
  }
}

/// 원장엔 확정돼 있는데 파일에 대응 거래가 없는 항목.
class UnbackedEntry {
  final int entryId;

  /// `INCOME` 또는 `EXPENSE`.
  final String kind;

  /// 정정을 반영한 순금액.
  final int amount;
  final String date;
  final String counterparty;
  final String purpose;

  const UnbackedEntry({
    required this.entryId,
    required this.kind,
    required this.amount,
    required this.date,
    required this.counterparty,
    required this.purpose,
  });

  bool get expense => kind == 'EXPENSE';

  factory UnbackedEntry.fromJson(Map<String, dynamic> json) {
    final r = _Reader(json, '대응 거래 없는 원장');
    final kind = r.text('kind');
    if (kind != 'INCOME' && kind != 'EXPENSE') throw FormatException('알 수 없는 항목 종류: $kind');
    return UnbackedEntry(
      entryId: r.integer('entry_id'),
      kind: kind,
      amount: r.integer('amount'),
      date: r.text('date'),
      counterparty: r.text('counterparty'),
      purpose: r.text('purpose'),
    );
  }
}

/// 필드를 타입대로 꺼내고, 틀리면 어느 필드인지 적어 [FormatException] 을 던진다.
/// (`settlement_model.dart` 의 것과 같은 방식. 두 PR 이 따로 리뷰 중이라 아직 합치지 않았다.)
class _Reader {
  final Map<String, dynamic> json;
  final String what;
  const _Reader(this.json, this.what);

  Never _bad(String key) => throw FormatException('$what 응답의 $key 형식이 올바르지 않아요');

  int integer(String key) {
    final v = json[key];
    return v is int ? v : _bad(key);
  }

  int? maybeInteger(String key) {
    final v = json[key];
    if (v == null) return null;
    return v is int ? v : _bad(key);
  }

  bool boolean(String key) {
    final v = json[key];
    return v is bool ? v : _bad(key);
  }

  String text(String key) {
    final v = json[key];
    return v is String ? v : _bad(key);
  }

  String? maybeText(String key) {
    final v = json[key];
    if (v == null) return null;
    return v is String ? v : _bad(key);
  }

  DateTime time(String key) {
    final v = json[key];
    // 표기(Z / +09:00)는 DB 설정에 따라 다르다 — 시각으로 파싱한다 (API.md)
    final t = v is String ? DateTime.tryParse(v) : null;
    return t ?? _bad(key);
  }

  List<T> list<T>(String key, T Function(Map<String, dynamic>) parse) {
    final v = json[key];
    if (v is! List) _bad(key);
    final out = <T>[];
    for (final item in v) {
      if (item is! Map<String, dynamic>) _bad(key);
      out.add(parse(item));
    }
    return out;
  }
}
