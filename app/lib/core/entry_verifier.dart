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
  /// [userIdByAddress] 는 `GET /users/wallets` 의 **주소(소문자) → user id** 매핑이다.
  /// 체인의 `registrant`·`approver` 는 지갑 주소인데 DB 의 `created_by`·`approved_by`
  /// 는 user id 라 값 자체가 달라서, 이 매핑 없이는 대조할 수 없다. 아직 못 받았으면
  /// null 이며 그동안 해당 검사는 「모름」으로 남는다.
  ///
  /// **방향이 주소 → id 인 것이 중요하다.** 반대 방향(user id → 주소 하나)이면
  /// 키를 교체한 사람의 **옛 주소가 응답에 아예 없어서**, 그 주소로 등록한 과거
  /// 항목이 전부 「등록자 불일치 = 변조 감지」로 뒤집힌다. 한 사람이 주소를 여러 개
  /// 갖는 것이 정상이므로(`RoleManager.rotateKey`) 매핑도 그 모양이어야 한다.
  static VerificationReport verify(
    EntryModel entry, {
    OnChainEntry? onChain,
    List<int>? receiptBytes,
    Map<String, int>? userIdByAddress,
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
        : _compareFields(entry, chain, userIdByAddress);

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
  ///
  /// **응답에 없는 필드는 「모름」으로 남긴다.** `OnChainEntry` 가 없는 값을 null 로
  /// 두는 것과 짝이다 — 여기서 `?? 0` 이나 `?? EXPENSE` 로 메우면 모델에서 막은
  /// 거짓 양성이 그대로 되살아난다.
  static List<FieldCheck> _compareFields(
    EntryModel e,
    OnChainEntry c,
    Map<String, int>? userIdByAddress,
  ) {
    final checks = <FieldCheck>[
      _compareOrUnknown(
        label: '금액',
        chain: c.amount?.toString(),
        local: '${e.amount}',
        missingField: 'amount',
      ),
      _compareOrUnknown(
        label: '수입·지출 구분',
        chain: c.kind?.code,
        local: e.kind.code,
        missingField: 'kind',
        note: '해시에 들어가지 않는 값이다',
      ),
      // 체인 상태를 못 읽었으면 「모름」으로 남긴다. 예전처럼 PENDING 으로
      // 채워 놓고 대조하면 확정된 항목이 전부 어긋난다.
      _compareOrUnknown(
        label: '상태',
        chain: c.status?.code,
        local: e.status.code,
        missingField: 'status',
      ),
      _compareOrUnknown(
        label: '사용일',
        chain: c.occurredAt?.toString(),
        local: '${e.occurredAt}',
        missingField: 'occurred_at',
      ),
      // 학기 — 체인에는 있지만 meta_hash 에는 없다. 빼면 **학기가 바뀐 항목도
      // 「검증됨」으로 뜬다** (IAccountingLedger `Entry.term`).
      _compareTerm(chainTerm: c.term, localTermCode: e.termCode),
      _compareOrUnknown(
        label: '예산 항목',
        // 실려 온 `0` 은 비교한다 — DB 의 NULL → 0 에 대응한다 (§2.1).
        // 모든 수입 항목이 여기 걸리므로 「없음」과 합치면 안 된다.
        chain: c.budgetId?.toString(),
        local: '${e.budgetId ?? 0}',
        missingField: 'budget_id',
        note: '해시에 들어가지 않는 값이다',
      ),
      _compareOrUnknown(
        label: '정정 대상',
        chain: c.correctsId?.toString(),
        local: '${e.correctsEntryId ?? 0}',
        missingField: 'corrects_id',
        note: '해시에 들어가지 않는 값이다',
      ),
    ];

    // 등록자·승인자는 체인에 지갑 주소, DB 에 user id 로 들어 있어 값 자체가 다르다.
    // **이 두 필드가 「누가 등록하고 누가 승인했는가」의 유일한 온체인 증거**이므로
    // 빠뜨리면 안 된다. 매핑이 없으면 비교하지 못했다고 남긴다.
    checks.add(_comparePerson(
      label: '등록자',
      chainAddress: c.registrant,
      missingField: 'registrant',
      userId: e.createdBy,
      userIdByAddress: userIdByAddress,
    ));

    // 컨트랙트의 approver 는 확정자와 반려자를 겸하고, DB 는 둘을 나눠 담는다.
    // 상태에 따라 대조 상대가 갈린다 — 틀린 쪽과 비교하면 멀쩡한 항목이 위조로 뜬다.
    final isRejected = e.status == EntryStatus.REJECTED;
    checks.add(_comparePerson(
      label: isRejected ? '반려자' : '승인자',
      chainAddress: c.approver,
      missingField: 'approver',
      userId: isRejected ? e.rejectedBy : e.approvedBy,
      userIdByAddress: userIdByAddress,
    ));

    checks.add(_compareReasonHash(e, c));

    return checks;
  }

  /// 사유 해시 대조 (`docs/HASHING.md` §3).
  ///
  /// 체인에는 해시만 남고 원문은 DB 에 있다. **학생이 읽는 사유가 승인·반려 당시의 그
  /// 사유인지**를 여기서 본다 — 원문을 나중에 고쳐도 해시는 못 고치기 때문이다.
  ///
  /// | 상태 | 체인 `reason_hash` | 원문 |
  /// |---|---|---|
  /// | 경고 무시 확정 | 사유 해시 | `warning_ack_reason` |
  /// | 반려 | 사유 해시 | `reject_reason` |
  /// | 경고 없는 확정 | `bytes32(0)` | 없음 |
  ///
  /// **받은 원문을 그대로 해시한다.** 앱이 [Hashing.canonicalText] 로 다시 다듬지
  /// 않는다 — 백엔드가 저장 시점에 다듬은 값이 정본이고(§1.1), 앱이 또 다듬으면 서버가
  /// 정본이 아닌 값을 내려보내도 조용히 교정되어 **통과해 버린다.** 검증은 화면에 보이는
  /// 바이트가 체인과 맞는지를 묻는 것이다.
  static FieldCheck _compareReasonHash(EntryModel e, OnChainEntry c) {
    const label = '승인·반려 사유';

    final isRejected = e.status == EntryStatus.REJECTED;
    final reason = isRejected ? e.rejectReason : e.warningAckReason;

    // **`had_warning` 이 없으면 사유 해시에 묻는다.** 이 값만 보고 「경고 없는 확정」으로
    // 단정하면, `reason_hash` 는 주면서 `had_warning` 은 빠뜨린 응답에서 **경고를 무시하고
    // 확정한 멀쩡한 항목이 「불일치」로 뜬다** — 0 이 아닌 해시가 체인에 남아 있는데도
    // 「사유가 없어야 한다」는 분기로 가기 때문이다. 체인에 사유 해시가 있다는 것 자체가
    // 사유가 있었다는 증거이므로, 모르는 쪽(null)에서는 그 증거를 따른다.
    final expectsReason = isRejected ||
        c.hadWarning == true ||
        (c.hadWarning == null &&
            c.reasonHash != null &&
            c.reasonHash != OnChainEntry.zeroHash);

    if (c.reasonHash == null) {
      // **서버가 아직 안 내려주는 필드다.** 여기서 무조건 「모름」을 남기면, 사유가
      // 애초에 없는 평범한 확정 항목까지 전부 「부분 검증」으로 떨어진다 — 확인할
      // 것이 없는데 확인 못 했다고 말하는 셈이다.
      //
      // 그래서 **학생에게 사유가 보이는 경우에만** 「모름」으로 남긴다. 보이는 글을
      // 대조하지 못한 것은 실제로 모르는 것이 맞다.
      final hasVisibleReason = expectsReason || (reason != null && reason.isNotEmpty);
      return FieldCheck(
        label: label,
        chain: '(읽지 못함)',
        local: hasVisibleReason ? (reason ?? '(원문 없음)') : '없음',
        state: hasVisibleReason ? CheckState.unavailable : CheckState.notApplicable,
        note: hasVisibleReason
            ? '응답에 reason_hash 가 없어 사유를 대조하지 못했다'
            : '사유가 없는 항목이라 대조할 것이 없다',
      );
    }

    // 경고 없는 확정 — 사유가 없는 것이 정상이고, 체인도 0 이어야 한다.
    if (!expectsReason) {
      // **장부에 사유가 있으면 「없음」이라고 말하지 않는다.** 체인은 경고 없이
      // 확정됐다는데 DB 에는 사유가 달려 있는 상태다. 그 사유는 체인에 해시가 없어
      // 재계산할 대상이 없고 `meta_hash` 에도 들어가지 않으므로, 통과로 두면 **검증된
      // 적 없는 글이 상세 화면에 뜬다** — 나중에 끼워 넣어도 배지는 초록이다.
      if (reason != null && reason.isNotEmpty) {
        return FieldCheck(
          label: label,
          chain: '없음',
          local: reason,
          state: CheckState.failed,
          note: '체인은 경고 없이 확정됐다는데 장부에는 사유가 있다',
        );
      }

      final isZero = c.reasonHash == OnChainEntry.zeroHash;
      return FieldCheck(
        label: label,
        chain: isZero ? '없음' : c.reasonHash!,
        local: '없음',
        state: isZero ? CheckState.passed : CheckState.failed,
        note: isZero ? '경고 없이 확정되어 사유가 없다' : '사유가 없어야 하는데 체인에 해시가 있다',
      );
    }

    if (reason == null || reason.isEmpty) {
      return FieldCheck(
        label: label,
        chain: c.reasonHash!,
        local: '(원문 없음)',
        state: CheckState.unavailable,
        note: '체인에는 사유 해시가 있는데 원문을 받지 못해 재계산할 수 없다',
      );
    }

    final recomputed = Hashing.textHash(reason);
    final ok = recomputed.toLowerCase() == c.reasonHash!.toLowerCase();
    return FieldCheck(
      label: label,
      chain: c.reasonHash!,
      local: recomputed,
      state: ok ? CheckState.passed : CheckState.failed,
      note: ok ? null : '화면에 보이는 사유가 승인·반려 당시의 사유와 다르다',
    );
  }

  /// 한 필드를 대조한다. [chain] 이 null 이면 **응답에 그 필드가 없었다**는 뜻이므로
  /// 불일치가 아니라 「모름」이다.
  ///
  /// 이 구분을 뭉개면 `/verify` 응답에서 필드 하나가 빠질 때마다 그 필드를 가진
  /// 모든 항목이 학생 화면에서 빨간 「변조 감지」가 된다.
  static FieldCheck _compareOrUnknown({
    required String label,
    required String? chain,
    required String local,
    required String missingField,
    String? note,
  }) {
    if (chain == null) {
      return FieldCheck(
        label: label,
        chain: '(읽지 못함)',
        local: local,
        state: CheckState.unavailable,
        note: '온체인 응답에 $missingField 필드가 없다',
      );
    }
    return FieldCheck.compare(
      label: label,
      chain: chain,
      local: local,
      note: note,
    );
  }

  /// 학기 대조 — **양쪽 모두 학기 코드(`YYYYS`)여야 한다.**
  ///
  /// 체인의 `Entry.term` 은 `20262` 같은 학기 코드이고 DB 의 `term_id` 는 1부터
  /// 매긴 행 번호다. 둘을 그냥 비교하면 `1 != 20262` 로 **모든 항목이 변조
  /// 판정된다.** 그래서 대조 상대는 [EntryModel.termId] 가 아니라
  /// [EntryModel.termCode] 이며, 아직 `EntryResponse` 에 그 필드가 없어
  /// 당분간은 「모름」으로 남는다.
  static FieldCheck _compareTerm({
    required int? chainTerm,
    required int? localTermCode,
  }) {
    if (chainTerm == null) {
      return FieldCheck(
        label: '학기',
        chain: '(읽지 못함)',
        local: localTermCode == null ? '(없음)' : '$localTermCode',
        state: CheckState.unavailable,
        note: '온체인 응답에 term 이 없다',
      );
    }
    if (localTermCode == null) {
      return FieldCheck(
        label: '학기',
        chain: '$chainTerm',
        local: '(없음)',
        state: CheckState.unavailable,
        note: 'EntryResponse 에 term_code 가 아직 없다 (term_id 와 비교하면 안 된다)',
      );
    }
    return FieldCheck.compare(
      label: '학기',
      chain: '$chainTerm',
      local: '$localTermCode',
      note: '해시에 들어가지 않는 값이다',
    );
  }

  /// 지갑 주소와 user id 를 매핑을 거쳐 대조한다.
  ///
  /// **체인 주소를 user id 로 옮겨서 비교한다** — 반대 방향(user id 로 「현재 주소」
  /// 하나를 꺼내 비교)이면 키를 교체한 사람의 옛 주소가 매핑에 없어서, 그 주소로
  /// 등록한 과거 항목이 전부 「불일치 = 변조 감지」가 된다. 주소는 바뀌어도
  /// **누구였는지는 바뀌지 않는다**는 쪽으로 대조해야 한다.
  ///
  /// 세 가지를 구분한다 — 응답에 필드가 없으면 「모름」, 실려 온 `address(0)` 은
  /// 「미처리」로 DB 의 `NULL` 과 맞아야 통과(§2.1), 주소가 있으면 매핑을 본다.
  static FieldCheck _comparePerson({
    required String label,
    required String? chainAddress,
    required String missingField,
    required int? userId,
    required Map<String, int>? userIdByAddress,
  }) {
    final localEmpty = userId == null;

    // 응답에 아예 없는 것은 「체인에 등록자가 없다」가 아니다.
    if (chainAddress == null) {
      return FieldCheck(
        label: label,
        chain: '(읽지 못함)',
        local: localEmpty ? '(미처리)' : 'user #$userId',
        state: CheckState.unavailable,
        note: '온체인 응답에 $missingField 필드가 없다',
      );
    }

    final chainEmpty = OnChainEntry.isZeroAddress(chainAddress);

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
        chain: chainEmpty ? '(미처리)' : chainAddress,
        local: localEmpty ? '(미처리)' : 'user #$userId',
        state: CheckState.failed,
        note: '한쪽만 값이 있다',
      );
    }

    if (userIdByAddress == null) {
      return FieldCheck(
        label: label,
        chain: chainAddress,
        local: 'user #$userId',
        state: CheckState.unavailable,
        note: '주소 ↔ user id 매핑 API 대기',
      );
    }

    // 주소는 대소문자 표기(EIP-55 체크섬)가 갈릴 수 있어 소문자로 맞춰서 찾는다.
    final owner = userIdByAddress[chainAddress.toLowerCase()];
    if (owner == null) {
      // 매핑에 없는 주소다. 「다른 사람이다」가 아니라 **누구인지 모른다**는 뜻이다 —
      // 키 교체 후 옛 주소가 아직 매핑에 안 실린 경우가 여기 걸린다.
      // 여기서 불일치로 판정하면 과거 항목이 학생 화면에서 빨갛게 뜬다.
      return FieldCheck(
        label: label,
        chain: chainAddress,
        local: 'user #$userId',
        state: CheckState.unavailable,
        note: '이 주소가 지갑 매핑에 없다 (키 교체 전 주소일 수 있다)',
      );
    }

    return FieldCheck(
      label: label,
      chain: '$chainAddress (user #$owner)',
      local: 'user #$userId',
      state: owner == userId ? CheckState.passed : CheckState.failed,
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

    if (hashState == CheckState.unavailable)
      return VerificationStatus.unavailable;

    // 세 단계를 다 못 돌았으면 초록을 주지 않는다.
    // 「확인 못 함」을 「이상 없음」으로 보여주면 검증의 의미가 없다.
    //
    // 체인 해시가 없어 서버 해시로 대신 맞춰본 경우도 여기 걸린다 —
    // 「서버가 준 값끼리」 일치한 것이라 체인과 대조했다고 말할 수 없다.
    final incomplete = !chainDataAvailable ||
        !chainHashCompared ||
        receiptState == CheckState.unavailable ||
        fields.any((f) => f.state == CheckState.unavailable);

    return incomplete
        ? VerificationStatus.partial
        : VerificationStatus.verified;
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
