import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/screens/student/student_home_screen.dart';
import 'package:student_council_app/services/student_api_service.dart';

/// 예시 데이터를 보고 있을 때 화면이 그 사실을 알리는지 확인한다.
///
/// 조용히 폴백하면 실제 원장인지 개발용 예시인지 구분할 수 없고,
/// 그러면 검증 배지가 아무 의미도 없어진다. 시연 도중 서버가 꺼져도
/// 화면이 멀쩡해 보여 아무도 알아채지 못한다.
void main() {
  testWidgets('서버가 없으면 예시 데이터 배너가 뜬다', (tester) async {
    tester.view.physicalSize = const Size(411, 914);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        // AppTheme.themeData 는 Google Fonts(Nunito)를 네트워크로 받으려 해서
        // 테스트 안에서 예외가 난다. 이 테스트는 배너 문구가 뜨는지만 보므로
        // 기본 테마로 충분하다. 글꼴이 레이아웃에 영향을 주는 검사는
        // student_layout_test.dart 가 실제 테마로 따로 한다.
        home: const MediaQuery(
          data: MediaQueryData(
            size: Size(411, 914),
            padding: EdgeInsets.only(top: 32),
          ),
          child: StudentHomeScreen(),
        ),
      ),
    );

    // 테스트 환경에는 서버가 없으므로 폴백한다.
    // 로딩 스피너가 계속 돌아 pumpAndSettle 은 쓸 수 없으므로 직접 돌린다.
    await _settle(tester);

    expect(StudentApiService().usingDemoData, isTrue);
    expect(find.text('예시 데이터입니다'), findsOneWidget);
    expect(
      find.textContaining('실제 학생회 회계 내역이 아닙니다'),
      findsOneWidget,
    );
  });

  // 서버 응답을 받았을 때 배너가 사라지는 것은 여기서 확인하지 못한다.
  //
  // (아래 주석 참고)
  // `StudentApiService` 가 `http` 를 직접 쓰고 있어 테스트에서 갈아끼울 수 없다.
  // 확인하려면 백엔드를 띄우고 앱을 실행해 배너가 없는지 봐야 한다:
  //   cd backend && .venv/bin/uvicorn app.main:app --port 8000
  // HTTP 클라이언트를 주입 가능하게 바꾸면 이것도 테스트로 고정할 수 있다.
}

/// 데이터 로딩이 끝나 본문이 그려질 때까지 기다린다.
///
/// 두 가지를 같이 처리해야 한다.
///   - 화면이 `http` 를 직접 쓰는데, 위젯 테스트의 가짜 시계 아래에서는
///     그 Future 가 `pump` 만으로 완료되지 않는다 → `runAsync` 로 실제 시간을 준다
///   - 로딩 스피너가 끝없이 회전해서 `pumpAndSettle` 은 타임아웃이 난다
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
  }
}
