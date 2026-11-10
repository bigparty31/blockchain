import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/format.dart';
import 'package:student_council_app/services/auth_service.dart';

/// 서버 쪽 로그인 차단 (`429`, 백엔드 #89)
///
/// 앱에도 5회 잠금이 있지만 **길이가 다르다** — 앱 60초, 서버 15분. 앱 잠금이
/// 먼저 풀린 뒤 다시 누르면 서버는 아직 잠금 중이라 또 거절한다. 그것을
/// 「서버에 닿지 못함」으로 보여주면 사용자는 네트워크 문제로 읽고 계속 누른다.
///
/// 눈으로는 잘 안 보이는 회귀다 — 두 잠금 길이가 같아지면 증상이 사라졌다가,
/// 서버 설정이 바뀌는 순간 돌아온다.
void main() {
  setUp(() async {
    AuthService.store = MemoryTokenStore();
    AuthService.lockStore = MemoryLoginLockStore();
    await AuthService().resetAttempts();
  });

  tearDown(() async {
    await AuthService().resetAttempts();
    AuthService.client = http.Client();
  });

  group('429 를 받았을 때', () {
    test('「연결 실패」가 아니라 LoginLocked 로 올린다', () async {
      AuthService.client = _locked(retryAfter: '600');

      expect(
        () => AuthService().login('20240001', 'wrong'),
        throwsA(isA<LoginLocked>()),
        reason: 'LoginUnavailable 이면 「연결에 실패했습니다」 토스트가 떠서 '
            '사용자가 네트워크 문제로 읽는다',
      );
    });

    test('Retry-After 를 남은 시간으로 쓴다', () async {
      AuthService.client = _locked(retryAfter: '600');

      final e = await _loginError();

      expect((e as LoginLocked).remaining, const Duration(seconds: 600));
    });

    /// 서버가 준 값으로 **앱 잠금까지 갈아끼운다.** 안 그러면 60초 뒤에
    /// 입력이 열리고, 눌러 보면 또 429 다.
    test('앱 잠금도 서버가 준 시간으로 맞춘다', () async {
      AuthService.client = _locked(retryAfter: '600');

      await _loginError();

      final left = AuthService().lockRemaining;
      expect(left, isNotNull);
      expect(left!.inSeconds, greaterThan(AuthService.lockDuration.inSeconds),
          reason: '앱 기본 잠금(60초)이 아니라 서버가 준 600초여야 한다');
    });

    test('기기에 남겨서 앱을 다시 켜도 풀리지 않는다', () async {
      final lockStore = MemoryLoginLockStore();
      AuthService.lockStore = lockStore;
      AuthService.client = _locked(retryAfter: '600');

      await _loginError();

      expect(lockStore.lockedUntil, isNotNull);
    });

    test('헤더가 없으면 서버 잠금 길이로 대신한다', () async {
      AuthService.client = _locked(retryAfter: null);

      final e = await _loginError();

      expect((e as LoginLocked).remaining, AuthService.serverLockFallback);
    });

    /// 「0초 남음」을 보여주면 바로 다시 눌러 또 거절당한다.
    test('0 이나 쓰레기 값도 폴백으로 간다', () async {
      for (final raw in ['0', '-5', 'Wed, 21 Oct 2026 07:28:00 GMT', 'abc']) {
        await AuthService().resetAttempts();
        AuthService.client = _locked(retryAfter: raw);

        final e = await _loginError();

        expect((e as LoginLocked).remaining, AuthService.serverLockFallback,
            reason: 'Retry-After: $raw');
      }
    });
  });

  /// **서버 잠금은 학번 단위다** (#89). 남이 내 학번으로 다섯 번 틀리면 나는
  /// 맞는 비밀번호를 넣고도 막힌다. 그때 「비밀번호를 5회 연속 틀렸습니다」라고
  /// 말하면 사실이 아니고, 그 사람은 자기 계정이 털린 줄 알고 비밀번호를 찾는다.
  /// 그래서 **앱이 센 5회와 서버가 건 잠금을 구분해 들고 다녀야 한다.**
  group('앱 잠금과 서버 잠금을 구분한다', () {
    test('429 로 잠긴 것은 byServer 다', () async {
      AuthService.client = _locked(retryAfter: '600');

      final e = await _loginError();

      expect((e as LoginLocked).byServer, isTrue);
      expect(AuthService().lockByServer, isTrue);
    });

    test('앱이 센 5회로 잠긴 것은 byServer 가 아니다', () async {
      AuthService.client = MockClient((_) async => http.Response('{}', 401));

      for (var i = 0; i < AuthService.maxAttempts; i++) {
        await _loginError();
      }

      expect(AuthService().lockByServer, isFalse);
      final e = await _loginError(); // 잠긴 상태에서 한 번 더
      expect((e as LoginLocked).byServer, isFalse,
          reason: '내가 틀려서 잠긴 것이 맞으므로 「5회 틀렸다」가 사실이다');
    });

    /// 깃발이 메모리에만 있으면 앱을 다시 켠 뒤 문구가 앱 잠금으로 바뀐다.
    test('앱을 다시 켜도 서버 잠금이라는 사실이 남는다', () async {
      final lockStore = MemoryLoginLockStore();
      AuthService.lockStore = lockStore;
      AuthService.client = _locked(retryAfter: '600');
      await _loginError();

      expect(lockStore.byServer, isTrue, reason: '기기에 남기지 않으면 재시작으로 사라진다');

      // 앱을 다시 켠 것과 같다 — 메모리를 비우고 보관소에서 읽어 온다.
      await AuthService().resetAttempts();
      AuthService.lockStore = lockStore
        ..attempts = AuthService.maxAttempts
        ..lockedUntil = DateTime.now().add(const Duration(minutes: 10))
        ..byServer = true;

      await AuthService().loadLock();

      expect(AuthService().lockByServer, isTrue);
    });

    /// 옛 형식(`attempts|millis`)으로 저장된 잠금도 읽어야 한다 — 못 읽으면
    /// **이미 잠겨 있던 기기의 잠금이 업데이트 한 번으로 풀린다.**
    test('세 번째 칸이 없는 옛 기록도 읽는다', () async {
      final until = DateTime.now().add(const Duration(minutes: 5));
      final stored = await _readFromSecureStore(
        '${AuthService.maxAttempts}|${until.millisecondsSinceEpoch}',
      );

      expect(stored, isNotNull, reason: '옛 기록을 못 읽으면 잠금이 그냥 사라진다');
      expect(stored!.attempts, AuthService.maxAttempts);
      expect(stored.byServer, isFalse, reason: '없으면 「서버 잠금 아님」으로 본다');
    });

    test('세 번째 칸이 S 면 서버 잠금으로 읽는다', () async {
      final until = DateTime.now().add(const Duration(minutes: 5));
      final stored = await _readFromSecureStore(
        '${AuthService.maxAttempts}|${until.millisecondsSinceEpoch}|S',
      );

      expect(stored?.byServer, isTrue);
    });
  });

  group('남은 시간 문구', () {
    /// `${d.inSeconds}초` 로 적으면 15분 잠금이 **「900초 후에 다시 시도해
    /// 주세요」**가 된다 — 읽는 사람이 암산을 해야 한다.
    test('분 단위는 분으로 적는다', () {
      expect(Fmt.duration(const Duration(seconds: 45)), '45초');
      expect(Fmt.duration(const Duration(seconds: 90)), '1분 30초');
      expect(Fmt.duration(const Duration(minutes: 15)), '15분');
      expect(Fmt.duration(const Duration(seconds: 900)), '15분');
    });

    test('음수는 0초다', () {
      expect(Fmt.duration(const Duration(seconds: -3)), '0초');
    });
  });
}

