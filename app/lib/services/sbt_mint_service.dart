import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/signing/eip712.dart';
import '../core/signing/sbt_types.dart';
import '../core/signing/signing_service.dart';
import '../core/term_info.dart';
import '../models/sbt_mint_model.dart';
import 'auth_service.dart';
import 'chain_domain_service.dart';

/// 실패 종류 — 화면이 다음에 무엇을 보여 줄지 정한다.
enum MintFailure {
  /// 학기·도메인 등 서명 전 준비가 안 됨. 서명하지 않았다.
  notReady,

  /// 기기 서명이 안 됨 (키 없음·본인 확인 실패).
  signing,

  /// 이 기기 키가 서버가 정한 서명자(`signer_address`)와 다르다. 보내지 않았다.
  wrongKey,

  /// 발행할 학생이 0명 — [MintFailed.excluded] 에 학생별 사유.
  nobody,
  unauthorized,
  forbidden,
  notFound,

  /// 409 — nonce 가 바뀌었거나, 이미 발행됐거나, 다른 제출이 진행 중. 조회해서 상태를 다시 본다.
  conflict,

  /// 400·422 — 서버가 거부. 문구를 그대로 보인다.
  refused,

  /// 503 — 체인·DB·릴레이어 준비 안 됨. 보내지 않았다.
  unavailable,

  /// 보냈는지·처리됐는지 모른다. **같은 서명을 다시 보내지 말고** 조회한다.
  unknownOutcome,
}

class MintFailed implements Exception {
  final MintFailure kind;
  final String message;
  final List<MintExcluded> excluded;
  const MintFailed(this.kind, this.message, {this.excluded = const []});

  @override
  String toString() => 'MintFailed(${kind.name}): $message';
}

typedef MintSigner = Future<String> Function(Eip712Domain domain, Eip712Message message, {required String reason});

/// 회원권(SBT) 일괄 발행 (A3) — docs/API.md 「회원권 2」, PRD §4.2·§7.2·§9.2.
///
/// 준비(학번 → 주소·nonce) → 기기 서명(`MintBatchRequest`) → 제출 → 결과. 서버 혼자서는 발행하지 않는다.
/// 회장·감사만 (서버가 403 으로 다시 막는다).
class SbtMintService {
  static http.Client client = http.Client();

  static const readTimeout = Duration(seconds: 10);

  /// 제출은 서버가 체인 결과까지 기다린다.
  static const submitTimeout = Duration(seconds: 45);

  /// 서명 유효 시간. 서명하고 바로 제출하므로 짧게 둔다 — 지나면 체인이 `SignatureExpired` 로 거부하고 다시 서명하면 된다.
  static const signatureTtl = Duration(minutes: 15);

  final int termCode;
  final MintSigner _sign;
  final Future<Eip712Domain> Function() _domain;
  final DateTime Function() _now;

  SbtMintService({
    this.termCode = TermInfo.currentTermCode,
    MintSigner? sign,
    Future<Eip712Domain> Function()? domain,
    DateTime Function()? now,
  })  : _sign = sign ?? SigningService().sign,
        _domain = domain ?? ChainDomainService.sbt,
        _now = now ?? DateTime.now;

  String get _base => '${ApiConfig.baseUrl}/memberships/mint-batches';

  /// 현재 학기의 서버 id (학기 코드와 다르다). 서버에 없으면 다른 학기를 대신 쓰지 않는다.
  Future<int> termId() async {
    final res = await _send(() => client.get(Uri.parse('${ApiConfig.baseUrl}/terms'), headers: _auth.headers),
        readTimeout, '학기 정보');
    if (res.statusCode == 200) {
      try {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        if (data is List) {
          for (final t in data) {
            if (t is Map && t['term_code'] == termCode && t['id'] is int) return t['id'] as int;
          }
          throw const MintFailed(MintFailure.notReady, '서버에 현재 학기가 없어요. 학기 설정을 확인해 주세요.');
        }
      } on FormatException {
        // 아래로
      }
    }
    throw const MintFailed(MintFailure.notReady, '학기 정보를 불러오지 못했어요. 잠시 후 다시 시도해 주세요.');
  }

