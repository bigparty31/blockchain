import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/hashing.dart';
import '../core/signing/budget_types.dart';
import '../core/signing/eip712.dart';
import '../core/signing/signing_service.dart';
import '../models/budget_revision_model.dart';
import 'api_service.dart';
import 'auth_service.dart';
import 'chain_domain_service.dart';

/// 회장 서명·감사 승인·반려를 끝내지 못한 이유. 화면은 [RevisionDecisionException.message] 를 띄우고
/// 이 값으로 다음 동작(목록 새로 읽기·로그인 화면)을 고른다. **서버 문구로 분기하지 않는다.**
///
/// #64 의 `EntryDecisionFailure` 와 이름을 나눈 이유: 그 파일은 다른 브랜치에 있고, 증액에만 있는
/// 경우([expired] — 회장 서명 시한 경과)가 따로 있다.
enum RevisionDecisionFailure {
  /// 정본화한 반려 사유가 비었다 (서버도 400).
  invalidReason,

  /// 서명에 필요한 값(현재 예산 버전·회장 서명 시한·서명 도메인)을 받지 못했다.
  notReady,

  /// 서명 직전에 다시 읽었더니 이미 처리됐거나 단계가 바뀌었거나 내용이 화면과 다르다.
  changed,

  /// 회장이 정한 서명 시한이 (곧) 지난다 — 감사가 서명해도 체인이 `SignatureExpired` 로 거부한다.
  expired,

  /// 키가 없거나 본인 확인을 취소·실패했다.
  signing,

  /// 401 — 로그인이 끝났다. 세션은 이미 비웠다.
  unauthorized,

  /// 403 — 역할이 아니다.
  forbidden,

  /// 404 — 그런 요청이나 예산이 없다.
  notFound,

  /// 409 — 다른 감사의 승인이 먼저 진행 중이거나 이미 반영됐다.
  conflict,

  /// 400·422 — 서버나 체인이 거부했다. 감사 승인에서 버전 불일치·시한 만료면 서버가 이미 `PENDING` 으로 되돌렸다.
  refused,

  /// 보냈지만 결과를 모른다 (503·연결 끊김·시간 초과). 다시 보내기 전에 목록부터 새로 읽는다.
  unknownOutcome,
}

class RevisionDecisionException implements Exception {
  final RevisionDecisionFailure failure;
  final String message;
  const RevisionDecisionException(this.failure, this.message);

  @override
  String toString() => 'RevisionDecisionException(${failure.name}): $message';
}

/// 기기 서명 함수 — [SigningService.sign] 과 같은 모양. 테스트에서 갈아끼운다.
typedef RevisionSigner = Future<String> Function(Eip712Domain domain, Eip712Message message, {required String reason});

/// 예산 증액 승인 쪽 (A7, PRD §4.1 개정 2·3단계). 총무 요청(T9)은 `budget_revision_service.dart`(#72) 몫이다.
///
/// - 회장: `PENDING` 건의 `IncreaseRequest` 에 서명해 `POST /budget-revisions/{id}/sign`.
///   `version` 은 **서명 직전에 읽은 현재 체인 예산 버전**, `deadline` 은 지금부터 [presidentTtl].
/// - 감사: `PRESIDENT_SIGNED` 건에 **회장이 정한 `signed_version`·`signature_deadline` 그대로** 서명해
///   `POST /{id}/approve`. 서버가 `BudgetToken.increase` 를 릴레이한다.
/// - 반려: 회장·감사 둘 다 `POST /{id}/reject` (서명 없음).
///
/// 서명하는 값은 화면이 보여 준 값이다. 서명 직전에 단건을 다시 읽어 상태·금액·사유가 그대로인지 본다.
class BudgetRevisionDecisionService {
  /// HTTP 클라이언트. 테스트에서 갈아끼운다.
  static http.Client client = http.Client();

  /// 회장 서명 시한. 감사가 이 안에 승인해야 한다. 컨트랙트에 상한은 없다 (`BudgetToken.increase`).
  /// 등록 서명(10분)처럼 짧으면 감사가 사실상 못 따라오고, 너무 길면 오래된 서명이 남는다.
  static const presidentTtl = Duration(hours: 24);

