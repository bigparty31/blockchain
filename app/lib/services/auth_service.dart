import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/enums.dart';

/// 로그인한 사용자. `POST /auth/login` + `GET /auth/me` 를 합친 것이다.
///
/// `role` 은 **서버가 판정한 값**이다. 학번으로 앱이 추측하지 않는다 —
/// 추측하면 학번 규칙이 바뀌는 순간 학생이 총무 화면을 열게 된다.
class Session {
  final int userId;
  final String studentNo;
  final String name;
  final UserRole role;
  final String token;

  /// 임원만 값이 있고 학생은 null (docs/API.md 「인증」 1).
  final String? walletAddress;

  const Session({
    required this.userId,
    required this.studentNo,
    required this.name,
    required this.role,
    required this.token,
    this.walletAddress,
  });
}

/// 학번 또는 비밀번호가 틀렸다 (401).
///
/// **어느 쪽이 틀렸는지 담지 않는다.** 서버가 구분하지 않는 것과 같은 이유로
/// (작성지침 화면 1 「화면 전체 규칙」), 앱도 구분해 보여줄 수단을 갖지 않는다.
class LoginFailure implements Exception {
  /// 이 실패로 차단까지 걸렸는지. 문구가 달라진다 (작성지침 ③ 실패 (2)).
  final bool locked;
  const LoginFailure({this.locked = false});
}

/// 연속 실패로 차단된 동안의 시도.
class LoginLocked implements Exception {
  final Duration remaining;
  const LoginLocked(this.remaining);
}

/// 서버에 닿지 못했다 (무응답·5xx·형식 불명). 토스트로 알린다 (작성지침 ③ 실패 (3)).
class LoginUnavailable implements Exception {
  const LoginUnavailable();
}

/// 토큰 보관소. 테스트에서 갈아끼운다 — [FlutterSecureStorage] 는 플랫폼 채널을
/// 쓰므로 `flutter test` 에서 `MissingPluginException` 이 난다.
abstract class TokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> clear();
}

/// 기본 구현 — 기기 키스토어. 실패는 「토큰 없음」으로 다룬다.
///
/// 저장이 안 되면 세션이 앱 재시작까지만 유지될 뿐이고, 읽기가 안 되면
/// 다시 로그인하면 된다. 어느 쪽도 로그인 자체를 막을 이유는 아니다.
class SecureTokenStore implements TokenStore {
  static const _key = 'auth_access_token';
  final FlutterSecureStorage _storage;

  const SecureTokenStore([this._storage = const FlutterSecureStorage()]);

