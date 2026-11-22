import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/screens/council/council_home_screen.dart';
import 'package:student_council_app/services/api_service.dart';

/// 시스템 글자 크기를 키운 태블릿에서 임원 홈 헤더(배지·제목·한 줄 소개)가 넘치지 않는다.
/// 높이를 200 으로 고정했을 때 글자 1.5배에서 7픽셀이 넘쳐 debug 빌드에 노란 경고띠가 떴고, 소개 줄이 가려졌다.
void main() {
  setUp(() => ApiService.useDemoData = true);

  for (final role in [UserRole.TREASURER, UserRole.AUDITOR, UserRole.PRESIDENT]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('$role 홈 헤더 — 글자 $scale배에서 넘치지 않는다', (tester) async {
        tester.view.physicalSize = const Size(1200, 2000);
        tester.view.devicePixelRatio = 1.5;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(
          builder: (context, child) =>
              MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
          home: CouncilHomeScreen(role: role),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '레이아웃 넘침(RenderFlex overflowed)이 보고되면 안 된다');
      });
    }
  }
}
