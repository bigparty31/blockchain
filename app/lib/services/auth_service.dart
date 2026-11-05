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

/// 세션이 더 이상 유효하지 않다 (`401`).
///
/// **null 이 아니라 예외인 이유가 있다.** 조회 메서드들은 「못 읽었으면 null」
/// 규약을 쓰고, 그 null 을 받은 쪽이 예시 데이터로 폴백한다. 401 을 null 로
/// 돌려주면 **만료된 세션에 데모 장부가 뜬다** — 학생은 로그인이 끊긴 줄 모르고
/// 예시 데이터를 실제 원장으로 읽는다 (PRD v0.14 §7.3). 폴백 경로와 갈라서려면
/// 「값이 없다」와 다른 신호여야 한다.
class SessionExpired implements Exception {
  const SessionExpired();
  @override
  String toString() => 'SessionExpired';
}

/// 기기에서 토큰을 지우지 못했다.
///
/// **삼키면 안 되는 실패다.** 세션은 메모리에서 비워졌으니 화면은 로그아웃된
/// 것처럼 보이는데, 보관소에는 토큰이 남아 **다음 실행의 [AuthService.restore]
/// 가 그것을 되살린다.** 공용 기기라면 다음 사람이 이전 사용자 세션으로 들어간다.
/// 호출자가 알아야 「로그아웃됐다」고 말하지 않을 수 있다.
class TokenClearFailed implements Exception {
  const TokenClearFailed();
  @override
  String toString() => 'TokenClearFailed';
}

/// 보관소에 넣는 것 — 토큰과 **그 토큰의 역할**.
///
/// 역할을 함께 저장하는 이유: [AuthService.restore] 는 `GET /auth/me` 를 불러야
/// 역할을 아는데, 그 요청을 보낼 주소를 고르려면 **먼저** 역할을 알아야 한다.
/// 역할 없이 복원하면 임원 토큰이 학생 서버로 가고, 학생 서버가 그것을 받지
/// 않으므로 401 이 되어 **유효한 토큰이 지워진다.**
class StoredSession {
  final String token;

  /// 저장할 때 몰랐거나(옛 형식) 모르는 코드였으면 null.
  final UserRole? role;

  const StoredSession(this.token, this.role);

  /// `ROLE|token`. 토큰(JWT base64url)에는 `|` 가 없어서 첫 구분자로 가른다.
  String encode() => '${role?.code ?? ''}|$token';

  /// **옛 형식(토큰만)도 읽는다.** 이미 기기에 저장된 세션을 한 번에 무효로
  /// 만들면, 업데이트한 사용자 전원이 이유 없이 다시 로그인해야 한다.
  /// 역할을 모르면 null 이고, 그때는 학생 서버로 보낸다 — 임원이면 401 이 나서
  /// 다시 로그인하게 되는데, 옛 형식이 남아 있는 한 번에만 생기는 일이다.
  static StoredSession? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;

    final sep = raw.indexOf('|');
    if (sep < 0) return StoredSession(raw, null);

    final code = raw.substring(0, sep);
    final token = raw.substring(sep + 1);
    if (token.isEmpty) return null;

    // `UserRole.fromCode` 는 모르는 코드를 STUDENT 로 떨어뜨린다. 여기서는
    // 「학생」과 「모름」을 구분해야 하므로 직접 찾는다.
    UserRole? role;
    for (final r in UserRole.values) {
      if (r.code == code) role = r;
    }
    return StoredSession(token, role);
  }
}

/// 토큰 보관소. 테스트에서 갈아끼운다 — [FlutterSecureStorage] 는 플랫폼 채널을
/// 쓰므로 `flutter test` 에서 `MissingPluginException` 이 난다.
abstract class TokenStore {
  Future<StoredSession?> read();
  Future<void> write(StoredSession session);

  /// Throws [TokenClearFailed] — 지우지 못하면 **반드시 알린다**.
  Future<void> clear();
}