/// `429` 만 돌려주는 서버. [retryAfter] 가 null 이면 헤더를 빼먹은 서버다.
MockClient _locked({required String? retryAfter}) => MockClient((req) async {
      return http.Response(
        '{"detail":"too many requests"}',
        429,
        headers: {
          'content-type': 'application/json',
          if (retryAfter != null) 'retry-after': retryAfter,
        },
      );
    });

/// 기기 키스토어에 [raw] 가 들어 있는 상태에서 [SecureLoginLockStore] 가 읽는 값.
///
/// 보관소 형식의 **하위 호환**을 보는 유일한 자리다. `MemoryLoginLockStore` 는
/// 문자열을 거치지 않아서 형식이 바뀌어도 모른다.
Future<({int attempts, DateTime? lockedUntil, bool byServer})?>
    _readFromSecureStore(String raw) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'read':
        return raw;
      case 'readAll':
        return <String, String>{};
      case 'containsKey':
        return true;
      default:
        return null;
    }
  });
  // 앞선 시험에서 「채널 없음」으로 판정됐을 수 있다.
  SecureLoginLockStore.resetAvailability();
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    SecureLoginLockStore.resetAvailability();
  });

  return const SecureLoginLockStore().read();
}

Future<Object> _loginError() async {
  try {
    await AuthService().login('20240001', 'wrong');
  } catch (e) {
    return e;
  }
  throw TestFailure('던지지 않았다 — 429 를 성공으로 처리하고 있다');
}
