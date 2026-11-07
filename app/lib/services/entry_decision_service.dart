import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/enums.dart';
import '../core/hashing.dart';
import '../core/signing/eip712.dart';
import '../core/signing/ledger_types.dart';
import '../core/signing/signing_service.dart';
import '../models/entry_model.dart';
import 'auth_service.dart';
import 'chain_domain_service.dart';

/// 승인·반려를 끝내지 못한 이유. 화면은 [EntryDecisionException.message] 를 그대로 띄우고,
/// 이 값으로 다음 동작(목록 새로 읽기·로그인 화면)을 고른다. **서버 문구로 분기하지 않는다.**
enum EntryDecisionFailure {
  /// 정본화한 사유가 비었다 (서버도 400).
  invalidReason,

  /// 화면 값으로 다시 계산한 `meta_hash` 가 서버가 준 값과 다르다 — 서명하지 않는다.
  mismatch,

  /// 서명에 필요한 값(최신 상태·학기 코드·등록자 주소·서명 도메인)을 받지 못했다.
  notReady,

  /// 서명 직전에 다시 읽었더니 이미 처리됐거나 등록 내용이 화면과 달라졌다 (보드 ②).
  changed,

  /// 키가 없거나 본인 확인을 취소·실패했다.
  signing,

  /// 401 — 로그인이 끝났다. 세션은 이미 비웠다.
  unauthorized,

  /// 403 — 역할이 아니거나 본인 등록 건이다.
  forbidden,

  /// 404 — 그런 내역이 없다.
  notFound,

  /// 409 — 다른 임원의 확정·반려가 먼저 진행 중이다.
  conflict,

  /// 400·422 — 서버나 체인이 거부했다. 항목은 그대로다.
  refused,

  /// 보냈지만 결과를 모른다 (503·연결 끊김·시간 초과). 다시 보내기 전에 목록부터 새로 읽는다.
  unknownOutcome,
}

class EntryDecisionException implements Exception {
  final EntryDecisionFailure failure;
  final String message;
  const EntryDecisionException(this.failure, this.message);

  @override
  String toString() => 'EntryDecisionException(${failure.name}): $message';
}

/// 감사·회장의 승인·반려 — 기기 키로 EIP-712 `ConfirmApproval`·`RejectDecision` 에 서명해
/// `POST /entries/{id}/confirm`·`/reject` 로 보낸다. 체인 제출은 서버 릴레이어가 한다 (`relay_confirm`·`relay_reject`).
///
/// **서명하는 값은 화면이 보여 준 값이다** (보드 ①). 화면 값으로 `meta_hash` 를 다시 계산해 서버 값과
/// 다르면 서명하지 않는다 — 서버 값을 그대로 서명하면 서버가 화면과 다른 내용에 서명을 받아 갈 수 있다.
///
/// 서명 직전에 막히는 경우(사유·해시·학기 코드·등록자 주소·도메인)는 본인 확인을 묻기 전에 멈춘다.
class EntryDecisionService {
  /// HTTP 클라이언트. 테스트에서 갈아끼운다.
  static http.Client client = http.Client();

  /// 서명 유효 시한. 등록 서명과 같은 10분 (docs/API.md §2.3).
  static const signatureTtl = Duration(minutes: 10);

  /// 서버는 릴레이 뒤 receipt 를 최대 30초 기다린다 (`RECEIPT_TIMEOUT_SECONDS`). 그보다 길게 둔다.
  static const postTimeout = Duration(seconds: 45);
  static const _readTimeout = Duration(seconds: 5);

  final SigningService _signer;
  final DateTime Function() _now;

  EntryDecisionService({SigningService? signer, DateTime Function()? now})
      : _signer = signer ?? SigningService(),
        _now = now ?? DateTime.now;

  /// 서버(`reject_entry`)가 다시 만드는 것과 같은 `RejectDecision`.
  ///
  /// `entryCommit` 의 등록자는 체인의 `registrant`(지갑 주소)이고, 학기는 학기 코드(`YYYYS`)다.
  /// 사유는 정본화(§3)한 뒤 해시한다 — 서버도 `canonical_text` 후 `text_hash` 를 쓴다.
  static Eip712Message rejectMessage({
    required EntryModel entry,
    required String registrant,
    required String reason,
    required int deadline,
  }) =>
      LedgerTypes.rejectDecision(
        id: entry.id,
        entryCommit: _entryCommit(entry, registrant),
        reasonHash: Hashing.textHash(Hashing.canonicalText(reason)),
        deadline: deadline,
      );

