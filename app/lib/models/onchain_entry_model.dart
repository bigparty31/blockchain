import '../core/enums.dart';

/// `AccountingLedger.getEntry(id)` 가 돌려주는 온체인 Entry (HASHING.md §2)
///
/// ```
/// Entry { hash, amount, budgetId, correctsId, registrant, occurredAt,
///         term, approver, kind, status }
/// ```
///
/// **해시 비교만으로는 검증이 반쪽이다.** `kind` 와 `budget_id` 는 `meta_hash` 에
/// 들어가지 않아서, 수입↔지출을 뒤바꾸거나 예산 항목을 옮겨도 해시가 한 글자도
/// 변하지 않는다 (§2 실측). 그래서 이 값들을 체인에서 직접 읽어 대조해야 한다.
///
/// **모든 필드가 nullable 인 이유** — null 은 「응답에 그 필드가 없었다」는 뜻이다.
/// 없는 값을 그럴듯한 기본값(`EXPENSE`, `0`, `address(0)`)으로 채우면 **지어낸 값과
/// 대조하게 되어 멀쩡한 항목이 「변조 감지」로 뜬다.** 응답에서 `kind` 가 빠지면
/// 모든 수입 항목이 지어낸 `EXPENSE` 와 어긋나고, `budget_id` 가 빠지면 예산이 붙은
/// 모든 지출이 어긋난다. 대조하지 못한 것은 「모름」이지 불일치가 아니다.
/// `/verify` 응답 모양이 확정되기 전이라 어느 필드가 실려 올지 모르므로 더 그렇다.
///
/// **「없음」과 「비어 있음」은 다르다.** 체인의 `budgetId = 0` · `approver =
/// address(0)` 은 값이 실려 왔고 그 값이 비어 있다는 뜻이라 DB 의 `NULL` 과 대조해
/// **통과해야 한다** (§2.1 — 수입 항목 전부가 여기 해당한다). 그래서 둘을 null 로
/// 합치지 않는다.
class OnChainEntry {
  /// 온체인에 기록된 `meta_hash`. SHA-256 출력 32바이트이며 keccak 이 아니다.
  ///
  /// **아직 체인에 해시가 올라가지 않은 항목이 있다** — 트랜잭션이 채굴되기 전이거나
  /// 서버가 `hash: null` 을 내려주는 경우다. 이때 빈 문자열로 뭉개서 비교에 넣으면
  /// 「재계산한 값 ≠ ''」 가 되어 **멀쩡한 대기 항목이 전부 「변조 감지」로 뜬다.**
  /// 없는 것은 없는 것으로 둔다 — 대조하지 못한 것은 「모름」이지 불일치가 아니다.
  final String? hash;

  /// 체인에 기록된 금액. 응답에 없으면 null — **`0` 으로 떨어뜨리지 않는다.**
  /// `0` 은 컨트랙트가 금지한 값이라(`HASHING.md` §5) 「기록 없음」의 표시로 쓰인다.
  final int? amount;

  /// 수입·지출 구분. 응답에 없으면 null — **지어낸 `EXPENSE` 가 아니다.**
  ///
  /// `?? 'EXPENSE'` 로 채우면 **모든 수입 항목이 지어낸 지출과 대조돼 「변조 감지」**
  /// 가 된다. `meta_hash` 가 덮지 않는 값이라 이 대조가 수입↔지출 뒤바꾸기를 잡는
  /// 유일한 경로인데, 기본값으로 채우면 그 경로가 거짓 양성 공장이 된다.
  final EntryKind? kind;

  /// 체인에서 읽은 상태. 응답에 없으면 null — **「대기」가 아니라 「모름」이다.**
  ///
  /// 예전에는 `?? 'PENDING'` 으로 채웠는데, 그러면 지어낸 PENDING 과 대조하게 되어
  /// **확정된 항목이 「상태 불일치」로 뜬다.** 대조하지 못한 것은 불일치가 아니다.
  final EntryStatus? status;

  /// 사용일(Unix epoch). 응답에 없으면 null.
  final int? occurredAt;

  /// 온체인 학기 코드 `YYYYS` (예: 20262 = 2026년 2학기). 응답에 없으면 null.
  ///
  /// **DB 의 `term_id`(1, 2…)와 비교하면 안 된다** — 인터페이스가 "DB 의 Term.id 가
  /// 아니다"라고 못박은 값이다. 대조 상대는 [EntryModel.termCode] 다.
  ///
  /// `meta_hash` 에는 들어가지 않으므로(IAccountingLedger: "meta_hash 에는
  /// kind·term·budgetId·correctsId 가 없다") 해시 검증으로는 학기 바꿔치기를
  /// 잡지 못한다. 그래서 `kind`·`budgetId` 와 같이 따로 대조한다.
  final int? term;

