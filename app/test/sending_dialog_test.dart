import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/screens/council/sending_dialog.dart';

void main() {
  testWidgets('send 가 예상 밖의 예외를 던져도 「전송 중」 창은 닫힌다 (#111 리뷰)', (tester) async {
    Object? caught;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            try {
              await sendWithBlocking(context, '전송 중', () async => throw StateError('키 처리 실패'));
            } catch (e) {
              caught = e;
            }
          },
          child: const Text('시작'),
        ),
      ),
    ));
    await tester.tap(find.text('시작'));
    await tester.pumpAndSettle();

    expect(caught, isA<StateError>(), reason: '예상 밖의 예외는 삼키지 않고 호출한 쪽에 돌려준다');
    expect(find.byType(SendingDialog), findsNothing, reason: '닫을 수 없는 창이 남아 화면이 갇히면 안 된다');
  });
}
