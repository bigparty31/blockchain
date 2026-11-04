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

  static String get studentBaseUrl =>
      _studentOverride.isNotEmpty ? _studentOverride : 'http://$_host:$_defaultPort';

  static String get councilBaseUrl =>
      _councilOverride.isNotEmpty ? _councilOverride : 'http://$_host:$_defaultPort';

  /// 지금 쓸 주소. 역할을 모르면(로그인 전) **학생 서버**다.
  ///
  /// 로그인은 양쪽 서버에 다 있다 (PRD §9.1). 로그인 전에는 역할을 알 수 없으니
  /// 바깥에 가장 넓게 열려 있는 학생 서버로 보내고, 응답의 role 을 본 뒤부터
  /// 주소를 가른다. 임원이 학생 서버로 로그인해도 토큰은 정상 발급되고,
  /// 그 다음 요청부터 [activeRole] 이 학생회 서버를 가리킨다.
  static String get baseUrl =>
      activeRole == null || activeRole == UserRole.STUDENT ? studentBaseUrl : councilBaseUrl;

  // Endpoints — 조회는 양쪽 서버에 다 있다.
  static String get entries => '$baseUrl/entries';
  static String get balance => '$baseUrl/balance';
  static String get budgets => '$baseUrl/budgets';
}
