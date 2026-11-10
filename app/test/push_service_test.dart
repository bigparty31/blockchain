import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/term_info.dart';
import 'package:student_council_app/services/push_service.dart';

/// FCM 토픽 구독 (PRD v0.15 §4.8)
///
/// 여기서 못박는 것은 **구독·해제가 제때 불리는가**다. 실제로 푸시가 뜨는지는
/// 기기에서만 알 수 있지만, 아래 세 가지는 눈으로 안 보이면서 틀리기 쉽다:
/// 학기가 바뀌었는데 옛 토픽이 남는 것, 로그아웃해도 구독이 남는 것, 설정이
/// 없는 기기에서 앱이 아예 안 뜨는 것.
void main() {
  late _FakeBackend fake;

  setUp(() {
    fake = _FakeBackend();
    PushService.backend = fake;
    PushService().resetForTest();
  });

  tearDown(() {
    PushService.backend = FirebasePushBackend();
    PushService().resetForTest();
  });

  group('초기화', () {
    test('성공하면 토큰을 들고 available 이 된다', () async {
      await PushService().init();

      expect(PushService().available, isTrue);
      expect(PushService().token, 'fake-token');
    });

    /// **던지면 안 된다.** `main()` 이 await 없이 부르므로, 던지면 처리되지
    /// 않은 비동기 예외가 되어 앱 시작 로그가 빨갛게 물든다. Firebase 설정이
    /// 없는 팀원(`google-services.json` 미배치)에게 매번 그렇게 된다.
    test('실패해도 던지지 않고 available 이 false 로 남는다', () async {
      fake.failInit = true;

      await PushService().init();

      expect(PushService().available, isFalse);
    });

    /// 알림 권한을 거부해도 앱은 돈다. Android 13+ 에서 흔한 경로다.
    test('권한을 거부하면 available 만 false 다', () async {
      fake.permission = false;

      await PushService().init();

      expect(PushService().available, isFalse);
      expect(PushService().token, 'fake-token', reason: '토큰 발급과는 별개다');
    });

    /// 앱이 **완전히 꺼져 있다가** 푸시를 눌러 열린 경로. 스트림으로는 오지
    /// 않아서 따로 물어봐야 하고, 빠지면 종료 상태에서 누른 알림만 아무 일도
    /// 일어나지 않는다.
    test('종료 상태에서 푸시로 열렸으면 onOpened 가 불린다', () async {
      fake.initialMessage = const PushMessage(title: '확정', body: '35,000원');
      var opened = 0;
      PushService().onOpened = () => opened++;

      await PushService().init();
      await Future<void>.delayed(Duration.zero); // scheduleMicrotask

      expect(opened, 1);
    });

    /// 권한을 거부한 사람에게 앱을 띄울 때마다 대화상자가 다시 뜨면 안 된다.
    /// [PushService.available] 로 중복을 막으면 거부한 경우 false 라서
    /// 매번 다시 돈다 — 그래서 별도 깃발을 둔다.
    test('거부해도 init 을 다시 부르면 권한을 또 묻지 않는다', () async {
      fake.permission = false;

      await PushService().init();
      await PushService().init();

      expect(fake.permissionAsked, 1);
    });

    test('그냥 열었으면 onOpened 는 안 불린다', () async {
      var opened = 0;
      PushService().onOpened = () => opened++;

      await PushService().init();
      await Future<void>.delayed(Duration.zero);

      expect(opened, 0);
    });
  });

  group('학생 토픽', () {
    test('학기 코드로 students_{코드} 를 구독한다', () async {
      await PushService().init();
      await PushService().subscribeStudentTopic(TermInfo.currentTermCode);

      expect(fake.subscribed, ['students_${TermInfo.currentTermCode}']);
      expect(PushService().subscribedTopic,
          'students_${TermInfo.currentTermCode}');
    });

    /// 안 끊으면 졸업하거나 학기가 지난 뒤에도 **남의 학기 지출 알림**을
    /// 계속 받는다. 토픽은 기기 단위라 저절로 끊기지 않는다.
    test('학기가 바뀌면 이전 토픽을 끊고 새로 붙는다', () async {
      await PushService().init();
      await PushService().subscribeStudentTopic(20262);
      await PushService().subscribeStudentTopic(20271);

      expect(fake.unsubscribed, ['students_20262']);
      expect(fake.subscribed, ['students_20262', 'students_20271']);
    });

    test('같은 학기를 다시 부르면 아무것도 하지 않는다', () async {
      await PushService().init();
      await PushService().subscribeStudentTopic(20262);
      await PushService().subscribeStudentTopic(20262);

      expect(fake.subscribed, ['students_20262'], reason: '중복 구독 요청을 보내지 않는다');
      expect(fake.unsubscribed, isEmpty);
    });

    /// 공용 기기에서 다음 사람이 이전 사용자의 학기 알림을 받으면 안 된다.
    test('로그아웃하면 구독을 끊는다', () async {
      await PushService().init();
      await PushService().subscribeStudentTopic(20262);

      await PushService().unsubscribe();

      expect(fake.unsubscribed, ['students_20262']);
      expect(PushService().subscribedTopic, isNull);
    });

    /// **앱을 다시 켠 뒤 세션이 끊기는 경로.** 구독은 기기에 남아 있지만
    /// `_topic` 은 메모리에만 있어서 null 이다. 학기 코드를 넘기지 않으면
    /// 그냥 돌아가고 **기기는 계속 구독된 채로 남는다** — 공용 기기에서 다음
    /// 사람이 이전 사용자의 학기 알림을 계속 받는다.
    test('이번 실행에서 구독한 적이 없어도 학기 코드를 주면 끊는다', () async {
      await PushService().init();
      expect(PushService().subscribedTopic, isNull, reason: '이번 실행에서는 구독하지 않았다');

      await PushService().unsubscribe(termCode: 20262);

      expect(fake.unsubscribed, ['students_20262']);
    });

    /// 4차 리뷰 Low — 구독이 날아가는 중에 로그아웃하면, 해제가 비운 상태를
    /// **뒤늦게 끝난 구독이 되살린다.** 기기는 끊겼는데 메모리만 구독 중이라고
    /// 믿게 되고, 다음 학생이 로그인하면 「같은 토픽」이라며 재구독을 건너뛰어
    /// 푸시가 한 건도 오지 않는다. 화면에는 아무 증상이 없다.
    test('구독 중에 로그아웃해도 구독 상태가 남지 않는다', () async {
      await PushService().init();
      fake.subscribeGate = Completer<void>();

      final subscribing = PushService().subscribeStudentTopic(20262);
      await fake.subscribeStarted.future; // **구독이 실제로 시작될 때까지** 기다린다

      final unsubscribing = PushService().unsubscribe(termCode: 20262);

      fake.subscribeGate!.complete(); // 붙잡아 둔 구독을 끝낸다
      await subscribing;
      await unsubscribing;

      expect(fake.subscribed, ['students_20262'], reason: '구독이 시작도 안 했으면 겹침을 시험한 것이 아니다');

      expect(
        PushService().subscribedTopic,
        isNull,
        reason: '로그아웃이 마지막 의도인데 구독이 상태를 되살렸다 — 다음 로그인에서 재구독을 건너뛴다',
      );
      expect(fake.unsubscribed, contains('students_20262'));
    });

    /// 위 상태가 남으면 실제로 다음 로그인이 조용히 깨진다. 거기까지 못 박는다.
    test('그 뒤 같은 학기로 다시 로그인하면 재구독된다', () async {
      await PushService().init();
      fake.subscribeGate = Completer<void>();
      final subscribing = PushService().subscribeStudentTopic(20262);
      await fake.subscribeStarted.future;
      final unsubscribing = PushService().unsubscribe(termCode: 20262);
      fake.subscribeGate!.complete();
      await subscribing;
      await unsubscribing;

      fake.subscribed.clear();
      await PushService().subscribeStudentTopic(20262); // 다음 사람 로그인

      expect(fake.subscribed, ['students_20262'], reason: '재구독을 건너뛰면 푸시가 오지 않는다');
      expect(PushService().subscribedTopic, 'students_20262');
    });

    test('학기 코드가 없고 구독 기록도 없으면 아무것도 하지 않는다', () async {
      await PushService().init();

      await PushService().unsubscribe();

      expect(fake.unsubscribed, isEmpty, reason: '끊을 대상을 모르는데 임의로 부르지 않는다');
    });

    /// 끊기 요청이 실패해도 앱 상태는 「안 구독됨」이어야 한다. 안 그러면
    /// 다음 로그인에서 같은 토픽이라며 재구독을 건너뛴다.
    test('끊기가 실패해도 상태는 비운다', () async {
      await PushService().init();
      await PushService().subscribeStudentTopic(20262);
      fake.failTopic = true;

      await PushService().unsubscribe();

      expect(PushService().subscribedTopic, isNull);
    });

    /// `main()` 은 [PushService.init] 을 **await 하지 않는다** (권한 대화상자가
    /// 첫 화면을 붙잡지 않게 하려고). 그래서 세션 복원·로그인이 초기화보다
    /// 먼저 끝날 수 있는데, 그때 초기화를 기다리지 않고 FCM 을 부르면 거부당하고
    /// 그 예외는 삼켜진다. **다시 부를 사람이 없다** — 로그인은 이미 끝났으므로
    /// 그 기기는 그 세션 내내 구독이 안 된 채 푸시를 한 건도 받지 못한다.
    test('초기화가 끝나기 전에 불려도 구독된다', () async {
      fake.initGate = Completer<void>();
      final initializing = PushService().init(); // main() 과 같이 await 하지 않는다

      final subscribing = PushService().subscribeStudentTopic(20262);
      fake.initGate!.complete();
      await subscribing;

      expect(
        PushService().subscribedTopic,
        'students_20262',
        reason: '초기화를 기다리지 않으면 FCM 이 거부하고, 재시도하는 곳이 없다',
      );
      expect(fake.subscribed, ['students_20262']);
      await initializing;
    });

    /// 구독에 필요한 것은 **초기화뿐**이고 권한은 필요하지 않다. 둘을 묶어
    /// 기다리면 권한 대화상자를 밀어둔 사용자는 답할 때까지 구독이 안 된다.
    test('권한 대화상자에 답하지 않았어도 구독은 된다', () async {
      fake.permissionGate = Completer<bool>();
      final initializing = PushService().init();

      await PushService().subscribeStudentTopic(20262);

      expect(fake.subscribed, ['students_20262']);
      expect(PushService().available, isFalse, reason: '권한은 아직 답 전이다');

      fake.permissionGate!.complete(true);
      await initializing;
      expect(PushService().available, isTrue);
    });

    test('구독 실패는 던지지 않는다', () async {
      await PushService().init();
      fake.failTopic = true;

      await PushService().subscribeStudentTopic(20262);

      expect(PushService().subscribedTopic, isNull);
    });
  });

  group('수신', () {
    test('앱이 떠 있을 때 온 메시지를 전달한다', () async {
      PushMessage? got;
      PushService().onForegroundMessage = (m) => got = m;
      await PushService().init();

      fake.emitMessage(const PushMessage(title: '확정', body: '35,000원 한결문구'));

      expect(got?.body, '35,000원 한결문구');
    });

    test('알림을 누르면 onOpened 가 불린다', () async {
      var opened = 0;
      PushService().onOpened = () => opened++;
      await PushService().init();

      fake.emitOpened(const PushMessage(title: '확정'));

      expect(opened, 1);
    });
  });
}

