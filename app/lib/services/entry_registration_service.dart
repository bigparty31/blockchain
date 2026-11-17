import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/enums.dart';
import '../core/hashing.dart';
import '../core/signing/eip712.dart';
import '../core/signing/ledger_types.dart';
import '../core/signing/signing_service.dart';
import 'auth_service.dart';
import 'signed_post.dart';

export 'signed_post.dart' show EntryDecisionException, EntryDecisionFailure;

/// 총무가 등록하는 한 건 — 화면에 입력한 값. 거래처·목적은 보낼 때 정본화한다 (HASHING §1.1).
class EntryDraft {
  final EntryKind kind;

  /// DB 의 학기 id. 서명에는 이 학기의 **학기 코드**(`term_code`)가 들어간다.
  final int termId;
  final int amount;
  final String counterparty;
  final String purpose;

  /// 지출의 예산 id. 수입은 null 이다 (서버가 예산 연결을 400 으로 막는다).
  final int? budgetId;

  /// 사용일의 KST 자정 Unix 초 (HASHING §1.3).
  final int occurredAt;

  /// 영수증 원본 바이트의 SHA-256 (`0x` + 소문자). 수입은 선택.
  final String? receiptHash;

  /// 서버에 올린 영수증 파일 경로 (`POST /receipts` 응답, `/receipts/{해시}.{확장자}`).
  /// 서버는 해시만 있고 파일이 없으면 400 으로 막는다 (#66 B2).
  final String? receiptPath;

  /// 정정이면 원본 id (`corrects_entry_id`). 서명의 `correctsId` 가 이 값이고, 정정이 아니면 0 이다.
  /// 정정의 [amount] 는 새 총액이 아니라 **증감분**이다 — 음수는 정정에만 허용된다 (CONTRACTS §정정).
  final int? correctsEntryId;

  /// 정정 사유 유형. 서명·해시에는 들어가지 않는다 (PRD §4.4).
  final CorrectionReason? correctionReason;

  /// 영수증 OCR 판독 결과 (`POST /ocr/receipt`). 초안 등록에 그대로 싣는다.
  /// **해시·서명에는 넣지 않는다** — 엔진이 바뀌어 판독값이 달라져도 검증 배지가 깨지지 않게 (PRD §6).
  final OcrReading? ocr;

  const EntryDraft({
    required this.kind,
    required this.termId,
    required this.amount,
    required this.counterparty,
    required this.purpose,
    this.budgetId,
    required this.occurredAt,
    this.receiptHash,
    this.receiptPath,
    this.correctsEntryId,
    this.correctionReason,
    this.ocr,
  });

  bool get isCorrection => correctsEntryId != null;

  /// 같은 초안에 서버에 올린 영수증 경로를 붙인 것 — 입력을 다시 읽지 않고 제출 시점의 값을 그대로 쓴다.
  EntryDraft withReceiptPath(String? path) => _copy(receiptPath: path, ocr: ocr);

  /// 같은 초안에 OCR 판독 결과를 붙인 것.
  EntryDraft withOcr(OcrReading? reading) => _copy(receiptPath: receiptPath, ocr: reading);

  EntryDraft _copy({required String? receiptPath, required OcrReading? ocr}) => EntryDraft(
        kind: kind,
        termId: termId,
        amount: amount,
        counterparty: counterparty,
        purpose: purpose,
        budgetId: budgetId,
        occurredAt: occurredAt,
        receiptHash: receiptHash,
        receiptPath: receiptPath,
        correctsEntryId: correctsEntryId,
        correctionReason: correctionReason,
        ocr: ocr,
      );

  String get canonicalCounterparty => Hashing.canonical(counterparty);
  String get canonicalPurpose => Hashing.canonical(purpose);

  /// 서버 `create_entry` 가 계산하는 것과 같은 `meta_hash`.
  String get metaHash => Hashing.metaHash(
        amount: amount,
        counterparty: canonicalCounterparty,
        purpose: canonicalPurpose,
        occurredAt: occurredAt,
        receiptHash: receiptHash,
      );