  /// 감사가 서명한 뒤 서버가 릴레이를 마칠 때까지의 여유. 시한이 이보다 적게 남았으면 서명하지 않는다.
  static const approveMargin = Duration(minutes: 2);

  /// 서버는 릴레이 뒤 receipt 를 최대 30초 기다린다. 그보다 길게 둔다.
  static const postTimeout = Duration(seconds: 45);
  static const _readTimeout = Duration(seconds: 5);

  final RevisionSigner _sign;
  final Future<Eip712Domain> Function() _budgetDomain;
  final DateTime Function() _now;

  BudgetRevisionDecisionService({
    RevisionSigner? sign,
    Future<Eip712Domain> Function()? budgetDomain,
    DateTime Function()? now,
  })  : _sign = sign ?? SigningService().sign,
        _budgetDomain = budgetDomain ?? ChainDomainService.budget,
        _now = now ?? DateTime.now;

  static String get _base => '${ApiConfig.baseUrl}/budget-revisions';

  /// 회장·감사가 서명하는 `IncreaseRequest`. 서버 `approve_budget_revision` 이 다시 만드는 값과 같다.
  static Eip712Message increaseMessage(BudgetRevisionModel rev, {required int version, required int deadline}) =>
      BudgetTypes.increaseRequest(
        budgetId: rev.budgetId,
        amount: rev.requestedAmount,
        reasonHash: BudgetTypes.reasonHashOf(rev.reason),
        version: version,
        deadline: deadline,
      );

  // ───────────────────────── 조회

