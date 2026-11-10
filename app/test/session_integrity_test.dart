import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/api_config.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/services/auth_service.dart';
import 'package:student_council_app/services/student_api_service.dart';

/// 세션이 **새지도, 엉뚱하게 끊기지도** 않는지 본다.
///
/// 네 가지 모두 눈으로는 안 보이는 결함이다. 토큰이 외부로 나가는 것도,
/// 늦게 온 401 이 새 로그인을 지우는 것도 화면에는 「그냥 로그아웃됨」으로만
/// 나타난다. 그래서 여기서 직접 못박는다.
void main() {
  const student = 'http://student.test:9001';
  const council = 'http://council.test:9002';

  setUp(() async {
    ApiConfig.studentBaseUrlOverride = student;
    ApiConfig.councilBaseUrlOverride = council;
    AuthService.store = MemoryTokenStore();
    AuthService.lockStore = MemoryLoginLockStore();
    await AuthService().resetAttempts();
    AuthService().onUnauthorized = null;
    AuthService().tokenClearFailed = false;
    ApiConfig.activeRole = null;
  });

  tearDown(() async {
    AuthService().onUnauthorized = null;
    AuthService().onSessionCleared = null;
    AuthService.store = MemoryTokenStore();
    await AuthService().logout();
    AuthService.client = http.Client();
    StudentApiService.client = http.Client();
    await StudentApiService().resetSessionState();
    ApiConfig.activeRole = null;
    ApiConfig.resetOverrides();
  });

  /// 학생으로 로그인한 세션을 만든다.
  Future<void> loginStudent() async {
    AuthService.client = MockClient((req) async {
      final body = switch (req.url.path) {
        '/auth/login' => {
            'access_token': 'token-abc',
            'token_type': 'bearer',
            'role': 'STUDENT',
            'name': '아무개',
          },
        '/auth/me' => {'id': 3, 'student_no': '20240001', 'name': '아무개', 'role': 'STUDENT'},
        _ => null,
      };
      if (body == null) return http.Response('{}', 404);
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await AuthService().login('20240001', 'pw');
  }

  /// 서버 원장을 보고 있는 상태로 만든다 — 데모 폴백이 꺼진다.
  ///
  /// [StudentApiService.usingDemoData] 는 초기값이 true 라서, 이것을 안 하면
  /// 「못 받았으면 null」 같은 실모드 규약이 아니라 데모 바이트가 돌아온다.
  Future<void> enterRealMode() async {
    StudentApiService.client = MockClient((req) async {
      if (req.url.path == '/entries') {
        return http.Response('[]', 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return http.Response('{}', 404);
    });
    await StudentApiService().fetchEntries();
    expect(StudentApiService().usingDemoData, isFalse);
  }

  EntryModel entryWithReceipt(String path) => EntryModel(
        id: 1,
        termId: 1,
        kind: EntryKind.EXPENSE,
        amount: 35000,
        counterparty: '한결문구',
        purpose: '명찰 구매',
        occurredAt: 1788793200,
        receiptPath: path,
        receiptHash: '0x${'a' * 64}',
        metaHash: '0x${'b' * 64}',
        status: EntryStatus.CONFIRMED,
        createdBy: 2,
      );

  group('영수증 — 토큰은 우리 서버에만 붙는다', () {
    test('절대 URL 이 외부면 Authorization 을 보내지 않는다', () async {
      await loginStudent();

      final headers = <String, String>{};
      StudentApiService.client = MockClient((req) async {
        headers.addAll(req.headers);
        return http.Response.bytes([1, 2, 3], 200);
      });

      await StudentApiService()
          .fetchReceiptBytes(entryWithReceipt('https://my-bucket.s3.amazonaws.com/r.jpg'));

      expect(
        headers.containsKey('Authorization'),
        isFalse,
        reason: '외부 주소로 학생 JWT 가 나갔다 — receipt_path 에는 출처 제한이 없다',
      );
    });

    test('우리 서버 주소면 Authorization 을 보낸다', () async {
      await loginStudent();

      final headers = <String, String>{};
      StudentApiService.client = MockClient((req) async {
        headers.addAll(req.headers);
        return http.Response.bytes([1, 2, 3], 200);
      });

      await StudentApiService().fetchReceiptBytes(entryWithReceipt('/receipts/sample_01.jpg'));
      expect(headers['Authorization'], 'Bearer token-abc');
    });

    test('절대 URL 이 우리 서버면 붙인다', () async {
      await loginStudent();

      final headers = <String, String>{};
      StudentApiService.client = MockClient((req) async {
        headers.addAll(req.headers);
        return http.Response.bytes([1, 2, 3], 200);
      });

      await StudentApiService().fetchReceiptBytes(entryWithReceipt('$student/receipts/1.jpg'));
      expect(headers['Authorization'], 'Bearer token-abc');
    });

    test('외부 서버의 401 로 세션이 끊기지 않는다', () async {
      await loginStudent();
      await enterRealMode();
      var notified = 0;
      AuthService().onUnauthorized = () => notified++;

      StudentApiService.client = MockClient((_) async => http.Response('denied', 401));

      // presigned URL 은 Authorization 헤더가 붙었다는 이유만으로도 거부한다.
      final bytes = await StudentApiService()
          .fetchReceiptBytes(entryWithReceipt('https://my-bucket.s3.amazonaws.com/r.jpg'));

      expect(bytes, isNull, reason: '못 받았으면 못 받은 것으로 둔다');
      expect(AuthService().session, isNotNull, reason: '남의 서버 401 로 로그아웃됐다');
      expect(notified, 0);
    });

    test('우리 서버의 401 은 세션 만료로 다룬다', () async {
      await loginStudent();
      var notified = 0;
      AuthService().onUnauthorized = () => notified++;

      StudentApiService.client = MockClient((_) async => http.Response('{}', 401));

      await expectLater(
        StudentApiService().fetchReceiptBytes(entryWithReceipt('/receipts/sample_01.jpg')),
        throwsA(isA<SessionExpired>()),
      );
      expect(AuthService().session, isNull);
      expect(notified, 1);
    });
  });

  group('늦게 온 401 이 새 세션을 지우지 않는다', () {
    test('지난 토큰의 401 은 무시한다', () async {
      await loginStudent();
      final first = AuthService().session!.token;

      // 다시 로그인해 토큰이 바뀐 상황을 만든다.
      AuthService.client = MockClient((req) async {
        final body = switch (req.url.path) {
          '/auth/login' => {
              'access_token': 'token-new',
              'token_type': 'bearer',
              'role': 'STUDENT',
              'name': '아무개',
            },
          '/auth/me' => {'id': 3, 'student_no': '20240001', 'name': '아무개', 'role': 'STUDENT'},
          _ => null,
        };
        if (body == null) return http.Response('{}', 404);
        return http.Response(jsonEncode(body), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      });
      await AuthService().logout();
      await AuthService().login('20240001', 'pw');
      expect(AuthService().session!.token, 'token-new');

      var notified = 0;
      AuthService().onUnauthorized = () => notified++;

      // 만료된 세션으로 보낸 조회가 이제서야 401 로 돌아왔다.
      await AuthService().reportUnauthorized(token: first);

      expect(
        AuthService().session,
        isNotNull,
        reason: '늦게 온 401 이 방금 만든 세션을 지웠다 — 「로그인했는데 바로 튕김」',
      );
      expect(AuthService().session!.token, 'token-new');
      expect(notified, 0);
    });

    test('지금 토큰의 401 은 로그아웃시킨다', () async {
      await loginStudent();
      var notified = 0;
      AuthService().onUnauthorized = () => notified++;

      await AuthService().reportUnauthorized(token: AuthService().session!.token);

      expect(AuthService().session, isNull);
      expect(notified, 1);
    });

    test('토큰을 모르는 호출자는 비교하지 않는다', () async {
      await loginStudent();
      await AuthService().reportUnauthorized();
      expect(AuthService().session, isNull);
    });
  });

  group('토큰 삭제 실패는 삼키지 않는다', () {
    test('logout 이 던진다', () async {
      final store = MemoryTokenStore('token-abc', UserRole.STUDENT);
      AuthService.store = store;
      store.failOnClear = true;

      await expectLater(AuthService().logout(), throwsA(isA<TokenClearFailed>()));
      expect(AuthService().tokenClearFailed, isTrue);
    });

    test('던지더라도 세션은 비워진다 — 화면은 로그아웃돼야 한다', () async {
      await loginStudent();
      final store = AuthService.store as MemoryTokenStore;
      store.failOnClear = true;

      try {
        await AuthService().logout();
      } on TokenClearFailed {
        // 알렸다
      }
      expect(AuthService().session, isNull);
      expect(ApiConfig.activeRole, isNull);
    });

    test('세션 만료 경로는 깃발로 알린다 — 로그인 화면으로는 그대로 보낸다', () async {
      await loginStudent();
      final store = AuthService.store as MemoryTokenStore;
      store.failOnClear = true;

      var notified = 0;
      AuthService().onUnauthorized = () => notified++;

      await AuthService().reportUnauthorized(token: AuthService().session!.token);

      expect(notified, 1, reason: '삭제가 실패해도 로그인 화면으로 보내야 한다');
      expect(AuthService().tokenClearFailed, isTrue);
      expect(AuthService().session, isNull);
    });

    test('삭제가 되면 깃발이 내려간다', () async {
      await loginStudent();
      await AuthService().logout();
      expect(AuthService().tokenClearFailed, isFalse);
    });
  });

  group('연속 실패 잠금은 앱을 다시 켜도 살아 있다', () {
    /// 이 테스트가 잡으려는 결함: 잠금이 메모리에만 있어서 앱을 다시 켜면
    /// 풀렸다 — 5회 제한이 사실상 없는 것과 같다 (작성지침 화면 1 ③ 실패 (2)).
    ///
    /// **무차별 시도를 막는 장치는 아니다.** 앱 데이터를 지우면 초기화되고 API
    /// 를 직접 부르면 앱을 거치지도 않는다. 실제 차단은 서버 몫이다. 여기서
    /// 보는 것은 「잠겼다고 말했으면 다시 켜도 잠겨 있다」는 화면의 약속이다.
    MockClient wrongPassword() =>
        MockClient((_) async => http.Response('{"detail":"unauthorized"}', 401));

    test('5회 틀리면 잠기고, 그 잠금이 보관소에 남는다', () async {
      final lock = MemoryLoginLockStore();
      AuthService.lockStore = lock;
      AuthService.client = wrongPassword();

      for (var i = 0; i < AuthService.maxAttempts; i++) {
        await expectLater(
          AuthService().login('20240001', 'wrong'),
          throwsA(isA<LoginFailure>()),
        );
      }

      expect(AuthService().lockRemaining, isNotNull);
      expect(lock.attempts, AuthService.maxAttempts);
      expect(lock.lockedUntil, isNotNull, reason: '잠금이 기기에 남지 않으면 재시작으로 풀린다');
    });

    test('앱을 다시 켜도 잠금이 유지된다', () async {
      // 「다시 켬」 = 메모리는 비었고 보관소에만 잠금이 남은 상태.
      final lock = MemoryLoginLockStore(
        attempts: AuthService.maxAttempts,
        lockedUntil: DateTime.now().add(const Duration(seconds: 45)),
      );
      AuthService.lockStore = lock;
      AuthService.client = wrongPassword();

      // **`loadLock()` 을 직접 부르지 않는다.** 여기서 부르면 「login 이 잠금을
      // 읽는가」가 아니라 「loadLock 이 동작하는가」만 보게 되어, login 에서
      // 그 호출을 지워도 테스트가 통과한다 (실제로 그랬다).
      expect(AuthService().lockRemaining, isNull, reason: '메모리에는 아직 잠금이 없다');

      await expectLater(
        AuthService().login('20240001', 'wrong'),
        throwsA(isA<LoginLocked>()),
        reason: 'login 이 기기의 잠금을 읽지 않으면 재시작으로 잠금이 풀린다',
      );
    });

    test('잠금이 끝났으면 실패 횟수도 0 부터 다시 센다', () async {
      // 지난 잠금의 5회를 그대로 들고 오면, 풀린 뒤 한 번만 틀려도 다시 잠긴다.
      final lock = MemoryLoginLockStore(
        attempts: AuthService.maxAttempts,
        lockedUntil: DateTime.now().subtract(const Duration(seconds: 1)),
      );
      AuthService.lockStore = lock;
      AuthService.client = wrongPassword();

      await expectLater(
        AuthService().login('20240001', 'wrong'),
        throwsA(isA<LoginFailure>().having((e) => e.locked, 'locked', isFalse)),
        reason: '끝난 잠금의 횟수를 들고 오면 한 번 틀리고 바로 잠긴다',
      );
      expect(AuthService().lockRemaining, isNull);
    });

    test('로그인에 성공하면 잠금 기록이 지워진다', () async {
      final lock = MemoryLoginLockStore(attempts: 3);
      AuthService.lockStore = lock;
      await loginStudent();

      expect(lock.attempts, 0);
      expect(lock.lockedUntil, isNull);
    });

    /// 이 테스트가 잡으려는 결함: `loadLock` 이 「읽었는지」를 `bool` 로 들고
    /// 있으면서 그 깃발을 **await 전에** 세웠다. 로그인 화면이 열릴 때 부른
    /// 쪽이 키스토어를 기다리는 동안(최대 2초) 사용자가 로그인을 누르면,
    /// `login` 의 `loadLock` 이 즉시 돌아와 **잠긴 기기에서 로그인이 통과했다.**
    /// 화면은 「잠겼습니다」를 띄우는 중인데 로그인은 되는 상태다.
    test('먼저 부른 읽기가 아직 안 끝났어도 login 은 잠금을 본다', () async {
      AuthService.lockStore = _SlowLockStore(
        const Duration(milliseconds: 300),
        attempts: AuthService.maxAttempts,
        lockedUntil: DateTime.now().add(const Duration(seconds: 45)),
      );
      // 서버는 성공을 돌려준다 — 잠금이 막지 않으면 그대로 로그인된다.
      AuthService.client = MockClient((req) async {
        final body = switch (req.url.path) {
          '/auth/login' => {
              'access_token': 'token-abc',
              'token_type': 'bearer',
              'role': 'STUDENT',
              'name': '아무개',
            },
          '/auth/me' => {'id': 3, 'student_no': '20240001', 'name': '아무개', 'role': 'STUDENT'},
          _ => null,
        };
        if (body == null) return http.Response('{}', 404);
        return http.Response(jsonEncode(body), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      });

      // 로그인 화면이 열릴 때 부르는 쪽 — `initState` 는 await 하지 않는다.
      final warmup = AuthService().loadLock();
      await Future<void>.delayed(Duration.zero); // 화면이 그려지고, 사용자가 버튼을 누른다

      await expectLater(
        AuthService().login('20240001', 'pw'),
        throwsA(isA<LoginLocked>()),
        reason: '읽는 중에 즉시 돌아오면 잠긴 기기에서 로그인이 통과한다',
      );
      await warmup;
      expect(AuthService().session, isNull);
    });

    test('로그아웃으로는 잠금이 풀리지 않는다', () async {
      final lock = MemoryLoginLockStore();
      AuthService.lockStore = lock;
      AuthService.client = wrongPassword();

      for (var i = 0; i < AuthService.maxAttempts; i++) {
        await expectLater(
          AuthService().login('20240001', 'wrong'),
          throwsA(isA<LoginFailure>()),
        );
      }
      expect(AuthService().lockRemaining, isNotNull);

      await AuthService().logout();
      expect(
        AuthService().lockRemaining,
        isNotNull,
        reason: '로그아웃으로 풀 수 있으면 5회 제한을 우회할 수 있다',
      );
    });
  });

  group('세션이 비워지면 서비스에 남은 상태도 비운다', () {
    test('로그아웃이 onSessionCleared 를 부른다', () async {
      await loginStudent();
      var cleared = 0;
      AuthService().onSessionCleared = () => cleared++;

      await AuthService().logout();
      expect(cleared, 1, reason: '이의 목록·데모 깃발이 다음 사람에게 남는다');
    });

    test('이미 로그아웃 상태에서는 부르지 않는다', () async {
      var cleared = 0;
      AuthService().onSessionCleared = () => cleared++;
      await AuthService().logout();
      expect(cleared, 0);
    });

    /// 4차 리뷰 Medium — 앱을 다시 켰을 때 저장된 토큰이 거부되는 경로.
    ///
    /// 메모리 세션이 애초에 없어서 `_setSession(null)` 의 「있던 세션이
    /// 비워질 때」 조건에 안 걸린다. 그래서 정리 콜백이 불리지 않고,
    /// `main.dart` 의 **FCM 토픽 해제에 도달하지 못한다** — 토픽은 기기 단위라
    /// 로그인 화면에 있는데도 이전 사용자의 학기 알림이 계속 온다.
    test('앱 시작 복원이 401 로 거부돼도 정리 콜백이 불린다', () async {
      AuthService.store = MemoryTokenStore('stale-token', UserRole.STUDENT);
      AuthService.client = MockClient((_) async => http.Response('{}', 401));
      var cleared = 0;
      AuthService().onSessionCleared = () => cleared++;

      final restored = await AuthService().restore();

      expect(restored, isNull);
      expect(
        cleared,
        1,
        reason: '해제에 도달하지 못하면 공용 기기에서 다음 사람이 이전 학기 알림을 받는다',
      );
    });

    /// 반대쪽도 못 박는다 — 저장된 토큰이 없으면 정리할 것도 없다.
    test('저장된 토큰이 없으면 정리 콜백을 부르지 않는다', () async {
      AuthService.store = MemoryTokenStore();
      var cleared = 0;
      AuthService().onSessionCleared = () => cleared++;

      expect(await AuthService().restore(), isNull);
      expect(cleared, 0);
    });

    test('resetSessionState 가 이의 목록과 데모 깃발을 되돌린다', () async {
      // 서버가 없는 상태로 이의를 제기하면 세션 동안 로컬에 남는다.
      StudentApiService.client = MockClient((_) async => throw http.ClientException('no server'));
      await StudentApiService().fetchEntries(); // 데모 모드로 들어간다
      await StudentApiService().raiseObjection(entryId: 1, content: '이 지출의 근거가 궁금합니다');
      expect(await StudentApiService().fetchObjections(), isNotEmpty);

      await StudentApiService().resetSessionState();

      expect(
        await StudentApiService().fetchObjections(),
        isEmpty,
        reason: '이전 사용자가 제기한 이의가 다음 사람에게 보인다',
      );
      expect(StudentApiService().usingDemoData, isTrue);
    });
  });

  group('토큰 저장 실패는 삼키지 않는다', () {
    /// 이전 사용자(A)의 토큰이 이미 기기에 남아 있는 상태.
    MemoryTokenStore withPreviousUser() {
      final store = MemoryTokenStore('token-of-A', UserRole.STUDENT);
      AuthService.store = store;
      return store;
    }

    test('남의 토큰이 남은 채로는 로그인을 확정하지 않는다', () async {
      final store = withPreviousUser()
        ..failOnWrite = true
        ..failOnClear = true;

      await expectLater(
        () => loginStudent(),
        throwsA(isA<SessionStoreUnsafe>()),
      );

      expect(AuthService().session, isNull, reason: '보관소에 A 의 토큰이 남은 채로 B 의 세션을 열었다');
      expect(
        store.value?.token,
        'token-of-A',
        reason: '이 상태로 로그인을 확정하면 다음 실행의 restore 가 A 의 세션을 되살린다',
      );
    });

    test('지우기까지는 되면 로그인은 되고 보관소는 비어 있다', () async {
      final store = withPreviousUser()..failOnWrite = true;

      await loginStudent();

      expect(AuthService().session?.token, 'token-abc');
      expect(store.value, isNull, reason: '남은 A 의 토큰을 지우지 못했다');
      expect(
        AuthService().sessionNotPersisted,
        isTrue,
        reason: '저장되지 않은 사실을 호출자가 알아야 「다시 켜면 로그인하세요」를 말할 수 있다',
      );
    });

    test('보관소가 비어 있었으면 저장 실패만으로 막지 않는다', () async {
      final store = MemoryTokenStore()..failOnWrite = true;
      AuthService.store = store;

      await loginStudent();

      expect(AuthService().session?.token, 'token-abc');
      expect(AuthService().sessionNotPersisted, isTrue);
    });

    test('무엇이 남았는지 못 읽으면 남았다고 보고 지운다', () async {
      final store = withPreviousUser()
        ..failOnWrite = true
        ..failOnRead = true;

      await loginStudent();

      expect(store.value, isNull, reason: '모를 때 그냥 두면 A 의 토큰이 남는다');
      expect(AuthService().sessionNotPersisted, isTrue);
    });

    // 3차 리뷰 Medium — 테스트 저장소가 읽기 실패를 **던져서** 통과했던 경로.
    // 실기기(`SecureTokenStore.read`)는 실패를 null 로 돌려주므로, `_persist` 가
    // `read` 를 쓰면 읽기 실패가 「남은 것이 없다」로 판정돼 A 의 토큰을 지우지
    // 않고 B 의 로그인이 확정된다. 그래서 두 가지를 같이 못 박는다.
    test('읽기 실패를 null 로 돌려주는 기기에서도 남은 토큰을 지운다', () async {
      final store = withPreviousUser()
        ..failOnWrite = true
        ..failOnRead = true;

      // 실기기와 같은 모양이어야 이 테스트가 뜻을 가진다.
      expect(
        await store.read(),
        isNull,
        reason: 'SecureTokenStore.read 는 실패를 삼킨다 — 테스트 저장소도 같아야 회귀가 잡힌다',
      );
      await expectLater(() => store.readStrict(), throwsA(isA<TokenReadFailed>()));

      await loginStudent();

      expect(
        store.value,
        isNull,
        reason: '읽기 실패를 「남은 것 없음」으로 읽으면 A 의 토큰이 남은 채 B 로 로그인된다',
      );
      expect(AuthService().session?.token, 'token-abc');
      expect(AuthService().sessionNotPersisted, isTrue);
    });

    test('정말로 비어 있을 때와 못 읽을 때를 가른다', () async {
      // 비어 있다 → 지울 것이 없고, 남의 세션이 열릴 일도 없다.
      final empty = MemoryTokenStore()..failOnWrite = true;
      AuthService.store = empty;
      await loginStudent();
      expect(AuthService().session?.token, 'token-abc');

      // 다음 경우를 깨끗한 상태에서 보려면 세션을 비워 둬야 한다.
      await AuthService().logout();
      expect(AuthService().session, isNull);

      // 못 읽는다 + 지우지도 못한다 → 남의 토큰이 남을 수 있으므로 세션을 만들지 않는다.
      final unknown = withPreviousUser()
        ..failOnWrite = true
        ..failOnRead = true
        ..failOnClear = true;
      await expectLater(() => loginStudent(), throwsA(isA<SessionStoreUnsafe>()));
      expect(AuthService().session, isNull);
      expect(unknown.value?.token, 'token-of-A');
    });

    test('저장이 되면 깃발이 내려간다', () async {
      final store = withPreviousUser();

      await loginStudent();

      expect(store.value?.token, 'token-abc');
      expect(store.value?.role, UserRole.STUDENT);
      expect(AuthService().sessionNotPersisted, isFalse);
    });

    test('보관소가 고장난 기기에서 로그인을 반복해도 잠기지 않는다', () async {
      withPreviousUser()
        ..failOnWrite = true
        ..failOnClear = true;

      for (var i = 0; i < AuthService.maxAttempts; i++) {
        await expectLater(() => loginStudent(), throwsA(isA<SessionStoreUnsafe>()));
      }

      expect(
        AuthService().lockRemaining,
        isNull,
        reason: '비밀번호는 맞았다 — 보관소 고장을 연속 실패로 세면 복구할 방법이 없다',
      );
    });
  });

  group('지난 세션의 응답은 싱글턴에 남지 않는다', () {
    /// 데모 모드로 들어간 뒤, **응답을 붙잡아 둘 수 있는** 클라이언트로 갈아끼운다.
    Future<Completer<void>> enterDemoThenGate() async {
      StudentApiService.client =
          MockClient((_) async => throw http.ClientException('no server'));
      await StudentApiService().fetchEntries(); // 데모 모드로 들어간다

      final gate = Completer<void>();
      StudentApiService.client = MockClient((_) async {
        await gate.future;
        throw http.ClientException('no server');
      });
      return gate;
    }

    test('세션 번호는 로그인·로그아웃마다 올라간다', () async {
      final before = AuthService().sessionGeneration;
      await loginStudent();
      final afterLogin = AuthService().sessionGeneration;
      await AuthService().logout();

      expect(afterLogin, greaterThan(before));
      expect(AuthService().sessionGeneration, greaterThan(afterLogin),
          reason: '로그아웃하면 토큰이 null 이라 토큰 비교로는 세션을 구분할 수 없다');
    });

    test('로그아웃 뒤에 실패한 이의 제기는 목록에 들어가지 않는다', () async {
      await loginStudent();
      AuthService().onSessionCleared = () => StudentApiService().resetSessionState();
      final gate = await enterDemoThenGate();

      // A 가 이의를 보냈고, 응답이 돌아오기 전에 로그아웃했다.
      final inFlight = StudentApiService().raiseObjection(
        entryId: 1,
        content: 'A 가 쓴 이의 내용',
      );
      await AuthService().logout();
      gate.complete();

      await expectLater(inFlight, throwsA(isA<ObjectionFailed>()));
      expect(
        await StudentApiService().fetchObjections(),
        isEmpty,
        reason: '다음 사람의 조회가 실패하면 A 가 쓴 이의가 자기 것으로 보인다',
      );
    });

    test('로그아웃 뒤에 돌아온 목록 응답이 데모 깃발을 끄지 않는다', () async {
      await loginStudent();
      AuthService().onSessionCleared = () => StudentApiService().resetSessionState();

      await StudentApiService().fetchEntries(); // 실패 → 데모 모드
      final gate = Completer<void>();
      StudentApiService.client = MockClient((_) async {
        await gate.future;
        return http.Response('[]', 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      });

      final inFlight = StudentApiService().fetchEntries();
      await AuthService().logout();
      gate.complete();
      await inFlight;

      expect(
        StudentApiService().usingDemoData,
        isTrue,
        reason: 'resetSessionState 가 되돌려 놓은 깃발을 지난 세션의 응답이 다시 껐다',
      );
    });
  });

  group('토큰 삭제 실패 경고는 한 번만 전달된다', () {
    test('consume 는 읽고 내린다', () async {
      AuthService().tokenClearFailed = true;

      expect(AuthService().consumeTokenClearFailed(), isTrue);
      expect(
        AuthService().consumeTokenClearFailed(),
        isFalse,
        reason: 'main.dart 와 로그인 화면이 같은 깃발을 봐서, 안 내리면 경고가 두 번 뜬다',
      );
    });

    test('복원이 401 을 받고 토큰을 지우지 못하면 깃발이 선다', () async {
      AuthService.store = MemoryTokenStore('token-of-A', UserRole.STUDENT)..failOnClear = true;
      AuthService.client = MockClient((_) async => http.Response('{}', 401));

      expect(await AuthService().restore(), isNull);
      expect(
        AuthService().tokenClearFailed,
        isTrue,
        reason: '앱 시작 복원은 세션 만료 스낵바를 지나지 않는다 — 깃발이 유일한 전달 수단이다',
      );
    });
  });
}

/// 느린 키스토어 — `read` 가 늦게 대답한다.
///
/// 실제 `SecureLoginLockStore` 는 플랫폼 채널을 타고 최대 2초를 기다린다. 그
/// 창 안에서 로그인이 통과하는지가 「먼저 부른 읽기가…」 테스트의 질문이다.
class _SlowLockStore implements LoginLockStore {
  final Duration delay;
  int attempts;
  DateTime? lockedUntil;
  bool byServer;

  _SlowLockStore(this.delay, {required this.attempts, this.lockedUntil})
      : byServer = false;

  @override
  Future<({int attempts, DateTime? lockedUntil, bool byServer})?> read() async {
    await Future<void>.delayed(delay);
    return (attempts: attempts, lockedUntil: lockedUntil, byServer: byServer);
  }

  @override
  Future<void> write({
    required int attempts,
    DateTime? lockedUntil,
    bool byServer = false,
  }) async {
    this.attempts = attempts;
    this.lockedUntil = lockedUntil;
    this.byServer = byServer;
  }

  @override
  Future<void> clear() async {
    attempts = 0;
    lockedUntil = null;
    byServer = false;
  }
}
