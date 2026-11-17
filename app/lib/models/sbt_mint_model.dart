/// 회원권(SBT) 일괄 발행 — 백엔드 `MintBatchResponse` 매핑 (docs/API.md 「회원권 2」, PRD §4.2·A3).
///
/// **서명할 값(`term_code`·`nonce`·`recipients`)은 기본값으로 메우지 않는다.** 하나라도 틀리면 다른
/// 다이제스트에 서명하게 되고, 체인은 `InvalidSignature` 로 거부한다. 형식이 틀리면 [FormatException].
library;

/// 발행 요청 상태 (`status`).
enum MintBatchStatus {
  /// 준비됨, 아직 보내지 않음 → 서명해 제출.
  prepared('PREPARED'),

  /// 다른 제출이 지금 체인에 보내는 중 → 잠시 뒤 조회.
  submitting('SUBMITTING'),

  /// 체인에 들어감. 학생별 결과는 targets.
  minted('MINTED'),

  /// 체인이 거부함. 사유는 reason.
  rejected('REJECTED'),

  /// 보냈지만 결과를 모름 → **같은 서명을 다시 보내지 않고** 조회한다.
  noResponse('NO_RESPONSE');

  final String code;
  const MintBatchStatus(this.code);

  static MintBatchStatus parse(String code) {
    for (final s in values) {
      if (s.code == code) return s;
    }
    throw FormatException('알 수 없는 발행 상태: $code');
  }

  /// 결과를 아직 모른다 — 다시 제출하지 말고 조회해야 하는 상태.
  bool get outcomeUnknown => this == submitting || this == noResponse;
}

/// 발행 대상 학생 한 명.
class MintTarget {
  final String studentNo;
  final int userId;
  final String name;
  final String address;

  /// `PENDING` | `MINTED` | `SKIPPED`
  final String status;
  final int? tokenId;
  final int? membershipId;

  const MintTarget({
    required this.studentNo,
    required this.userId,
    required this.name,
    required this.address,
    required this.status,
    required this.tokenId,
    required this.membershipId,
  });

  /// 체인에는 들어갔는데 DB 기록을 못 만든 학생 — 회원권은 유효하지만 운영자 확인이 필요하다 (API.md).
  bool get needsCheck => (status == 'MINTED' || status == 'SKIPPED') && membershipId == null;

  factory MintTarget.fromJson(Map<String, dynamic> json) {
    final r = _Reader(json, '발행 대상');
    final status = r.text('status');
    if (!const {'PENDING', 'MINTED', 'SKIPPED'}.contains(status)) throw FormatException('알 수 없는 대상 상태: $status');
    return MintTarget(
      studentNo: r.text('student_no'),
      userId: r.integer('user_id'),
      name: r.text('name'),
      address: r.text('address'),
      status: status,
      tokenId: r.maybeInteger('token_id'),
      membershipId: r.maybeInteger('membership_id'),
    );
  }
}

/// 준비 단계에서 빠진 학생.
class MintExcluded {
  final String studentNo;
  final String? name;

  /// `ALREADY_MEMBER` | `NOT_FOUND` | `NOT_STUDENT` | `DUPLICATE` | `DB_MISMATCH`
  final String status;

  const MintExcluded({required this.studentNo, required this.name, required this.status});

  /// 화면에 쓰는 이유.
  String get reasonLabel => switch (status) {
        'ALREADY_MEMBER' => '이미 보유',
        'NOT_FOUND' => '등록되지 않은 학번',
        'NOT_STUDENT' => '임원 계정',
        'DUPLICATE' => '명단에 중복',
        'DB_MISMATCH' => '기록 불일치 — 운영자 확인 필요',
        _ => status,
      };

  factory MintExcluded.fromJson(Map<String, dynamic> json) {
    final r = _Reader(json, '제외 학생');
    return MintExcluded(
      studentNo: r.text('student_no'),
      name: r.maybeText('name'),
      status: r.text('status'),
    );
  }

  static List<MintExcluded> listFrom(Object? json) {
    if (json is! List) throw const FormatException('제외 목록 형식이 올바르지 않아요');
    return [
      for (final e in json)
        if (e is Map<String, dynamic>) MintExcluded.fromJson(e) else throw const FormatException('제외 학생 형식이 올바르지 않아요'),
    ];
  }
}

/// 발행 요청 한 묶음 (최대 100명).
class MintBatch {
  final int id;
  final int termId;

  /// 서명할 `MintBatchRequest.term` (YYYYS).
  final int termCode;
  final MintBatchStatus status;

  /// 이 지갑으로 서명해야 한다.
  final String signerAddress;

  /// 서명할 `MintBatchRequest.nonce`.
  final int nonce;

  /// 서명할 `MintBatchRequest.recipients` — **받은 순서 그대로** 쓴다.
  final List<String> recipients;
  final int? deadline;
  final String? txHash;

  /// REJECTED 사유 (Solidity 에러 이름).
  final String? reason;
  final List<MintTarget> targets;

  /// 준비 응답에만 있다.
  final List<MintExcluded> excluded;
  final String message;

  const MintBatch({
    required this.id,
    required this.termId,
    required this.termCode,
    required this.status,
    required this.signerAddress,
    required this.nonce,
    required this.recipients,
    required this.deadline,
    required this.txHash,
    required this.reason,
    required this.targets,
    required this.excluded,
    required this.message,
  });

  int get mintedCount => targets.where((t) => t.status == 'MINTED').length;
  int get skippedCount => targets.where((t) => t.status == 'SKIPPED').length;

  factory MintBatch.fromJson(Map<String, dynamic> json) {
    final r = _Reader(json, '발행 요청');
    final recipients = json['recipients'];
    if (recipients is! List || recipients.any((e) => e is! String)) {
      throw const FormatException('발행 요청의 recipients 형식이 올바르지 않아요');
    }
    final targets = json['targets'];
    if (targets is! List) throw const FormatException('발행 요청의 targets 형식이 올바르지 않아요');
    final parsedTargets = [
      for (final t in targets)
        if (t is Map<String, dynamic>) MintTarget.fromJson(t) else throw const FormatException('발행 대상 형식이 올바르지 않아요'),
    ];
    // 화면은 targets(학번·이름)를 보여 주고 서명은 recipients 에 한다 — 둘이 어긋나면 본 것과 다른 것에 서명하게 된다
    if (parsedTargets.length != recipients.length ||
        [for (var i = 0; i < recipients.length; i++) parsedTargets[i].address.toLowerCase() != (recipients[i] as String).toLowerCase()]
            .any((d) => d)) {
      throw const FormatException('발행 대상과 서명할 주소가 서로 맞지 않아요');
    }
    return MintBatch(
      id: r.integer('id'),
      termId: r.integer('term_id'),
      termCode: r.integer('term_code'),
      status: MintBatchStatus.parse(r.text('status')),
      signerAddress: r.text('signer_address'),
      nonce: r.integer('nonce'),
      recipients: List<String>.from(recipients),
      deadline: r.maybeInteger('deadline'),
      txHash: r.maybeText('tx_hash'),
      reason: r.maybeText('reason'),
      targets: parsedTargets,
      excluded: json['excluded'] == null ? const [] : MintExcluded.listFrom(json['excluded']),
      message: r.text('message'),
    );
  }
}

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

  String? maybeText(String key) {
    final v = json[key];
    if (v == null) return null;
    return v is String ? v : _bad(key);
  }
}