  /// `POST /entries` 본문 (EntryCreate).
  Map<String, Object> toCreateJson() => {
        'term_id': termId,
        'kind': kind.code,
        'amount': amount,
        'counterparty': canonicalCounterparty,
        'purpose': canonicalPurpose,
        if (budgetId != null) 'budget_id': budgetId!,
        'occurred_at': occurredAt,
        if (receiptHash != null) 'receipt_hash': receiptHash!,
        if (receiptPath != null) 'receipt_path': receiptPath!,
        if (correctsEntryId != null) 'corrects_entry_id': correctsEntryId!,
        if (correctionReason != null) 'correction_reason': correctionReason!.code,
        ...?ocr?.toCreateJson(),
      };

  @override
  bool operator ==(Object other) =>
      other is EntryDraft &&
      other.kind == kind &&
      other.termId == termId &&
      other.amount == amount &&
      other.canonicalCounterparty == canonicalCounterparty &&
      other.canonicalPurpose == canonicalPurpose &&
      other.budgetId == budgetId &&
      other.occurredAt == occurredAt &&
      other.receiptHash == receiptHash &&
      other.receiptPath == receiptPath &&
      other.correctsEntryId == correctsEntryId &&
      other.correctionReason == correctionReason &&
      other.ocr == ocr;

  @override
  int get hashCode => Object.hash(kind, termId, amount, canonicalCounterparty, canonicalPurpose, budgetId, occurredAt,
      receiptHash, receiptPath, correctsEntryId, correctionReason, ocr);
}

/// 영수증 OCR 판독 결과 — `POST /ocr/receipt` 응답 (PRD §6). **차단이 아니라 경고다.**
///
/// 판정은 서버가 한다(입력 금액과 판독 금액 비교, 같은 승인번호·결제일시·금액 중복 조회). 앱은 받은 값을
/// 초안에 그대로 싣고, 불일치·중복이면 제출 전에 한 번 알린다.
class OcrReading {
  final OcrStatus status;

  /// 판독한 금액. 못 읽었으면 null.
  final int? amount;
  final String? approvalNo;

  /// 영수증에 찍힌 결제 일시 (Unix 초).
  final int? paidAt;

  /// 중복이면 이미 올라간 내역 id.
  final int? duplicateOf;

  const OcrReading({required this.status, this.amount, this.approvalNo, this.paidAt, this.duplicateOf});

  /// `ocr_status` 가 없으면 판독 결과가 아니다 — [FormatException].
  factory OcrReading.fromJson(Map<String, dynamic> json) {
    final status = json['ocr_status'];
    if (status is! String) throw const FormatException('ocr_status 가 없다');
    return OcrReading(
      status: OcrStatus.fromCode(status),
      amount: json['ocr_amount'] as int?,
      approvalNo: json['ocr_approval_no'] as String?,
      paidAt: json['ocr_paid_at'] as int?,
      duplicateOf: json['duplicate_of'] as int?,
    );
  }

  /// 그대로 제출하면 승인할 때 사유를 적어야 하는 경고 — 제출 전에 한 번 묻는다.
  bool get needsConfirm => status == OcrStatus.MISMATCH || status == OcrStatus.DUPLICATE;

  /// `POST /entries` 에 싣는 값 (EntryCreate 의 `ocr_*`). 중복 대상 id 는 서버가 다시 찾으므로 보내지 않는다.
  Map<String, Object> toCreateJson() => {
        'ocr_status': status.code,
        if (amount != null) 'ocr_amount': amount!,
        if (approvalNo != null) 'ocr_approval_no': approvalNo!,
        if (paidAt != null) 'ocr_paid_at': paidAt!,
      };

  @override
  bool operator ==(Object other) =>
      other is OcrReading &&
      other.status == status &&
      other.amount == amount &&
      other.approvalNo == approvalNo &&
      other.paidAt == paidAt &&
      other.duplicateOf == duplicateOf;

