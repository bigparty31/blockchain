import 'auth_service.dart';

/// 임원 기기 토큰의 등록(로그인)과 해제(로그아웃)를 **한 줄로 세운다.**
///
/// 둘을 기다리지 않고 따로 보내면, 로그아웃의 DELETE 가 먼저 서버에 닿은 뒤 뒤늦은 POST 가
/// 토큰을 다시 살려(`revoked_at = null`) 로그아웃한 기기로 이전 임원의 알림이 간다 (#122 codex-loop 1차).
/// 그래서 ① 요청을 순서대로 하나씩 보내고 ② 등록은 토큰을 받은 뒤 **세션이 그대로일 때만** 보낸다.
///
/// 푸시는 부가 기능이라 어떤 실패도 던지지 않는다 — 로그인·로그아웃을 막지 않는다.
class DeviceTokenSync {
  DeviceTokenSync({
    required this.sessionToken,
    required this.fcmToken,
    required this.cachedToken,
    required this.register,
    required this.revoke,
    this.retryDelay = const Duration(seconds: 10),
  });

  /// 지금 세션의 토큰 (없으면 null)
  final String? Function() sessionToken;

  /// FCM 토큰을 받는다 (권한 대화상자가 닫혀야 나온다). 못 받으면 null
  final Future<String?> Function() fcmToken;

  /// 이미 받아 둔 FCM 토큰. 해제 때 쓴다
  final String? Function() cachedToken;

  final Future<bool> Function(String fcmToken) register;
  final Future<bool> Function(String fcmToken, Session ending) revoke;

  /// 등록이 결과를 못 낸 채 끝났을 때(시간 초과), 해제를 한 번 더 보내기까지 기다리는 시간.
  /// 시간 초과는 요청을 취소하지 않아서, 서버가 해제 뒤에 그 등록을 처리해 토큰을 되살릴 수 있다 (#122 codex-loop 2차).
  final Duration retryDelay;

  /// 마지막 등록이 서버의 답을 받지 못했다 — 요청이 아직 날아가는 중일 수 있다
  bool _registerInconclusive = false;

  Future<void> _tail = Future<void>.value();

  /// 줄에 선 일이 모두 끝날 때까지 (시험용)
  Future<void> get idle => _tail;

  /// 로그인·복원. [startedWith] 는 그때 세션의 토큰이다
  void onStarted(String startedWith) {
    _enqueue(() async {
      final token = await fcmToken();
      if (token == null) return;
      // 토큰을 기다리는 사이 로그아웃했거나 다른 사람이 로그인했다면 이 등록은 버린다
      if (sessionToken() != startedWith) return;
      _registerInconclusive = !await register(token);
    });
  }

  /// 로그아웃 직전. 앞선 등록이 끝난 뒤에 해제한다
  void onEnding(Session ending) {
    _enqueue(() async {
      final token = cachedToken();
      if (token == null) return;
      await revoke(token, ending);
      if (_registerInconclusive) {
        // 늦게 닿은 등록이 방금 해제를 덮었을 수 있다 — 잠시 뒤 한 번 더 해제한다
        _registerInconclusive = false;
        await Future<void>.delayed(retryDelay);
        await revoke(token, ending);
      }
    });
  }

  void _enqueue(Future<void> Function() job) {
    _tail = _tail.then((_) => job()).catchError((Object _) {});
  }
}
