import '../core/enums.dart';
import '../core/hashing.dart';
import '../models/entry_model.dart';
import '../models/onchain_entry_model.dart';

/// 항목 검증 (S4) — `docs/HASHING.md` §2 의 세 단계를 모두 수행한다.
///
/// 1. 원본 필드로 `meta_hash` 를 재계산해 `getEntry(id).hash` 와 비교
/// 2. 해시가 덮지 않는 필드를 `getEntry(id)` 값과 직접 비교
/// 3. 내려받은 영수증 바이트로 `fileHash` 를 재계산해 `receipt_hash` 와 비교
///
/// **1번만 하면 반쪽짜리 검증이다.** `kind` 와 `budget_id` 는 해시에 안 들어가서,
/// 수입↔지출 뒤바꾸기와 예산 항목 옮기기를 해시 비교로는 탐지하지 못한다.
/// **3번을 빠뜨리면** `receipt_hash` 는 맞는데 실제 파일은 다른 위조를 놓친다.
///
/// **이 로직은 앱 배포본에 내장되어야 한다** (PRD §7.3).
/// 서버가 내려주는 코드로 검증하면 서버 장악 시 항상 통과를 반환하도록 바꿀 수 있다.
class EntryVerifier {
  EntryVerifier._();

  /// [onChain] 이 null 이면 체인 대조를 못 한 것이므로 「통과」로 만들지 않는다.
  /// [receiptBytes] 가 null 이면 영수증 재계산을 건너뛴다 (아직 안 내려받은 상태).
  ///
  /// [walletByUserId] 는 `User.wallet_address` 매핑이다. 체인의 `registrant`·
  /// `approver` 는 지갑 주소인데 DB 의 `created_by`·`approved_by` 는 user id 라
  /// 값 자체가 달라서, 이 매핑 없이는 대조할 수 없다. 인증 파트(손종인)가
  /// API 로 내려주기 전까지는 null 이며 그동안 해당 검사는 「모름」으로 남는다.
  static VerificationReport verify(
    EntryModel entry, {
    OnChainEntry? onChain,
    List<int>? receiptBytes,
    Map<int, String>? walletByUserId,
  }) {
    final recomputed = Hashing.metaHash(
      // API 가 준 정본 값을 그대로 쓴다. 앱이 다시 다듬으면 값이 갈린다 (§1.1).
      amount: entry.amount,
      counterparty: entry.counterparty,
      purpose: entry.purpose,
      occurredAt: entry.occurredAt,
      receiptHash: entry.receiptHash,
    );

    // 내용이 하나도 안 담긴 struct 는 「기록 없음」이지 불일치가 아니다.
    // 그대로 대조하면 아직 체인에 안 올라간 항목이 전부 「변조 감지」가 된다.
    final chain = (onChain != null && onChain.hasRecord) ? onChain : null;

    // ── 1단계: 해시 대조 ──────────────────────────────────────
    // 체인 값이 있으면 그것과, 없으면 API 가 준 meta_hash 와 비교한다.
    // 후자는 「서버가 준 값끼리」 맞춰보는 것이라 신뢰도가 낮다.
    //
    // **체인 해시가 없을 때 빈 문자열과 비교하지 않는다.** 아직 채굴되지 않아
    // 해시가 안 올라간 것뿐인데 「재계산한 값 ≠ ''」 로 불일치를 만들면,
    // 멀쩡한 대기 항목이 학생 화면에 「변조 감지」로 뜬다.
    final chainHash = chain?.hash;
    final serverHash = entry.metaHash;

    // 체인 기록을 **읽었는데** 해시 자리가 비어 있으면, 대조할 것이 없다는 사실을
    // 확인한 것이다. 이때는 서버 해시로 대신 맞춰보지 않는다 — 통과시켜 봐야
    // 「서버가 준 값끼리」 맞는다는 뜻이라 확인한 것이 없는데, 1단계가 초록으로
    // 남으면 화면이 「확인함」에 가깝게 읽힌다. 「검증 불가」로 남긴다.
    //
    // 체인 조회 자체를 못 한 경우(`chain == null`)는 다르다. 체인에 무엇이 있는지
    // 모르는 상태이므로, 서버 값과라도 맞춰보고 「부분 검증」에 머문다.
    final chainReadButNoHash = chain != null && chainHash == null;
    final comparedAgainst = chainReadButNoHash
        ? null
        : (chainHash ?? (serverHash.isEmpty ? null : serverHash));

    final CheckState hashState;
    if (comparedAgainst == null) {
      hashState = CheckState.unavailable;
    } else {
      hashState = Hashing.hashEquals(recomputed, comparedAgainst)
          ? CheckState.passed
          : CheckState.failed;
    }

    // ── 2단계: 해시가 덮지 않는 필드 대조 ─────────────────────
    final fieldChecks = chain == null
        ? <FieldCheck>[]
        : _compareFields(entry, chain, walletByUserId);

    // ── 3단계: 영수증 바이트 재계산 ───────────────────────────
    final receipt = _checkReceipt(entry, receiptBytes);

    return VerificationReport(
      status: _decide(
        hashState,
        fieldChecks,
        receipt.state,
        chainDataAvailable: chain != null,
        chainHashCompared: chainHash != null,
      ),
      hashState: hashState,
      recomputedHash: recomputed,
      onChainHash: chainHash,
      serverHash: serverHash.isEmpty ? null : serverHash,
      comparedAgainst: comparedAgainst,
      chainDataAvailable: chain != null,
      fieldChecks: fieldChecks,
      receipt: receipt,
    );
  }

