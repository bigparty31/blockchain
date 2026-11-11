import 'package:flutter/material.dart';

import 'core/app_theme.dart';
import 'core/enums.dart';
import 'core/role_home.dart';
import 'core/term_info.dart';
import 'router.dart';
import 'screens/login_screen.dart';
import 'services/auth_service.dart';
import 'services/push_service.dart';
import 'services/student_api_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // **await 하지 않는다.** [PushService.init] 은 Android 13+ 에서 알림 권한
  // 대화상자를 띄우고 사용자가 답할 때까지 완료되지 않는다. 기다리면 그동안
  // `runApp` 이 불리지 않아 **대화상자 뒤가 빈 회색 화면**이고, 답하지 않고
  // 밀어내면 앱이 그대로 멈춘 것처럼 보인다.
  //
  // 푸시는 부가 기능이라 첫 화면을 붙잡을 이유가 없다. 결과는 [PushService]
  // 안에 남고, 구독은 로그인 시점에 [AuthService.onSessionStarted] 가 건다 —
  // 그때는 이미 init 이 끝나 있다.
  PushService().init();

  runApp(const StudentCouncilApp());
}

/// **팀 공용 파일.** 화면 코드를 두지 않는다 — 로그인 화면은
/// `screens/login_screen.dart` 에 있다 (`router.dart` 의 같은 판단).
class StudentCouncilApp extends StatefulWidget {
  const StudentCouncilApp({super.key});

  @override
  State<StudentCouncilApp> createState() => _StudentCouncilAppState();
}

