import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/budget_plan.dart';
import '../core/enums.dart';
import '../core/signing/budget_types.dart';
import '../core/signing/device_key.dart';
import '../core/signing/eip712.dart';
import '../core/signing/signing_service.dart';
import '../core/term_info.dart';
import 'auth_service.dart';
import 'budget_issuer.dart';
import 'chain_domain_service.dart';

typedef BudgetSigner = Future<String> Function(Eip712Domain domain, Eip712Message message, {required String reason});

/// 실제 예산 발행기 (A4) — docs/API.md 「예산」, PRD §4.1·§9.2.
///
/// 항목마다: ① `POST /budgets` 로 budgetId 를 받고 → ② 회장 기기 키로 EIP-712 `IssueRequest` 서명 →
/// ③ `POST /budgets/{id}/submit`. 서버가 서명자를 대조하고 릴레이어로 `BudgetToken.issue` 를 보낸다.
///
/// **결과 구분이 이 클래스의 핵심이다.** 컨트롤러는 「거부」 줄은 고쳐서 다시 보내게 하고, 「응답 없음」 줄은
/// 잠근다. 그래서:
///  - 제출(③)을 **보내기 전**에 실패하면 → [BudgetIssueStatus.rejected] (체인에 아무것도 안 나갔다)
///  - 제출을 보냈는데 결과를 모르면(시간 초과·409·5xx·응답 해석 실패) → [BudgetIssueStatus.noResponse]
///
/// 다시 확정해도 안전하다 — 서버가 같은 (학기, 항목)이 체인에 있으면 ①에서 `ALREADY_ISSUED` 를 주고,
/// 앞서 보낸 트랜잭션이 있으면 새로 보내기 전에 그 결과부터 확인한다.
class ServerBudgetIssuer implements BudgetIssuer {
  static http.Client client = http.Client();

  static const readTimeout = Duration(seconds: 10);

  /// 제출은 서버가 체인 결과까지 기다린다.
  static const submitTimeout = Duration(seconds: 45);

  /// 서명 유효 시간. 서명하고 바로 제출하므로 짧게 둔다.
  static const signatureTtl = Duration(minutes: 15);

  final int termCode;
  final BudgetSigner _sign;
  final Future<Eip712Domain> Function() _domain;
  final Future<bool> Function() _hasKey;
  final DateTime Function() _now;

  ServerBudgetIssuer({
    this.termCode = TermInfo.currentTermCode,
    BudgetSigner? sign,
    Future<Eip712Domain> Function()? domain,
    Future<bool> Function()? hasKey,
    DateTime Function()? now,
  })  : _sign = sign ?? SigningService().sign,
        _domain = domain ?? ChainDomainService.budget,
        _hasKey = hasKey ?? DeviceKey.exists,
        _now = now ?? DateTime.now;

  @override
  Future<List<BudgetIssueOutcome>> issueAll({
    int? termId,
    required List<BudgetDraftItem> items,
  }) async {
    // 시작도 못 하는 경우 — 한 줄도 보내기 전에 던진다 (인터페이스 약속)
    final session = AuthService().session;
    if (session != null && session.role != UserRole.PRESIDENT) {
      throw const BudgetIssueException(BudgetIssueFailure.notPresident);
    }
    if (!await _hasKey()) throw const BudgetIssueException(BudgetIssueFailure.walletNotConnected);

    // 모든 줄에 공통인 준비. 실패하면 아무것도 보내지 않았으니 전부 「거부」(다시 확정 가능)로 돌려준다
    final Eip712Domain domain;
    final int term;
    try {
      domain = await _loadDomain();
      term = termId ?? await _currentTermId();
    } on _Abort catch (e) {
      return [for (final _ in items) _rejected(e.message)];
    }

    final outcomes = <BudgetIssueOutcome>[];
    String? abort; // 로그인 끝남·서명 거부 등 — 남은 줄도 같은 이유로 못 보낸다
    for (var k = 0; k < items.length; k++) {
      if (abort != null) {
        outcomes.add(_rejected(abort));
        continue;
      }
      try {
        outcomes.add(await _issueOne(items[k],
            termId: term, domain: domain, first: k == 0, expectTermCode: termId == null));
      } on _Abort catch (e) {
        abort = e.message;
        outcomes.add(_rejected(abort));
      } on BudgetIssueException {
        rethrow; // 첫 줄 403 — 아무것도 안 보냈다
      } catch (_) {
        // 예상 못 한 오류(플랫폼 저장소 등)로 앞 줄의 결과까지 잃지 않는다. 제출 이후 단계는 모두
        // 따로 잡으므로 여기 오는 것은 보내기 전이다 (#120 리뷰)
        abort = '발행을 준비하다 오류가 났어요. 다시 확정해 주세요.';
        outcomes.add(_rejected(abort));
      }
    }
    return outcomes;
  }

