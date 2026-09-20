/// docs/enums.md 기준 공통 Enums 정의
/// 임의로 추가하거나 표기를 변경하지 않습니다.

/// 1. role
enum UserRole {
  STUDENT('STUDENT', '학생'),
  TREASURER('TREASURER', '회계/총무'),
  AUDITOR('AUDITOR', '감사'),
  PRESIDENT('PRESIDENT', '회장');

  final String code;
  final String label;
  const UserRole(this.code, this.label);

  static UserRole fromCode(String code) {
    return UserRole.values.firstWhere(
      (e) => e.code == code,
      orElse: () => UserRole.STUDENT,
    );
  }
}

/// 2. kind
enum EntryKind {
  INCOME('INCOME', '수입'),
  EXPENSE('EXPENSE', '지출');

  final String code;
  final String label;
  const EntryKind(this.code, this.label);

  static EntryKind fromCode(String code) {
    return EntryKind.values.firstWhere(
      (e) => e.code == code,
      orElse: () => EntryKind.EXPENSE,
    );
  }
}

/// 3. entry status
enum EntryStatus {
  PENDING('PENDING', '대기'),
  CONFIRMED('CONFIRMED', '확정'),
  REJECTED('REJECTED', '반려'),
  BLOCKED('BLOCKED', '차단');

  final String code;
  final String label;
  const EntryStatus(this.code, this.label);

  static EntryStatus fromCode(String code) {
    return EntryStatus.values.firstWhere(
      (e) => e.code == code,
      orElse: () => EntryStatus.PENDING,
    );
  }
}

/// 4. correction_reason
enum CorrectionReason {
  INPUT_ERROR('INPUT_ERROR', '입력 오류'),
  RECEIPT_RECHECK('RECEIPT_RECHECK', '영수증 재확인'),
  REFUND('REFUND', '환불'),
  RECLASSIFY('RECLASSIFY', '재분류');

  final String code;
  final String label;
  const CorrectionReason(this.code, this.label);

  static CorrectionReason fromCode(String code) {
    return CorrectionReason.values.firstWhere(
      (e) => e.code == code,
      orElse: () => CorrectionReason.INPUT_ERROR,
    );
  }
}

/// 5. ocr_status
enum OcrStatus {
  MATCH('MATCH', '일치'),
  MISMATCH('MISMATCH', '불일치'),
  DUPLICATE('DUPLICATE', '중복'),
  NO_NUMBER('NO_NUMBER', '번호 없음'),
  UNREADABLE('UNREADABLE', '판독 불가');

  final String code;
  final String label;
  const OcrStatus(this.code, this.label);

  static OcrStatus fromCode(String code) {
    return OcrStatus.values.firstWhere(
      (e) => e.code == code,
      orElse: () => OcrStatus.UNREADABLE,
    );
  }
}

/// 6. block_reason (EntryBlocked.reason — 등록 시점 예산 검사 실패 사유)
/// 온체인 enum 순서 = docs/enums.md 표 순서.
enum BlockReason {
  BUDGET_EXCEEDED('BUDGET_EXCEEDED', '잔량 부족'),
  BUDGET_EXPIRED('BUDGET_EXPIRED', '집행 마감 경과'),
  BUDGET_NOT_FOUND('BUDGET_NOT_FOUND', '존재하지 않는 예산');

  final String code;
  final String label;
  const BlockReason(this.code, this.label);

  static BlockReason fromCode(String code) {
    return BlockReason.values.firstWhere(
      (e) => e.code == code,
      orElse: () => BlockReason.BUDGET_EXCEEDED,
    );
  }
}