  /// 정정 체인 전체(원본 + 정정)의 대표 상태.
  ///
  /// **정정 항목도 저마다 온체인 entry 다.** 원본만 검증하면 화면에 크게 뜨는
  /// 최종 금액(`원본 + Σ확정정정`)의 근거가 검증 밖에 남는다. 확정된 기록을
  /// 고치는 유일한 통로가 정정이므로(PRD, `CLAUDE.md` 규칙 5), 여기가 사각지대면
  /// 「확정 기록은 못 고친다」는 보장이 그대로 우회된다.
  ///
  /// 집계는 나쁜 쪽을 따른다 — 하나라도 어긋나면 체인 전체가 「변조 감지」다.
  static VerificationStatus chainStatus(Iterable<VerificationStatus> statuses) {
    final all = statuses.toList();
    if (all.isEmpty) return VerificationStatus.unavailable;
    if (all.contains(VerificationStatus.tampered)) {
      return VerificationStatus.tampered;
    }
    // 전부 대조할 기록이 없을 때만 「검증 불가」다. 일부라도 확인했으면
    // 「아무것도 모른다」가 아니라 「일부만 확인했다」이므로 부분 검증이다.
    if (all.every((s) => s == VerificationStatus.unavailable)) {
      return VerificationStatus.unavailable;
    }
    if (all.every((s) => s == VerificationStatus.verified)) {
      return VerificationStatus.verified;
    }
    return VerificationStatus.partial;
  }

  /// HASHING.md §2 의 비교 표. NULL ↔ 0 변환을 반드시 거친다 —
  /// 빼먹으면 `None != 0` 이라 정상 항목이 거의 전부 위조로 판정된다 (§2.1).
  static List<FieldCheck> _compareFields(
    EntryModel e,
    OnChainEntry c,
    Map<int, String>? walletByUserId,
  ) {
    final checks = <FieldCheck>[
      FieldCheck.compare(
        label: '금액',
        chain: '${c.amount}',
        local: '${e.amount}',
      ),
      FieldCheck.compare(
        label: '수입·지출 구분',
        chain: c.kind.code,
        local: e.kind.code,
        note: '해시에 들어가지 않는 값이다',
      ),
      FieldCheck.compare(
        label: '상태',
        chain: c.status.code,
        local: e.status.code,
      ),
      FieldCheck.compare(
        label: '사용일',
        chain: '${c.occurredAt}',
        local: '${e.occurredAt}',
      ),
      FieldCheck.compare(
        label: '예산 항목',
        chain: '${c.budgetId}',
        // NULL → 0 (§2.1). 모든 수입 항목이 여기 걸린다.
        local: '${e.budgetId ?? 0}',
        note: '해시에 들어가지 않는 값이다',
      ),
      FieldCheck.compare(
        label: '정정 대상',
        chain: '${c.correctsId}',
        local: '${e.correctsEntryId ?? 0}',
        note: '해시에 들어가지 않는 값이다',
      ),
    ];

    // 등록자·승인자는 체인에 지갑 주소, DB 에 user id 로 들어 있어 값 자체가 다르다.
    // **이 두 필드가 「누가 등록하고 누가 승인했는가」의 유일한 온체인 증거**이므로
    // 빠뜨리면 안 된다. 매핑이 없으면 비교하지 못했다고 남긴다.
    checks.add(_comparePerson(
      label: '등록자',
      chainAddress: c.registrant,
      userId: e.createdBy,
      walletByUserId: walletByUserId,
    ));

    if (e.status == EntryStatus.REJECTED) {
      // 컨트랙트의 approver 는 확정자와 반려자를 겸하는데 DB 에는 반려자 컬럼이 없다.
      // 그대로 비교하면 반려된 항목이 전부 위조로 판정된다 (§2, §8).
      checks.add(FieldCheck(
        label: '승인자',
        chain: c.approver,
        local: '—',
        state: CheckState.notApplicable,
        note: 'rejected_by 컬럼이 생기기 전까지 반려 항목은 비교하지 않는다',
      ));
    } else {
      checks.add(_comparePerson(
        label: '승인자',
        chainAddress: c.hasApprover ? c.approver : null,
        userId: e.approvedBy,
        walletByUserId: walletByUserId,
      ));
    }

    return checks;
  }