  /// 「응답 없음」 줄의 결과 확인 (#120 리뷰). ①(`POST /budgets`)만 다시 부른다 — **서명도 제출도 하지 않는다.**
  /// 서버는 그 (학기, 항목)이 체인에 있으면 `ALREADY_ISSUED`(체인 값)를, 없으면 `DRAFT` 를 주는데,
  /// `DRAFT` 의 `tx_hash` 가 남아 있으면 앞서 보낸 트랜잭션이 아직 끝나지 않은 것이고, 없으면 실패해 선점이 풀린 것이다.
  @override
  Future<List<BudgetIssueOutcome>> checkAll({
    int? termId,
    required List<BudgetDraftItem> items,
  }) async {
    final session = AuthService().session;
    if (session != null && session.role != UserRole.PRESIDENT) {
      throw const BudgetIssueException(BudgetIssueFailure.notPresident);
    }
    final int term;
    try {
      term = termId ?? await _currentTermId();
    } on _Abort catch (e) {
      return [for (final _ in items) _unknown(e.message)];
    }

    final outcomes = <BudgetIssueOutcome>[];
    String? abort;
    for (final item in items) {
      if (abort != null) {
        outcomes.add(_unknown(abort));
        continue;
      }
      try {
        outcomes.add(await _checkOne(item, termId: term));
      } on _Abort catch (e) {
        abort = e.message;
        outcomes.add(_unknown(abort));
      } catch (_) {
        outcomes.add(_unknown(_checkFailed));
      }
    }
    return outcomes;
  }