  @override
  int get hashCode => Object.hash(status, amount, approvalNo, paidAt, duplicateOf);
}

/// OCR 서버가 받는 이미지 형식 (`jpg`·`png`). PDF·WebP 영수증은 판독하지 않는다 — null.
String? ocrImageFormat(List<int> bytes) {
  bool starts(List<int> sig) {
    if (bytes.length < sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (bytes[i] != sig[i]) return false;
    }
    return true;
  }

  if (starts(const [0xFF, 0xD8, 0xFF])) return 'jpg';
  if (starts(const [0x89, 0x50, 0x4E, 0x47])) return 'png';
  return null;
}

/// 제출 결과 — 체인에 기록된 상태. 예산 문제는 revert 가 아니라 `BLOCKED` 로 **기록된다** (IAccountingLedger).
class SubmitOutcome {
  final EntryStatus status; // PENDING | BLOCKED
  final BlockReason? blockReason;
  const SubmitOutcome(this.status, this.blockReason);
}

/// 서버에 올린 영수증 — 서버가 다시 계산한 해시(앱 계산과 같음을 확인한 값)와 저장 경로.
class ReceiptUpload {
  final String hash;
  final String path;
  const ReceiptUpload(this.hash, this.path);
}

/// 등록 화면이 쓰는 입구. 테스트는 가짜를 넣는다.
abstract class EntryRegistrar {
  /// 영수증 원본을 올린다 — 초안보다 먼저. 서버 해시가 원본과 다르면 던진다.
  Future<ReceiptUpload> uploadReceipt(List<int> bytes, {required String filename});

  /// 서버에 있는 영수증 원본 (`GET /receipts/{파일}`). 못 받으면 null — 해시 대조는 부르는 쪽이 한다.
  Future<List<int>?> downloadReceipt(String receiptPath);

  /// 영수증 OCR 판독·판정 (`POST /ocr/receipt`, 저장하지 않음). **등록을 막지 않는다** — 판독하지 못하면
  /// (형식이 PDF·WebP, 서버 오류, 시간 초과) null 이고 OCR 값 없이 등록한다. 로그인이 끝났을 때만 던진다.
  Future<OcrReading?> readReceipt(List<int> bytes, {required int amount});

  /// 초안 저장 — 발급된 id.
  Future<int> saveDraft(EntryDraft draft);

  /// 서명해 제출 — `PENDING` 또는 `BLOCKED`.
  Future<SubmitOutcome> submit(int id, EntryDraft draft);
}

/// 총무의 등록 — ① 초안 `POST /entries`(체인에 없음, id 만 발급) → ② 기기 키로 EIP-712 `RecordRequest` 에 서명해
/// `POST /entries/{id}/submit`. 체인 제출은 서버 릴레이어가 한다 (`relay_record`).
///
/// **서명하는 값은 총무가 입력한 값이다.** 서버는 DB 에 저장한 값으로 `RecordRequest` 를 다시 만들어 서명자를
/// 복구하므로, 서버가 저장한 값이 입력과 다르면 서명이 맞지 않아 400 으로 돌아온다 — 다른 값으로 기록되지 않는다.
///
/// 같은 초안은 서명 시한 안에서 같은 id 로 다시 제출할 수 있다 (docs/API.md §2.3). 화면은 제출이 실패하면 id 를
/// 들고 있다가 다시 제출한다.
class EntryRegistrationService implements EntryRegistrar {
  /// HTTP 클라이언트. 테스트에서 갈아끼운다.
  static http.Client client = http.Client();

  /// 서명 유효 시한 (docs/API.md §2.3 — 발급 시점 + 10분).
  static const signatureTtl = Duration(minutes: 10);

  /// 서버는 릴레이 뒤 receipt 를 최대 30초 기다린다. 그보다 길게 둔다.
  static const postTimeout = Duration(seconds: 45);
  static const _readTimeout = Duration(seconds: 5);

  final SigningService _signer;
  final DateTime Function() _now;