/// 기본 구현 — 기기 키스토어.
///
/// 읽기·쓰기 실패는 「토큰 없음」으로 다룬다. 저장이 안 되면 세션이 앱
/// 재시작까지만 유지될 뿐이고, 읽기가 안 되면 다시 로그인하면 된다. 어느 쪽도
/// 로그인 자체를 막을 이유는 아니다.
///
/// **삭제 실패는 다르다.** 그 경우 지워졌다고 믿은 토큰이 기기에 남으므로
/// [TokenClearFailed] 를 던진다 (그 클래스의 설명 참고).
class SecureTokenStore implements TokenStore {
  static const _key = 'auth_access_token';
  final FlutterSecureStorage _storage;

  const SecureTokenStore([this._storage = const FlutterSecureStorage()]);

  @override
  Future<StoredSession?> read() async {
    try {
      return StoredSession.decode(await _storage.read(key: _key));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(StoredSession session) async {
    try {
      await _storage.write(key: _key, value: session.encode());
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      // 한 번은 다시 해 본다 — 키스토어는 잠깐 잠겨 있을 수 있다.
      try {
        await _storage.delete(key: _key);
      } catch (_) {
        throw const TokenClearFailed();
      }
    }
  }
}

/// 연속 실패 잠금을 **기기에 남긴다.**
///
/// 메모리에만 두면 앱을 다시 켜는 것으로 잠금이 풀린다 — 5회 제한이 사실상
/// 없는 것과 같다 (작성지침 화면 1 ③ 실패 (2)).
///
/// **이것으로 무차별 시도를 막을 수는 없다.** 앱 데이터를 지우거나 다시
/// 설치하면 초기화되고, 애초에 API 를 직접 부르면 앱을 거치지도 않는다.
/// 실제 차단은 서버가 해야 한다(계정·IP 단위). 여기 있는 것은 **화면의 약속을
/// 지키는 것**까지다 — 잠겼다고 말했으면 앱을 다시 켜도 잠겨 있어야 한다.
abstract class LoginLockStore {
  Future<({int attempts, DateTime? lockedUntil})?> read();
  Future<void> write({required int attempts, DateTime? lockedUntil});
  Future<void> clear();
}

/// 기본 구현 — 기기 키스토어. 실패는 「잠금 없음」으로 다룬다.
class SecureLoginLockStore implements LoginLockStore {
  static const _key = 'auth_login_lock';

  /// 키스토어가 **응답하지 않아도** 로그인 화면이 멈추지 않게 한다.
  ///
  /// 잠금은 편의 기능이라 못 읽으면 「잠금 없음」으로 넘어가면 되는데, 기다리는
  /// 동안 화면이 멈추면 로그인 자체를 못 한다. 플랫폼 채널이 끝내 대답하지 않는
  /// 경우(테스트 환경이 그렇다)가 실제로 있다.
  static const _ioTimeout = Duration(seconds: 2);

  /// 플랫폼 채널이 없다고 **한 번 확인했으면 다시 기다리지 않는다.**
  ///
  /// `flutter test` 에는 `flutter_secure_storage` 의 네이티브 쪽이 없어서 호출이
  /// 대답하지 않는다. 매번 [_ioTimeout] 만큼 기다리면 테스트가 호출 수만큼
  /// 느려지고, 보관소를 갈아끼우지 않은 테스트(`AuthService.lockStore` 를 모르는
  /// 다른 사람의 테스트)가 통째로 멈춘 것처럼 보인다. 한 번 실패한 뒤에는
  /// 「잠금 없음」으로 즉시 넘어간다 — 잠금은 편의 기능이라 그래도 된다.
  static bool _unavailable = false;

  /// 테스트에서 되돌린다 (`flutter test` 는 프로세스를 공유한다).
  static void resetAvailability() => _unavailable = false;

  final FlutterSecureStorage _storage;

  const SecureLoginLockStore([this._storage = const FlutterSecureStorage()]);

  @override
  Future<({int attempts, DateTime? lockedUntil})?> read() async {
    if (_unavailable) return null;
    try {
      final raw = await _storage.read(key: _key).timeout(_ioTimeout);
      if (raw == null || raw.isEmpty) return null;

      // `attempts|lockedUntilMillis` — 뒤쪽은 비어 있을 수 있다.
      final sep = raw.indexOf('|');
      if (sep < 0) return null;
      final attempts = int.tryParse(raw.substring(0, sep));
      if (attempts == null) return null;

      final millis = int.tryParse(raw.substring(sep + 1));
      return (
        attempts: attempts,
        lockedUntil: millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis),
      );
    } catch (_) {
      _unavailable = true;
      return null;
    }
  }

  @override
  Future<void> write({required int attempts, DateTime? lockedUntil}) async {
    if (_unavailable) return;
    try {
      await _storage
          .write(
            key: _key,
            value: '$attempts|${lockedUntil?.millisecondsSinceEpoch ?? ''}',
          )
          .timeout(_ioTimeout);
    } catch (_) {
      // 저장이 안 되면 잠금이 재시작으로 풀릴 뿐이다. 로그인을 막을 이유는 아니다.
      _unavailable = true;
    }
  }

  @override
  Future<void> clear() async {
    if (_unavailable) return;
    try {
      await _storage.delete(key: _key).timeout(_ioTimeout);
    } catch (_) {
      _unavailable = true;
    }
  }
}

/// 메모리 잠금 보관소 — 테스트용.
class MemoryLoginLockStore implements LoginLockStore {
  int attempts = 0;
  DateTime? lockedUntil;