class _FakeBackend implements PushBackend {
  bool failInit = false;
  bool failTopic = false;
  bool permission = true;
  PushMessage? initialMessage;

  /// 완료될 때까지 [initializeApp] 이 끝나지 않는다 — 초기화 중을 흉내 낸다.
  Completer<void>? initGate;

  /// 완료될 때까지 [requestPermission] 이 끝나지 않는다 — 사용자가 권한
  /// 대화상자에 답하지 않은 상태를 흉내 낸다.
  Completer<bool>? permissionGate;

  /// 완료될 때까지 [subscribeToTopic] 이 끝나지 않는다 — 구독이 날아가는
  /// 중에 로그아웃이 끼어드는 상황을 만든다.
  Completer<void>? subscribeGate;

  /// **구독에 실제로 진입했음**을 알린다 (게이트에 걸리기 직전).
  ///
  /// 이것을 기다리지 않고 바로 로그아웃하면, 큐의 `.then` 이 아직 돌지 않아
  /// 구독이 시작조차 하지 않는다 — 겹치는 상황이 아니라 「구독을 건너뛴」
  /// 상황을 시험하게 된다 (6차 리뷰 Low 지적).
  final subscribeStarted = Completer<void>();

  /// **초기화 전에는 FCM 호출이 거부된다** — 실제 동작이 그렇다
  /// (`No Firebase App '[DEFAULT]' has been created`). 이것을 흉내 내지 않으면
  /// 「초기화를 기다리지 않는」 회귀가 테스트를 통과한다.
  bool _initialized = false;

