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
  });

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
      other.receiptPath == receiptPath;

  @override
  int get hashCode =>
      Object.hash(kind, termId, amount, canonicalCounterparty, canonicalPurpose, budgetId, occurredAt, receiptHash, receiptPath);
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
        return http.Response.fromStream(await client.send(request).timeout(uploadTimeout));
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

  /// ① 초안 저장. 발급된 id 를 돌려준다. 체인에는 아무것도 올라가지 않는다.
  @override
  Future<int> saveDraft(EntryDraft draft) async {
    final body = await postSigned(client, ApiConfig.entries, draft.toCreateJson(), what: '초안 저장', timeout: _readTimeout);
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
        correctsId: 0,
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
