import '../core/enums.dart';

/// 정정 사유 표시 이름 — `docs/enums.md` 기준. 앱 [CorrectionReason] 에 없는 `OTHER` 는 여기서 붙인다.
/// 결산 화면과 결산 PDF 가 같이 쓴다.
String correctionReasonLabel(String code) {
  for (final r in CorrectionReason.values) {
    if (r.code == code) return r.label;
  }
  return code == 'OTHER' ? '기타' : code;
}

/// 장부 잔액 − 통장 잔액([gap])이 무엇을 뜻하는지. 0 이면 null.
String? balanceGapMeaning(int gap) {
  if (gap == 0) return null;
  return gap > 0 ? '장부에는 있는데 통장에 없는 돈이에요.' : '통장에는 있는데 장부에 없는 돈이에요.';
}

/// 학기 결산 — 백엔드 `SettlementResponse` 매핑 (docs/API.md 「결산」, PRD §4.7).
///
/// **숫자는 기본값으로 메우지 않는다.** 결산에서 0 은 「정말 0건·0원」이라는 뜻이라, 응답이 깨졌을 때
/// `?? 0` 으로 채우면 문제없는 학기처럼 보인다. 형식이 틀리면 [FormatException] 으로 거부한다.
/// 서버가 `null` 을 주는 자리(계좌 스냅샷 없음·편성액 0·개정 0회)만 null 을 허용한다.
class SettlementModel {
  final int termId;
  final int termCode;
  final String termName;

  /// 확정 수입·지출 합계 (정정 반영).
  final int income;
  final int expense;

  /// 장부잔액 = 확정 수입 − 확정 지출.
  final int ledgerBalance;

  /// 가장 최근 계좌 스냅샷의 통장 잔액과 시각. 거래내역을 올린 적 없으면 null.
  final int? bankBalance;
  final DateTime? bankSnapshotAt;

  /// 장부잔액 − 통장 잔액. 스냅샷이 없으면 null. 0 이 아니면 장부와 계좌가 어긋났다.
  final int? balanceGap;

  final List<BudgetExecution> budgets;
  final SettlementMetrics metrics;

  const SettlementModel({
    required this.termId,
    required this.termCode,
    required this.termName,
    required this.income,
    required this.expense,
    required this.ledgerBalance,
    required this.bankBalance,
    required this.bankSnapshotAt,
    required this.balanceGap,
    required this.budgets,
    required this.metrics,
  });

  factory SettlementModel.fromJson(Map<String, dynamic> json) {
    final r = _Reader(json, '결산');
    final budgets = json['budgets'];
    if (budgets is! List) throw const FormatException('결산 응답의 budgets 형식이 올바르지 않아요');
    final metrics = json['metrics'];
    if (metrics is! Map<String, dynamic>) throw const FormatException('결산 응답의 metrics 형식이 올바르지 않아요');
    return SettlementModel(
      termId: r.integer('term_id'),
      termCode: r.integer('term_code'),
      termName: r.text('term_name'),
      income: r.integer('income'),
      expense: r.integer('expense'),
      ledgerBalance: r.integer('ledger_balance'),
      bankBalance: r.maybeInteger('bank_balance'),
      bankSnapshotAt: r.maybeTime('bank_snapshot_at'),
      balanceGap: r.maybeInteger('balance_gap'),
      budgets: [
        for (final b in budgets)
          if (b is Map<String, dynamic>)
            BudgetExecution.fromJson(b)
          else
            throw const FormatException('결산 응답의 예산 항목 형식이 올바르지 않아요'),
      ],
      metrics: SettlementMetrics.fromJson(metrics),
    );
  }
}

/// 예산 항목별 집행. 체인에 발행된 예산만 온다.
class BudgetExecution {
  final int budgetId;
  final String category;

  /// v1 편성액과 최신 편성액. 다르면 개정(증액)된 예산이다.
  final int initialAmount;
  final int plannedAmount;
  final int version;

  /// 확정 지출과 남은 금액 (DB 기준).
  final int spent;
  final int remaining;

  /// 확정 지출 / 최신 편성액. 편성액이 0 이면 null.
  final double? executionRate;