  /// 1단계 — 학번(1~100개)을 보내 서명할 값을 받는다.
  Future<MintBatch> prepare({required int termId, required List<String> studentNos}) async {
    if (studentNos.isEmpty || studentNos.length > SbtTypes.maxBatch) {
      throw const MintFailed(MintFailure.refused, '한 번에 1~${SbtTypes.maxBatch}명까지 준비할 수 있어요.');
    }
    final res = await _post(_base, {'term_id': termId, 'student_nos': studentNos}, readTimeout, '발행 준비');
    if (res.statusCode == 201) return _batch(res, '발행 준비');
    if (res.statusCode == 400) {
      final detail = _detail(res);
      if (detail is Map && detail['excluded'] is List) {
        // 발행할 학생이 0명 — 왜 빠졌는지 보여 준다
        List<MintExcluded> excluded;
        try {
          excluded = MintExcluded.listFrom(detail['excluded']);
        } on FormatException {
          excluded = const [];
        }
        throw MintFailed(MintFailure.nobody, '발행할 학생이 없어요.', excluded: excluded);
      }
    }
    throw _failure(res, '발행 준비', sent: false);
  }

  /// 2단계 — 준비한 값으로 기기 서명하고 제출한다. 서명은 [batch] 의 값 **그대로**(recipients 순서 포함).
  Future<MintBatch> signAndSubmit(MintBatch batch) async {
    final Eip712Domain domain;
    try {
      domain = await _domain();
    } catch (_) {
      throw const MintFailed(MintFailure.notReady, '회원권 서명 도메인을 확인하지 못해 서명하지 않았어요. 서버 설정을 확인해 주세요.');
    }
    final deadline = _now().add(signatureTtl).millisecondsSinceEpoch ~/ 1000;
    final Eip712Message message;
    try {
      message = SbtTypes.mintBatchRequest(
        recipients: batch.recipients,
        term: batch.termCode,
        nonce: batch.nonce,
        deadline: deadline,
      );
    } on ArgumentError catch (e) {
      // 0 주소·학기 0 등 — 체인이 되돌릴 값. 서명하지 않는다
      throw MintFailed(MintFailure.refused, '서버가 준 발행 값이 올바르지 않아 서명하지 않았어요 (${e.message}).');
    }

    final String signature;
    try {
      signature = await _sign(domain, message, reason: '회원권 ${batch.targets.length}명 발행 서명');
    } on SigningException catch (e) {
      throw MintFailed(MintFailure.signing, e.message);
    }

    // 보내기 전에 서명자를 확인한다 — 다른 키로 서명했으면 서버가 400 을 주지만, 이유를 먼저 정확히 알려 준다
    final signer = SigningService.recoverSigner(Eip712.digest(domain, message), signature);
    if (signer.toLowerCase() != batch.signerAddress.toLowerCase()) {
      throw const MintFailed(
        MintFailure.wrongKey,
        '이 기기의 서명 키가 서버에 등록된 내 지갑과 달라요. 보내지 않았어요. 키를 등록한 기기에서 서명해 주세요.',
      );
    }

    final res = await _post('$_base/${batch.id}/submit', {'deadline': deadline, 'signature': signature},
        submitTimeout, '발행 제출');
    if (res.statusCode == 200) return _batch(res, '발행 제출', sent: true);
    throw _failure(res, '발행 제출', sent: true);
  }

  /// 결과 조회. 결과를 모르는 상태면 서버가 저장된 tx hash 로 체인을 다시 확인해 준다.
  Future<MintBatch> fetch(int batchId) async {
    final res = await _send(() => client.get(Uri.parse('$_base/$batchId'), headers: _auth.headers), readTimeout, '발행 결과');
    if (res.statusCode == 200) return _batch(res, '발행 결과');
    throw _failure(res, '발행 결과', sent: false);
  }