  MemoryLoginLockStore({this.attempts = 0, this.lockedUntil});

  @override
  Future<({int attempts, DateTime? lockedUntil})?> read() async =>
      (attempts: attempts, lockedUntil: lockedUntil);

  @override
  Future<void> write({required int attempts, DateTime? lockedUntil}) async {
    this.attempts = attempts;
    this.lockedUntil = lockedUntil;
  }

  @override
  Future<void> clear() async {
    attempts = 0;
    lockedUntil = null;
  }
}

/// 메모리 보관소 — 테스트용.
class MemoryTokenStore implements TokenStore {
  StoredSession? value;

  MemoryTokenStore([String? token, UserRole? role])
      : value = token == null ? null : StoredSession(token, role);

  /// 삭제가 실패하는 기기를 흉내 낸다 ([TokenClearFailed] 경로 테스트용).
  bool failOnClear = false;

  @override
  Future<StoredSession?> read() async => value;

  @override
  Future<void> write(StoredSession session) async => value = session;

  @override
  Future<void> clear() async {
    if (failOnClear) throw const TokenClearFailed();
    value = null;
  }
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

  /// 연속 실패 잠금 보관소. 테스트에서 [MemoryLoginLockStore] 로 갈아끼운다.
  static LoginLockStore lockStore = const SecureLoginLockStore();

  /// 로그인은 서버에서 bcrypt 검사(~0.25초)를 하므로 조회보다 넉넉히 준다.
  static const timeout = Duration(seconds: 5);

  /// 연속 실패 차단 (작성지침 화면 1 ③ 실패 (2)).
  static const maxAttempts = 5;
  static const lockDuration = Duration(seconds: 60);

  Session? get session => _session;
  Session? _session;

  int _failedAttempts = 0;
  DateTime? _lockedUntil;

  /// 기기에 남은 잠금을 읽는 **진행 중인 작업**. 끝났으면 완료된 Future 다.
  ///
  /// 「읽었는지」를 `bool` 로 두면 안 된다. 깃발은 `await` **전에** 세워야 두 번째
  /// 호출자를 막을 수 있는데, 그러면 아직 읽지 못한 값을 「읽었다」고 말하게 된다.
  /// 로그인 화면이 열릴 때 부른 [loadLock] 이 키스토어를 기다리는 사이
  /// (`SecureLoginLockStore._ioTimeout` 만큼) 사용자가 로그인을 누르면,
  /// [login] 의 [loadLock] 이 즉시 돌아와 **잠긴 기기에서 로그인이 통과한다.**
  /// Future 를 공유하면 두 번째 호출자도 같은 읽기를 끝까지 기다린다.
  Future<void>? _lockLoading;

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
  Map<String, String> get authHeaders => authSnapshot.headers;

