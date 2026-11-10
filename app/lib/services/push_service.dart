import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// FCM 푸시 수신 (PRD v0.15 §4.8)
///
/// **학생은 토픽만 쓴다.** `students_{학기코드}` 를 구독하고, 서버는 메시지 하나만
/// 보낸다. 학생 푸시 토큰을 서버에 등록하지 않는다 — 토픽 구독은 기기와 Firebase
/// 사이에서 끝나므로 서버는 누가 받는지 알 필요가 없다. 확정 1건에 학생 1,000명
/// 분의 알림 행을 쌓지 않으려고 이렇게 정했다.
///
/// **임원은 기기 토큰**을 학생회 서버에 등록한다 (`DeviceToken`). 받는 사람이
/// 4명이고 사람마다 처리할 건이 달라서 알림함이 필요하기 때문이다. 그쪽 등록
/// 경로는 임원 앱(이승호) 몫이라 여기서는 [token] 만 노출한다.
///
/// **학생 알림함(S14)은 없다.** 푸시를 누르면 대시보드로 가고, 거기 미확인
/// 뱃지와 차액 배너가 이미 있다 (§4.8).
///
/// ### 실패해도 앱은 돈다
///
/// 모든 공개 메서드가 실패를 삼키고 [available] 로만 알린다. Firebase 설정이
/// 없거나(`google-services.json` 미배치), Play 서비스가 없는 기기이거나,
/// 사용자가 알림 권한을 거부할 수 있다. 그중 어느 것도 **장부를 못 보게 만들
/// 이유가 아니다.** 푸시는 부가 기능이고, 못 받아도 앱을 열면 미확인 뱃지로
/// 같은 사실을 알 수 있다.
class PushService {
  PushService._internal();
  static final PushService _instance = PushService._internal();
  factory PushService() => _instance;

  /// 테스트에서 갈아끼운다. 기본값은 실제 FCM.
  @visibleForTesting
  static PushBackend backend = FirebasePushBackend();

  bool _ready = false;
  String? _token;
  String? _topic;

  /// [init] 이 이미 돌았는지. **[available] 과 따로 둔다** — 권한을 거부하면
  /// [available] 이 false 인데, 그것으로 중복을 막으면 앱을 띄울 때마다 거부한
  /// 사람에게 권한 대화상자가 다시 뜬다.
  Future<void>? _initializing;

  /// Firebase 앱 초기화만 가리킨다. **[_initializing] 과 따로 둔다.**
  ///
  /// [init] 은 권한 대화상자에서 사용자가 답할 때까지 끝나지 않는데, 토픽 구독에
  /// 필요한 것은 **초기화뿐**이고 권한은 필요하지 않다. 하나로 묶으면 대화상자를
  /// 밀어둔 사용자는 구독이 그때까지 걸린다.
  Future<void>? _appReady;

  /// 푸시를 실제로 받을 수 있는 상태인지. [init] 이 끝나야 의미가 있다.
  bool get available => _ready;

  /// 이 기기의 FCM 토큰. **임원 기기 등록에만 쓴다** — 학생은 토픽이라 불필요하다.
  String? get token => _token;

  /// 지금 구독 중인 토픽. 구독한 적이 없으면 null.
  String? get subscribedTopic => _topic;

  /// 푸시를 누르고 들어왔을 때 호출된다. 앱이 꺼져 있다 열린 경우도 포함한다.
  ///
  /// 대상 화면은 **언제나 대시보드**다 (§4.8). 학생 알림함이 없어서 보낼 곳이
  /// 거기뿐이고, 항목 하나로 바로 보내면 그 건만 읽음 처리돼 **나머지 새 항목을
  /// 영영 못 보게 된다** — 미확인 뱃지는 목록을 열 때 통째로 지워진다.
  void Function()? onOpened;

  /// 앱이 **떠 있는 동안** 메시지가 왔을 때. 포그라운드에서는 OS 가 알림을
  /// 띄우지 않으므로, 화면이 직접 알려야 한다면 여기서 받는다.
  void Function(PushMessage)? onForegroundMessage;