  // ───────────────────────────── HTTP

  ({Map<String, String> headers, String? token, int generation}) get _auth => AuthService().authSnapshot;

  Future<http.Response> _post(String url, Map<String, Object> body, Duration timeout, String what) {
    final auth = _auth;
    return _send(
      () => client.post(Uri.parse(url),
          headers: {...auth.headers, 'Content-Type': 'application/json'}, body: jsonEncode(body)),
      timeout,
      what,
      sentOnTimeout: url.endsWith('/submit'),
      token: auth.token,
    );
  }

  /// 보내고 401 을 처리한다. [sentOnTimeout] 이면 응답을 못 받은 것을 「결과 모름」으로 본다 (제출).
  Future<http.Response> _send(
    Future<http.Response> Function() call,
    Duration timeout,
    String what, {
    bool sentOnTimeout = false,
    String? token,
  }) async {
    final sentWith = token ?? _auth.token;
    final http.Response res;
    try {
      res = await call().timeout(timeout);
    } catch (_) {
      if (sentOnTimeout) {
        throw MintFailed(MintFailure.unknownOutcome, '$what 결과를 받지 못했어요. 같은 서명을 다시 보내지 말고 「결과 확인」을 눌러 주세요.');
      }
      throw MintFailed(MintFailure.notReady, '$what 요청을 보내지 못했어요. 네트워크를 확인해 주세요.');
    }
    if (res.statusCode == 401) {
      await AuthService().reportUnauthorized(token: sentWith);
      throw const MintFailed(MintFailure.unauthorized, '로그인이 끝났어요. 다시 로그인해 주세요.');
    }
    return res;
  }

  static MintBatch _batch(http.Response res, String what, {bool sent = false}) {
    try {
      return MintBatch.fromJson(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } catch (_) {
      throw MintFailed(
        sent ? MintFailure.unknownOutcome : MintFailure.notReady,
        sent ? '$what은(는) 보냈지만 응답을 읽지 못했어요. 「결과 확인」으로 확인해 주세요.' : '$what 응답을 읽지 못했어요.',
      );
    }
  }

  static Object? _detail(http.Response res) {
    try {
      return (jsonDecode(utf8.decode(res.bodyBytes)) as Map)['detail'];
    } catch (_) {
      return null;
    }
  }

  static MintFailed _failure(http.Response res, String what, {required bool sent}) {
    final detail = _detail(res);
    final text = detail is String ? detail : (detail is Map && detail['message'] is String ? detail['message'] as String : null);
    switch (res.statusCode) {
      case 403:
        return const MintFailed(MintFailure.forbidden, '회원권 발행은 회장·감사만, 준비한 본인만 제출할 수 있어요.');
      case 404:
        return const MintFailed(MintFailure.notFound, '학기나 발행 요청을 찾지 못했어요.');
      case 409:
        return MintFailed(MintFailure.conflict, text ?? '다른 제출이 진행 중이거나 이미 처리됐어요. 상태를 다시 확인할게요.');
      case 400:
      case 422:
        return MintFailed(MintFailure.refused, text == null ? '서버가 $what을(를) 거부했어요.' : '서버가 $what을(를) 거부했어요: $text');
      case 503:
        return MintFailed(MintFailure.unavailable, '체인이나 서버가 준비되지 않아 $what을(를) 하지 못했어요. 잠시 후 다시 시도해 주세요.');
      default:
        return MintFailed(
          sent ? MintFailure.unknownOutcome : MintFailure.notReady,
          sent ? '$what 결과를 확인하지 못했어요. 같은 서명을 다시 보내지 말고 「결과 확인」을 눌러 주세요.' : '$what을(를) 하지 못했어요 (서버 ${res.statusCode}).',
        );
    }
  }
}
