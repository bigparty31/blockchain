import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/api_config.dart';
import 'package:student_council_app/services/auth_service.dart';
import 'package:student_council_app/services/student_api_service.dart';

/// **못 읽은 값은 지어내지 않는다** — 학생 화면(`StudentApiService`) 쪽.
///
/// 총무·감사 화면(`ApiService`)의 같은 문제는 `feat/app-council` 의
/// `19de5dc`·`96e80a3` 이 다룬다 — `ApiUnavailable`/`ApiUnauthorized`/
/// `ApiForbidden` 과 `DEV_TOOLS` 빌드 플래그로, 403 까지 구분하고 시연용 더미는
/// 개발 빌드에만 남긴다. 그쪽 테스트는 `api_unavailable_test.dart` 다.
/// 여기서 같은 일을 다시 하면 설계가 둘로 갈린다.
///
/// 이 앱의 존재 이유가 「학생이 숫자를 직접 검증한다」인데, 조회 실패를 예시
/// 데이터로 메우면 그 이유가 무너진다. 화면에는 멀쩡한 숫자가 떠 있고 그것이
/// 실제 장부인지 개발용 예시인지 구분할 방법이 없기 때문이다.
///
/// 특히 **실서버를 보고 있을 때** 섞이는 것이 나쁘다. `usingDemoData` 가
/// false 라서 데모 배너조차 뜨지 않아, 학생은 실제 장부 옆의 가짜 통장 잔액을
/// 알아챌 수 없다.
void main() {
  setUp(() {
    ApiConfig.studentBaseUrlOverride = 'http://student.test:9001';
    ApiConfig.councilBaseUrlOverride = 'http://council.test:9002';
    AuthService.store = MemoryTokenStore();
    AuthService.lockStore = MemoryLoginLockStore();
    AuthService().onUnauthorized = null;
  });

  tearDown(() async {
    AuthService().onUnauthorized = null;
    AuthService.store = MemoryTokenStore();
    await AuthService().logout();
    AuthService.client = http.Client();
    StudentApiService.client = http.Client();
    await StudentApiService().resetSessionState();
    ApiConfig.resetOverrides();
  });

  /// `/entries` 만 성공시켜 **서버 원장을 보고 있는 상태**로 만든다.
  Future<void> enterRealMode() async {
    StudentApiService.client = MockClient((req) async {
      if (req.url.path == '/entries') {
        return http.Response('[]', 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return http.Response('{"detail":"not found"}', 404);
    });
    await StudentApiService().fetchEntries();
    expect(StudentApiService().usingDemoData, isFalse);
  }

  group('학생 화면 — 실서버를 보고 있으면 예시로 메우지 않는다', () {
    /// 이 테스트가 잡으려는 결함: `/snapshots/latest` 는 백엔드에 아직 없어서
    /// 실모드에서 404 가 **확정**인데, 예전에는 `_usingDemoData` 와 무관하게
    /// 예시 스냅샷을 돌려줬다. 실제 장부 + 가짜 통장 잔액·미등록 거래가 한
    /// 화면에 섞이고, `usingDemoData` 가 false 라 배너도 뜨지 않았다.
    test('스냅샷을 못 읽으면 null — 가짜 통장 잔액을 만들지 않는다', () async {
      await enterRealMode();
      expect(
        await StudentApiService().fetchLatestSnapshot(),
        isNull,
        reason: '실장부 옆에 예시 통장 잔액이 섞이면 학생이 구분할 수 없다',
      );
    });

    test('예산을 못 읽으면 던진다 — 예시 집행률을 만들지 않는다', () async {
      await enterRealMode();
      await expectLater(
        StudentApiService().fetchBudgets(),
        throwsA(isA<LedgerUnavailable>()),
      );
    });

    test('서버에 닿지도 못했으면 데모 모드다 — 그때는 배너와 함께 예시를 쓴다', () async {
      StudentApiService.client =
          MockClient((_) async => throw http.ClientException('no server'));
      await StudentApiService().fetchEntries();

      expect(StudentApiService().usingDemoData, isTrue);
      expect(await StudentApiService().fetchLatestSnapshot(), isNotNull);
      expect(await StudentApiService().fetchBudgets(), isNotEmpty);
    });
  });

  group('학생 화면 — 401 은 데모 폴백으로 내려가지 않는다', () {
    /// 이 테스트가 잡으려는 결함: `_getJson` 이 401 에 null 을 돌려주고,
    /// `fetchEntries` 가 그 null 을 보고 `_usingDemoData = true` 로 바꾼 뒤
    /// 데모 7건을 돌려줬다. 만료된 세션에 예시 장부가 뜨는데, 코드 주석은
    /// 「데모 폴백으로 넘기지 않는다」고 적혀 있었다 (PRD v0.14 §7.3).
    test('내역 조회 401 은 SessionExpired 다', () async {
      StudentApiService.client = MockClient((_) async => http.Response('{}', 401));
      await expectLater(
        StudentApiService().fetchEntries(),
        throwsA(isA<SessionExpired>()),
      );
    });

    test('401 뒤에도 데모 모드로 바뀌지 않는다', () async {
      await enterRealMode();
      StudentApiService.client = MockClient((_) async => http.Response('{}', 401));

      try {
        await StudentApiService().fetchEntries();
      } on SessionExpired {
        // 기대한 경로
      }
      expect(
        StudentApiService().usingDemoData,
        isFalse,
        reason: '만료된 세션에 데모 장부가 뜨면 학생은 예시를 실제 장부로 읽는다',
      );
    });
  });

}
