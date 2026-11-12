import 'package:flutter/material.dart';

import '../screens/council/council_home_screen.dart';
import '../screens/student/student_home_screen.dart';
import 'enums.dart';

/// 역할별 첫 화면 (작성지침 화면 1 「역할 분기표」).
///
/// **한 군데만 둔다.** 로그인 성공(`screens/login_screen.dart`)과 앱 시작 시
/// 세션 복원(`main.dart`) 두 경로가 같은 분기를 쓰는데, 각자 적어 두면 한쪽만
/// 고쳐져 「로그인하면 총무 화면인데 앱을 다시 켜면 학생 화면」이 된다.
///
/// 지침의 목적지는 TREASURER → 9. 내 등록 현황, AUDITOR → 12. 승인 대기,
/// PRESIDENT → 미정(12 또는 15) 이다. 그 화면들이 아직 없어 총무·감사 홈으로
/// 보낸다 — 화면 9·12 가 생기면 여기만 바꾼다.
Widget homeScreenFor(UserRole role) {
  if (role == UserRole.STUDENT) return const StudentHomeScreen();
  return CouncilHomeScreen(role: role);
}
