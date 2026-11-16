import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/hashing.dart';
import '../core/term_info.dart';
import '../models/bank_reconcile_model.dart';
import 'api_service.dart';
import 'auth_service.dart';

/// 업로드·재대조가 서버에서 거절됐거나 결과를 모른다. [message] 를 그대로 화면에 쓴다.
class BankActionFailed implements Exception {
  final String message;

  /// 결과를 모르거나 목록이 바뀌었을 수 있다 — 화면은 목록을 다시 읽는다.
  final bool reload;

  const BankActionFailed(this.message, {this.reload = false});

  @override
  String toString() => 'BankActionFailed: $message';
}

/// 계좌 대조 (A9, PRD §4.6) — docs/API.md 「계좌 대조」.
///
/// - 조회(목록·결과)는 임원 모두, 업로드·재대조는 총무만 (서버가 403 으로 다시 막는다).
/// - 조회 실패는 [ApiUnavailable] 계열. **대조 결과를 지어내지 않는다** — 「미등록 0건」이 가짜로 보이면 안 된다.
/// - 쓰기 실패는 [BankActionFailed]. 401·403 은 조회와 같이 [ApiUnauthorized]·[ApiForbidden].
class BankReconcileService {
  /// HTTP 클라이언트. 테스트에서 갈아끼운다.
  static http.Client client = http.Client();

  static const readTimeout = Duration(seconds: 10);

  /// 업로드는 서버가 파일을 읽고 학기 원장 전체와 맞춰 본다. 조회보다 넉넉히 둔다.
  static const writeTimeout = Duration(seconds: 30);

  /// 서버 한도 (API.md: 최대 2MB). 넘으면 base64 로 부풀리기 전에 앱에서 막는다.
  static const maxFileBytes = 2 * 1024 * 1024;

  /// 대조할 학기 코드. 기본은 앱의 현재 학기.
  final int termCode;

  BankReconcileService({this.termCode = TermInfo.currentTermCode});

  String get _base => ApiConfig.baseUrl;

  // ───────────────────────────── 조회

  /// [termCode] 학기의 서버 id. 결산 화면과 같은 방식 — 학기 코드(YYYYS)와 id 는 다르다.
  Future<int> termId() async {
    const what = '학기 정보';
    final data = await _getJson('$_base/terms', what);
    if (data is List) {
      for (final t in data) {
        if (t is Map && t['term_code'] == termCode) {
          final id = t['id'];
          if (id is int) return id;
        }
      }
      // 서버에 현재 학기가 없다 — 다른 학기를 대신 보여 주지 않는다
      throw const ApiUnavailable('현재 학기 정보');
    }
    throw const ApiUnavailable(what);
  }

  /// 업로드 목록. 최근 업로드가 먼저 온다.
  Future<List<BankSnapshotItem>> snapshots(int termId) async {
    const what = '거래내역 업로드 목록';
    final data = await _getJson('$_base/bank/snapshots?term_id=$termId', what);
    return _parse(what, () {
      if (data is! List) throw const FormatException('목록이 아니다');
      return [
        for (final item in data)
          if (item is Map<String, dynamic>)
            BankSnapshotItem.fromJson(item)
          else
            throw const FormatException('목록 항목이 객체가 아니다'),
      ];
    });
  }

  /// 대조 결과. 상태는 **조회 시점의 원장**으로 다시 매겨진다 (API.md 4번).
  Future<BankReconcileReport> report(int snapshotId) async {
    const what = '대조 결과';
    final data = await _getJson('$_base/bank/snapshots/$snapshotId', what);
    return _parse(what, () => BankReconcileReport.fromJson(data as Map<String, dynamic>));
  }

  // ───────────────────────────── 쓰기 (총무)

