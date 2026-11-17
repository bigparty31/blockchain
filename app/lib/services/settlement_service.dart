import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/term_info.dart';
import '../models/settlement_model.dart';
import 'api_service.dart';
import 'auth_service.dart';

/// 학기 결산 조회 (A11, PRD §4.7) — `GET /terms` 로 현재 학기 id 를 찾고 `GET /settlement/{term_id}` 를 읽는다.
///
/// **실패하면 [ApiUnavailable] 계열을 던진다. 더미 숫자로 메우지 않는다** — 결산 화면에 가짜 합계·차액이
/// 보이면 그 자체가 잘못된 정보다. 401·403 은 [ApiService] 와 같은 방식으로 나눈다.
class SettlementService {
  /// HTTP 클라이언트. 테스트에서 갈아끼운다.
  static http.Client client = http.Client();

  /// 서버가 학기 전체 확정 건을 모아 계산한다. 목록 조회(3초)보다 넉넉히 둔다.
  static const timeout = Duration(seconds: 10);

  /// 결산할 학기 코드. 기본은 앱의 현재 학기 (`TermInfo.currentTermCode`).
  final int termCode;

  SettlementService({this.termCode = TermInfo.currentTermCode});

  Future<SettlementModel> fetch() async {
    final termId = await _termId();
    const what = '결산';
    final res = await _get('${ApiConfig.baseUrl}/settlement/$termId', what);
    if (res.statusCode != 200) throw const ApiUnavailable(what);
    try {
      return SettlementModel.fromJson(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } on FormatException {
      throw const ApiUnavailable(what);
    } on TypeError {
      throw const ApiUnavailable(what);
    }
  }

  /// [termCode] 학기의 서버 id. 학기 코드와 id 는 다르다 (id 는 1부터, 코드는 YYYYS).
  Future<int> _termId() async {
    const what = '학기 정보';
    final res = await _get('${ApiConfig.baseUrl}/terms', what);
    if (res.statusCode != 200) throw const ApiUnavailable(what);
    try {
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is! List) throw const FormatException('학기 목록이 아니다');
      for (final t in data) {
        if (t is Map && t['term_code'] == termCode) {
          final id = t['id'];
          if (id is int) return id;
        }
      }
    } on FormatException {
      throw const ApiUnavailable(what);
    }
    // 서버에 현재 학기가 없다 — 다른 학기를 대신 보여 주지 않는다
    throw const ApiUnavailable('현재 학기 정보');
  }

  /// GET + 로그인 토큰. 토큰은 **보내기 직전에** 잡아 401 보고에 넘긴다 (늦은 401 이 새 로그인을 지우지 않게).
  static Future<http.Response> _get(String url, String what) async {
    final auth = AuthService().authSnapshot;
    final http.Response res;
    try {
      res = await client.get(Uri.parse(url), headers: auth.headers).timeout(timeout);
    } catch (_) {
      throw ApiUnavailable(what);
    }
    if (res.statusCode == 401) {
      await AuthService().reportUnauthorized(token: auth.token);
      throw ApiUnauthorized(what);
    }
    if (res.statusCode == 403) throw ApiForbidden(what);
    return res;
  }
}