  /// 예산 항목. 응답에 없으면 null이고, **실려 온 `0` 은 DB 의 `budget_id = NULL` 에
  /// 대응한다** (§2.1). 모든 수입 항목이 후자이므로 둘을 합치면 안 된다.
  final int? budgetId;

  /// 정정 대상. 응답에 없으면 null이고, 실려 온 `0` 은 `corrects_entry_id = NULL` 이다.
  final int? correctsId;

  /// 등록자 지갑 주소. 응답에 없으면 null.
  ///
  /// DB 의 `created_by`(user id)와 값 자체가 달라 지갑 매핑을 거쳐야 대조할 수 있다.
  /// 없는 것을 `address(0)` 으로 채우면 「체인에는 등록자가 없는데 DB 에는 있다」가
  /// 되어 **멀쩡한 항목이 불일치로 판정된다.**
  final String? registrant;

  /// 확정자 **또는 반려자**의 지갑 주소. 응답에 없으면 null, 미처리면 `address(0)`.
  ///
  /// 컨트랙트의 `approver` 는 둘을 겸하는데 DB 에는 `approved_by` 만 있고
  /// 반려자 컬럼이 없다. 그래서 `REJECTED` 항목에서는 이 필드를 비교하지 않는다
  /// (`rejected_by` 컬럼 추가 요청됨 — HASHING.md §8).
  final String? approver;

  const OnChainEntry({
    required this.hash,
    required this.amount,
    required this.kind,
    required this.status,
    required this.occurredAt,
    this.term,
    required this.budgetId,
    required this.correctsId,
    required this.registrant,
    required this.approver,
  });

  /// 비어 있는 주소. DB 의 `NULL` 에 대응한다.
  static const String zeroAddress = '0x0000000000000000000000000000000000000000';

  /// 승인자 자리에 **실제 주소가 들어 있는지.** 응답에 없거나 `address(0)` 이면 거짓.
  bool get hasApprover => approver != null && !isZeroAddress(approver!);

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
      hasHash ||
      (amount ?? 0) != 0 ||
      (registrant != null && !isZeroAddress(registrant!));

  /// 「아직 처리되지 않음」을 뜻하는 주소 표기. DB 의 `NULL` 에 대응한다.
  ///
  /// **응답에 필드가 없는 것(null)과는 다르다** — 그쪽은 「모름」이다.
  static bool isZeroAddress(String address) {
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

  /// 숫자 필드. 없거나 숫자로 읽을 수 없으면 null — **0 으로 떨어뜨리지 않는다.**
  static int? _intOrNull(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// 주소 필드. 빈 문자열은 값이 없는 것으로 본다.
  static String? _addressOrNull(dynamic value) {
    if (value is! String || value.isEmpty) return null;
    return value;
  }

  /// `kind` 는 **모르는 코드를 지출로 떨어뜨리지 않는다.**
  ///
  /// [EntryKind.fromCode] 는 화면 표시용이라 모르는 코드를 `EXPENSE` 로 넘기는데,
  /// 검증에서 그렇게 하면 「확인하지 못한 값」이 「지출이라고 확인했다」로 바뀐다.
  static EntryKind? _kindOrNull(dynamic value) {
    if (value is! String) return null;
    for (final k in EntryKind.values) {
      if (k.code == value) return k;
    }
    return null;
  }

  factory OnChainEntry.fromJson(Map<String, dynamic> json) {
    return OnChainEntry(
      hash: _hashOrNull(json['hash']),
      // 아래는 전부 **없으면 null 이다.** 지어낸 값과 대조하면 멀쩡한 항목이 어긋난다.
      amount: _intOrNull(json['amount']),
      kind: _kindOrNull(json['kind']),
      status: json['status'] == null
          ? null
          : EntryStatus.fromCode(json['status'] as String),
      occurredAt: _intOrNull(json['occurred_at']),
      term: _intOrNull(json['term']),
      budgetId: _intOrNull(json['budget_id']),
      correctsId: _intOrNull(json['corrects_id']),
      registrant: _addressOrNull(json['registrant']),
      approver: _addressOrNull(json['approver']),
    );
  }
}
