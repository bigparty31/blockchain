import 'dart:io';

import 'enums.dart';

/// 백엔드 주소. **서버가 둘이다** (PRD v0.14 §9.1).
///
/// | | 학생 서버 | 학생회 서버 |
/// |---|---|---|
/// | 붙는 라우터 | 조회용 | 쓰기용 + 조회용 |
/// | DB 계정 | 읽기 전용 | 읽기·쓰기 |
/// | 릴레이어·FCM 키 | 없음 | 있음 |
/// | 받는 토큰 | 학생 롤만 | 임원 롤만 |
///
/// 앱은 **로그인한 역할에 따라 둘 중 하나**를 쓴다. 각 서버가 자기 롤이 아닌
/// 토큰을 받지 않으므로, 역할과 주소가 어긋나면 모든 요청이 거부된다.
class ApiConfig {
  ApiConfig._();

  /// 현재 세션의 역할. [AuthService] 가 로그인·복원·로그아웃 때 설정한다.
  ///
  /// 여기서 `AuthService` 를 직접 읽지 않는 이유는 순환 import 가 되기 때문이다
  /// (`auth_service.dart` 가 이 파일을 쓴다). 값을 밀어 넣는 쪽이 한 방향이라 안전하고,
  /// 테스트에서도 이 값만 바꾸면 주소 분기를 확인할 수 있다.
  static UserRole? activeRole;

  /// 플랫폼별 기본 host. Android 에뮬레이터만 호스트 PC 를 `10.0.2.2` 로 본다.
  static String get _host {
    try {
      return Platform.isAndroid ? '10.0.2.2' : '127.0.0.1';
    } catch (_) {
      return 'localhost';
    }
  }

  /// 학생 서버 — 조회만. 빌드 때 `--dart-define=STUDENT_API_URL=...` 로 바꾼다.
  static const _studentOverride = String.fromEnvironment('STUDENT_API_URL');

  /// 학생회 서버 — 등록·승인·반려·릴레이. `--dart-define=COUNCIL_API_URL=...`
  static const _councilOverride = String.fromEnvironment('COUNCIL_API_URL');

  /// **기본값은 둘 다 같은 주소다.** 지금 저장소에는 진입점이 하나뿐이라
  /// (`backend/app/main.py`), 포트를 미리 갈라 두면 오늘 당장 앱이 안 붙는다.
  /// 서버가 실제로 나뉘면 `--dart-define` 으로 주소만 바꾸면 되고 앱 코드는 그대로다.
  static const _defaultPort = 8000;

  /// 테스트에서 두 주소를 **다르게** 주기 위한 자리.
  ///
  /// [_studentOverride]·[_councilOverride] 는 `String.fromEnvironment` 라
  /// **컴파일 타임 상수**이고, 기본값은 둘 다 같은 주소다. 그래서 주소 분기를
  /// 통째로 지워도 `baseUrl == studentBaseUrl == councilBaseUrl` 이 되어
  /// 테스트가 그대로 통과했다 — 분기가 맞는지 물을 수 없는 테스트였다.
  /// 여기를 런타임에 갈아끼울 수 있게 두면 **두 주소가 다른 상황**을 만들 수 있고,
  /// 그때야 「역할에 맞는 서버로 갔는지」가 실패할 수 있는 질문이 된다.
  ///
  /// 실행 코드는 이 값을 쓰지 않는다. 테스트가 [resetOverrides] 로 되돌린다.
  static String? studentBaseUrlOverride;
  static String? councilBaseUrlOverride;

  static String get studentBaseUrl => studentBaseUrlOverride ?? _compiled(_studentOverride);

  static String get councilBaseUrl => councilBaseUrlOverride ?? _compiled(_councilOverride);

  static String _compiled(String value) =>
      value.isNotEmpty ? value : 'http://$_host:$_defaultPort';

  /// 테스트 격리 — `tearDown` 에서 부른다.
  static void resetOverrides() {
    studentBaseUrlOverride = null;
    councilBaseUrlOverride = null;
  }

  /// **이 역할이 쓸 주소.** 역할을 모르면(로그인 전) 학생 서버다.
  ///
  /// 로그인은 양쪽 서버에 다 있다 (PRD §9.1). 로그인 전에는 역할을 알 수 없으니
  /// 바깥에 가장 넓게 열려 있는 학생 서버로 보내고, 응답의 role 을 본 뒤부터
  /// 주소를 가른다.
  ///
  /// [baseUrl] 과 따로 있는 이유: 로그인 **도중**에는 [activeRole] 이 아직 비어
  /// 있는데 이미 역할을 알고 있는 순간이 있다 (`POST /auth/login` 응답을 받은
  /// 직후). 그때 `GET /auth/me` 를 [baseUrl] 로 보내면 학생 서버로 가고,
  /// 학생 서버가 임원 토큰을 받지 않으므로 **임원은 로그인 자체가 막힌다.**
  /// 역할을 아는 쪽이 주소를 직접 고를 수 있어야 한다
  /// (`AuthService.login`·`AuthService.restore`).
  static String baseUrlFor(UserRole? role) =>
      role == null || role == UserRole.STUDENT ? studentBaseUrl : councilBaseUrl;

  /// 지금 쓸 주소 — 로그인이 끝난 뒤의 모든 요청이 쓴다.
  static String get baseUrl => baseUrlFor(activeRole);

  /// 이 URL 이 **우리 서버**인가.
  ///
  /// 두 가지 판단의 기준이다:
  ///   1. `Authorization` 헤더를 붙일지 — 외부 주소(S3·CDN)에 우리 JWT 를
  ///      보내면 그 서버가 학생 토큰을 받아 간다. 영수증 `receipt_path` 는
  ///      절대 URL 일 수 있고 백엔드에 출처 제한이 없다.
  ///   2. `401` 을 세션 만료로 볼지 — 남의 서버가 준 401 로 우리 세션을
  ///      로그아웃시키면 멀쩡한 로그인이 끊긴다. presigned URL 은 `Authorization`
  ///      헤더가 붙었다는 이유만으로 거부하기도 한다.
  ///
  /// scheme·host·port 가 모두 같아야 한다. [Uri.port] 는 scheme 기본값으로
  /// 채워지므로 `http://h` 와 `http://h:80` 은 같다고 본다.
  static bool isOwnOrigin(String url) {
    final target = Uri.tryParse(url);
    if (target == null || !target.hasAuthority) return false;

    for (final base in <String>{studentBaseUrl, councilBaseUrl}) {
      final b = Uri.tryParse(base);
      if (b == null || !b.hasAuthority) continue;
      if (target.scheme == b.scheme && target.host == b.host && target.port == b.port) {
        return true;
      }
    }
    return false;
  }

  // Endpoints — 조회는 양쪽 서버에 다 있다.
  static String get entries => '$baseUrl/entries';
  static String get balance => '$baseUrl/balance';
  static String get budgets => '$baseUrl/budgets';
}