  /// 인증 헤더와 **그때 쓴 토큰**을 함께.
  ///
  /// 401 을 받으면 [reportUnauthorized] 에 그 요청이 쓴 토큰을 넘겨야 하는데,
  /// 응답이 돌아온 뒤에 다시 읽으면 그 사이 재로그인으로 **바뀐 새 토큰**을 보게
  /// 되어 비교가 무의미해진다. 요청을 보내기 직전의 값을 그대로 들고 가야 한다.
  ({Map<String, String> headers, String? token}) get authSnapshot {
    final token = _session?.token;
    return (
      headers: token == null
          ? const <String, String>{}
          : <String, String>{'Authorization': 'Bearer $token'},
      token: token,
    );
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
    // **기기에 남은 잠금을 먼저 읽는다.** 메모리에만 두면 앱을 다시 켜는 것으로
    // 잠금이 풀려서, 5회 제한이 사실상 없는 것과 같다 ([LoginLockStore]).
    await loadLock();

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
      await lockStore.write(attempts: _failedAttempts, lockedUntil: _lockedUntil);
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

    // 서버 판정을 그대로 쓴다. docs/enums.md 에 없는 값이면 fromCode 가 STUDENT 로
    // 떨어뜨리므로, 모르는 역할에 임원 화면이 열리는 일은 없다.
    final role = UserRole.fromCode(roleCode);

    // **역할에 맞는 서버로 묻는다.** [ApiConfig.baseUrl] 을 쓰면 아직 `_setSession`
    // 전이라 `activeRole` 이 비어 있어 학생 서버로 가고, 학생 서버가 임원 토큰을
    // 받지 않으므로 총무·감사·회장이 로그인 단계에서 막힌다. 로그인 응답의 role 을
    // 이미 알고 있으니 그걸로 고른다 (`ApiConfig.baseUrlFor` 설명 참고).
    final me = await _fetchMe(token, baseUrl: ApiConfig.baseUrlFor(role));

    final session = Session(
      userId: me.userId,
      studentNo: me.studentNo,
      name: body['name'] is String ? body['name'] as String : me.name,
      role: role,
      token: token,
      walletAddress: body['wallet_address'] is String ? body['wallet_address'] as String : null,
    );

    // 역할도 함께 저장한다 — 다음 실행의 [restore] 가 주소를 고를 근거다.
    await store.write(StoredSession(token, role));
    _setSession(session);
    _failedAttempts = 0;
    _lockedUntil = null;
    await lockStore.clear();
    return session;
  }