  EntryRegistrationService({SigningService? signer, DateTime Function()? now})
      : _signer = signer ?? SigningService(),
        _now = now ?? DateTime.now;

  /// 업로드는 사진 크기에 따라 오래 걸릴 수 있다.
  static const uploadTimeout = Duration(seconds: 60);

  /// 영수증 원본 바이트를 그대로 `POST /receipts`(multipart `file`)로 올린다 — 재인코딩하지 않는다 (HASHING §4).
  ///
  /// 서버는 받은 바이트로 SHA-256 을 다시 계산해 돌려준다. **앱이 계산한 해시와 다르면 멈춘다** — 전송 중에
  /// 바뀌었거나 서버가 다른 파일을 저장했다는 뜻이고, 그 해시로 등록하면 학생이 내려받은 영수증과 기록이 어긋난다.
  @override
  Future<ReceiptUpload> uploadReceipt(List<int> bytes, {required String filename}) async {
    final body = await sendAndDecode(
      (authHeaders) async {
        final request = http.MultipartRequest('POST', Uri.parse('${ApiConfig.baseUrl}/receipts'))
          ..headers.addAll(authHeaders)
          ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
        // 제한은 본문을 다 받을 때까지 건다 — 헤더만 오고 본문이 끝나지 않으면 `send()` 의 제한만으로는 영영 안 끝난다.
        return (() async => http.Response.fromStream(await client.send(request)))().timeout(uploadTimeout);
      },
      what: '영수증 업로드',
    );
    final hash = body['receipt_hash'];
    final path = body['receipt_path'];
    if (hash is! String || path is! String) {
      throw const EntryDecisionException(EntryDecisionFailure.unknownOutcome, '영수증 업로드 결과를 읽지 못했어요. 다시 첨부해 주세요.');
    }
    if (!Hashing.hashEquals(hash, Hashing.fileHash(bytes))) {
      throw const EntryDecisionException(
        EntryDecisionFailure.mismatch,
        '서버에 저장된 영수증이 고른 사진과 달라요. 다시 첨부해 주세요.',
      );
    }
    return ReceiptUpload(hash.toLowerCase(), path);
  }

  /// 영수증 원본을 내려받는다 — 반려·차단 건을 다시 등록할 때 같은 영수증을 다시 쓰려고.
  /// 경로의 파일 이름만 쓴다(`/receipts/{파일}`). 옛 서버(#66 이전)나 네트워크 오류면 null.
  @override
  Future<List<int>?> downloadReceipt(String receiptPath) async {
    final name = receiptPath.split('/').last;
    if (name.isEmpty) return null;
    try {
      final res = await client
          .get(Uri.parse('${ApiConfig.baseUrl}/receipts/${Uri.encodeComponent(name)}'), headers: AuthService().authHeaders)
          .timeout(uploadTimeout);
      return res.statusCode == 200 ? res.bodyBytes : null;
    } catch (_) {
      return null;
    }
  }

  /// 서버는 CLOVA 를 최대 15초 기다린다. 그보다 조금 길게 둔다.
  static const ocrTimeout = Duration(seconds: 25);

  @override
  Future<OcrReading?> readReceipt(List<int> bytes, {required int amount}) async {
    final format = ocrImageFormat(bytes);
    if (format == null) return null;
    try {
      final body = await postSigned(
        client,
        '${ApiConfig.baseUrl}/ocr/receipt',
        {'image_base64': base64Encode(bytes), 'format': format, 'amount': amount},
        what: '영수증 판독',
        timeout: ocrTimeout,
      );
      return OcrReading.fromJson(body);
    } on EntryDecisionException catch (e) {
      if (e.failure == EntryDecisionFailure.unauthorized) rethrow;
      return null;
    } catch (_) {
      return null; // 응답 모양이 다르면(옛 서버 등) 판독 없이 등록한다
    }
  }

