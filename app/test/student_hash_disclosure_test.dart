import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/app_theme.dart';
import 'package:student_council_app/screens/student/entry_detail_screen.dart';

/// 지출 상세의 **해시 값은 기본으로 접혀 있고, 어긋났을 때만 펼쳐진다.**
///
/// 잘린 해시 두 줄을 눈으로 맞춰 보는 학생은 없고 그 비교는 이미 1단계 배지가
/// 해줬다. 반면 불일치일 때는 이 두 값이 학생이 이의 제기에 붙일 수 있는 유일한
/// 증거라서 처음부터 보여야 한다.
///
/// 「기본값」은 눈에 안 보이는 회귀다 — `autoExpand` 를 넘기는 쪽이 끊기거나
/// 초기값이 `true` 로 뒤집혀도 화면은 멀쩡히 그려진다. 그래서 여기서 못박는다.
void main() {
  group('해시 값 접기 (지출 상세 검증 카드 1단계)', () {
    testWidgets('통과했을 때는 접혀 있고, 값이 트리에 없다', (tester) async {
      await _pump(tester, autoExpand: false);

      expect(find.text('해시 값 보기'), findsOneWidget,
          reason: '접었으면 펼칠 길이 보여야 한다 — 값을 없앤 것이 아니다');
      expect(find.text(_recomputed), findsNothing,
          reason: '배지가 이미 비교 결과를 말했으므로 값까지 깔아 둘 이유가 없다');
    });

    testWidgets('불일치면 펼친 채로 시작한다', (tester) async {
      await _pump(tester, autoExpand: true);

      expect(find.text(_recomputed), findsOneWidget,
          reason: '어긋났을 때 값을 숨기면 학생이 이의에 붙일 증거가 사라진다');
      expect(find.text('해시 값 숨기기'), findsOneWidget);
    });

    testWidgets('접힌 상태에서 눌러 펼칠 수 있고, 다시 접힌다', (tester) async {
      await _pump(tester, autoExpand: false);

      await tester.tap(find.text('해시 값 보기'));
      await tester.pump();
      expect(find.text(_recomputed), findsOneWidget);

      await tester.tap(find.text('해시 값 숨기기'));
      await tester.pump();
      expect(find.text(_recomputed), findsNothing);
    });
  });
}

const _recomputed = '앱에서 재계산한 값입니다';

Future<void> _pump(WidgetTester tester, {required bool autoExpand}) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.themeData,
    home: Scaffold(
      body: HashDisclosure(
        autoExpand: autoExpand,
        children: const [Text(_recomputed)],
      ),
    ),
  ));
  await tester.pump();
}
