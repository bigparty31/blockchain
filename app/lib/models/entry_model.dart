import '../core/enums.dart';

/// 백엔드 EntryResponse 스키마 1:1 매핑
class EntryModel {
  final int id;
  final int termId;
  final EntryKind kind;
  final int amount;
  final String counterparty;
  final String purpose;
  final int? budgetId;
  final int occurredAt;
  final String? receiptPath;
  final String? receiptHash;
  final String metaHash;
  final int? ocrAmount;
  final String? ocrApprovalNo;
  final int? ocrPaidAt;
  final OcrStatus? ocrStatus;
  final bool categoryWarning;
  final String? warningAckReason;
  final EntryStatus status;
  final int createdBy;
  final int? approvedBy;
  final String? rejectReason;
  final String? txPending;
  final String? txConfirm;

  /// 확정 트랜잭션이 담긴 블록 번호 (S10).
  ///
  /// **백엔드에 아직 `block_number` 필드가 없어 현재는 항상 null 이다.**
  /// 필드가 생기면 응답에 실려 오는 즉시 상세 화면에 표시된다 — 앱 쪽은 손댈 것이 없다.
  final int? blockNumber;

  final int? correctsEntryId;
  final CorrectionReason? correctionReason;

  EntryModel({
    required this.id,
    required this.termId,
    required this.kind,
    required this.amount,
    required this.counterparty,
    required this.purpose,
    this.budgetId,
    required this.occurredAt,
    this.receiptPath,
    this.receiptHash,
    required this.metaHash,
    this.ocrAmount,
    this.ocrApprovalNo,
    this.ocrPaidAt,
    this.ocrStatus,
    this.categoryWarning = false,
    this.warningAckReason,
    required this.status,
    required this.createdBy,
    this.approvedBy,
    this.rejectReason,
    this.txPending,
    this.txConfirm,
    this.blockNumber,
    this.correctsEntryId,
    this.correctionReason,
  });

  factory EntryModel.fromJson(Map<String, dynamic> json) {
    return EntryModel(
      id: json['id'] ?? 0,
      termId: json['term_id'] ?? 1,
      kind: EntryKind.fromCode(json['kind'] ?? 'EXPENSE'),
      amount: json['amount'] ?? 0,
      counterparty: json['counterparty'] ?? '',
      purpose: json['purpose'] ?? '',
      budgetId: json['budget_id'],
      occurredAt: json['occurred_at'] ?? 0,
      receiptPath: json['receipt_path'],
      receiptHash: json['receipt_hash'],
      metaHash: json['meta_hash'] ?? '',
      ocrAmount: json['ocr_amount'],
      ocrApprovalNo: json['ocr_approval_no'],
      ocrPaidAt: json['ocr_paid_at'],
      ocrStatus: json['ocr_status'] != null ? OcrStatus.fromCode(json['ocr_status']) : null,
      categoryWarning: json['category_warning'] ?? false,
      warningAckReason: json['warning_ack_reason'],
      status: EntryStatus.fromCode(json['status'] ?? 'PENDING'),
      createdBy: json['created_by'] ?? 0,
      approvedBy: json['approved_by'],
      rejectReason: json['reject_reason'],
      txPending: json['tx_pending'],
      txConfirm: json['tx_confirm'],
      blockNumber: json['block_number'],
      correctsEntryId: json['corrects_entry_id'],
      correctionReason: json['correction_reason'] != null
          ? CorrectionReason.fromCode(json['correction_reason'])
          : null,
    );
  }

  /// 백엔드 POST /entries 전송용 JSON 변환 (EntryCreate 스키마 규격)
  Map<String, dynamic> toCreateJson() {
    return {
      'term_id': termId,
      'kind': kind.code,
      'amount': amount,
      'counterparty': counterparty,
      'purpose': purpose,
      if (budgetId != null) 'budget_id': budgetId,
      'occurred_at': occurredAt,
      if (receiptHash != null) 'receipt_hash': receiptHash,
      if (correctsEntryId != null) 'corrects_entry_id': correctsEntryId,
      if (correctionReason != null) 'correction_reason': correctionReason!.code,
    };
  }
}