  Future<BudgetIssueOutcome> _checkOne(BudgetDraftItem item, {required int termId}) async {
    final http.Response res;
    try {
      res = await _post('/budgets', {
        'term_id': termId,
        'category': item.category!.label,
        'planned_amount': item.amount!,
        'expires_at': BudgetPlanRules.expiresAtSeconds(item.expiresOn!),
      }, readTimeout);
    } on _Abort {
      rethrow;
    } catch (_) {
      return _unknown(_checkFailed);
    }
    if (res.statusCode == 403) throw const _Abort('회장만 예산 발행 결과를 확인할 수 있어요.');
    if (res.statusCode != 201 && res.statusCode != 200) return _unknown(_checkFailed);

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      return _unknown(_checkFailed);
    }
    switch (body['status']) {
      case 'ALREADY_ISSUED':
        return _existing(body);
      case 'DRAFT':
        final tx = body['tx_hash'];
        if (tx is String && tx.isNotEmpty) return _unknown('아직 체인에서 확인되지 않았어요. 잠시 후 다시 확인해 주세요.');
        // 「실패해 선점이 풀렸다」뿐 아니라 「서버가 아직 브로드캐스트 전」일 수도 있다(선점은 보내기 직전에 쓴다).
        // 그래도 다시 확정해 안전하다 — 서버의 선점 UPDATE(tx_issue IS NULL 조건)가 두 번째 전송을 막고,
        // 컨트랙트도 같은 (학기, 항목) 재발행을 막는다(BudgetAlreadyIssued). 그래서 단정하지 않는 문구로 둔다 (#125 리뷰)
        return _rejected('체인 기록이 확인되지 않았어요'); // 화면이 「· 고쳐서 다시 확정할 수 있어요」를 붙인다
      default:
        return _unknown(_checkFailed);
    }
  }

  static const _checkFailed = '결과를 확인하지 못했어요. 잠시 후 다시 확인해 주세요.';

  static BudgetIssueOutcome _unknown(String message) =>
      BudgetIssueOutcome(BudgetIssueStatus.noResponse, message: message);

  /// 한 줄 발행. [first] 면 아직 아무것도 안 보냈으므로 403 을 [BudgetIssueException] 으로 던질 수 있다.
  Future<BudgetIssueOutcome> _issueOne(
    BudgetDraftItem item, {
    required int termId,
    required Eip712Domain domain,
    required bool first,
    required bool expectTermCode,
  }) async {
    // 컨트롤러가 다 채운 줄만 보낸다. 어기면 바로 터지게 둔다 (FakeBudgetIssuer 와 같다)
    final category = item.category!.label;
    final amount = item.amount!;
    final expiresAt = BudgetPlanRules.expiresAtSeconds(item.expiresOn!);

    // ① 초안 — budgetId 받기
    final http.Response prep;
    try {
      prep = await _post('/budgets', {
        'term_id': termId,
        'category': category,
        'planned_amount': amount,
        'expires_at': expiresAt,
      }, readTimeout);
    } on _Abort {
      rethrow;
    } catch (_) {
      return _rejected('서버에 연결하지 못했어요. 다시 확정해 주세요.');
    }
    if (prep.statusCode == 403) {
      // 같은 세션이면 남은 줄도 전부 403 이다. 첫 줄이면 아직 아무것도 안 보냈으니 「회장 아님」으로 알린다
      if (first) throw const BudgetIssueException(BudgetIssueFailure.notPresident);
      throw const _Abort('회장만 예산을 발행할 수 있어요.');
    }
    if (prep.statusCode != 201 && prep.statusCode != 200) return _rejected(_refusal(prep, '예산 준비'));

    final Map<String, dynamic> draft;
    try {
      draft = jsonDecode(utf8.decode(prep.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      return _rejected('서버 응답을 읽지 못했어요. 다시 확정해 주세요.');
    }
    if (draft['status'] == 'ALREADY_ISSUED') return _existing(draft);

    // ② 서명 — 서버가 준 값이 우리가 보낸 값과 같은지 먼저 본다. 다르면 엉뚱한 예산에 서명하게 된다
    final id = draft['id'];
    final term = draft['term_code'];
    final hash = draft['category_hash'];
    final expected = BudgetTypes.categoryHash(category);
    if (draft['status'] != 'DRAFT' ||
        id is! int ||
        id <= 0 || // 컨트랙트에서 budgetId 0 은 무효
        term is! int ||
        term <= 0 ||
        (expectTermCode && term != termCode) || // 현재 학기로 보냈는데 다른 학기 코드가 오면 서명하지 않는다
        hash is! String ||
        hash.toLowerCase() != expected.toLowerCase()) {
      return _rejected('서버가 준 발행 값이 올바르지 않아 서명하지 않았어요.');
    }

    final deadline = _now().add(signatureTtl).millisecondsSinceEpoch ~/ 1000;
    final message = BudgetTypes.issueRequest(
      budgetId: id,
      term: term,
      category: expected,
      amount: amount,
      expiresAt: expiresAt,
      deadline: deadline,
    );
    final String signature;
    try {
      signature = await _sign(domain, message, reason: '$category 예산 발행 서명');
    } on SigningException catch (e) {
      // 지문 취소 등 — 남은 줄마다 또 묻지 않는다
      throw _Abort('서명하지 않아 보내지 않았어요: ${e.message}');
    } catch (_) {
      // 기기 키 저장소 오류(PlatformException) 등 — 서명이 없으니 보내지 않았다
      throw const _Abort('기기 서명 키를 읽지 못해 보내지 않았어요. 다시 확정해 주세요.');
    }

    // 보내기 전에 서명자를 확인한다 — 서버가 400 으로 막지만 이유를 먼저 정확히 알려 준다
    final wallet = AuthService().session?.walletAddress;
    if (wallet != null) {
      final signer = SigningService.recoverSigner(Eip712.digest(domain, message), signature);
      if (signer.toLowerCase() != wallet.toLowerCase()) {
        throw const _Abort('이 기기의 서명 키가 서버에 등록된 회장 지갑과 달라요. 보내지 않았어요.');
      }
    }

    // ③ 제출 — 여기부터는 보냈을 수 있다. 결과를 모르면 「응답 없음」
    final http.Response res;
    try {
      res = await _post('/budgets/$id/submit', {
        'planned_amount': amount,
        'expires_at': expiresAt,
        'deadline': deadline,
        'signature': signature,
      }, submitTimeout);
    } on _Abort {
      rethrow; // 401 — 서버가 인증부터 막으므로 처리되지 않았다
    } catch (_) {
      return BudgetIssueOutcome.noResponse;
    }

    switch (res.statusCode) {
      case 200:
        return _submitted(res);
      case 400:
      case 403:
      case 404:
      case 422:
        // 서명자·값 검증에서 막혔다 — 릴레이 전이다
        return _rejected(_refusal(res, '예산 발행'));
      default:
        // 409(다른 발행이 진행 중·이미 처리)·503(체인 반영 후 DB 실패일 수도)·그 밖 — 결과를 모른다
        return BudgetIssueOutcome.noResponse;
    }
  }

  static BudgetIssueOutcome _submitted(http.Response res) {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      return BudgetIssueOutcome.noResponse;
    }
    switch (body['status']) {
      case 'ISSUED':
        return BudgetIssueOutcome.issued;
      case 'ALREADY_ISSUED':
        return _existing(body);
      case 'REJECTED':
        final text = body['message'] ?? body['reason'];
        return _rejected(text is String ? text : '체인이 거부했어요');
      default:
        return BudgetIssueOutcome.noResponse; // NO_RESPONSE 포함
    }
  }

  /// 서버가 알려 준 체인 값(`planned_amount`·`expires_at`)과 함께 「이미 발행됨」.
  static BudgetIssueOutcome _existing(Map<String, dynamic> body) {
    final amount = body['planned_amount'];
    final expiresAt = body['expires_at'];
    return BudgetIssueOutcome.existing(
      amount: amount is int && amount > 0 ? amount : null,
      expiresAt: expiresAt is int && expiresAt > 0 ? expiresAt : null,
    );
  }

  Future<Eip712Domain> _loadDomain() async {
    try {
      return await _domain();
    } catch (_) {
      throw const _Abort('예산 서명 도메인을 확인하지 못해 서명하지 않았어요. 서버 설정을 확인해 주세요.');
    }
  }

  /// 현재 학기의 서버 id (학기 코드와 다르다). 서버에 없으면 다른 학기를 대신 쓰지 않는다.
  Future<int> _currentTermId() async {
    final auth = AuthService().authSnapshot;
    final http.Response res;
    try {
      res = await client.get(Uri.parse('${ApiConfig.baseUrl}/terms'), headers: auth.headers).timeout(readTimeout);
    } catch (_) {
      throw const _Abort('학기 정보를 불러오지 못했어요. 네트워크를 확인해 주세요.');
    }
    if (res.statusCode == 401) {
      await AuthService().reportUnauthorized(token: auth.token);
      throw const _Abort(_loggedOut);
    }
    if (res.statusCode == 200) {
      try {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        if (data is List) {
          for (final t in data) {
            if (t is Map && t['term_code'] == termCode && t['id'] is int) return t['id'] as int;
          }
          throw const _Abort('서버에 현재 학기가 없어요. 학기 설정을 확인해 주세요.');
        }
      } on FormatException {
        // 아래로
      }
    }
    throw const _Abort('학기 정보를 불러오지 못했어요. 잠시 후 다시 시도해 주세요.');
  }

  /// 보내고 401 을 처리한다. 네트워크 오류·시간 초과는 그대로 던진다 — 부르는 쪽이 보냈는지에 따라 나눈다.
  Future<http.Response> _post(String path, Map<String, Object> body, Duration timeout) async {
    final auth = AuthService().authSnapshot;
    final res = await client
        .post(Uri.parse('${ApiConfig.baseUrl}$path'),
            headers: {...auth.headers, 'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(timeout);
    if (res.statusCode == 401) {
      await AuthService().reportUnauthorized(token: auth.token);
      throw const _Abort(_loggedOut);
    }
    return res;
  }

  static const _loggedOut = '로그인이 끝났어요. 다시 로그인한 뒤 확정해 주세요.';

  static BudgetIssueOutcome _rejected(String message) =>
      BudgetIssueOutcome(BudgetIssueStatus.rejected, message: message);

  static String _refusal(http.Response res, String what) {
    if (res.statusCode == 503) return '체인이나 서버가 준비되지 않았어요. 잠시 후 다시 확정해 주세요.';
    if (res.statusCode == 403) return '회장만 예산을 발행할 수 있어요.';
    String? text;
    try {
      final detail = (jsonDecode(utf8.decode(res.bodyBytes)) as Map)['detail'];
      if (detail is String) text = detail;
    } catch (_) {
      // 문구 없이
    }
    return text == null ? '서버가 $what을(를) 거부했어요 (${res.statusCode}).' : '서버가 $what을(를) 거부했어요: $text';
  }
}

/// 이 줄과 남은 줄을 모두 같은 이유로 보내지 못한다 (로그인 끝남·서명 거부·다른 키).
class _Abort implements Exception {
  final String message;
  const _Abort(this.message);
}
