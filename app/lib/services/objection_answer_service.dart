import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/hashing.dart';
import '../core/signing/eip712.dart';
import '../core/signing/objection_types.dart';
import '../core/signing/signing_service.dart';
import '../models/objection_model.dart';
import 'auth_service.dart';
import 'chain_domain_service.dart';
import 'signed_post.dart';

/// 임원(감사·회장)의 이의 답변 — 목록 조회와 서명해 답하기 (PRD §4.5).
///
/// 화면은 이 인터페이스만 안다. 테스트는 가짜로 갈아끼운다.
abstract class ObjectionAnswerApi {
  /// 이의 전체 목록 (미답변·답변 완료). 못 읽으면 [EntryDecisionException] 을 던진다 — 더미로 메우지 않는다.
  Future<List<ObjectionModel>> list();

  /// [objection] 에 [answer] 로 답한다. 성공하면 서버에 기록된(답변 완료) 이의를 돌려준다.
  Future<ObjectionModel> answer(ObjectionModel objection, String answer);
}

/// 서버 연동 구현. 답변 서명 흐름은 둘로 나뉜다 (`docs/API.md` 이의 제기).
///
///   1. `POST /objections/{id}/prepare-answer` — 서버가 답변 본문을 정본화해 해시(`answer_hash`)와 서명 시한을 준다.
///   2. 앱이 **그 해시를 자기 계산과 맞춰 본 뒤** 임원 기기 키로 `AnswerRequest` 에 서명하고
///      `POST /objections/{id}/answer` 로 보낸다. 서버는 서명을 풀어 서명자가 임원인지 보고 체인에 기록한다.
///
/// 서버가 준 해시를 그대로 믿고 서명하지 않는다 — 화면에 적은 답변과 다른 글의 해시에 서명하게 되면
/// 체인에는 쓰지 않은 말이 임원 이름으로 남는다.
class ObjectionAnswerService implements ObjectionAnswerApi {
  /// HTTP 클라이언트. 테스트에서 갈아끼운다.
  static http.Client client = http.Client();

  /// 서버는 릴레이 뒤 receipt 를 최대 30초 기다린다. 그보다 길게 둔다.
  static const postTimeout = Duration(seconds: 45);
  static const _readTimeout = Duration(seconds: 8);

  final SigningFunction _sign;
  final Future<Eip712Domain> Function() _domain;

  ObjectionAnswerService({SigningFunction? sign, Future<Eip712Domain> Function()? domain})
      : _sign = sign ?? SigningService().sign,
        _domain = domain ?? ChainDomainService.objection;

  static String get _base => '${ApiConfig.baseUrl}/objections';

  @override
  Future<List<ObjectionModel>> list() async {
    final auth = AuthService().authSnapshot;
    final http.Response res;
    try {
      res = await client.get(Uri.parse(_base), headers: auth.headers).timeout(_readTimeout);
    } catch (_) {
      throw const EntryDecisionException(EntryDecisionFailure.notReady, '이의 목록을 불러오지 못했어요. 네트워크를 확인해 주세요.');
    }
    if (res.statusCode == 401) {
      await AuthService().reportUnauthorized(token: auth.token);
      throw const EntryDecisionException(EntryDecisionFailure.unauthorized, '로그인이 끝났어요. 다시 로그인해 주세요.');
    }
    if (res.statusCode == 403) {
      throw const EntryDecisionException(EntryDecisionFailure.forbidden, '이 작업을 할 권한이 없어요.');
    }
    if (res.statusCode != 200) {
      throw EntryDecisionException(EntryDecisionFailure.notReady, '이의 목록을 불러오지 못했어요 (서버 ${res.statusCode}).');
    }
    try {
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is! List) throw const FormatException('목록이 아니다');
      return [for (final row in data) ObjectionModel.fromJson(row as Map<String, dynamic>)];
    } catch (_) {
      throw const EntryDecisionException(EntryDecisionFailure.notReady, '이의 목록 응답 형식이 올바르지 않아요.');
    }
  }

  @override
  Future<ObjectionModel> answer(ObjectionModel objection, String answer) async {
    // 정본화는 서버 `_normalize_multiline` 과 같은 규칙이다 (HASHING §3). 비면 서버도 400 이다.
    final canon = Hashing.canonicalText(answer);
    if (canon.isEmpty) {
      throw const EntryDecisionException(EntryDecisionFailure.invalidReason, '답변을 입력해 주세요.');
    }
    final localHash = Hashing.textHash(canon);

    final prepared = await postSigned(
      client,
      '$_base/${objection.id}/prepare-answer',
      {'answer': canon},
      what: '답변 서명 준비',
      timeout: postTimeout,
    );
    final hash = prepared['answer_hash'];
    final deadline = prepared['deadline'];
    final id = prepared['objection_id'];
    if (hash is! String || deadline is! int || id != objection.id) {
      throw const EntryDecisionException(EntryDecisionFailure.notReady, '서명할 값을 받지 못해 서명하지 않았어요. 다시 시도해 주세요.');
    }
    if (hash.toLowerCase() != localHash.toLowerCase()) {
      throw const EntryDecisionException(
        EntryDecisionFailure.mismatch,
        '서버가 준 답변 해시가 적은 답변과 달라 서명하지 않았어요. 잠시 후 다시 시도해 주세요.',
      );
    }

    final Eip712Domain domain;
    try {
      domain = await _domain();
    } on ChainDomainException catch (e) {
      throw EntryDecisionException(EntryDecisionFailure.notReady, e.message);
    }
    final String signature;
    try {
      signature = await _sign(
        domain,
        ObjectionTypes.answerRequest(objectionId: objection.id, answerHash: hash, deadline: deadline),
        reason: '이의 답변 서명',
      );
    } on SigningException catch (e) {
      throw EntryDecisionException(EntryDecisionFailure.signing, e.message);
    }

    final body = await postSigned(
      client,
      '$_base/${objection.id}/answer',
      {'answer': canon, 'answer_hash': hash, 'deadline': deadline, 'signature': signature},
      what: '이의 답변',
      timeout: postTimeout,
    );
    if (body.isEmpty) {
      throw const EntryDecisionException(
        EntryDecisionFailure.unknownOutcome,
        '이의 답변 결과를 읽지 못했어요. 목록을 새로 고쳐 처리됐는지 확인해 주세요.',
      );
    }
    return ObjectionModel.fromJson(body);
  }
}

/// 기기 서명 함수 — [SigningService.sign] 과 같은 모양. 테스트에서 갈아끼운다.
typedef SigningFunction = Future<String> Function(Eip712Domain domain, Eip712Message message, {required String reason});
