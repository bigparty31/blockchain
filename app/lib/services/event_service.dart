import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/term_info.dart';
import '../models/event_model.dart';
import 'api_service.dart';
import 'auth_service.dart';

/// 행사 등록·입장 처리가 안 됐다. [message] 를 그대로 화면에 쓴다.
class EventActionFailed implements Exception {
  final String message;
  const EventActionFailed(this.message);

  @override
  String toString() => 'EventActionFailed: $message';
}

/// 행사·QR 입장 (A12, PRD §4.2) — docs/API.md 「행사·입장」. 임원만 (학생 토큰이면 서버가 403).
///
/// - 조회 실패는 [ApiUnavailable] 계열(401 [ApiUnauthorized], 403 [ApiForbidden]).
/// - 등록·입장 실패는 [EventActionFailed]. **입장 판정 다섯 가지는 실패가 아니다** — 모두 [CheckInOutcome] 으로 돌려준다.
/// - 입장은 다시 보내도 안전하다. 이미 들어갔으면 서버가 `ALREADY_CHECKED_IN` 을 주므로, 응답을 못 받으면 다시 찍으면 된다.
class EventService {
  /// HTTP 클라이언트. 테스트에서 갈아끼운다.
  static http.Client client = http.Client();

  static const readTimeout = Duration(seconds: 10);

  /// 서버는 체인 확인을 3초까지 기다린다(넘으면 UNVERIFIABLE). 그보다 넉넉히.
  static const checkInTimeout = Duration(seconds: 10);

  final int termCode;

  EventService({this.termCode = TermInfo.currentTermCode});

  String get _base => ApiConfig.baseUrl;

  /// [termCode] 학기의 서버 id. 학기 코드(YYYYS)와 id 는 다르다. 없으면 다른 학기를 대신 쓰지 않는다.
  Future<int> termId() async {
    const what = '학기 정보';
    final data = await _getJson('$_base/terms', what);
    if (data is List) {
      for (final t in data) {
        if (t is Map && t['term_code'] == termCode && t['id'] is int) return t['id'] as int;
      }
      throw const ApiUnavailable('현재 학기 정보');
    }
    throw const ApiUnavailable(what);
  }

  /// 학기의 행사 목록. 최근 행사가 먼저 온다.
  Future<List<EventInfo>> events(int termId) async {
    const what = '행사 목록';
    final data = await _getJson('$_base/events?term_id=$termId', what);
    try {
      if (data is! List) throw const FormatException('목록이 아니다');
      return [for (final e in data) EventInfo.fromJson(e as Map<String, dynamic>)];
    } on Object {
      throw const ApiUnavailable(what);
    }
  }

  /// 행사 등록. [heldAt] 은 시간대를 붙여 보낸다.
  Future<EventInfo> create({required int termId, required String name, required DateTime heldAt}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const EventActionFailed('행사 이름을 적어 주세요.');
    if (trimmed.length > 100) throw const EventActionFailed('행사 이름은 100자까지예요.');
    final res = await _post(
      '$_base/events',
      {'term_id': termId, 'name': trimmed, 'held_at': heldAt.toUtc().toIso8601String()},
      readTimeout,
      '행사 등록',
    );
    switch (res.statusCode) {
      case 201:
        try {
          return EventInfo.fromJson(_json(res) as Map<String, dynamic>);
        } on Object {
          throw const EventActionFailed('행사는 등록됐지만 응답을 읽지 못했어요. 목록을 다시 불러와 주세요.');
        }
      case 404:
        throw const EventActionFailed('현재 학기를 서버에서 찾지 못했어요.');
      case 422:
        throw const EventActionFailed('행사 이름이나 날짜가 올바르지 않아요.');
      default:
        throw const EventActionFailed('행사를 등록하지 못했어요. 잠시 후 다시 시도해 주세요.');
    }
  }

  /// QR 입장 처리. 학생 QR 모양이 아니면 보내지 않는다 ([isStudentQr]).
  Future<CheckInOutcome> checkIn({required int eventId, required String payload}) async {
    if (!isStudentQr(payload)) throw const EventActionFailed('학생 회원권 QR 이 아니에요.');
    final res = await _post(
      '$_base/events/$eventId/check-in',
      {'qr_payload': payload.trim()},
      checkInTimeout,
      '입장 확인',
    );
    switch (res.statusCode) {
      case 200:
        try {
          return CheckInOutcome.fromJson(_json(res) as Map<String, dynamic>);
        } on Object {
          throw const EventActionFailed('입장 결과를 읽지 못했어요. 다시 스캔해 주세요.');
        }
      case 400:
      case 422:
        throw const EventActionFailed('학생 회원권 QR 이 아니에요.');
      case 404:
        throw const EventActionFailed('행사를 찾지 못했어요. 행사를 다시 골라 주세요.');
      default:
        throw const EventActionFailed('서버에 연결하지 못했어요. 다시 스캔해 주세요.');
    }
  }

  // ───────────────────────────── HTTP

  static Object? _json(http.Response res) => jsonDecode(utf8.decode(res.bodyBytes));

  static Future<Object?> _getJson(String url, String what) async {
    final auth = AuthService().authSnapshot;
    final http.Response res;
    try {
      res = await client.get(Uri.parse(url), headers: auth.headers).timeout(readTimeout);
    } on Object {
      throw ApiUnavailable(what);
    }
    await _checkAuth(res, auth.token, what);
    if (res.statusCode != 200) throw ApiUnavailable(what);
    try {
      return _json(res);
    } on FormatException {
      throw ApiUnavailable(what);
    }
  }

  static Future<http.Response> _post(String url, Map<String, Object?> body, Duration timeout, String what) async {
    final auth = AuthService().authSnapshot;
    final http.Response res;
    try {
      res = await client
          .post(Uri.parse(url), headers: {...auth.headers, 'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(timeout);
    } on Object {
      // 입장은 다시 보내도 안전하다(이미 들어갔으면 ALREADY_CHECKED_IN). 행사 등록은 목록을 다시 보면 된다
      throw EventActionFailed('$what 응답을 받지 못했어요. 네트워크를 확인하고 다시 시도해 주세요.');
    }
    await _checkAuth(res, auth.token, what);
    return res;
  }

  /// 토큰은 **보내기 직전에** 잡은 것을 넘긴다 (늦은 401 이 새 로그인을 지우지 않게).
  static Future<void> _checkAuth(http.Response res, String? token, String what) async {
    if (res.statusCode == 401) {
      await AuthService().reportUnauthorized(token: token);
      throw ApiUnauthorized(what);
    }
    if (res.statusCode == 403) throw ApiForbidden(what);
  }
}
