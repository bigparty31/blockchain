import '../core/enums.dart';

/// `AccountingLedger.getEntry(id)` 가 돌려주는 온체인 Entry (HASHING.md §2)
///
/// ```
/// Entry { hash, amount, kind, status, occurredAt, budgetId, correctsId,
///         registrant, approver }
/// ```
///
/// **해시 비교만으로는 검증이 반쪽이다.** `kind` 와 `budget_id` 는 `meta_hash` 에
/// 들어가지 않아서, 수입↔지출을 뒤바꾸거나 예산 항목을 옮겨도 해시가 한 글자도
/// 변하지 않는다 (§2 실측). 그래서 이 값들을 체인에서 직접 읽어 대조해야 한다.
class OnChainEntry {
  /// 온체인에 기록된 `meta_hash`. SHA-256 출력 32바이트이며 keccak 이 아니다.
  ///
  /// **아직 체인에 해시가 올라가지 않은 항목이 있다** — 트랜잭션이 채굴되기 전이거나
  /// 서버가 `hash: null` 을 내려주는 경우다. 이때 빈 문자열로 뭉개서 비교에 넣으면
  /// 「재계산한 값 ≠ ''」 가 되어 **멀쩡한 대기 항목이 전부 「변조 감지」로 뜬다.**
  /// 없는 것은 없는 것으로 둔다 — 대조하지 못한 것은 「모름」이지 불일치가 아니다.
  final String? hash;
  final int amount;
  final EntryKind kind;
  final EntryStatus status;
  final int occurredAt;

  /// 없으면 `0`. DB 의 `budget_id = NULL` 에 대응한다 (§2.1).
  final int budgetId;

  /// 정정이 아니면 `0`. DB 의 `corrects_entry_id = NULL` 에 대응한다 (§2.1).
  final int correctsId;

  /// 등록자 지갑 주소. DB 의 `created_by`(user id)와 값 자체가 다르므로
  /// `User.wallet_address` 로 옮긴 뒤 대조해야 한다.
  final String registrant;

  /// 확정자 **또는 반려자**의 지갑 주소. 미처리면 `address(0)`.
  ///
  /// 컨트랙트의 `approver` 는 둘을 겸하는데 DB 에는 `approved_by` 만 있고
  /// 반려자 컬럼이 없다. 그래서 `REJECTED` 항목에서는 이 필드를 비교하지 않는다
  /// (`rejected_by` 컬럼 추가 요청됨 — HASHING.md §8).
  final String approver;

  const OnChainEntry({
    required this.hash,
    required this.amount,
    required this.kind,
    required this.status,
    required this.occurredAt,
    required this.budgetId,
    required this.correctsId,
    required this.registrant,
    required this.approver,
  });

  /// 비어 있는 주소. DB 의 `NULL` 에 대응한다.
  static const String zeroAddress = '0x0000000000000000000000000000000000000000';

  bool get hasApprover => !_isZeroAddress(approver);

  /// 체인에 해시가 기록되어 있는지. 없으면 1단계 대조를 「모름」으로 남긴다.
  bool get hasHash => hash != null;

  /// 체인에 이 항목의 기록이 실제로 있는지.
  ///
  /// 컨트랙트의 `getEntry(id)` 는 없는 id 에 대해 **0 으로 채운 struct** 를 돌려준다.
  /// 그것을 진짜 기록으로 믿고 대조하면 `금액 35,000 ↔ 0` 이 어긋나 **아직 안 올라간
  /// 항목이 「변조 감지」로 뜬다.** 해시만 「모름」으로 돌려서는 이 경로가 안 막힌다.
  ///
  /// 기록이 지워진 경우도 같은 모양으로 나타나는데, 그것 역시 검증 실패가 아니라
  /// **데이터 없음**으로 보여줘야 한다 (`student_screens.md` §3.2, PRD §7.3).
  ///
  /// `amount` 는 0 이 금지된 값이라(`HASHING.md` §5) 판별 기준으로 쓸 수 있다.
  bool get hasRecord =>
      hasHash || amount != 0 || !_isZeroAddress(registrant);

  static bool _isZeroAddress(String address) {
    final lower = address.toLowerCase();
    return lower == zeroAddress || lower == '0x0' || address.isEmpty;
  }

  /// 「아직 기록되지 않음」을 뜻하는 해시 표기를 모두 null 로 모은다.
  ///
  /// 서버는 `null`, 컨트랙트는 `bytes32(0)` 으로 같은 뜻을 말한다. 어느 쪽이든
  /// **값이 없다는 뜻이지 「재계산한 값과 다르다」는 뜻이 아니다.**
  static String? _hashOrNull(dynamic value) {
    if (value is! String) return null;
    final bare = value.toLowerCase().replaceFirst(RegExp(r'^0x'), '');
    if (bare.isEmpty) return null;
    // bytes32(0) — `0x000…0`. 길이에 상관없이 0 뿐이면 기록 없음으로 본다.
    if (RegExp(r'^0+$').hasMatch(bare)) return null;
    return value;
  }

  factory OnChainEntry.fromJson(Map<String, dynamic> json) {
    return OnChainEntry(
      hash: _hashOrNull(json['hash']),
      amount: json['amount'] ?? 0,
      kind: EntryKind.fromCode(json['kind'] ?? 'EXPENSE'),
      status: EntryStatus.fromCode(json['status'] ?? 'PENDING'),
      occurredAt: json['occurred_at'] ?? 0,
      budgetId: json['budget_id'] ?? 0,
      correctsId: json['corrects_id'] ?? 0,
      registrant: json['registrant'] ?? zeroAddress,
      approver: json['approver'] ?? zeroAddress,
    );
  }
}