  final subscribed = <String>[];
  final unsubscribed = <String>[];

  void Function(PushMessage)? _onMessage;
  void Function(PushMessage)? _onOpened;

  void emitMessage(PushMessage m) => _onMessage?.call(m);
  void emitOpened(PushMessage m) => _onOpened?.call(m);

  @override
  Future<void> initializeApp() async {
    if (initGate != null) await initGate!.future;
    if (failInit) throw Exception('google-services.json 없음');
    _initialized = true;
  }

  int permissionAsked = 0;

  @override
  Future<bool> requestPermission() async {
    permissionAsked++;
    if (permissionGate != null) return permissionGate!.future;
    return permission;
  }

  @override
  Future<String?> getToken() async => 'fake-token';

  @override
  Future<void> subscribeToTopic(String topic) async {
    if (!_initialized) throw Exception("No Firebase App '[DEFAULT]'");
    if (!subscribeStarted.isCompleted) subscribeStarted.complete();
    if (subscribeGate != null) await subscribeGate!.future;
    if (failTopic) throw Exception('네트워크 실패');
    subscribed.add(topic);
  }

  @override
  Future<void> unsubscribeFromTopic(String topic) async {
    if (!_initialized) throw Exception("No Firebase App '[DEFAULT]'");
    if (failTopic) throw Exception('네트워크 실패');
    unsubscribed.add(topic);
  }

  @override
  Future<PushMessage?> getInitialMessage() async => initialMessage;

  @override
  void onMessage(void Function(PushMessage) handler) => _onMessage = handler;

  @override
  void onMessageOpenedApp(void Function(PushMessage) handler) =>
      _onOpened = handler;
}
