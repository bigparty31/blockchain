import 'package:flutter/material.dart';

import 'core/app_theme.dart';
import 'core/role_home.dart';
import 'router.dart';
import 'screens/login_screen.dart';
import 'services/auth_service.dart';
import 'services/student_api_service.dart';

void main() {
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
    };
  }

  @override
  void dispose() {
    AuthService().onUnauthorized = null;
    AuthService().onSessionCleared = null;
    super.dispose();
  }

  void _forceLogin() {
    // 쌓인 화면을 모두 버린다 — 뒤로 가서 만료된 세션의 화면으로 돌아갈 수 없게 한다.
    _navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
    // 기기에서 토큰을 지우지 못했으면 그 사실도 말한다 — 「다시 로그인하세요」만
    // 보여주면 사용자는 기기에 세션이 남은 것을 모른다 ([TokenClearFailed]).
    _messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(
          AuthService().tokenClearFailed
              ? '세션이 만료되었습니다. 다만 이 기기에서 로그인 정보를 지우지 못했습니다 — '
                  '공용 기기라면 앱 데이터를 삭제해 주세요.'
              : '세션이 만료되었습니다. 다시 로그인해 주세요.',
        ),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: AuthService().tokenClearFailed ? 6 : 4),
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