  /// 경고 항목인가 — 카테고리 경고이거나 OCR 이 `MISMATCH`·`DUPLICATE`·`UNREADABLE` 이면 경고다.
  /// 서버 `confirm_entry` 의 `had_warning` 판정과 같다. `MATCH`·`NO_NUMBER`·OCR 없음(null)은 정상이다.
  static bool hadWarning(EntryModel entry) =>
      entry.categoryWarning ||
      entry.ocrStatus == OcrStatus.MISMATCH ||
      entry.ocrStatus == OcrStatus.DUPLICATE ||
      entry.ocrStatus == OcrStatus.UNREADABLE;

  static const _zeroHash = '0x0000000000000000000000000000000000000000000000000000000000000000';

  /// 서버(`confirm_entry`)가 다시 만드는 것과 같은 `ConfirmApproval`.
  ///
  /// 경고 항목이면 [warningReason] 을 정본화(§3)해 해시하고, 아니면 `bytes32(0)` 이다 (빈 문자열을 해시하지 않는다).
  static Eip712Message confirmMessage({
    required EntryModel entry,
    required String registrant,
    String? warningReason,
    required int deadline,
  }) {
    final warned = hadWarning(entry);
    return LedgerTypes.confirmApproval(
      id: entry.id,
      hash: entry.metaHash,
      entryCommit: _entryCommit(entry, registrant),
      hadWarning: warned,
      warningReasonHash: warned ? Hashing.textHash(Hashing.canonicalText(warningReason ?? '')) : _zeroHash,
      deadline: deadline,
    );
  }

  /// [entry] 를 확정한다. 경고 항목이면 [warningReason] 이 필수다. 실패하면 [EntryDecisionException] 을 던진다.
  ///
  /// 경고가 아닌 건에는 사유를 보내지 않는다 — 서버가 400 으로 거부한다.
  Future<void> confirm(EntryModel entry, {String? warningReason}) async {
    final warned = hadWarning(entry);
    final canon = warned ? Hashing.canonicalText(warningReason ?? '') : null;
    if (warned && canon!.isEmpty) {
      throw const EntryDecisionException(EntryDecisionFailure.invalidReason, '경고 무시 사유를 입력해 주세요.');
    }
    final ready = await _prepare(entry);
    final message = confirmMessage(
      entry: entry,
      registrant: ready.registrant,
      warningReason: canon,
      deadline: ready.deadline,
    );
    final signature = await _sign(ready.domain, message, '승인 서명');

    await _post(
      '${ApiConfig.entries}/${entry.id}/confirm',
      {'signature': signature, 'deadline': ready.deadline, if (canon != null) 'warning_reason': canon},
      what: '승인',
    );
  }

  /// [entry] 를 [reason] 으로 반려한다. 실패하면 [EntryDecisionException] 을 던진다.
  Future<void> reject(EntryModel entry, String reason) async {
    final canon = Hashing.canonicalText(reason);
    if (canon.isEmpty) {
      throw const EntryDecisionException(EntryDecisionFailure.invalidReason, '반려 사유를 입력해 주세요.');
    }
    final ready = await _prepare(entry);
    final message = rejectMessage(entry: entry, registrant: ready.registrant, reason: canon, deadline: ready.deadline);
    final signature = await _sign(ready.domain, message, '반려 서명');

    await _post(
      '${ApiConfig.entries}/${entry.id}/reject',
      {'signature': signature, 'deadline': ready.deadline, 'reject_reason': canon},
      what: '반려',
    );
  }

  /// 서명 직전까지의 공통 준비 — 화면 값 검산, 학기 코드, 최신 상태 재조회, 등록자 주소, 서명 도메인, 시한.
  /// 여기서 막히면 본인 확인을 묻지 않는다.
  Future<({String registrant, Eip712Domain domain, int deadline})> _prepare(EntryModel entry) async {
    _checkShownValues(entry);
    if (entry.termCode == null) {
      throw const EntryDecisionException(
        EntryDecisionFailure.notReady,
        '학기 코드를 받지 못해 서명할 수 없어요. 목록을 새로 고쳐 주세요.',
      );
    }
    await _checkStillSame(entry);
    final registrant = await _registrantOf(entry.createdBy);
    final domain = await _ledgerDomain();
    final deadline = _now().millisecondsSinceEpoch ~/ 1000 + signatureTtl.inSeconds;
    return (registrant: registrant, domain: domain, deadline: deadline);
  }

