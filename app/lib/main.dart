import 'package:flutter/material.dart';

import 'core/app_theme.dart';
import 'core/role_home.dart';
import 'router.dart';
import 'screens/login_screen.dart';
import 'services/auth_service.dart';

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
  }

  @override
  void dispose() {
    AuthService().onUnauthorized = null;
    super.dispose();
  }

  void _forceLogin() {
    // 쌓인 화면을 모두 버린다 — 뒤로 가서 만료된 세션의 화면으로 돌아갈 수 없게 한다.
    _navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
    _messengerKey.currentState?.showSnackBar(
      const SnackBar(
        content: Text('세션이 만료되었습니다. 다시 로그인해 주세요.'),
        behavior: SnackBarBehavior.floating,
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