  /// 지갑 주소와 user id 를 매핑을 거쳐 대조한다.
  ///
  /// 양쪽이 모두 비어 있으면(미처리) 일치로 본다 — `address(0)` ↔ `NULL` (§2.1).
  /// 한쪽만 비어 있으면 매핑이 없어도 불일치를 알 수 있다.
  static FieldCheck _comparePerson({
    required String label,
    required String? chainAddress,
    required int? userId,
    required Map<int, String>? walletByUserId,
  }) {
    final chainEmpty = chainAddress == null;
    final localEmpty = userId == null;

    if (chainEmpty && localEmpty) {
      return FieldCheck(
        label: label,
        chain: '(미처리)',
        local: '(미처리)',
        state: CheckState.passed,
      );
    }

    if (chainEmpty != localEmpty) {
      return FieldCheck(
        label: label,
        chain: chainAddress ?? '(미처리)',
        local: localEmpty ? '(미처리)' : 'user #$userId',
        state: CheckState.failed,
        note: '한쪽만 값이 있다',
      );
    }

    final wallet = walletByUserId?[userId];
    if (wallet == null) {
      return FieldCheck(
        label: label,
        chain: chainAddress!,
        local: 'user #$userId',
        state: CheckState.unavailable,
        note: '주소 ↔ user id 매핑 API 대기',
      );
    }

    return FieldCheck(
      label: label,
      chain: chainAddress!,
      local: wallet,
      // 주소는 대소문자 표기(EIP-55 체크섬)가 갈릴 수 있어 맞춰서 본다.
      state: wallet.toLowerCase() == chainAddress.toLowerCase()
          ? CheckState.passed
          : CheckState.failed,
    );
  }

  static ReceiptCheck _checkReceipt(EntryModel e, List<int>? bytes) {
    if (e.receiptHash == null) {
      return const ReceiptCheck(state: CheckState.notApplicable);
    }
    if (bytes == null) {
      return ReceiptCheck(
        state: CheckState.unavailable,
        expected: e.receiptHash,
      );
    }
    final actual = Hashing.fileHash(bytes);
    return ReceiptCheck(
      state: Hashing.hashEquals(actual, e.receiptHash!)
          ? CheckState.passed
          : CheckState.failed,
      expected: e.receiptHash,
      actual: actual,
    );
  }

  static VerificationStatus _decide(
    CheckState hashState,
    List<FieldCheck> fields,
    CheckState receiptState, {
    required bool chainDataAvailable,
    required bool chainHashCompared,
  }) {
    final anyFailed = hashState == CheckState.failed ||
        receiptState == CheckState.failed ||
        fields.any((f) => f.state == CheckState.failed);
    if (anyFailed) return VerificationStatus.tampered;

    if (hashState == CheckState.unavailable) return VerificationStatus.unavailable;

    // 세 단계를 다 못 돌았으면 초록을 주지 않는다.
    // 「확인 못 함」을 「이상 없음」으로 보여주면 검증의 의미가 없다.
    //
    // 체인 해시가 없어 서버 해시로 대신 맞춰본 경우도 여기 걸린다 —
    // 「서버가 준 값끼리」 일치한 것이라 체인과 대조했다고 말할 수 없다.
    final incomplete = !chainDataAvailable ||
        !chainHashCompared ||
        receiptState == CheckState.unavailable ||
        fields.any((f) => f.state == CheckState.unavailable);

    return incomplete ? VerificationStatus.partial : VerificationStatus.verified;
  }
}

/// 개별 검사의 결과.
enum CheckState {
  /// 대조했고 일치한다.
  passed,

