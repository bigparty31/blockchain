import 'package:flutter/material.dart';

import '../screens/login_screen.dart';
import '../services/auth_service.dart';
import 'app_theme.dart';

/// 로그아웃 버튼. 역할별 홈 화면의 AppBar `actions:` 에 넣는다.
///
/// ```dart
/// actions: const [LogoutAction()],
/// ```
///
/// **한 군데만 둔다.** 학생 홈과 총무·감사 홈이 각자 구현하면 한쪽만 고쳐져
/// 「학생은 토큰이 지워지는데 총무는 화면만 돌아가는」 상태가 된다. 그 경우
/// 다음 사람이 그 기기에서 앱을 켜면 **이전 임원의 세션으로 들어간다** —
/// 조회뿐 아니라 등록·승인 화면까지 열린다.
///
/// 작성지침에는 로그아웃이 없다(화면 1 「들어오는 경로」는 앱 실행과 세션 만료
/// 둘뿐이다). 세션을 기기에 저장하게 된 이상 사용자가 직접 끊을 수단이 없으면
/// 안 되므로 넣는다 — 공용 기기에서 한 번 로그인하면 지울 방법이 없다.
class LogoutAction extends StatelessWidget {
  const LogoutAction({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const Key('logout_action'),
      onPressed: () => confirmAndLogout(context),
      icon: const Icon(Icons.logout_rounded),
      tooltip: '로그아웃',
    );
  }
}

/// 확인을 받고 로그아웃한다. 확인하지 않으면 아무 일도 하지 않는다.
///
/// 되돌릴 수 없는 동작은 아니지만(다시 로그인하면 된다) 잘못 눌렀을 때
/// 작업 중인 화면이 통째로 닫히므로 한 번 묻는다.
Future<void> confirmAndLogout(BuildContext context) async {
  final navigator = Navigator.of(context);

  final confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      icon: const Icon(Icons.logout_rounded, color: AppTheme.primary, size: 36),
      title: const Text('로그아웃할까요?'),
      content: const Text(
        '이 기기에 저장된 로그인 정보가 지워집니다.\n다시 보려면 학번으로 로그인해야 합니다.',
        style: TextStyle(fontSize: 14, height: 1.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('취소'),
        ),
        TextButton(
          key: const Key('logout_confirm'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('로그아웃'),
        ),
      ],
    ),
  );

  if (confirmed != true) return;

  // **토큰을 먼저 지운다.** 화면을 먼저 보내면 그 사이 남아 있는 세션으로
  // 조회가 한 번 더 나갈 수 있다.
  await AuthService().logout();

  // 쌓인 화면을 모두 버린다 — 뒤로 가서 로그아웃 전 화면으로 돌아갈 수 없게 한다
  // (`main.dart` 의 세션 만료 처리와 같은 방식).
  navigator.pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const LoginScreen()),
    (route) => false,
  );
}