  @override
  Future<String?> read() async {
    try {
      return await _storage.read(key: _key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String token) async {
    try {
      await _storage.write(key: _key, value: token);
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
  }
}

/// 메모리 보관소 — 테스트용.
class MemoryTokenStore implements TokenStore {
  String? value;
  MemoryTokenStore([this.value]);

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String token) async => value = token;

  @override
  Future<void> clear() async => value = null;
}

/// 로그인·세션 관리.
///
/// **토큰은 여기만 들고 있는다.** 화면이나 다른 서비스가 각자 복사해 두면
/// 로그아웃·만료 때 한 군데가 빠져 「로그아웃했는데 조회는 되는」 상태가 된다.
/// 다른 서비스는 [authHeaders] 로 가져다 쓴다.
class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  /// HTTP 클라이언트. **테스트에서 갈아끼운다** ([StudentApiService.client] 와 같은 이유).
  static http.Client client = http.Client();

  /// 토큰 보관소. 테스트에서 [MemoryTokenStore] 로 갈아끼운다.
  static TokenStore store = const SecureTokenStore();

  /// 로그인은 서버에서 bcrypt 검사(~0.25초)를 하므로 조회보다 넉넉히 준다.
  static const timeout = Duration(seconds: 5);

  /// 연속 실패 차단 (작성지침 화면 1 ③ 실패 (2)).
  static const maxAttempts = 5;
  static const lockDuration = Duration(seconds: 60);

  Session? get session => _session;
  Session? _session;

  int _failedAttempts = 0;
  DateTime? _lockedUntil;

  /// 토큰이 더 이상 유효하지 않을 때 불린다 (`401`). `main.dart` 가 로그인 화면으로 보낸다.
  ///
  /// 기본값 null — 붙이지 않으면 아무 일도 하지 않는다. 테스트가 네비게이션을
  /// 끌고 들어오지 않아도 되게 하기 위한 것이다.
  void Function()? onUnauthorized;

  /// 남은 차단 시간. 차단 중이 아니면 null.
  Duration? get lockRemaining {
    final until = _lockedUntil;
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    if (left <= Duration.zero) {
      _lockedUntil = null;
      _failedAttempts = 0;
      return null;
    }
    return left;
  }

  /// 인증이 필요한 요청에 붙이는 헤더. 로그인 전이면 빈 맵이다.
  Map<String, String> get authHeaders {
    final token = _session?.token;
    return token == null ? const {} : {'Authorization': 'Bearer $token'};
  }

  /// 학번·비밀번호로 로그인한다.
  ///
  /// 성공하면 토큰을 보관소에 쓰고 [session] 을 채운다. **`GET /auth/me` 까지
  /// 성공한 뒤에 저장한다** — user id 는 로그인 응답에 없는데(docs/API.md 「인증」 1)
  /// 자기 승인 차단 판정과 푸시 토큰 연결에 필요해서, id 없는 반쪽 세션을
  /// 만들어 두면 그 화면들이 조용히 틀린다.
  ///
  /// Throws: [LoginLocked], [LoginFailure], [LoginUnavailable].
  Future<Session> login(String studentNo, String password) async {
    final locked = lockRemaining;
    if (locked != null) throw LoginLocked(locked);

    final http.Response res;
    try {
      res = await client
          .post(
            Uri.parse('${ApiConfig.baseUrl}/auth/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'student_no': studentNo, 'password': password}),
          )
          .timeout(timeout);
    } catch (_) {
      // 서버에 닿지 못했다. 실패 횟수에 세지 않는다 — 비밀번호가 틀렸다는 근거가 없고,
      // 와이파이가 끊긴 것으로 차단까지 걸리면 복구할 방법이 없다.
      throw const LoginUnavailable();
    }

    if (res.statusCode == 401) {
      _failedAttempts++;
      final nowLocked = _failedAttempts >= maxAttempts;
      if (nowLocked) _lockedUntil = DateTime.now().add(lockDuration);
      throw LoginFailure(locked: nowLocked);
    }
    if (res.statusCode != 200) throw const LoginUnavailable();

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const LoginUnavailable();
    }

    final token = body['access_token'];
    final roleCode = body['role'];
    if (token is! String || token.isEmpty || roleCode is! String) {
      throw const LoginUnavailable();
    }

    final me = await _fetchMe(token);
    final session = Session(
      userId: me.userId,
      studentNo: me.studentNo,
      name: body['name'] is String ? body['name'] as String : me.name,
      // 서버 판정을 그대로 쓴다. docs/enums.md 에 없는 값이면 fromCode 가 STUDENT 로
      // 떨어뜨리므로, 모르는 역할에 임원 화면이 열리는 일은 없다.
      role: UserRole.fromCode(roleCode),
      token: token,
      walletAddress: body['wallet_address'] is String ? body['wallet_address'] as String : null,
    );

    await store.write(token);
    _session = session;
    _failedAttempts = 0;
    _lockedUntil = null;
    return session;
  }

  /// 보관된 토큰으로 세션을 되살린다. 앱을 켤 때 부른다.
  ///
  /// 토큰이 없거나 만료됐으면 null 이고, 만료된 토큰은 지운다. 서버에 닿지
  /// 못했을 때는 **토큰을 지우지 않는다** — 유효한 토큰을 와이파이 문제로
  /// 버리면 다시 로그인해야 한다. 이 경우도 null 이라 화면은 로그인으로 간다.
  Future<Session?> restore() async {
    final token = await store.read();
    if (token == null || token.isEmpty) return null;

    try {
      final me = await _fetchMe(token);
      _session = Session(
        userId: me.userId,
        studentNo: me.studentNo,
        name: me.name,
        role: me.role,
        token: token,
        // 로그인 응답에만 있는 값이라 되살릴 때는 모른다. 필요한 화면이 /users/wallets 로 받는다.
        walletAddress: null,
      );
      return _session;
    } on _Unauthorized {
      await store.clear();
      _session = null;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 로그아웃. 토큰을 지우고 세션을 비운다.
  Future<void> logout() async {
    _session = null;
    _failedAttempts = 0;
    _lockedUntil = null;
    await store.clear();
  }

  /// 다른 서비스가 `401` 을 받았을 때 부른다. 세션을 비우고 [onUnauthorized] 를 알린다.
  Future<void> reportUnauthorized() async {
    if (_session == null) return; // 이미 로그아웃 상태. 중복 이동을 막는다
    await logout();
    onUnauthorized?.call();
  }

  /// 차단·실패 횟수를 되돌린다. 테스트에서 쓴다.
  void resetAttempts() {
    _failedAttempts = 0;
    _lockedUntil = null;
  }

  Future<_Me> _fetchMe(String token) async {
    final http.Response res;
    try {
      res = await client
          .get(
            Uri.parse('${ApiConfig.baseUrl}/auth/me'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(timeout);
    } catch (_) {
      throw const LoginUnavailable();
    }

    if (res.statusCode == 401) throw const _Unauthorized();
    if (res.statusCode != 200) throw const LoginUnavailable();

    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      return _Me(
        userId: body['id'] as int,
        studentNo: body['student_no'] as String,
        name: body['name'] as String,
        role: UserRole.fromCode(body['role'] as String),
      );
    } catch (_) {
      throw const LoginUnavailable();
    }
  }
}

/// `GET /auth/me` 응답.
class _Me {
  final int userId;
  final String studentNo;
  final String name;
  final UserRole role;
  const _Me({
    required this.userId,
    required this.studentNo,
    required this.name,
    required this.role,
  });
}

/// 내부 신호 — 토큰이 거부됐다. 밖으로 나가지 않는다.
class _Unauthorized implements Exception {
  const _Unauthorized();
}
