import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/screens/council/my_entries_screen.dart';
import 'package:student_council_app/screens/council/notification_inbox_screen.dart';
import 'package:student_council_app/services/notification_service.dart';

/// 알림을 눌렀을 때의 동작 — `docs/NOTIFICATION_API.md` 「`kind` 값」 표의 받는 사람대로.
///
///   - `ENTRY_BLOCKED` 는 **총무와 회장**이 받는다. 총무는 내 등록 현황으로 가고, 회장은 갈 화면이 없어도
///     눌렀는데 아무 반응이 없으면 안 된다 (읽음 처리만 되고 끝나면 알림이 고장 난 것처럼 보인다).
///   - `REVISION_APPROVED`·`REVISION_REJECTED` 는 **총무와 회장**이 받는다. 총무가 할 일은 차단 건을 다시
///     등록하거나 다시 요청하는 것이라 내 등록 현황으로 간다.
void main() {
  AppNotification n(String kind) => AppNotification(id: 1, kind: kind, body: '', createdAt: 0, notifiedAt: 0);

  group('notificationDestination', () {
    test('증액 승인·반려 결과는 총무를 내 등록 현황으로 보낸다', () {
      expect(notificationDestination(n('REVISION_APPROVED'), UserRole.TREASURER), isA<MyEntriesScreen>());
      expect(notificationDestination(n('REVISION_REJECTED'), UserRole.TREASURER), isA<MyEntriesScreen>());
    });

    test('회장·감사에게는 증액 결과로 갈 화면이 아직 없다', () {
      for (final role in [UserRole.PRESIDENT, UserRole.AUDITOR]) {
        expect(notificationDestination(n('REVISION_APPROVED'), role), isNull);
        expect(notificationDestination(n('REVISION_REJECTED'), role), isNull);
      }
    });

    test('서명을 기다리는 증액 알림은 아직 갈 화면이 없다 (문승준 파트)', () {
      for (final kind in ['REVISION_REQUESTED', 'REVISION_PRESIDENT_SIGNED', 'SIGNATURE_DEADLINE_NEAR']) {
        for (final role in UserRole.values) {
          expect(notificationDestination(n(kind), role), isNull, reason: '$kind · $role');
        }
      }
    });

    test('차단 알림은 총무만 내 등록 현황으로 간다 — 지금까지와 같다', () {
      expect(notificationDestination(n('ENTRY_BLOCKED'), UserRole.TREASURER), isA<MyEntriesScreen>());
      expect(notificationDestination(n('ENTRY_BLOCKED'), UserRole.PRESIDENT), isNull);
    });
  });

  group('notificationNoDestinationNotice — 갈 곳이 없을 때 알려 주는 말', () {
    test('회장의 차단 알림에는 이유를 알려 준다', () {
      expect(notificationNoDestinationNotice(n('ENTRY_BLOCKED'), UserRole.PRESIDENT), contains('차단'));
    });

    test('증액 쪽 알림은 준비 중이라고 알려 준다', () {
      for (final kind in ['REVISION_REQUESTED', 'REVISION_PRESIDENT_SIGNED', 'SIGNATURE_DEADLINE_NEAR']) {
        expect(notificationNoDestinationNotice(n(kind), UserRole.PRESIDENT), contains('준비 중'), reason: kind);
      }
      expect(notificationNoDestinationNotice(n('REVISION_APPROVED'), UserRole.PRESIDENT), contains('준비 중'));
    });

    test('갈 화면이 있으면 알릴 것이 없다', () {
      expect(notificationNoDestinationNotice(n('ENTRY_BLOCKED'), UserRole.TREASURER), isNull);
      expect(notificationNoDestinationNotice(n('REVISION_APPROVED'), UserRole.TREASURER), isNull);
      expect(notificationNoDestinationNotice(n('ENTRY_REGISTERED'), UserRole.AUDITOR), isNull);
    });

    test('모르는 종류는 아무 말도 덧붙이지 않는다 — 본문이 그대로 보인다', () {
      expect(notificationNoDestinationNotice(n('SOMETHING_NEW'), UserRole.PRESIDENT), isNull);
    });
  });

  group('알림함 화면', () {
    http.Response json(Object body) =>
        http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

    Future<List<String>> pumpInbox(WidgetTester tester, UserRole role, String kind) async {
      final reads = <String>[];
      NotificationService.client = MockClient((req) async {
        if (req.method == 'POST') {
          reads.add(req.url.path);
          return json({'id': 1, 'read_at': 1793552400});
        }
        return json([
          {
            'id': 1,
            'kind': kind,
            'entry_id': 34,
            'budget_revision_request_id': null,
            'body': '서버 문구',
            'created_at': 1793548800,
            'notified_at': 1793548800,
            'read_at': null,
            'remind_count': 0,
          }
        ]);
      });
      addTearDown(() => NotificationService.client = http.Client());
      tester.view.physicalSize = const Size(411, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: NotificationInboxScreen(role: role)));
      await tester.pumpAndSettle();
      return reads;
    }

    testWidgets('회장이 차단 알림을 누르면 읽음 처리하고, 반응 없이 끝나지 않고 이유를 알려 준다', (tester) async {
      final reads = await pumpInbox(tester, UserRole.PRESIDENT, 'ENTRY_BLOCKED');
      await tester.tap(find.byKey(const Key('notification_1')));
      await tester.pumpAndSettle();
      expect(reads, ['/notifications/1/read']);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('차단'), findsWidgets);
    });

    testWidgets('총무가 증액 승인 알림을 누르면 내 등록 현황으로 간다', (tester) async {
      await pumpInbox(tester, UserRole.TREASURER, 'REVISION_APPROVED');
      await tester.tap(find.byKey(const Key('notification_1')));
      await tester.pumpAndSettle();
      expect(find.byType(MyEntriesScreen), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing, reason: '갈 화면이 있으면 「준비 중」을 띄우지 않는다');
    });
  });
}
