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

  group('펼친 상태는 스크롤에 살아남는다', () {
    // 상세 화면은 `ListView` 라 화면 밖으로 나간 자식을 버리고 돌아올 때 새로
    // 만든다. 그러면 펼침 상태가 `autoExpand` 로 되돌아가서, 긴 해시를 비교하려고
    // 펼친 학생이 위아래로 한 번 오가면 다시 접혀 있었다.
    testWidgets('펼쳐 두고 화면 밖으로 내렸다 돌아오면 그대로 펼쳐져 있다', (tester) async {
      await _pumpInList(tester, autoExpand: false);

      await tester.tap(find.text('해시 값 보기'));
      await tester.pump();
      expect(find.text(_recomputed), findsOneWidget);

      // 멀리 내려 이 자식을 화면 밖으로 보낸다.
      await tester.drag(find.byType(ListView), const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(find.text('해시 값 보기'), findsNothing, reason: '화면 밖으로 나가지 않았다');

      // 돌아온다.
      await tester.drag(find.byType(ListView), const Offset(0, 3000));
      await tester.pumpAndSettle();

      expect(
        find.text(_recomputed),
        findsOneWidget,
        reason: '스크롤 한 번에 펼쳐 둔 해시 값이 다시 접혔다',
      );
      expect(find.text('해시 값 숨기기'), findsOneWidget);
    });

    testWidgets('손대지 않았으면 되돌아가도 상관없다 — 기본은 접힘', (tester) async {
      await _pumpInList(tester, autoExpand: false);

      await tester.drag(find.byType(ListView), const Offset(0, -3000));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 3000));
      await tester.pumpAndSettle();

      expect(find.text('해시 값 보기'), findsOneWidget);
      expect(find.text(_recomputed), findsNothing);
    });

    testWidgets('접어 둔 불일치 항목도 돌아와서 접힌 채로 있다', (tester) async {
      // `autoExpand: true` 를 사용자가 직접 접은 경우. 되돌아가면 다시 펼쳐지는데,
      // 그것도 사용자가 한 일을 무르는 것이다.
      await _pumpInList(tester, autoExpand: true);

      await tester.tap(find.text('해시 값 숨기기'));
      await tester.pump();
      expect(find.text(_recomputed), findsNothing);

      await tester.drag(find.byType(ListView), const Offset(0, -3000));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 3000));
      await tester.pumpAndSettle();

      expect(find.text('해시 값 보기'), findsOneWidget, reason: '접어 둔 것이 다시 펼쳐졌다');
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

/// 실제 화면처럼 **`ListView` 안에** 둔다.
///
/// `Scaffold` 에 바로 올리면 자식이 버려지는 일이 없어서, 「스크롤로 나갔다
/// 돌아왔을 때」를 물을 수 없다 — 그 조건에서만 나는 결함이다.
Future<void> _pumpInList(WidgetTester tester, {required bool autoExpand}) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.themeData,
    home: Scaffold(
      body: ListView(
        children: [
          HashDisclosure(
            autoExpand: autoExpand,
            children: const [Text(_recomputed)],
          ),
          // 뒤에 긴 내용을 둬서 위의 자식이 화면 밖으로 나갈 수 있게 한다.
          for (var i = 0; i < 40; i++)
            SizedBox(height: 200, child: Text('아래 내용 $i')),
        ],
      ),
    ),
  ));
  await tester.pump();
}
