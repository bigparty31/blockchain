import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/app_theme.dart';
import 'package:student_council_app/screens/student/entry_list_screen.dart';
import 'package:student_council_app/services/student_api_service.dart';

/// 목록 화면이 **좁은 기기·큰 글자에서도 넘치지 않는지** (S2)
///
/// 「새 항목」 칩은 미확인 뱃지로 들어왔을 때만 생겨 5개가 된다. 그 5번째가
/// 끝자리라, 넘쳐서 잘리면 **선택돼 있는 칩이 화면 밖으로 나가** 「전체」를 한 번
/// 누른 뒤 새 항목만 보는 화면으로 돌아갈 수 없다 — 뱃지는 목록을 연 순간
/// 지워지므로 다시 들어올 길도 없다. 디버그에서는 줄무늬가 보이지만 릴리스에서는
/// 그냥 잘려서, 화면만 봐서는 멀쩡해 보인다.
///
/// **픽셀 수를 단정하지 않는다.** `flutter test` 에는 앱 폰트가 없어서 글자마다
/// 정사각형인 테스트 폰트로 대체되고, 공백이 든 문구(「확인 필요」·「새 항목」)를
/// 실제보다 넓게 잰다 — 실기기 411dp 에서 넘치지 않는 것이 여기서는 18px 초과로
/// 나왔다. 그래서 「몇 px 넘쳤나」가 아니라 **「오버플로가 났나」만** 본다.
void main() {
  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async {
      switch (call.method) {
        case 'readAll':
          return <String, String>{};
        case 'containsKey':
          return false;
        default:
          return null;
      }
    });
    StudentApiService.client = MockClient((req) async {
      if (req.url.path.endsWith('/entries')) {
        return http.Response(_entriesJson, 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return http.Response('[]', 200);
    });
  });

  tearDown(() {
    StudentApiService.client = http.Client();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null);
  });

  // 320dp 는 칩 4개만으로도 넘치던 폭이다 — 스크롤로 바꾸면 같이 닫힌다.
  for (final width in [320.0, 360.0, 411.0]) {
    for (final scale in [1.0, 1.3, 1.5]) {
      for (final entry in [null, 2]) {
        final chips = entry == null ? 4 : 5;
        testWidgets('폭 ${width.toInt()}dp · 글자 ${(scale * 100).toInt()}% · '
            '칩 $chips개 — 넘치지 않는다', (tester) async {
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          await tester.pumpWidget(MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: MaterialApp(
              theme: AppTheme.themeData,
              home: EntryListScreen(unseenAfterEntryId: entry),
            ),
          ));
          // 목록의 `_timeout` 타이머가 남아 pumpAndSettle 은 쓰지 않는다.
          for (var i = 0; i < 12; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }

          expect(
            tester.takeException(),
            isNull,
            reason: '화면이 넘쳤다 — 끝자리 칩이나 금액이 잘려 보이지 않게 된다',
          );
        });
      }
    }
  }

  /// 가로 스크롤로 바꾸면서 한 번 깨진 자리다. 스크롤뷰는 콘텐츠 너비만큼만
  /// 차지해서, 폭을 지정하지 않으면 **흰 배경이 칩 끝에서 끊기고** 오른쪽이
  /// 페이지 배경으로 비친다. 넘침 시험으로는 안 잡힌다 — 넘치지는 않으니까.
  testWidgets('필터 바 배경이 화면 폭을 채운다', (tester) async {
    const width = 411.0;
    tester.view.physicalSize = const Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: EntryListScreen()));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 필터 바 = 가로 스크롤을 품고 있는 Container.
    final bar = find.ancestor(
      of: find.byType(SingleChildScrollView),
      matching: find.byType(Container),
    );
    expect(bar, findsWidgets);
    expect(
      tester.getSize(bar.first).width,
      width,
      reason: '칩 너비만큼만 그려져 오른쪽이 비어 보인다',
    );
  });

  testWidgets('좁은 기기에서도 모든 칩에 닿을 수 있다', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(
      home: EntryListScreen(unseenAfterEntryId: 2),
    ));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 잘린 칩은 `ensureVisible` 로도 못 가져온다 — 스크롤이 있어야 올라온다.
    await tester.scrollUntilVisible(find.text('새 항목'), 60,
        scrollable: find.byType(Scrollable).first);
    await tester.pump();

    await tester.tap(find.text('새 항목'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
  });
}

/// **긴 금액과 긴 이름을 일부러 넣는다.** 항목 카드의 금액 열도 좁은 기기·큰
/// 글자에서 넘쳤다(`entry_list_screen.dart` 의 금액 `Row`, 320dp·150% 에서 1px).
/// 짧은 값만 넣으면 그 경로가 시험에 걸리지 않는다.
const _entriesJson = '''
[
  {"id":1,"term_id":1,"kind":"INCOME","amount":5000000,
   "counterparty":"컴퓨터공학과 학생회비 일괄 납부",
   "purpose":"2026-2학기 학과 학생회비 수납","occurred_at":1762000000,"status":"CONFIRMED"},
  {"id":3,"term_id":1,"kind":"EXPENSE","amount":1234567,"counterparty":"한결문구 제본소",
   "purpose":"새로 들어온 지출 — 학과 행사 인쇄물","occurred_at":1762600000,"status":"CONFIRMED"}
]
''';
