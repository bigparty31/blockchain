/// 개발용 화면 요소를 보일지 여부.
///
/// `flutter run --dart-define=DEV_TOOLS=true` 로 켠다. 기본은 꺼져 있어서
/// 발표·배포 빌드에는 로그인 화면의 테스트 계정 선택기와 홈의 실기 검증 메뉴가 보이지 않는다
/// (스토리보드 1 화면 규칙 — "개발용 · 발표 빌드에서 제거").
const bool kDevTools = bool.fromEnvironment('DEV_TOOLS');
