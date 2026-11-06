import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/signing/eip712.dart';
import '../core/signing/signing_service.dart';
import 'auth_service.dart';
import 'chain_domain_service.dart';

/// 서명해서 서버에 보내는 요청(등록 제출·승인·반려)의 공통 부분 — 실패 분류, 서명 도메인, 서명, 전송.

/// 서명 요청(등록·승인·반려)을 끝내지 못한 이유. 화면은 [EntryDecisionException.message] 를 그대로 띄우고,
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

/// 원장 서명 도메인. 검산을 통과하지 못하면 서명하지 않는다.
Future<Eip712Domain> ledgerDomainForSigning() async {
  try {
    return await ChainDomainService.ledger();
  } on ChainDomainException catch (e) {
    throw EntryDecisionException(EntryDecisionFailure.notReady, e.message);
  }
}

/// 본인 확인 → 기기 키 서명. 실패하면 [EntryDecisionFailure.signing].
Future<String> signOrThrow(SigningService signer, Eip712Domain domain, Eip712Message message, String reason) async {
  try {
    return await signer.sign(domain, message, reason: reason);
  } on SigningException catch (e) {
    throw EntryDecisionException(EntryDecisionFailure.signing, e.message);
  }
}

/// 서명을 보낸다. 상태 코드로만 나누고, 400·403·409 는 서버 설명을 그대로 붙여 보여 준다.
/// 성공(200·201)이면 응답 본문(JSON 객체)을 돌려준다.
///
/// [conflictMessage] 는 409 때 보여 줄 문구다. 주지 않으면 서버 설명을 쓴다.
Future<Map<String, dynamic>> postSigned(
  http.Client client,
  String url,
  Map<String, Object> body, {
  required String what,
  required Duration timeout,
  String? conflictMessage,
}) =>
    sendAndDecode(
      () => client
          .post(
            Uri.parse(url),
            headers: {...AuthService().authHeaders, 'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout),
      what: what,
      conflictMessage: conflictMessage,
    );

/// 요청을 보내고 상태 코드로만 결과를 나눈다 ([postSigned]·영수증 업로드 공통).
/// 성공(200·201)이면 응답 본문(JSON 객체)을, 아니면 [EntryDecisionException] 을 던진다.
Future<Map<String, dynamic>> sendAndDecode(
  Future<http.Response> Function() send, {
  required String what,
  String? conflictMessage,
}) async {
  final http.Response res;
  try {
    res = await send();
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
      try {
        final decoded = jsonDecode(utf8.decode(res.bodyBytes));
        return decoded is Map<String, dynamic> ? decoded : const {};
      } catch (_) {
        return const {};
      }
    case 401:
      await AuthService().reportUnauthorized();
      throw const EntryDecisionException(EntryDecisionFailure.unauthorized, '로그인이 끝났어요. 다시 로그인해 주세요.');
    case 403:
      throw EntryDecisionException(EntryDecisionFailure.forbidden, detail ?? '이 작업을 할 권한이 없어요.');
    case 404:
      throw const EntryDecisionException(EntryDecisionFailure.notFound, '이 내역을 찾지 못했어요. 목록을 새로 고쳐 주세요.');
    case 409:
      throw EntryDecisionException(
        EntryDecisionFailure.conflict,
        conflictMessage ?? detail ?? '$what 이 다른 요청과 겹쳤어요. 목록을 새로 고쳐 확인해 주세요.',
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
String? _detail(http.Response res) {
  try {
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (body is Map && body['detail'] is String) return body['detail'] as String;
  } catch (_) {}
  return null;
}
