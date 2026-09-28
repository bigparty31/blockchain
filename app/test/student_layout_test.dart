import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/app_theme.dart';
import 'package:student_council_app/screens/student/student_home_screen.dart';

/// 학생 대시보드 **헤더**가 여러 화면 크기에서 오버플로 없이 그려지는지 확인한다.
///
/// 오버플로는 `RenderFlex overflowed` 예외로 보고되며, 위젯 테스트에서는
/// 그대로 실패로 잡힌다. 눈으로 한 기기만 보고 넘어가면 다른 기기에서 다시 난다.
///
/// **범위 한계 — 본문(카드 목록)은 여기서 검사되지 않는다.**
/// 화면이 `http` 를 직접 쓰는데 위젯 테스트의 가짜 시계 아래에서는 그 Future 가
/// `pump` 만으로 완료되지 않아, 로딩이 끝나지 않은 채로 헤더만 그려진다.
/// `runAsync` 로 실제 시간을 주면 본문까지 그려지지만, 그때는 테마가 쓰는
/// Google Fonts 가 네트워크로 폰트를 받으려다 예외를 던진다.
/// 본문까지 덮으려면 HTTP 클라이언트를 주입 가능하게 바꾸거나 폰트를
/// 애셋으로 번들해야 한다.
///
/// 실제로 오버플로가 났던 곳이 헤더라 지금 범위로도 그 회귀는 잡는다
/// (`expandedHeight` 를 되돌리면 이 테스트가 실패하는 것을 확인했다).
void main() {
  /// Pixel 8 (411×914) 을 포함해 흔한 크기들.
  const sizes = <String, Size>{
    'Pixel 8 (411x914)': Size(411, 914),
    '작은 기기 (360x640)': Size(360, 640),
    '큰 기기 (430x932)': Size(430, 932),
  };

  for (final entry in sizes.entries) {
    testWidgets('학생 대시보드 — ${entry.key}', (tester) async {
      await _pumpAt(tester, entry.value, const StudentHomeScreen());

      // 로딩 스피너 → 데모 데이터 적용까지 기다린다.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(tester.takeException(), isNull);
      expect(find.text('학생회비 열람'), findsOneWidget);
      // 부제목이 잘리지 않고 그려져야 한다 — 2px 오버플로가 났던 자리다.
      expect(find.text('2026학년도 2학기 · 컴퓨터공학과'), findsOneWidget);
    });
  }

  testWidgets('글꼴 배율을 키워도 헤더가 넘치지 않는다', (tester) async {
    // 접근성 설정으로 글자를 키운 사용자. 헤더는 높이가 고정이라 여기서 깨지기 쉽다.
    await _pumpAt(
      tester,
      const Size(411, 914),
      const StudentHomeScreen(),
      textScale: 1.3,
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpAt(
  WidgetTester tester,
  Size size,
  Widget child, {
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.themeData,
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          // 상태바가 있는 기기를 가정한다. SafeArea 가 이만큼 깎아 간다.
          padding: const EdgeInsets.only(top: 32),
          textScaler: TextScaler.linear(textScale),
        ),
        child: child,
      ),
    ),
  );
}
