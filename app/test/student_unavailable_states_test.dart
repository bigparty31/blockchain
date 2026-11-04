import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/app_theme.dart';
import 'package:student_council_app/core/term_info.dart';
import 'package:student_council_app/screens/student/my_sbt_screen.dart';
import 'package:student_council_app/screens/student/student_home_screen.dart';
import 'package:student_council_app/services/student_api_service.dart';

/// **「없다」와 「못 읽었다」가 화면에서 달라 보이는지**를 못박는다.
///
/// 둘 다 결과적으로 빈 화면이라 코드가 한쪽으로 뭉개기 쉽고, 뭉개져도 화면은
/// 멀쩡해 보인다 — 눈으로는 안 잡히는 회귀다. 그런데 학생 입장에서는 정반대의
/// 말이다. 하나는 「아직 아무 일도 없었다」이고 하나는 「지금 알 수 없다」인데,
/// 장애가 전자로 읽히면 학생은 확인했다고 믿고 화면을 닫는다.
///
/// 스토리보드 2 ⑥(대시보드 조회 실패)과 6 ②·③(SBT 미보유 / 조회 실패)이
/// 화면을 따로 그려 둔 이유가 이것이다.
void main() {
  tearDown(() => StudentApiService.client = http.Client());

  group('학생 대시보드 — 조회 실패 (스토리보드 2 ⑥)', () {
    testWidgets('못 읽었으면 숫자 대신 「불러올 수 없습니다」와 다시 시도를 띄운다', (tester) async {
      // 원장은 읽혔는데 예산 응답의 모양이 깨진 경우. `fetchBudgets` 가 그대로
      // 던지므로 대시보드는 반쯤 채워진 상태가 된다.
      StudentApiService.client = MockClient((req) async {
        if (req.url.path.endsWith('/entries')) {
          return http.Response('[]', 200);
        }
        if (req.url.path.endsWith('/budgets')) {
          return http.Response('[1, 2, 3]', 200); // 항목이 객체가 아니다
        }
        return http.Response('', 404);
      });

      await _pumpHome(tester);

      expect(find.text('불러올 수 없습니다'), findsOneWidget);
      expect(find.text('다시 시도'), findsOneWidget,
          reason: '막는 데서 끝내면 서버가 돌아와도 학생은 길이 없다');

      // **「편성된 예산이 없습니다」가 뜨면 안 된다** — 읽어 보니 비어 있다는
      // 뜻이라 장애가 「학기 초」(스토리보드 2-B)로 읽힌다.
      expect(find.text('편성된 예산이 없습니다'), findsNothing);
      // 반쯤 채워진 값으로 잔액을 그려도 안 된다. ₩0 은 없는 돈이 아니라
      // 모르는 돈이다.
      expect(find.text('장부 잔액'), findsNothing);
    });

    testWidgets('응답이 멀쩡하면 실패 화면으로 빠지지 않는다', (tester) async {
      StudentApiService.client = MockClient((req) async {
        if (req.url.path.endsWith('/entries')) {
          return http.Response('[]', 200);
        }
        if (req.url.path.endsWith('/budgets')) {
          return http.Response('[]', 200);
        }
        return http.Response('', 404);
      });

      await _pumpHome(tester);

      // **범위 한계** — 조회의 마지막 단계인 `lastSeenEntryId` 가
      // `flutter_secure_storage` 를 타는데, 위젯 테스트의 가짜 시계 아래에서는
      // 그 Future 가 `pump` 만으로 끝나지 않는다 (`student_layout_test.dart` 의
      // 같은 한계). 그래서 성공 경로는 로딩에서 멈춘 채로만 볼 수 있다.
      //
      // 그래도 이 테스트에는 값이 있다 — 「실패 화면이 늘 떠 있다」와
      // 「로딩 중에 미리 실패라고 단정한다」를 둘 다 잡는다.
      expect(find.text('불러올 수 없습니다'), findsNothing);
      expect(find.text('다시 시도'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('내 SBT · QR — 미보유 (스토리보드 6 ②)', () {
    testWidgets('미납이면 「미보유」라고 못박아 말하고 학기를 함께 적는다', (tester) async {
      // 서버가 분명히 「발급받은 적 없음」이라고 답한 경우 (`200` + 본문 `null`).
      StudentApiService.client =
          MockClient((req) async => http.Response('null', 200));

      await _pumpSbt(tester);

      expect(find.text('미보유'), findsOneWidget,
          reason: '발표 대본·스토리보드 6-B 가 못박은 문구다');
      expect(find.text(TermInfo.currentTerm), findsOneWidget,
          reason: 'SBT 는 학기 단위라 어느 학기 이야기인지 밝혀야 한다');
      expect(find.text('학생회비 납부 확인이 필요합니다'), findsOneWidget);

      // 조회 실패 화면의 문구를 빌려 쓰면 안 된다.
      expect(find.text('확인할 수 없습니다'), findsNothing);
      expect(find.text('다시 시도'), findsNothing,
          reason: '미보유는 다시 조회한다고 달라지지 않는다');
    });

    testWidgets('조회 실패는 미보유와 다른 화면이다 (스토리보드 6 ③)', (tester) async {
      // 서버가 대답은 했는데 읽을 수 없는 경우 — 「없음」이 아니라 「모름」이다.
      StudentApiService.client =
          MockClient((req) async => http.Response('', 500));

      await _pumpSbt(tester);

      expect(find.text('확인할 수 없습니다'), findsOneWidget);
      expect(find.text('다시 시도'), findsOneWidget);
      expect(find.text('미보유'), findsNothing,
          reason: '못 읽은 것을 미보유라고 하면 납부한 학생에게 거짓을 말한다');
    });
  });
}

Future<void> _pumpHome(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.themeData,
    home: const StudentHomeScreen(),
  ));
  await _settle(tester);
}

Future<void> _pumpSbt(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.themeData,
    home: const MySbtScreen(),
  ));
  await _settle(tester);
}

/// 조회가 끝나고 화면이 다시 그려질 때까지. `_timeout` 타이머가 남아 있어
/// `pumpAndSettle` 은 쓰지 않는다.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