  /// ① 초안 저장. 발급된 id 를 돌려준다. 체인에는 아무것도 올라가지 않는다.
  @override
  Future<int> saveDraft(EntryDraft draft) async {
    // 쓰기 요청이라 제출과 같은 시간을 기다린다 — 서버는 초안을 만들었는데 응답만 5초 안에 못 받으면 id 를 잃고
    // 다시 누를 때 두 번째 초안이 생긴다 (서버 중복 검사는 ocr_approval_no 기준이라 여기서는 막지 못한다).
    final body = await postSigned(client, ApiConfig.entries, draft.toCreateJson(), what: '초안 저장', timeout: postTimeout);
    final id = body['id'];
    if (id is! int) {
      throw const EntryDecisionException(
        EntryDecisionFailure.unknownOutcome,
        '초안 번호를 받지 못했어요. 내 등록 현황에서 저장됐는지 확인해 주세요.',
      );
    }
    return id;
  }

  /// ② 서명해 제출한다. 결과는 `PENDING` 또는 `BLOCKED`.
  @override
  Future<SubmitOutcome> submit(int id, EntryDraft draft) async {
    final term = await _termCodeOf(draft.termId);
    final domain = await ledgerDomainForSigning();
    final deadline = _now().millisecondsSinceEpoch ~/ 1000 + signatureTtl.inSeconds;
    final message = recordMessage(id: id, draft: draft, term: term, deadline: deadline);
    final signature = await signOrThrow(_signer, domain, message, '등록 서명');

    final body = await postSigned(
      client,
      '${ApiConfig.entries}/$id/submit',
      {'signature': signature, 'deadline': deadline},
      what: '등록 제출',
      timeout: postTimeout,
    );
    final status = body['status'];
    final reason = body['block_reason'];
    try {
      final outcome = SubmitOutcome(
        EntryStatus.fromCode(status as String),
        reason is String ? BlockReason.fromCode(reason) : null,
      );
      // 제출 결과는 PENDING·BLOCKED 뿐이고, BLOCKED 는 사유가 있어야 한다 (서버 스키마). 사유를 지어내지 않는다
      final valid = outcome.status == EntryStatus.PENDING ||
          (outcome.status == EntryStatus.BLOCKED && outcome.blockReason != null);
      if (!valid) throw const FormatException('제출 결과가 PENDING·BLOCKED(사유 포함)가 아니다');
      return outcome;
    } catch (_) {
      throw const EntryDecisionException(
        EntryDecisionFailure.unknownOutcome,
        '등록 결과를 읽지 못했어요. 내 등록 현황에서 확인해 주세요.',
      );
    }
  }

  /// 서버(`submit_entry`)가 DB 값으로 다시 만드는 것과 같은 `RecordRequest`.
  static Eip712Message recordMessage({
    required int id,
    required EntryDraft draft,
    required int term,
    required int deadline,
  }) =>
      LedgerTypes.recordRequest(
        id: id,
        hash: draft.metaHash,
        amount: draft.amount,
        kind: draft.kind,
        term: term,
        occurredAt: draft.occurredAt,
        budgetId: draft.budgetId ?? 0,
        correctsId: draft.correctsEntryId ?? 0,
        deadline: deadline,
      );

  /// DB 학기 id → 온체인 학기 코드 (`GET /terms/{id}`). 못 읽으면 서명하지 않는다.
  Future<int> _termCodeOf(int termId) async {
    const notReady = EntryDecisionException(
      EntryDecisionFailure.notReady,
      '학기 정보를 받지 못해 서명할 수 없어요. 잠시 후 다시 시도해 주세요.',
    );
    try {
      final res = await client
          .get(Uri.parse('${ApiConfig.baseUrl}/terms/$termId'), headers: AuthService().authHeaders)
          .timeout(_readTimeout);
      if (res.statusCode != 200) throw notReady;
      final code = (jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>)['term_code'];
      if (code is! int) throw notReady;
      return code;
    } on EntryDecisionException {
      rethrow;
    } catch (_) {
      throw notReady;
    }
  }
}
