import '../core/enums.dart';

/// 백엔드 EntryResponse 스키마 1:1 매핑
class EntryModel {
  final int id;

  /// DB 의 학기 id (1, 2…). **온체인 학기 코드가 아니다** — [termCode] 를 볼 것.
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

  /// 온체인 학기 코드 `YYYYS` (예: 20262 = 2026년 2학기).
  ///
  /// **[termId] 와 다른 값이다.** 체인의 `Entry.term` 은 학기 코드이고 DB 의
  /// `term_id` 는 1부터 매긴 행 번호라, 둘을 그냥 비교하면 `1 != 20262` 로
  /// **모든 항목이 변조 판정된다** (IAccountingLedger: "DB 의 Term.id 가 아니다").
  ///
  /// 서버(`develop` 의 `GET /entries`)는 `term_code` 를 실어 준다. 옛 서버·시연용 더미처럼 없으면 null 이고,
  /// 그때 학기 대조는 「모름」으로 남는다 — 승인·반려 서명은 학기 코드가 없으면 서명 전에 멈춘다.
  final int? termCode;

  /// 등록자 지갑 주소 (#65) — 서버가 체인에서 읽은 registrant 다. **체인을 못 읽었거나 기록이 없으면 null 이다**
  /// (서버가 DB 등록자 지갑으로 메우지 않는다 — 앱이 체인 값으로 오인하지 않게). 옛 서버도 null.
  /// 검증용 체인 값으로 쓰지 않는다(그건 `/entries/{id}/onchain`). 서명의 `entryCommit` 에만 쓴다.
  /// null 이면 승인·반려는 `GET /users/wallets` 로 찾되, 주소가 정확히 하나일 때만 서명한다.
  final String? registrant;

  final int? correctsEntryId;
  final CorrectionReason? correctionReason;

  EntryModel({
    required this.id,
    required this.termId,
    this.termCode,
    this.registrant,
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
      termCode: json['term_code'],
      registrant: json['registrant'] is String && (json['registrant'] as String).isNotEmpty ? json['registrant'] as String : null,
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
      status: _requireStatus(json['status']),
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

  /// `status` 가 없으면 **채우지 않고 던진다.**
  ///
  /// 예전에는 `?? 'PENDING'` 으로 떨어뜨렸는데, `status` 가 없다는 것은 총무가
  /// 저장만 하고 체인에 올리지 않은 **초안**이라는 뜻이다. 그것을 「승인대기」로
  /// 바꿔 놓으면 아직 아무 데도 올라가지 않아 검증할 대상조차 없는 건이
  /// 학생 목록에 섞여 보인다 (스토리보드 3 「화면 전체 규칙」 — status IS NULL 제외).
  ///
  /// 초안은 애초에 학생 앱에 내려오면 안 되는 값이라, 조용히 메우는 대신
  /// 계약 위반으로 드러낸다. 목록 조회는 파싱 전에 한 번 더 걸러 둔다
  /// ([StudentApiService.fetchEntries]).
  static EntryStatus _requireStatus(dynamic raw) {
    if (raw == null) {
      throw const FormatException(
        'entry.status 가 없다 — 초안(status IS NULL)은 학생 앱에 내려오면 안 된다',
      );
    }
    return EntryStatus.fromCode(raw as String);
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