  /// 은행에서 받은 CSV 를 **바이트 그대로** 올린다. 앱에서 해시를 계산해 함께 보내,
  /// 서버가 받은 파일이 고른 파일과 같은지 서버가 확인하게 한다 (HASHING.md §4).
  Future<BankReconcileReport> upload({required int termId, required List<int> bytes}) async {
    if (bytes.isEmpty) throw const BankActionFailed('빈 파일이에요. 은행에서 받은 거래내역 파일을 골라 주세요.');
    if (bytes.length > maxFileBytes) throw const BankActionFailed('파일이 2MB 를 넘어요. 조회 기간을 나눠서 받아 주세요.');
    final body = {
      'term_id': termId,
      'file_base64': base64Encode(bytes),
      'file_hash': Hashing.fileHash(bytes),
    };
    final res = await _post('$_base/bank/snapshots', body, '거래내역 업로드');
    switch (res.statusCode) {
      case 201:
        return _report(res);
      case 400:
        // 형식 오류는 서버가 몇 번째 거래인지 적어 준다 — 총무가 파일을 고칠 수 있게 그대로 보인다
        final detail = _detail(res);
        throw BankActionFailed(detail == null ? '파일을 읽지 못했어요. 은행에서 받은 CSV 원본인지 확인해 주세요.' : '파일을 읽지 못했어요: $detail');
      case 404:
        throw const BankActionFailed('현재 학기를 서버에서 찾지 못했어요.');
      case 409:
        // 같은 파일 재업로드 또는 동시 업로드. 어느 쪽이든 목록이 바뀌었을 수 있다
        throw const BankActionFailed(
          '이 파일은 이미 올렸거나 다른 대조가 진행 중이에요. 원장을 고친 뒤라면 「재대조」를 눌러 주세요.',
          reload: true,
        );
      case 413:
        throw const BankActionFailed('파일이 2MB 를 넘어요. 조회 기간을 나눠서 받아 주세요.');
      default:
        throw const BankActionFailed('업로드하지 못했어요. 잠시 후 다시 시도해 주세요.');
    }
  }

  /// 원장을 고친 뒤 **같은 파일로** 다시 맞춘다. 최신 스냅샷에서만 된다.
  Future<BankReconcileReport> rematch(int snapshotId) async {
    final res = await _post('$_base/bank/snapshots/$snapshotId/rematch', const {}, '재대조');
    switch (res.statusCode) {
      case 200:
        return _report(res);
      case 404:
        throw const BankActionFailed('대조 결과를 찾지 못했어요. 목록을 다시 불러올게요.', reload: true);
      case 409:
        throw const BankActionFailed(
          '더 최근에 올린 파일이 있거나 다른 대조가 진행 중이에요. 목록을 다시 불러올게요.',
          reload: true,
        );
      default:
        throw const BankActionFailed('재대조하지 못했어요. 잠시 후 다시 시도해 주세요.');
    }
  }

  // ───────────────────────────── HTTP

  /// 쓰기는 성공했는데 결과를 못 읽은 경우 — 다시 올리면 409 가 나니 목록을 다시 읽게 한다.
  static BankReconcileReport _report(http.Response res) {
    try {
      return BankReconcileReport.fromJson(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } on Object {
      throw const BankActionFailed('대조는 됐지만 결과를 읽지 못했어요. 목록을 다시 불러올게요.', reload: true);
    }
  }

  static String? _detail(http.Response res) {
    try {
      final d = (jsonDecode(utf8.decode(res.bodyBytes)) as Map)['detail'];
      return d is String && d.isNotEmpty ? d : null;
    } on Object {
      return null;
    }
  }

  static T _parse<T>(String what, T Function() parse) {
    try {
      return parse();
    } on FormatException {
      throw ApiUnavailable(what);
    } on TypeError {
      throw ApiUnavailable(what);
    }
  }

  static Future<Object?> _getJson(String url, String what) async {
    final auth = AuthService().authSnapshot;
    final http.Response res;
    try {
      res = await client.get(Uri.parse(url), headers: auth.headers).timeout(readTimeout);
    } catch (_) {
      throw ApiUnavailable(what);
    }
    await _checkAuth(res, auth.token, what);
    if (res.statusCode != 200) throw ApiUnavailable(what);
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw ApiUnavailable(what);
    }
  }

  static Future<http.Response> _post(String url, Map<String, Object?> body, String what) async {
    final auth = AuthService().authSnapshot;
    final http.Response res;
    try {
      res = await client
          .post(
            Uri.parse(url),
            headers: {...auth.headers, 'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(writeTimeout);
    } on Object {
      // 보낸 뒤 응답만 못 받았을 수 있다 — 서버에선 이미 대조됐을 수 있으니 목록을 다시 본다
      throw BankActionFailed('$what 결과를 받지 못했어요. 목록을 다시 불러와 반영됐는지 확인할게요.', reload: true);
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