  /// 대조했고 다르다. 변조 가능성.
  failed,

  /// 대조할 자료가 없다. **「통과」가 아니라 「모름」이다.**
  unavailable,

  /// 이 항목에는 해당하지 않는 검사다 (영수증 없는 수입 등).
  notApplicable,
}

/// 검증 배지 상태 (S4)
enum VerificationStatus {
  /// 세 단계를 모두 통과했다.
  verified,

  /// 어느 한 단계라도 불일치. 등록 이후 내용이 바뀌었다.
  tampered,

  /// 통과한 것만 보면 이상 없지만 **일부 단계를 돌리지 못했다.**
  /// 초록으로 보여주면 확인하지 못한 것을 확인했다고 말하는 셈이 된다.
  partial,

  /// 대조할 기록이 아예 없다.
  unavailable,
}

/// 필드 하나의 대조 결과.
class FieldCheck {
  final String label;
  final String chain;
  final String local;
  final CheckState state;
  final String? note;

  const FieldCheck({
    required this.label,
    required this.chain,
    required this.local,
    required this.state,
    this.note,
  });

  factory FieldCheck.compare({
    required String label,
    required String chain,
    required String local,
    String? note,
  }) {
    return FieldCheck(
      label: label,
      chain: chain,
      local: local,
      state: chain == local ? CheckState.passed : CheckState.failed,
      note: note,
    );
  }
}

/// 영수증 바이트 재계산 결과 (§4).
class ReceiptCheck {
  final CheckState state;
  final String? expected;
  final String? actual;

  const ReceiptCheck({required this.state, this.expected, this.actual});
}

/// 세 단계의 결과를 한데 모은 것.
///
/// 배지 색만 보여주면 학생은 그 색을 믿는 수밖에 없다.
/// 근거가 된 값들을 함께 들고 다녀야 상세 화면에서 직접 확인할 수 있다.
class VerificationReport {
  final VerificationStatus status;

  final CheckState hashState;
  final String recomputedHash;

  /// 체인에서 읽은 해시.
  ///
  /// API 가 아직 없을 때뿐 아니라 **채굴 전이라 체인에 해시가 없을 때도 null** 이다.
  /// 두 경우 모두 「대조하지 못했다」이지 「다르다」가 아니다.
  final String? onChainHash;

  /// 서버가 내려준 해시. **비교에 썼다는 뜻은 아니다** — [comparedAgainst] 를 볼 것.
  final String? serverHash;

  /// 재계산한 해시를 **실제로 맞춰본 상대 값.** 아무것도 대조하지 못했으면 null.
  ///
  /// 체인 기록을 읽었는데 해시가 비어 있으면 서버 값으로 대신 맞춰보지 않으므로
  /// 여기도 null 이다. 화면이 「무엇과 비교했는가」를 정확히 말할 수 있어야 한다.
  final String? comparedAgainst;

  /// `getEntry(id)` 결과를 받아왔는지.
  final bool chainDataAvailable;

  final List<FieldCheck> fieldChecks;
  final ReceiptCheck receipt;

  const VerificationReport({
    required this.status,
    required this.hashState,
    required this.recomputedHash,
    required this.onChainHash,
    required this.serverHash,
    required this.comparedAgainst,
    required this.chainDataAvailable,
    required this.fieldChecks,
    required this.receipt,
  });

  bool get isTampered => status == VerificationStatus.tampered;
  bool get isVerified => status == VerificationStatus.verified;

  /// 불일치한 필드만 추린다.
  List<FieldCheck> get mismatches =>
      fieldChecks.where((f) => f.state == CheckState.failed).toList();

  /// 아직 돌리지 못한 검사의 사유. 화면에 그대로 보여준다.
  List<String> get pendingReasons {
    final reasons = <String>[];
    if (!chainDataAvailable) {
      reasons.add('온체인 조회 API가 아직 없어 체인 값과 대조하지 못했습니다');
    } else if (onChainHash == null) {
      // 대조 실패가 아니라 아직 대조할 것이 없는 상태다.
      reasons.add('체인에 아직 해시가 기록되지 않아 온체인 값과 대조하지 못했습니다');
    }
    if (receipt.state == CheckState.unavailable) {
      reasons.add('영수증을 내려받아야 파일 해시를 다시 계산할 수 있습니다');
    }
    for (final f in fieldChecks) {
      if (f.state == CheckState.unavailable && f.note != null) {
        reasons.add('${f.label}: ${f.note}');
      }
    }
    return reasons;
  }
}