  const BudgetExecution({
    required this.budgetId,
    required this.category,
    required this.initialAmount,
    required this.plannedAmount,
    required this.version,
    required this.spent,
    required this.remaining,
    required this.executionRate,
  });

  bool get revised => version > 1;

  factory BudgetExecution.fromJson(Map<String, dynamic> json) {
    final r = _Reader(json, '예산 집행');
    return BudgetExecution(
      budgetId: r.integer('budget_id'),
      category: r.text('category'),
      initialAmount: r.integer('initial_amount'),
      plannedAmount: r.integer('planned_amount'),
      version: r.integer('version'),
      spent: r.integer('spent'),
      remaining: r.integer('remaining'),
      executionRate: r.maybeRate('execution_rate'),
    );
  }
}

/// PRD §4.7 메타지표. 이의 제기 건수는 v0.13 범위 밖이라 서버가 주지 않는다.
class SettlementMetrics {
  /// OCR 경고(MISMATCH·DUPLICATE·UNREADABLE) 상태로 확정된 건수.
  final int ocrWarningApproved;

  /// 용도 불일치 경고 상태로 확정된 건수.
  final int categoryWarningApproved;

  /// 확정된 정정 건수와 사유별 분포 (서버가 5종을 모두 준다, 없으면 0).
  final int corrections;
  final Map<String, int> correctionsByReason;

  /// 감사일 30일 전부터 감사일까지 등록된 확정 정정 건수와 그 감사일.
  final int correctionsBeforeAudit;
  final DateTime auditAt;

  /// 승인된 예산 증액 횟수, 그중 차단 지출을 근거로 한 횟수, 그 비율(증액 0회면 null).
  final int budgetRevisions;
  final int budgetRevisionsAfterBlock;
  final double? revisionAfterBlockRate;

  const SettlementMetrics({
    required this.ocrWarningApproved,
    required this.categoryWarningApproved,
    required this.corrections,
    required this.correctionsByReason,
    required this.correctionsBeforeAudit,
    required this.auditAt,
    required this.budgetRevisions,
    required this.budgetRevisionsAfterBlock,
    required this.revisionAfterBlockRate,
  });

  factory SettlementMetrics.fromJson(Map<String, dynamic> json) {
    final r = _Reader(json, '메타지표');
    final byReason = json['corrections_by_reason'];
    if (byReason is! Map) throw const FormatException('메타지표의 corrections_by_reason 형식이 올바르지 않아요');
    final reasons = <String, int>{};
    for (final e in byReason.entries) {
      final key = e.key, value = e.value;
      if (key is! String || value is! int) throw const FormatException('정정 사유별 건수 형식이 올바르지 않아요');
      reasons[key] = value;
    }
    return SettlementMetrics(
      ocrWarningApproved: r.integer('ocr_warning_approved'),
      categoryWarningApproved: r.integer('category_warning_approved'),
      corrections: r.integer('corrections'),
      correctionsByReason: reasons,
      correctionsBeforeAudit: r.integer('corrections_before_audit'),
      auditAt: r.time('audit_at'),
      budgetRevisions: r.integer('budget_revisions'),
      budgetRevisionsAfterBlock: r.integer('budget_revisions_after_block'),
      revisionAfterBlockRate: r.maybeRate('revision_after_block_rate'),
    );
  }
}

/// 필드를 타입대로 꺼내고, 틀리면 어느 필드인지 적어 [FormatException] 을 던진다.
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

  String text(String key) {
    final v = json[key];
    return v is String ? v : _bad(key);
  }

  DateTime time(String key) {
    final v = json[key];
    // 표기(Z / +09:00)는 DB 설정에 따라 다르다 — 문자열이 아니라 시각으로 파싱한다 (API.md)
    final t = v is String ? DateTime.tryParse(v) : null;
    return t ?? _bad(key);
  }

  DateTime? maybeTime(String key) => json[key] == null ? null : time(key);

  /// 비율. JSON 에서는 0.5 처럼 오지만 0 이나 1 은 정수로 올 수 있다.
  double? maybeRate(String key) {
    final v = json[key];
    if (v == null) return null;
    return v is num ? v.toDouble() : _bad(key);
  }
}