  /// 보관된 토큰으로 세션을 되살린다. 앱을 켤 때 부른다.
  ///
  /// 토큰이 없거나 만료됐으면 null 이고, 만료된 토큰은 지운다. 서버에 닿지
  /// 못했을 때는 **토큰을 지우지 않는다** — 유효한 토큰을 와이파이 문제로
  /// 버리면 다시 로그인해야 한다. 이 경우도 null 이라 화면은 로그인으로 간다.
  Future<Session?> restore() async {
    final stored = await store.read();
    if (stored == null || stored.token.isEmpty) return null;

    try {
      // **저장해 둔 역할로 주소를 고른다.** 역할을 모른 채 [ApiConfig.baseUrl] 로
      // 보내면 임원 토큰이 학생 서버로 가고, 학생 서버가 받지 않아 401 이 되며
      // 아래 `store.clear()` 가 **유효한 토큰을 지운다.**
      final me = await _fetchMe(
        stored.token,
        baseUrl: ApiConfig.baseUrlFor(stored.role),
      );

      // 서버가 말한 역할이 저장된 것과 다르면(권한 변경·키 회전) 저장값을 고친다.
      if (me.role != stored.role) {
        await store.write(StoredSession(stored.token, me.role));
      }

      _setSession(Session(
        userId: me.userId,
        studentNo: me.studentNo,
        name: me.name,
        role: me.role,
        token: stored.token,
        // 로그인 응답에만 있는 값이라 되살릴 때는 모른다. 필요한 화면이 /users/wallets 로 받는다.
        walletAddress: null,
      ));
      return _session;
    } on _Unauthorized {
      // 서버가 이 토큰을 거부했다 — 지운다. 지우지 못하면 알리되, 세션은 비운다.
      _setSession(null);
      try {
        await store.clear();
      } on TokenClearFailed {
        tokenClearFailed = true;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 마지막 로그아웃·만료 처리에서 기기의 토큰을 **지우지 못했는지**.
  ///
  /// 로그인 화면이 읽어 경고를 띄운다. [logout] 은 던져서 알리지만, 세션 만료
  /// 경로([reportUnauthorized])는 호출자가 서비스 내부의 `catch` 라 던질 상대가
  /// 없다 — 그쪽은 이 깃발로 전달한다.
  bool tokenClearFailed = false;

  /// 세션이 비워질 때마다 불린다 (로그아웃·만료 모두).
  ///
  /// 토큰 말고도 **세션에 묶인 상태**가 서비스 싱글턴에 남는다 — 이의 목록,
  /// 데모 모드 깃발, 마지막 확인 항목 id. 그대로 두면 같은 기기의 다음 사람에게
  /// 이전 사용자의 것이 보인다. 여기서 직접 비우지 않는 이유는 `AuthService` 가
  /// 화면·서비스를 모르기 때문이다 (`student_api_service.dart` 가 이 파일을
  /// import 한다 — 반대로 부르면 순환 import 다). `main.dart` 가 연결한다.
  void Function()? onSessionCleared;

  /// 로그아웃. 토큰을 지우고 세션을 비운다.
  ///
  /// Throws [TokenClearFailed] — 기기에서 토큰을 지우지 못한 경우. **세션은
  /// 그래도 비워진다.** 호출자는 로그인 화면으로 보내되 「이 기기에 로그인
  /// 정보가 남아 있다」고 알려야 한다 (`core/logout_action.dart`).
  /// 잠금은 **지우지 않는다.** 로그아웃으로 풀 수 있으면 5회 제한이 무의미하다
  /// (성공한 로그인만 잠금을 되돌린다).
  Future<void> logout() async {
    _setSession(null);

    try {
      await store.clear();
      tokenClearFailed = false;
    } on TokenClearFailed {
      tokenClearFailed = true;
      rethrow;
    }
  }

  /// 세션을 바꾸는 **유일한 통로**.
  ///
  /// 역할이 바뀌면 앱이 붙는 서버도 바뀐다 (PRD v0.14 §9.1 — 학생 서버 / 학생회 서버).
  /// 세션만 바꾸고 [ApiConfig.activeRole] 을 안 바꾸면, 임원이 로그인했는데 요청은
  /// 학생 서버로 나가고 **학생 서버가 임원 토큰을 받지 않아 전부 거부된다.**
  /// 두 값이 갈리지 않도록 한 함수에서만 바꾼다.
  void _setSession(Session? session) {
    final had = _session != null;
    _session = session;
    ApiConfig.activeRole = session?.role;
    if (had && session == null) onSessionCleared?.call();
  }

  /// 다른 서비스가 `401` 을 받았을 때 부른다. 세션을 비우고 [onUnauthorized] 를 알린다.
  ///
  /// [token] 은 **그 401 을 받은 요청에 실제로 쓴 토큰**이다. 지금 세션의 토큰과
  /// 다르면 아무 일도 하지 않는다 — 늦게 돌아온 응답이 **새 로그인을 지우는**
  /// 것을 막는다: 만료된 세션으로 보낸 조회가 아직 날아다니는 동안 사용자가 다시
  /// 로그인하면, 그 응답의 401 이 방금 만든 세션을 로그아웃시킨다. 사용자에게는
  /// 「로그인했는데 바로 튕겼다」로 보이고 원인이 화면에 남지 않는다.
  ///
  /// null 을 넘기면 비교하지 않는다 — 어느 토큰이었는지 모르는 호출자용이다.
  Future<void> reportUnauthorized({String? token}) async {
    final current = _session;
    if (current == null) return; // 이미 로그아웃 상태. 중복 이동을 막는다
    if (token != null && token != current.token) return; // 지난 세션의 응답

    try {
      await logout();
    } on TokenClearFailed {
      // 세션은 비워졌다. 로그인 화면으로 보내는 일이 더 급하므로 여기서 멈추지
      // 않는다 — 남은 토큰은 [tokenClearFailed] 로 로그인 화면이 알린다.
    }
    onUnauthorized?.call();
  }

  /// 기기에 남은 잠금을 메모리로 읽어 온다. 한 번만 읽는다.
  ///
  /// [login] 이 먼저 부르므로 보통 직접 부를 일은 없다. 로그인 화면이 열릴 때
  /// 남은 시간을 바로 보여주려면 화면에서 부른다 (`login_screen.dart`).
  /// **읽기가 끝날 때까지 기다린다** — 이미 읽는 중이면 그 작업에 합류한다
  /// ([_lockLoading] 설명). 먼저 부른 쪽이 아직 키스토어를 기다리는 동안
  /// 즉시 돌아오면, 잠긴 기기에서 [login] 이 그대로 통과한다.
  Future<void> loadLock() => _lockLoading ??= _loadLockOnce();

  Future<void> _loadLockOnce() async {
    final ({int attempts, DateTime? lockedUntil})? stored;
    try {
      stored = await lockStore.read();
    } catch (_) {
      // 실패한 Future 를 캐시에 남기면 **이후 모든 호출자가 같은 예외를 받는다.**
      // 다음 호출이 다시 읽게 비워 둔다 (기본 구현은 던지지 않지만, 보관소를
      // 갈아끼운 쪽은 던질 수 있다).
      _lockLoading = null;
      rethrow;
    }
    if (stored == null) return;

    final until = stored.lockedUntil;

    // **잠금이 이미 끝났으면 실패 횟수도 되돌린다.** [lockRemaining] 이 그렇게
    // 하므로(끝난 잠금은 0회부터 다시 센다) 보관소만 5회를 들고 있으면,
    // 60초가 지나 풀린 뒤 한 번만 틀려도 바로 다시 잠긴다.
    //
    // 변이 테스트로 확인한 것: 이 분기를 지워도 테스트가 통과한다 —
    // [lockRemaining] 의 같은 처리가 뒤에서 한 번 더 걸러 주기 때문이다.
    // 그래도 남겨 둔다. 끝난 잠금을 들고 오지 않는다는 불변식을 **읽는 자리에서**
    // 지키는 쪽이, getter 의 부수효과에 의존하는 쪽보다 깨지기 어렵다.
    if (until != null && !until.isAfter(DateTime.now())) {
      await lockStore.clear();
      return;
    }

    // 메모리 쪽이 더 많이 센 경우(이번 실행에서 실패한 뒤)는 그것을 지킨다.
    if (stored.attempts > _failedAttempts) _failedAttempts = stored.attempts;
    if (until != null) _lockedUntil = until;
  }

  /// 차단·실패 횟수를 **메모리와 보관소 양쪽에서** 되돌린다. 테스트에서 쓴다.
  ///
  /// [_lockLoading] 도 비운다 — 「아직 아무것도 읽지 않은 상태」가 곧 앱을 막
  /// 켠 상태이고, 테스트가 보관소만 갈아끼워 재시작을 흉내 낼 수 있어야 한다.
  Future<void> resetAttempts() async {
    _failedAttempts = 0;
    _lockedUntil = null;
    _lockLoading = null;
    await lockStore.clear();
  }

  /// [baseUrl] 을 **호출자가 정한다.** 이 요청은 역할이 세션에 반영되기 전에
  /// 나가므로 [ApiConfig.baseUrl] 이 아직 학생 서버를 가리킨다 (`login` 주석 참고).
  Future<_Me> _fetchMe(String token, {required String baseUrl}) async {
    final http.Response res;
    try {
      res = await client
          .get(
            Uri.parse('$baseUrl/auth/me'),
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