  static String _entryCommit(EntryModel entry, String registrant) {
    final term = entry.termCode;
    if (term == null) throw ArgumentError('termCode 가 없으면 entryCommit 을 만들 수 없다');
    return LedgerTypes.entryCommit(
      hash: entry.metaHash,
      amount: entry.amount,
      kind: entry.kind,
      term: term,
      occurredAt: entry.occurredAt,
      budgetId: entry.budgetId ?? 0,
      correctsId: entry.correctsEntryId ?? 0,
      registrant: registrant,
    );
  }

  /// 화면에 보인 값으로 `meta_hash` 를 다시 계산해 서버 값과 맞춰 본다.
  static void _checkShownValues(EntryModel entry) {
    final recomputed = Hashing.metaHash(
      amount: entry.amount,
      counterparty: entry.counterparty,
      purpose: entry.purpose,
      occurredAt: entry.occurredAt,
      receiptHash: entry.receiptHash,
    );
    if (!Hashing.hashEquals(recomputed, entry.metaHash)) {
      throw const EntryDecisionException(
        EntryDecisionFailure.mismatch,
        '화면의 등록 내용이 기록된 해시와 맞지 않아 서명하지 않았어요. 목록을 새로 고쳐 다시 확인해 주세요.',
      );
    }
  }

