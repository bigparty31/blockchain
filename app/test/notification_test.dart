import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/screens/council/approval_list_screen.dart';
import 'package:student_council_app/screens/council/council_home_screen.dart';
import 'package:student_council_app/screens/council/notification_inbox_screen.dart';
import 'package:student_council_app/services/api_service.dart';
import 'package:student_council_app/services/notification_service.dart';

/// 임원 알림함·뱃지·폴링 — `docs/NOTIFICATION_API.md` 초안(손종인)의 경로·응답 형태로 만든다.
///
/// 서버 구현(11/7~8) 전이라 가짜 서버로 확인한다. 지키는 것:
///   - 못 읽은 것은 못 읽었다고 보여 준다 (빈 목록·0 으로 내리지 않는다)
///   - 모르는 `kind` 도 본문을 보여 준다
///   - 15초마다 다시 읽는다
void main() {
  http.Response json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  Map<String, dynamic> item(int id, String kind, {int? readAt, int remind = 0, int? entryId = 34}) => {
        'id': id,
        'kind': kind,
        'entry_id': entryId,
        'budget_revision_request_id': null,
        'body': '알림 본문 $id',
        'created_at': 1793548800,
        'notified_at': 1793548800,
        'read_at': readAt,
        'remind_count': remind,
      };

  tearDown(() {
    NotificationService.client = http.Client();
    ApiService.client = http.Client();
  });

  group('NotificationService', () {
    test('목록을 읽고, 모르는 kind 도 버리지 않는다', () async {
      NotificationService.client = MockClient((req) async {
        expect(req.url.path, '/notifications');
        expect(req.url.queryParameters['unread_only'], 'false');
        return json([item(1, 'ENTRY_REGISTERED'), item(2, 'SOMETHING_NEW')]);
      });
      final list = await NotificationService.list();
      expect(list!.map((n) => n.kind), ['ENTRY_REGISTERED', 'SOMETHING_NEW']);
      expect(notificationKindLabel('SOMETHING_NEW'), '알림');
    });

    test('모양이 어긋난 한 건 때문에 목록 전체를 잃지 않는다', () async {
      NotificationService.client = MockClient((_) async => json([item(1, 'ENTRY_REGISTERED'), {'id': 'x'}]));
      expect(await NotificationService.list(), hasLength(1));
    });

    test('서버 오류·연결 실패는 null — 빈 목록이나 0 이 아니다', () async {
      NotificationService.client = MockClient((_) async => json({}, 500));
      expect(await NotificationService.list(), isNull);
      expect(await NotificationService.unreadCount(), isNull);
      NotificationService.client = MockClient((_) async => throw http.ClientException('연결 실패'));
      expect(await NotificationService.list(), isNull);
      expect(await NotificationService.unreadCount(), isNull);
    });

    test('안 읽은 수', () async {
      NotificationService.client = MockClient((req) async {
        expect(req.url.path, '/notifications/unread-count');
        return json({'count': 3});
      });
      expect(await NotificationService.unreadCount(), 3);
    });

    test('읽음 처리 — 200 이면 read_at, 404(없거나 남의 알림)면 null', () async {
      NotificationService.client = MockClient((req) async {
        expect(req.method, 'POST');
        return req.url.path == '/notifications/12/read' ? json({'id': 12, 'read_at': 1793552400}) : json({}, 404);
      });
      expect(await NotificationService.markRead(12), 1793552400);
      expect(await NotificationService.markRead(99), isNull);
    });
  });

  group('알림함 화면', () {
    Future<void> pumpInbox(WidgetTester tester, UserRole role) async {
      tester.view.physicalSize = const Size(411, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: NotificationInboxScreen(role: role)));
      await tester.pumpAndSettle();
    }

    testWidgets('못 읽으면 「새 알림이 없어요」가 아니라 실패라고 말한다', (tester) async {
      NotificationService.client = MockClient((_) async => json({}, 503));
      await pumpInbox(tester, UserRole.AUDITOR);
      expect(find.text('알림을 불러오지 못했어요.'), findsOneWidget);
      expect(find.text('새 알림이 없어요.'), findsNothing);
    });

    testWidgets('빈 목록이면 「새 알림이 없어요」', (tester) async {
      NotificationService.client = MockClient((_) async => json([]));
      await pumpInbox(tester, UserRole.AUDITOR);
      expect(find.text('새 알림이 없어요.'), findsOneWidget);
    });

    testWidgets('종류·재알림 횟수·본문을 보여 준다', (tester) async {
      NotificationService.client = MockClient((_) async => json([item(1, 'ENTRY_REGISTERED', remind: 2)]));
      await pumpInbox(tester, UserRole.AUDITOR);
      expect(find.text('승인 필요'), findsOneWidget);
      expect(find.text('재알림 2회'), findsOneWidget);
      expect(find.text('알림 본문 1'), findsOneWidget);
    });

    testWidgets('등록 알림을 누르면 읽음 처리하고 승인 대기로 간다', (tester) async {
      final reads = <String>[];
      NotificationService.client = MockClient((req) async {
        if (req.method == 'POST') {
          reads.add(req.url.path);
          return json({'id': 1, 'read_at': 1793552400});
        }
        return json([item(1, 'ENTRY_REGISTERED')]);
      });
      await pumpInbox(tester, UserRole.AUDITOR);
      await tester.tap(find.byKey(const Key('notification_1')));
      await tester.pumpAndSettle();
      expect(reads, ['/notifications/1/read']);
      expect(find.byType(ApprovalListScreen), findsOneWidget);
    });

    testWidgets('이미 읽은 알림은 읽음 처리를 다시 보내지 않는다', (tester) async {
      var posts = 0;
      NotificationService.client = MockClient((req) async {
        if (req.method == 'POST') posts++;
        return json([item(1, 'ENTRY_CONFIRMED', readAt: 1793550000)]);
      });
      await pumpInbox(tester, UserRole.TREASURER);
      await tester.tap(find.byKey(const Key('notification_1')));
      await tester.pumpAndSettle();
      expect(posts, 0);
    });

    testWidgets('열려 있는 동안 15초마다 다시 읽는다', (tester) async {
      var gets = 0;
      NotificationService.client = MockClient((_) async {
        gets++;
        return json([]);
      });
      await pumpInbox(tester, UserRole.AUDITOR);
      expect(gets, 1);
      await tester.pump(NotificationService.pollInterval);
      await tester.pump();
      expect(gets, 2);
    });

    test('누르면 갈 곳 — 역할마다 다르다', () {
      const registered = AppNotification(id: 1, kind: 'ENTRY_REGISTERED', body: '', createdAt: 0, notifiedAt: 0);
      const confirmed = AppNotification(id: 2, kind: 'ENTRY_CONFIRMED', body: '', createdAt: 0, notifiedAt: 0);
      expect(notificationDestination(registered, UserRole.AUDITOR), isA<ApprovalListScreen>());
      expect(notificationDestination(registered, UserRole.TREASURER), isNull);
      expect(notificationDestination(confirmed, UserRole.TREASURER), isNotNull);
      expect(notificationDestination(confirmed, UserRole.AUDITOR), isNull);
    });

    test('알린 시각 표시', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1793548800 * 1000);
      expect(notificationAge(1793548800, now: now), '방금');
      expect(notificationAge(1793548800 - 5 * 60, now: now), '5분 전');
      expect(notificationAge(1793548800 - 3 * 3600, now: now), '3시간 전');
      expect(notificationAge(1793548800 - 2 * 86400, now: now), '2일 전');
    });
  });

  group('홈 알림 뱃지', () {
    Future<void> pumpHome(WidgetTester tester) async {
      ApiService.client = MockClient((_) async => json([]));
      await tester.pumpWidget(const MaterialApp(home: CouncilHomeScreen(role: UserRole.AUDITOR)));
      await tester.pumpAndSettle();
    }

    Badge badge(WidgetTester tester) => tester.widget<Badge>(find.byKey(const Key('notification_unread_badge')));

    testWidgets('안 읽은 수를 뱃지로 보여 준다', (tester) async {
      NotificationService.client = MockClient((_) async => json({'count': 3}));
      await pumpHome(tester);
      expect(badge(tester).isLabelVisible, isTrue);
      expect(find.descendant(of: find.byKey(const Key('notification_unread_badge')), matching: find.text('3')), findsOneWidget);
    });

    testWidgets('못 읽으면 숫자를 지어내지 않는다', (tester) async {
      NotificationService.client = MockClient((_) async => json({}, 503));
      await pumpHome(tester);
      expect(badge(tester).isLabelVisible, isFalse);
    });

    testWidgets('홈이 열려 있는 동안 15초마다 다시 읽는다', (tester) async {
      var calls = 0;
      NotificationService.client = MockClient((_) async => json({'count': ++calls}));
      await pumpHome(tester);
      expect(calls, 1);
      await tester.pump(NotificationService.pollInterval);
      await tester.pump();
      expect(calls, 2);
      expect(find.descendant(of: find.byKey(const Key('notification_unread_badge')), matching: find.text('2')), findsOneWidget);
    });

    testWidgets('종을 누르면 알림함으로 간다', (tester) async {
      NotificationService.client = MockClient((req) async =>
          req.url.path.endsWith('unread-count') ? json({'count': 0}) : json([]));
      await pumpHome(tester);
      await tester.tap(find.byKey(const Key('notification_bell')));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationInboxScreen), findsOneWidget);
    });
  });
}