  /// 앱 시작 때 한 번 부른다.
  ///
  /// 실패하면 [available] 이 false 로 남고 조용히 끝난다 — 던지지 않는다.
  /// 여기서 던지면 Firebase 설정이 없는 팀원의 앱이 아예 안 뜬다.
  Future<void> init() => _initializing ??= _init();

  /// Firebase 앱 초기화를 **한 번만** 한다. 구독 경로도 이것을 기다린다.
  ///
  /// 실패는 기억하지 않는다 — 다음 시도에서 다시 해 본다. 설정이 없으면 계속
  /// 실패할 뿐이지만, Play 서비스 갱신 중처럼 **일시적인 실패**도 있어서
  /// 한 번 실패한 것으로 그 세션 내내 푸시를 포기할 이유는 없다.
  Future<void> _ensureApp() async {
    final pending = _appReady;
    if (pending != null) return pending;

    final started = backend.initializeApp();
    _appReady = started;
    try {
      await started;
    } catch (_) {
      if (_appReady == started) _appReady = null;
      rethrow;
    }
  }

  Future<void> _init() async {
    try {
      await _ensureApp();

      // Android 13+ 는 런타임 권한이다. 거부해도 계속 간다 — 푸시만 못 받을 뿐이다.
      final granted = await backend.requestPermission();

      _token = await backend.getToken();

      // **디버그 빌드에서만 찍는다.** 콘솔 테스트 전송에 이 값이 필요한데,
      // 릴리스에 남기면 기기 토큰이 로그로 새어 나간다 — 그 토큰을 쥐면
      // 그 기기로 임의의 알림을 보낼 수 있다.
      if (kDebugMode) debugPrint('[FCM] token=$_token');

      backend.onMessage(_handleForeground);
      backend.onMessageOpenedApp(_handleOpened);

      // 앱이 **완전히 꺼져 있다가** 푸시를 눌러 열린 경우. 위 스트림으로는
      // 오지 않아서 따로 물어봐야 한다. 이것이 빠지면 종료 상태에서 누른
      // 알림만 아무 일도 일어나지 않는다.
      if (await backend.getInitialMessage() != null) {
        // 첫 화면이 그려지기 전이라 바로 부르면 Navigator 가 없다.
        scheduleMicrotask(() => onOpened?.call());
      }

      _ready = granted;
    } catch (e) {
      // 설정 없음·Play 서비스 없음·네트워크 실패. 전부 「푸시 없이 돈다」로 끝난다.
      debugPrint('푸시를 켜지 못했습니다 (앱은 그대로 동작합니다): $e');
      _ready = false;
    }
  }

  /// 학생 토픽을 구독한다. **로그인할 때 부른다** (§4.8).
  ///
  /// 학기가 바뀌면 이전 토픽을 끊고 새로 붙는다 — 안 끊으면 졸업하거나 학기가
  /// 지난 뒤에도 남의 학기 지출 알림을 계속 받는다.
  ///
  /// **초기화를 기다린다** ([_ensureApp]). `main()` 은 [init] 을 await 하지 않아서
  /// 세션 복원이나 로그인이 그보다 먼저 끝날 수 있는데, 초기화 전에 FCM 을 부르면
  /// 거부당한다. 그 예외를 삼키고 끝내면 `_topic` 이 null 로 남고 **다시 부를
  /// 사람이 없다** — 로그인은 이미 끝났으므로 그 기기는 그 세션 내내 구독이 안 된
  /// 상태로 있고, 푸시가 한 건도 오지 않는다.
  Future<void> subscribeStudentTopic(int termCode) async {
    final next = topicFor(termCode);
    if (_topic == next) return;
    try {
      await _ensureApp();
      if (_topic != null) await backend.unsubscribeFromTopic(_topic!);
      await backend.subscribeToTopic(next);
      _topic = next;
    } catch (e) {
      debugPrint('토픽 구독 실패 ($next): $e');
    }
  }