  /// 서명 직전 재조회 (보드 ②) — `GET /entries/{id}` 로 지금 값을 다시 읽어, 아직 `PENDING` 이고
  /// 서명에 들어가는 값이 화면에 보인 것과 같을 때만 넘어간다.
  ///
  /// 목록은 15초마다 읽으니 그 사이 다른 임원이 먼저 확정·반려했거나 정정·수정 요청으로 값이 바뀌었을 수 있다.
  /// 그대로 서명하면 서버가 400·409 로 돌려보내는데, 그때는 이미 지문을 댄 뒤다 — 묻기 전에 멈춘다.
  Future<void> _checkStillSame(EntryModel shown) async {
    const unreadable = EntryDecisionException(
      EntryDecisionFailure.notReady,
      '이 건의 최신 상태를 확인하지 못해 서명하지 않았어요. 잠시 후 다시 시도해 주세요.',
    );
    final EntryModel fresh;
    try {
      final res = await client
          .get(Uri.parse('${ApiConfig.entries}/${shown.id}'), headers: AuthService().authHeaders)
          .timeout(_readTimeout);
      if (res.statusCode == 401) {
        await AuthService().reportUnauthorized();
        throw const EntryDecisionException(EntryDecisionFailure.unauthorized, '로그인이 끝났어요. 다시 로그인해 주세요.');
      }
      if (res.statusCode == 404) {
        throw const EntryDecisionException(EntryDecisionFailure.notFound, '이 내역을 찾지 못했어요. 목록을 새로 고쳐 주세요.');
      }
      if (res.statusCode != 200) throw unreadable;
      fresh = EntryModel.fromJson(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } on EntryDecisionException {
      rethrow;
    } catch (_) {
      throw unreadable;
    }
    if (fresh.status != EntryStatus.PENDING) {
      throw EntryDecisionException(
        EntryDecisionFailure.changed,
        '이 건은 이미 「${fresh.status.label}」 상태예요. 목록을 새로 고쳐 확인해 주세요.',
      );
    }
    if (!_sameSignedValues(shown, fresh)) {
      throw const EntryDecisionException(
        EntryDecisionFailure.changed,
        '이 건의 등록 내용이 화면과 달라졌어요. 목록을 새로 고쳐 다시 확인한 뒤 서명해 주세요.',
      );
    }
  }

  /// 서명(`entryCommit`·`meta_hash`·`hadWarning`)에 들어가거나 화면이 보여 준 값이 같은가.
  static bool _sameSignedValues(EntryModel a, EntryModel b) {
    bool sameHash(String? x, String? y) => x == null || y == null ? x == y : Hashing.hashEquals(x, y);
    return sameHash(a.metaHash, b.metaHash) &&
        a.amount == b.amount &&
        a.kind == b.kind &&
        a.termCode == b.termCode &&
        a.occurredAt == b.occurredAt &&
        a.budgetId == b.budgetId &&
        a.correctsEntryId == b.correctsEntryId &&
        a.createdBy == b.createdBy &&
        a.counterparty == b.counterparty &&
        a.purpose == b.purpose &&
        sameHash(a.receiptHash, b.receiptHash) &&
        hadWarning(a) == hadWarning(b);
  }

  /// 등록자(user id)의 지갑 주소 — `GET /users/wallets`(주소 → user id)를 뒤집어 찾는다.
  ///
  /// `EntryResponse` 에 등록자 지갑 주소가 아직 없어서 쓰는 길이다 (보드 kky-fld). 필드가 생기거나
  /// 체인 조회(`GET /entries/{id}/onchain`)가 붙으면 그쪽으로 바꾼다. 서버가 주소를 틀리게 줘도
  /// `entryCommit` 이 체인 값과 달라져 반려가 revert 될 뿐, 서명이 다른 건에 쓰이지는 않는다.
  ///
  /// 한 사람이 주소를 여러 개 가질 수 있다(롤 변경). 그때는 어느 주소로 등록했는지 몰라 멈춘다.
  Future<String> _registrantOf(int userId) async {
    const notReady = EntryDecisionException(
      EntryDecisionFailure.notReady,
      '등록자 지갑 주소를 확인하지 못해 서명할 수 없어요. 잠시 후 다시 시도해 주세요.',
    );
    final Map<String, dynamic> wallets;
    try {
      final res = await client
          .get(Uri.parse('${ApiConfig.baseUrl}/users/wallets'), headers: AuthService().authHeaders)
          .timeout(_readTimeout);
      if (res.statusCode != 200) throw notReady;
      wallets = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } on EntryDecisionException {
      rethrow;
    } catch (_) {
      throw notReady;
    }
    final addresses = [for (final e in wallets.entries) if (e.value == userId) e.key];
    if (addresses.length != 1) throw notReady;
    return addresses.single;
  }

  static Future<Eip712Domain> _ledgerDomain() async {
    try {
      return await ChainDomainService.ledger();
    } on ChainDomainException catch (e) {
      throw EntryDecisionException(EntryDecisionFailure.notReady, e.message);
    }
  }

  Future<String> _sign(Eip712Domain domain, Eip712Message message, String reason) async {
    try {
      return await _signer.sign(domain, message, reason: reason);
    } on SigningException catch (e) {
      throw EntryDecisionException(EntryDecisionFailure.signing, e.message);
    }
  }

  /// 서명을 보낸다. 상태 코드로만 나누고, 400·403 은 서버 설명을 그대로 붙여 보여 준다.
  static Future<void> _post(String url, Map<String, Object> body, {required String what}) async {
    final http.Response res;
    try {
      res = await client
          .post(
            Uri.parse(url),
            headers: {...AuthService().authHeaders, 'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(postTimeout);
    } catch (_) {
      throw EntryDecisionException(
        EntryDecisionFailure.unknownOutcome,
        '$what 결과를 확인하지 못했어요. 목록을 새로 고쳐 처리됐는지 확인해 주세요.',
      );
    }

    final detail = _detail(res);
    switch (res.statusCode) {
      case 200:
      case 201:
        return;
      case 401:
        await AuthService().reportUnauthorized();
        throw const EntryDecisionException(EntryDecisionFailure.unauthorized, '로그인이 끝났어요. 다시 로그인해 주세요.');
      case 403:
        throw EntryDecisionException(EntryDecisionFailure.forbidden, detail ?? '이 작업을 할 권한이 없어요.');
      case 404:
        throw const EntryDecisionException(EntryDecisionFailure.notFound, '이 내역을 찾지 못했어요. 목록을 새로 고쳐 주세요.');
      case 409:
        throw const EntryDecisionException(
          EntryDecisionFailure.conflict,
          '다른 임원이 이 건을 먼저 처리하고 있어요. 목록을 새로 고쳐 결과를 확인해 주세요.',
        );
      case 400:
      case 422:
        throw EntryDecisionException(
          EntryDecisionFailure.refused,
          detail == null ? '$what 요청이 거부되었어요.' : '$what 요청이 거부되었어요: $detail',
        );
      default:
        throw EntryDecisionException(
          EntryDecisionFailure.unknownOutcome,
          '$what 결과를 확인하지 못했어요 (서버 ${res.statusCode}). 목록을 새로 고쳐 처리됐는지 확인해 주세요.',
        );
    }
  }

  /// FastAPI 오류 응답의 `detail` (문자열일 때만).
  static String? _detail(http.Response res) {
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is Map && body['detail'] is String) return body['detail'] as String;
    } catch (_) {}
    return null;
  }
}
