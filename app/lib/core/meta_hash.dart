import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../models/entry_model.dart';

/// 항목 해시 재계산 및 검증 (PRD §7.3 · S4)
///
/// **이 파일은 앱 배포본에 내장된 검증 로직이다.**
/// 서버가 내려주는 코드로 검증하면 서버 장악 시 항상 통과를 반환하도록
/// 바꿀 수 있으므로, 서버 응답으로 이 규칙을 바꾸는 코드를 절대 추가하지 말 것.
///
/// ---
/// ⚠️ **해시 조합 규칙은 백엔드(손종인)와 한 글자도 달라선 안 된다.**
/// 구분자 하나, 숫자 표기 하나만 어긋나도 모든 항목이 「변조 감지」(빨강)로
/// 표시된다. 규칙이 확정되면 이 파일의 [separator] 와 [canonical] 만 고치면 된다.
///
/// 현재는 PRD §8 표기를 그대로 따른 잠정 구현이다:
/// `meta_hash = SHA256(amount | counterparty | purpose | occurred_at | receipt_hash)`
///
/// 확정 전까지 열려 있는 쟁점 — 규칙을 받으면 반드시 대조할 것:
///   1. 구분자가 정말 `|` 인지 (`:` 나 빈 문자열일 수도 있다)
///   2. `amount` 를 문자열로 어떻게 쓰는지 (`35000` / `35,000`)
///   3. `occurred_at` 이 epoch 초인지 ISO8601 문자열인지
///   4. `receipt_hash` 가 null 인 수입 항목에서 무엇으로 대체되는지 (빈 문자열 / `0x00..`)
///   5. 해시 결과 표기에 `0x` 접두사가 붙는지
class MetaHash {
  MetaHash._();

  /// 필드 구분자. 백엔드 확정 규칙에 맞춰 교체한다.
  static const String separator = '|';

  /// `receipt_hash` 가 없는 항목(수입 등)에서 대신 넣는 값.
  static const String nullReceiptPlaceholder = '';

  /// 해시 대상 문자열을 만든다. 규칙 변경 시 여기만 고친다.
  ///
  /// OCR 판독값은 **의도적으로 포함하지 않는다** (PRD §6) —
  /// OCR 엔진을 교체하면 판독값이 달라져 기존 검증 배지가 전부 깨지기 때문이다.
  static String canonical({
    required int amount,
    required String counterparty,
    required String purpose,
    required int occurredAt,
    String? receiptHash,
  }) {
    return [
      amount.toString(),
      counterparty,
      purpose,
      occurredAt.toString(),
      receiptHash ?? nullReceiptPlaceholder,
    ].join(separator);
  }

  /// 조합 문자열을 SHA-256으로 해시해 소문자 16진수로 돌려준다.
  static String compute({
    required int amount,
    required String counterparty,
    required String purpose,
    required int occurredAt,
    String? receiptHash,
  }) {
    final source = canonical(
      amount: amount,
      counterparty: counterparty,
      purpose: purpose,
      occurredAt: occurredAt,
      receiptHash: receiptHash,
    );
    return sha256.convert(utf8.encode(source)).toString();
  }

  /// 항목에서 직접 재계산한다.
  static String computeFor(EntryModel entry) => compute(
        amount: entry.amount,
        counterparty: entry.counterparty,
        purpose: entry.purpose,
        occurredAt: entry.occurredAt,
        receiptHash: entry.receiptHash,
      );

  /// 비교용 정규화 — `0x` 접두사와 대소문자 차이는 변조가 아니다.
  static String _normalize(String hash) {
    var h = hash.trim().toLowerCase();
    if (h.startsWith('0x')) h = h.substring(2);
    return h;
  }

  /// 앱에서 재계산한 값과 서버·온체인 값을 대조한다.
  static VerificationOutcome verify(EntryModel entry) {
    final onChain = entry.metaHash;
    final recomputed = computeFor(entry);

    if (onChain.isEmpty) {
      // 「통과」가 아니라 「모름」이다. 삭제 공격은 검증 실패가 아니라
      // 데이터 없음으로 나타난다 (PRD §7.3).
      return VerificationOutcome(
        status: VerificationStatus.unavailable,
        recomputed: recomputed,
        onChain: '',
      );
    }

    final matches = _normalize(recomputed) == _normalize(onChain);
    return VerificationOutcome(
      status: matches ? VerificationStatus.verified : VerificationStatus.tampered,
      recomputed: recomputed,
      onChain: onChain,
    );
  }

  /// 백엔드 규칙 확정 시 샘플 값으로 대조하기 위한 헬퍼.
  ///
  /// 손종인이 준 샘플 항목과 기대 해시를 넣어 `true` 가 나오는지 확인한다.
  /// `false` 면 [separator] 나 [canonical] 이 아직 안 맞는 것이다.
  static bool matchesSample({
    required int amount,
    required String counterparty,
    required String purpose,
    required int occurredAt,
    String? receiptHash,
    required String expectedHash,
  }) {
    final actual = compute(
      amount: amount,
      counterparty: counterparty,
      purpose: purpose,
      occurredAt: occurredAt,
      receiptHash: receiptHash,
    );
    return _normalize(actual) == _normalize(expectedHash);
  }
}

/// 검증 배지 상태 (S4)
enum VerificationStatus {
  /// 재계산 해시 == 온체인 해시. 기록이 등록 이후 바뀌지 않았다.
  verified,

  /// 불일치. 원본이 등록 이후 변경되었다.
  tampered,

  /// 온체인 해시가 없어 대조할 수 없다. 「통과」가 아니라 「모름」이다.
  unavailable,
}

/// 검증 결과와 근거가 된 두 해시를 함께 들고 다닌다.
/// 상세 화면에서 두 값을 나란히 보여줘야 학생이 직접 확인할 수 있다.
class VerificationOutcome {
  final VerificationStatus status;
  final String recomputed;
  final String onChain;

  const VerificationOutcome({
    required this.status,
    required this.recomputed,
    required this.onChain,
  });

  bool get isVerified => status == VerificationStatus.verified;
  bool get isTampered => status == VerificationStatus.tampered;
}