  /// [status] 단계의 증액 요청 목록. 실패하면 [ApiUnavailable] 계열을 던진다 (더미로 메우지 않는다).
  Future<List<BudgetRevisionModel>> list(BudgetRevisionStatus status) async {
    const what = '예산 증액 요청';
    final res = await _get('$_base?status_filter=${status.name}', what);
    if (res.statusCode != 200) throw const ApiUnavailable(what);
    try {
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is! List) throw const FormatException('목록이 아니다');
      return [for (final row in data) BudgetRevisionModel.fromJson(row as Map<String, dynamic>)];
    } on FormatException {
      throw const ApiUnavailable(what);
    } on TypeError {
      throw const ApiUnavailable(what);
    }
  }

  // ───────────────────────── 회장

  /// 회장 서명. 성공하면 `PRESIDENT_SIGNED` 가 된 요청을 돌려준다.
  Future<BudgetRevisionModel> presidentSign(BudgetRevisionModel rev) async {
    await _checkStillSame(rev, BudgetRevisionStatus.PENDING);
    final version = await _currentVersion(rev);
    final domain = await _domain();
    final deadline = _now().millisecondsSinceEpoch ~/ 1000 + presidentTtl.inSeconds;
    final signature = await _signOrThrow(domain, increaseMessage(rev, version: version, deadline: deadline), '예산 증액 서명');
    return _post(
      '$_base/${rev.id}/sign',
      {'president_signature': signature, 'signature_deadline': deadline, 'signed_version': version},
      what: '회장 서명',
    );
  }

  // ───────────────────────── 감사

  /// 감사 승인. 성공하면 `APPROVED` 가 된 요청을 돌려준다 (체인 증액까지 끝난 상태).
  Future<BudgetRevisionModel> auditorApprove(BudgetRevisionModel rev) async {
    final latest = await _checkStillSame(rev, BudgetRevisionStatus.PRESIDENT_SIGNED);
    final version = latest.signedVersion;
    final deadline = latest.signatureDeadline;
    if (version == null || deadline == null) {
      throw const RevisionDecisionException(
        RevisionDecisionFailure.notReady,
        '회장 서명 정보를 받지 못해 서명할 수 없어요. 목록을 새로 고쳐 주세요.',
      );
    }
    final nowSec = _now().millisecondsSinceEpoch ~/ 1000;
    if (deadline - nowSec <= approveMargin.inSeconds) {
      throw const RevisionDecisionException(
        RevisionDecisionFailure.expired,
        '회장 서명 시한이 지나 승인할 수 없어요. 회장이 다시 서명해야 해요.',
      );
    }
    final domain = await _domain();
    final signature = await _signOrThrow(domain, increaseMessage(rev, version: version, deadline: deadline), '예산 증액 승인 서명');
    return _post('$_base/${rev.id}/approve', {'auditor_signature': signature}, what: '감사 승인');
  }

  // ───────────────────────── 반려

  /// 반려 (회장·감사). 사유는 정본화해 보낸다. 성공하면 `REJECTED` 가 된 요청을 돌려준다.
  Future<BudgetRevisionModel> reject(BudgetRevisionModel rev, String reason) async {
    final canon = Hashing.canonicalText(reason);
    if (canon.isEmpty) {
      throw const RevisionDecisionException(RevisionDecisionFailure.invalidReason, '반려 사유를 입력해 주세요.');
    }
    return _post('$_base/${rev.id}/reject', {'reject_reason': canon}, what: '반려');
  }

  // ───────────────────────── 내부

  /// 서명 직전에 단건을 다시 읽는다. 상태가 [expected] 가 아니거나 서명할 내용이 화면과 다르면 멈춘다.
  Future<BudgetRevisionModel> _checkStillSame(BudgetRevisionModel shown, BudgetRevisionStatus expected) async {
    final BudgetRevisionModel latest;
    try {
      final res = await _get('$_base/${shown.id}', '예산 증액 요청');
      if (res.statusCode == 404) {
        throw const RevisionDecisionException(RevisionDecisionFailure.notFound, '그 증액 요청을 찾을 수 없어요.');
      }
      if (res.statusCode != 200) throw const ApiUnavailable('예산 증액 요청');
      latest = BudgetRevisionModel.fromJson(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } on ApiUnauthorized {
      throw const RevisionDecisionException(RevisionDecisionFailure.unauthorized, '로그인이 끝났어요. 다시 로그인해 주세요.');
    } on ApiForbidden {
      throw const RevisionDecisionException(RevisionDecisionFailure.forbidden, '이 작업을 할 권한이 없어요.');
    } on RevisionDecisionException {
      rethrow;
    } catch (_) {
      throw const RevisionDecisionException(
        RevisionDecisionFailure.notReady,
        '요청의 최신 상태를 확인하지 못해 서명하지 않았어요. 잠시 후 다시 시도해 주세요.',
      );
    }
    final same = latest.status == expected &&
        latest.budgetId == shown.budgetId &&
        latest.requestedAmount == shown.requestedAmount &&
        latest.reason == shown.reason;
    if (!same) {
      throw const RevisionDecisionException(
        RevisionDecisionFailure.changed,
        '그새 요청이 처리됐거나 단계가 바뀌었어요. 목록을 새로 고쳐 다시 확인해 주세요.',
      );
    }
    return latest;
  }

  /// 대상 예산의 현재 체인 버전 — `GET /budgets?term_id=` (서버가 체인 `getBudget` 으로 채운다).
  /// 서버 `/sign` 이 이 값을 체인과 다시 맞춰 본다. 없거나 형식이 틀리면 기본값 없이 멈춘다.
  Future<int> _currentVersion(BudgetRevisionModel rev) async {
    const notReady = RevisionDecisionException(
      RevisionDecisionFailure.notReady,
      '예산의 현재 버전을 읽지 못해 서명하지 않았어요. 잠시 후 다시 시도해 주세요.',
    );
    try {
      final res = await _get('${ApiConfig.budgets}?term_id=${rev.termId}', '예산 목록');
      if (res.statusCode != 200) throw notReady;
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is! List) throw notReady;
      for (final row in data) {
        if (row is Map && row['id'] == rev.budgetId) {
          final v = row['version'];
          if (v is int && v >= 1) return v;
          throw notReady;
        }
      }
      throw const RevisionDecisionException(
        RevisionDecisionFailure.notReady,
        '대상 예산이 체인에 발행돼 있지 않아 서명할 수 없어요.',
      );
    } on ApiUnauthorized {
      throw const RevisionDecisionException(RevisionDecisionFailure.unauthorized, '로그인이 끝났어요. 다시 로그인해 주세요.');
    } on RevisionDecisionException {
      rethrow;
    } catch (_) {
      throw notReady;
    }
  }

  Future<Eip712Domain> _domain() async {
    try {
      return await _budgetDomain();
    } catch (_) {
      throw const RevisionDecisionException(
        RevisionDecisionFailure.notReady,
        '예산 서명 도메인을 확인하지 못해 서명하지 않았어요. 서버 설정을 확인해 주세요.',
      );
    }
  }

  Future<String> _signOrThrow(Eip712Domain domain, Eip712Message message, String reason) async {
    try {
      return await _sign(domain, message, reason: reason);
    } on SigningException catch (e) {
      throw RevisionDecisionException(RevisionDecisionFailure.signing, e.message);
    }
  }

  static Future<http.Response> _get(String url, String what) async {
    final http.Response res;
    try {
      res = await client.get(Uri.parse(url), headers: AuthService().authHeaders).timeout(_readTimeout);
    } catch (_) {
      throw ApiUnavailable(what);
    }
    if (res.statusCode == 401) {
      await AuthService().reportUnauthorized();
      throw ApiUnauthorized(what);
    }
    if (res.statusCode == 403) throw ApiForbidden(what);
    return res;
  }

  /// 쓰기 요청. 200 이면 바뀐 요청을, 아니면 [RevisionDecisionException] 을 던진다.
  static Future<BudgetRevisionModel> _post(String url, Map<String, Object> body, {required String what}) async {
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
      // 보냈는지·처리됐는지 모른다. 같은 서명을 다시 보내기 전에 목록부터 새로 읽게 한다.
      throw RevisionDecisionException(
        RevisionDecisionFailure.unknownOutcome,
        '$what 결과를 확인하지 못했어요. 목록을 새로 고쳐 처리됐는지 먼저 확인해 주세요.',
      );
    }
    switch (res.statusCode) {
      case 200:
        try {
          return BudgetRevisionModel.fromJson(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
        } catch (_) {
          throw RevisionDecisionException(
            RevisionDecisionFailure.unknownOutcome,
            '$what은(는) 보냈지만 응답을 읽지 못했어요. 목록을 새로 고쳐 확인해 주세요.',
          );
        }
      case 401:
        await AuthService().reportUnauthorized();
        throw const RevisionDecisionException(RevisionDecisionFailure.unauthorized, '로그인이 끝났어요. 다시 로그인해 주세요.');
      case 403:
        throw const RevisionDecisionException(RevisionDecisionFailure.forbidden, '이 작업을 할 권한이 없어요.');
      case 404:
        throw const RevisionDecisionException(RevisionDecisionFailure.notFound, '그 증액 요청이나 예산을 찾을 수 없어요.');
      case 409:
        throw RevisionDecisionException(
          RevisionDecisionFailure.conflict,
          '다른 임원의 $what 처리가 먼저 진행 중이거나 이미 끝났어요. 목록을 새로 고쳐 주세요.',
        );
      case 400:
      case 422:
        // 서버 문구는 보여 주기만 한다 (버전 불일치·시한 만료 → 서버가 이미 PENDING 으로 되돌림).
        final detail = _detailOf(res);
        throw RevisionDecisionException(
          RevisionDecisionFailure.refused,
          detail == null ? '서버가 $what을(를) 거부했어요. 목록을 새로 고쳐 주세요.' : '서버가 $what을(를) 거부했어요: $detail',
        );
      default:
        throw RevisionDecisionException(
          RevisionDecisionFailure.unknownOutcome,
          '$what 결과를 확인하지 못했어요. 목록을 새로 고쳐 처리됐는지 먼저 확인해 주세요.',
        );
    }
  }

  static String? _detailOf(http.Response res) {
    try {
      final d = (jsonDecode(utf8.decode(res.bodyBytes)) as Map)['detail'];
      return d is String && d.isNotEmpty ? d : null;
    } catch (_) {
      return null;
    }
  }
}