  /// **로그아웃할 때 부른다.** 끊지 않으면 공용 기기에서 다음 사람이 이전
  /// 사용자의 학기 알림을 계속 받는다. 토픽은 기기 단위라 로그아웃만으로는
  /// 끊기지 않는다.
  ///
  /// [termCode] 를 주면 **이번 실행에서 구독한 적이 없어도** 그 학기 토픽을
  /// 끊는다. 구독은 기기에 남지만 `_topic` 은 메모리에만 있어서, 앱이 꺼졌다
  /// 켜진 뒤 세션이 끊기는 경로(저장된 토큰이 거부돼 `restore` 가 세션을 비우는
  /// 경우)에서는 `_topic` 이 null 이다. 그대로 돌아가면 **기기는 계속 구독된
  /// 채로 남는다** — 이 메서드가 막겠다고 한 상황 그대로다.
  Future<void> unsubscribe({int? termCode}) async {
    final current = _topic ?? (termCode == null ? null : topicFor(termCode));
    if (current == null) return;
    _topic = null;
    try {
      await _ensureApp();
      await backend.unsubscribeFromTopic(current);
    } catch (e) {
      debugPrint('토픽 해제 실패 ($current): $e');
    }
  }

  static String topicFor(int termCode) => 'students_$termCode';

  void _handleForeground(PushMessage m) => onForegroundMessage?.call(m);
  void _handleOpened(PushMessage m) => onOpened?.call();

  @visibleForTesting
  void resetForTest() {
    _initializing = null;
    _appReady = null;
    _ready = false;
    _token = null;
    _topic = null;
    onOpened = null;
    onForegroundMessage = null;
  }
}

/// 푸시 한 건. FCM 타입을 화면·테스트에 노출하지 않으려고 한 겹 덮었다.
class PushMessage {
  final String? title;
  final String? body;
  final Map<String, String> data;

  const PushMessage({this.title, this.body, this.data = const {}});
}

/// [PushService] 가 쓰는 바깥 세계. 테스트가 갈아끼운다.
abstract class PushBackend {
  Future<void> initializeApp();

  /// 알림 권한. 이미 있으면 true.
  Future<bool> requestPermission();

  Future<String?> getToken();
  Future<void> subscribeToTopic(String topic);
  Future<void> unsubscribeFromTopic(String topic);

  /// 앱이 꺼져 있다 푸시로 열렸으면 그 메시지. 아니면 null.
  Future<PushMessage?> getInitialMessage();

  void onMessage(void Function(PushMessage) handler);
  void onMessageOpenedApp(void Function(PushMessage) handler);
}

/// 실제 FCM.
class FirebasePushBackend implements PushBackend {
  @override
  Future<void> initializeApp() => Firebase.initializeApp();

  @override
  Future<bool> requestPermission() async {
    final settings = await FirebaseMessaging.instance.requestPermission();
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  @override
  Future<String?> getToken() => FirebaseMessaging.instance.getToken();

  @override
  Future<void> subscribeToTopic(String topic) =>
      FirebaseMessaging.instance.subscribeToTopic(topic);

  @override
  Future<void> unsubscribeFromTopic(String topic) =>
      FirebaseMessaging.instance.unsubscribeFromTopic(topic);

  @override
  Future<PushMessage?> getInitialMessage() async =>
      _convert(await FirebaseMessaging.instance.getInitialMessage());

  @override
  void onMessage(void Function(PushMessage) handler) {
    FirebaseMessaging.onMessage.listen((m) {
      final converted = _convert(m);
      if (converted != null) handler(converted);
    });
  }

  @override
  void onMessageOpenedApp(void Function(PushMessage) handler) {
    FirebaseMessaging.onMessageOpenedApp.listen((m) {
      final converted = _convert(m);
      if (converted != null) handler(converted);
    });
  }

  static PushMessage? _convert(RemoteMessage? m) {
    if (m == null) return null;
    return PushMessage(
      title: m.notification?.title,
      body: m.notification?.body,
      data: m.data.map((k, v) => MapEntry(k, '$v')),
    );
  }
}
