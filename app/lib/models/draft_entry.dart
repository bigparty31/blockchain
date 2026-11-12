import '../core/enums.dart';
import '../services/entry_registration_service.dart';

/// `GET /entries/drafts` 의 한 건 — 아직 체인에 올리지 않은 **초안**.
///
/// 초안은 `status` 가 null 이다. [EntryModel] 은 status 없는 응답을 계약 위반으로 던지게 해 두었다
/// (초안을 「승인대기」로 바꿔 보이지 않으려고). 그래서 초안은 이 모델로 따로 읽는다.
class DraftEntry {
  final int id;
  final int termId;
  final EntryKind kind;
  final int amount;
  final String counterparty;
  final String purpose;
  final int? budgetId;
  final int occurredAt;
  final String? receiptHash;
  final String? receiptPath;
  final int? correctsEntryId;
  final CorrectionReason? correctionReason;

  const DraftEntry({
    required this.id,
    required this.termId,
    required this.kind,
    required this.amount,
    required this.counterparty,
    required this.purpose,
    required this.occurredAt,
    this.budgetId,
    this.receiptHash,
    this.receiptPath,
    this.correctsEntryId,
    this.correctionReason,
  });

  /// status 가 있으면 초안이 아니다 — [FormatException].
  factory DraftEntry.fromJson(Map<String, dynamic> json) {
    if (json['status'] != null) {
      throw FormatException('초안이 아닌 항목(status=${json['status']})');
    }
    return DraftEntry(
      id: json['id'] as int,
      termId: json['term_id'] as int,
      kind: EntryKind.fromCode(json['kind'] as String),
      amount: json['amount'] as int,
      counterparty: json['counterparty'] as String? ?? '',
      purpose: json['purpose'] as String? ?? '',
      budgetId: json['budget_id'] as int?,
      occurredAt: json['occurred_at'] as int,
      receiptHash: json['receipt_hash'] as String?,
      receiptPath: json['receipt_path'] as String?,
      correctsEntryId: json['corrects_entry_id'] as int?,
      correctionReason:
          json['correction_reason'] == null ? null : CorrectionReason.fromCode(json['correction_reason'] as String),
    );
  }

  /// 이어서 제출할 때 서명·저장에 쓰는 값. 해시는 화면이 만드는 초안과 같게 소문자로 맞춘다
  /// (다르면 「바뀌지 않았다」를 알아보지 못해 초안 번호를 다시 쓰지 못한다).
  EntryDraft toEntryDraft() => EntryDraft(
        kind: kind,
        termId: termId,
        amount: amount,
        counterparty: counterparty,
        purpose: purpose,
        budgetId: budgetId,
        occurredAt: occurredAt,
        receiptHash: receiptHash?.toLowerCase(),
        receiptPath: receiptPath,
        correctsEntryId: correctsEntryId,
        correctionReason: correctionReason,
      );
}