class _StudentCouncilAppState extends State<StudentCouncilApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    // 어느 화면에서든 토큰이 거부되면(401) 로그인으로 되돌린다.
    // 이것이 없으면 만료된 세션으로 화면이 빈 채 떠 있고, 학생은 왜 안 보이는지 모른다.
    AuthService().onUnauthorized = _forceLogin;

    // 세션이 비워질 때 **서비스 싱글턴에 남은 세션 상태**도 비운다.
    // 토큰만 지우면 이의 목록·데모 깃발·마지막 확인 항목 id 가 살아 있어서
    // 같은 기기의 다음 사람에게 이전 사용자의 것이 보인다
    // (`StudentApiService.resetSessionState`). 여기서 연결하는 이유는 그 서비스가
    // `AuthService` 를 import 하므로 반대 방향이 순환 import 가 되기 때문이다.
    AuthService().onSessionCleared = () {
      StudentApiService().resetSessionState();
      // 토픽은 **기기** 단위라 로그아웃만으로 끊기지 않는다. 안 끊으면 공용
      // 기기에서 다음 사람이 이전 사용자의 학기 알림을 계속 받는다.
      //
      // 학기 코드를 같이 넘긴다 — 앱을 다시 켠 뒤 저장된 토큰이 거부돼 세션이
      // 비워지는 경로에서는 이번 실행에 구독한 기록이 없어서, 안 넘기면 기기가
      // 구독된 채로 남는다 ([PushService.unsubscribe]).
      PushService().unsubscribe(termCode: TermInfo.currentTermCode);
    };

    // 학생만 토픽을 쓴다 (PRD §4.8). 임원은 기기 토큰을 학생회 서버에 등록하며
    // 그 경로는 임원 앱 몫이다 — 여기서 임원까지 토픽에 넣으면 임원 기기에
    // 학생용 공개 알림이 중복으로 뜬다.
    AuthService().onSessionStarted = (session) {
      if (session.role == UserRole.STUDENT) {
        PushService().subscribeStudentTopic(TermInfo.currentTermCode);
      }
    };

    // 푸시를 누르면 **대시보드**로 간다. 학생 알림함이 없어서 보낼 곳이
    // 거기뿐이고, 항목 하나로 바로 보내면 그 건만 읽고 나머지 새 항목은
    // 뱃지가 지워진 뒤라 다시 못 찾는다 (§4.8).
    PushService().onOpened = _openDashboard;

    // **앱이 떠 있는 동안 온 푸시는 OS 가 띄우지 않는다.** Android 는 포그라운드
    // 메시지를 알림 트레이에 올리지 않고 앱에 바로 넘긴다. 그래서 이것을 연결하지
    // 않으면 **앱을 보고 있는 동안 온 알림만 아무 표시 없이 사라진다** — 학생이
    // 가장 자주 앱을 열어 보는 시간에만 알림이 없는 셈이다.
    PushService().onForegroundMessage = _showForegroundPush;
  }

  @override
  void dispose() {
    AuthService().onUnauthorized = null;
    AuthService().onSessionCleared = null;
    AuthService().onSessionStarted = null;
    PushService().onOpened = null;
    PushService().onForegroundMessage = null;
    super.dispose();
  }

  /// 앱이 떠 있는 동안 온 푸시. 화면 위에 띄우고 대시보드로 갈 길을 준다.
  ///
  /// **로그인 전에는 띄우지 않는다.** 토픽은 기기 단위라 로그아웃한 기기에도
  /// 계속 오는데, 로그인 화면에 남의 학기 지출 내역을 띄울 이유가 없다.
  void _showForegroundPush(PushMessage message) {
    if (AuthService().session == null) return;

    final text = message.body ?? message.title;
    if (text == null || text.isEmpty) return;

    _messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        action: SnackBarAction(label: '보기', onPressed: _openDashboard),
      ),
    );
  }

  /// 푸시를 눌러 들어온 경로. 로그인 전이면 아무것도 하지 않는다 —
  /// `SessionGate` 가 이미 로그인 화면을 띄우고 있다.
  /// **쌓인 화면을 버리지 않는다.** 세션 만료([_forceLogin])와 달리 푸시는
  /// 「보던 것을 그만두라」는 신호가 아니다. 스택을 지우면 이의 제기 폼에 쓰던
  /// 글처럼 **저장되지 않은 입력이 경고 없이 사라진다.** 대시보드를 위에 얹고,
  /// 뒤로 가면 하던 일로 돌아가게 둔다.
  ///
  /// 이미 대시보드면 아무것도 하지 않는다 — 푸시를 연달아 누를 때 같은 화면이
  /// 계속 쌓이면 뒤로 가기를 그만큼 눌러야 빠져나온다.
  void _openDashboard() {
    final session = AuthService().session;
    if (session == null) return;

    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;

    var onDashboard = false;
    navigator.popUntil((route) {
      onDashboard = route.settings.name == _dashboardRoute;
      return true; // 아무것도 pop 하지 않는다 — 맨 위 route 를 보기만 한다.
    });
    if (onDashboard) return;

    navigator.push(
      MaterialPageRoute(
        settings: const RouteSettings(name: _dashboardRoute),
        builder: (_) => homeScreenFor(session.role),
      ),
    );
  }

  /// 푸시로 띄운 대시보드를 알아보기 위한 이름. 중복해서 쌓지 않으려고 쓴다.
  static const _dashboardRoute = 'push:dashboard';

  void _forceLogin() {
    // 쌓인 화면을 모두 버린다 — 뒤로 가서 만료된 세션의 화면으로 돌아갈 수 없게 한다.
    _navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
    // 기기에서 토큰을 지우지 못했으면 그 사실도 말한다 — 「다시 로그인하세요」만
    // 보여주면 사용자는 기기에 세션이 남은 것을 모른다 ([TokenClearFailed]).
    //
    // **읽으면서 깃발을 내린다** ([AuthService.consumeTokenClearFailed]). 로그인
    // 화면도 같은 깃발을 보는데(앱 시작 복원 실패는 이 경로를 지나지 않아서),
    // 그냥 읽으면 여기서 알린 경고를 로그인 화면이 한 번 더 띄운다.
    final clearFailed = AuthService().consumeTokenClearFailed();
    _messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(
          clearFailed
              ? '세션이 만료되었습니다. 다만 이 기기에서 로그인 정보를 지우지 못했습니다 — '
                  '공용 기기라면 앱 데이터를 삭제해 주세요.'
              : '세션이 만료되었습니다. 다시 로그인해 주세요.',
        ),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: clearFailed ? 6 : 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '학생회 회계 투명성 시스템',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeData,
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
      home: const SessionGate(),
      onGenerateRoute: AppRouter.onGenerateRoute,
    );
  }
}

/// 앱을 켤 때 보관된 토큰으로 세션을 되살리고, 되살아나면 역할별 첫 화면으로 간다.
///
/// 토큰이 없거나 만료됐으면 로그인 화면이다. 서버에 닿지 못한 경우도 로그인
/// 화면인데, 토큰은 지우지 않으므로 연결이 돌아온 뒤 다시 로그인하면 된다
/// ([AuthService.restore]).
class SessionGate extends StatefulWidget {
  const SessionGate({super.key});

  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  late final Future<Session?> _restoring = AuthService().restore();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Session?>(
      future: _restoring,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            backgroundColor: AppTheme.bgPage,
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final session = snapshot.data;
        if (session == null) return const LoginScreen();
        return homeScreenFor(session.role);
      },
    );
  }
}
