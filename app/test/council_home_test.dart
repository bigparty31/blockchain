import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/screens/council/my_entries_screen.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/screens/council/council_home_screen.dart';
import 'package:student_council_app/screens/council/inquiry_response_screen.dart';
import 'package:student_council_app/screens/president/budget_plan_screen.dart';
import 'package:student_council_app/services/api_service.dart';
import 'package:student_council_app/services/notification_service.dart';

import 'support/session.dart';

/// 역할별 홈(스토리보드 0). 로그인은 `login_screen_test.dart` 가 본다.
///
/// 기록을 만드는 사람과 확정하는 사람을 화면에서 가른다 — 총무 홈에는 승인·이의 답변이 없고,
/// 감사·회장 홈에는 등록 메뉴가 없다. 승인 대기 건수 배지의 네 상태는 `council_pending_count_test.dart` 가 본다.
void main() {
  // 목업 화면 테스트 — 서버 없이 시연용 더미로 돈다. 실패 표시는 api_unavailable_test.dart 가 본다 (PRD v0.14 §7.3).
  setUp(() => ApiService.useDemoData = true);

  /// 승인 대기 [pending] 건이 담긴 `GET /entries` 응답.
  http.Response entriesReply(int pending) => http.Response(
        jsonEncode([
          for (var i = 0; i < pending; i++)
            {
              'id': i + 1, 'term_id': 1, 'kind': 'EXPENSE', 'amount': 1000, 'counterparty': '가게',
              'purpose': '구매', 'occurred_at': 1788793200, 'meta_hash': '0x00', 'status': 'PENDING', 'created_by': 2,
            }
        ]),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  /// 승인 대기 [pending] 건이 있는 `GET /entries` 서버.
  void serveEntries(int pending) {
    ApiService.client = MockClient((_) async => entriesReply(pending));
  }

  tearDown(() => ApiService.client = http.Client());

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(411, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: home));
    await tester.pumpAndSettle();
  }

  group('역할별 홈', () {
    testWidgets('총무 홈에는 등록·정정·개정 요청이 있고 승인·이의 답변은 없다', (tester) async {
      await pump(tester, const CouncilHomeScreen(role: UserRole.TREASURER));

      for (final t in ['내 등록 현황', '정정 등록', '예산 개정 요청', '내 등록 건']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.text('지출 등록'), findsNWidgets(2), reason: '빠른 실행 + 메뉴');
      expect(find.text('승인 대기'), findsNothing);
      expect(find.text('이의 답변'), findsNothing);
      expect(find.textContaining('미답변 이의'), findsNothing);
    });

    testWidgets('총무 홈은 보여 주지 않는 승인 대기 건수를 읽지 않는다 — 15초마다 내역 전체를 받지 않게', (tester) async {
      await signInAs(UserRole.TREASURER, userId: 2);
      addTearDown(signOutForTest);
      var entryRequests = 0;
      ApiService.client = MockClient((req) async {
        if (req.url.path != '/entries') return http.Response('{}', 503);
        entryRequests++;
        return http.Response('[]', 200, headers: {'content-type': 'application/json; charset=utf-8'});
      });
      await pump(tester, const CouncilHomeScreen(role: UserRole.TREASURER));
      expect(entryRequests, 1, reason: '내 등록 현황만 내역을 읽는다');

      final refresh = find.byKey(const Key('council_refresh'));
      expect(tester.widget<IconButton>(refresh).onPressed, isNotNull, reason: '새로고침이 「읽는 중」에 묶이지 않는다');

      await tester.pump(const Duration(seconds: 16)); // 15초 폴링 한 번
      await tester.pumpAndSettle();
      expect(entryRequests, 1, reason: '15초 폴링은 내역을 읽지 않는다');

      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(entryRequests, 2, reason: '새로고침은 내 등록 현황을 다시 읽는다 — 승인 대기 건수는 여전히 읽지 않는다');
    });

    testWidgets('읽기가 겹치면 마지막에 보낸 것만 반영한다 — 늦게 온 옛 응답이 새 숫자를 덮지 않게', (tester) async {
      final entries = <Completer<http.Response>>[];
      final unread = <Completer<http.Response>>[];
      ApiService.client = MockClient((req) {
        if (req.url.path != '/entries') return Future.value(http.Response('{}', 503));
        return (entries..add(Completer())).last.future;
      });
      NotificationService.client = MockClient((_) => (unread..add(Completer())).last.future);
      addTearDown(() => NotificationService.client = http.Client());
      http.Response unreadReply(int n) =>
          http.Response(jsonEncode({'count': n}), 200, headers: {'content-type': 'application/json'});
      Finder badgeText(String n) =>
          find.descendant(of: find.byKey(const Key('notification_unread_badge')), matching: find.text(n));

      tester.view.physicalSize = const Size(411, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: CouncilHomeScreen(role: UserRole.AUDITOR)));
      await tester.pump();
      entries[0].complete(entriesReply(1));
      unread[0].complete(unreadReply(1));
      await tester.pumpAndSettle();
      expect(find.text('대기 1건'), findsOneWidget);

      // 15초 폴링(B)이 나간 직후 새로고침(C)을 누른다 — 두 읽기가 겹친다.
      await tester.pump(NotificationService.pollInterval);
      await tester.tap(find.byKey(const Key('council_refresh')));
      await tester.pump();
      expect(entries, hasLength(3));
      expect(unread, hasLength(3));

      // 나중에 보낸 C 가 먼저 오고, 먼저 보낸 B 가 늦게 온다.
      entries[2].complete(entriesReply(2));
      unread[2].complete(unreadReply(2));
      await tester.pumpAndSettle();
      expect(find.text('대기 2건'), findsOneWidget);
      entries[1].complete(entriesReply(5));
      unread[1].complete(unreadReply(5));
      await tester.pumpAndSettle();

      expect(find.text('대기 2건'), findsOneWidget);
      expect(find.text('대기 5건'), findsNothing);
      expect(badgeText('2'), findsOneWidget);
      expect(badgeText('5'), findsNothing);
    });

    testWidgets('장부 잔액은 서버 값을 쓴다 — 고정 숫자를 두지 않는다', (tester) async {
      ApiService.client = MockClient((req) async => req.url.path == '/balance'
          ? http.Response(jsonEncode({'balance': 1234000, 'income': 2000000, 'expense': 766000}), 200,
              headers: {'content-type': 'application/json; charset=utf-8'})
          : http.Response('{}', 503));
      await pump(tester, const CouncilHomeScreen(role: UserRole.TREASURER));
      expect(find.text('₩ 1,234,000'), findsOneWidget);
      expect(find.text('₩ 2,000,000'), findsOneWidget);
      expect(find.text('₩ 766,000'), findsOneWidget);
      expect(find.text('₩ 4,965,000'), findsNothing);
    });

    testWidgets('내 등록 건은 로그인한 총무가 등록한 건만 센다 — GET /entries 는 전체 내역이다', (tester) async {
      await signInAs(UserRole.TREASURER, userId: 2);
      addTearDown(signOutForTest);
      Map<String, Object?> e(int id, int createdBy, String status) => {
            'id': id, 'term_id': 1, 'kind': 'EXPENSE', 'amount': 1000, 'counterparty': '가게', 'purpose': '구매',
            'occurred_at': 1788793200, 'meta_hash': '0x00', 'status': status, 'created_by': createdBy,
          };
      ApiService.client = MockClient((req) async => req.url.path == '/entries'
          ? http.Response(
              jsonEncode([
                e(1, 2, 'PENDING'), e(2, 2, 'REJECTED'), // 내 건
                e(3, 5, 'PENDING'), e(4, 5, 'PENDING'), e(5, 5, 'BLOCKED'), // 다른 총무의 건
              ]),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'})
          : http.Response('{}', 503));
      await pump(tester, const CouncilHomeScreen(role: UserRole.TREASURER));

      expect(find.text('대기 1'), findsOneWidget);
      expect(find.text('반려 1'), findsOneWidget);
      expect(find.text('차단 0'), findsOneWidget);
    });

    testWidgets('내 등록 건은 새로고침 때 다시 읽는다 — 첫 조회가 실패해도 서버가 돌아오면 회복한다', (tester) async {
      ApiService.useDemoData = false;
      await signInAs(UserRole.TREASURER, userId: 2);
      addTearDown(signOutForTest);
      var up = false;
      ApiService.client = MockClient((req) async => up && req.url.path == '/entries'
          ? entriesReply(1)
          : http.Response('{}', 503));
      await pump(tester, const CouncilHomeScreen(role: UserRole.TREASURER));
      expect(find.byKey(const Key('my_entry_status_failed')), findsOneWidget);
      expect(find.text('대기 -'), findsOneWidget);

      up = true;
      await tester.tap(find.byKey(const Key('council_refresh')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('my_entry_status_failed')), findsNothing);
      expect(find.text('대기 1'), findsOneWidget);
    });

    testWidgets('총무 홈은 내 등록 건을 상태별로 센다', (tester) async {
      await signInAs(UserRole.TREASURER, userId: 2);
      addTearDown(signOutForTest);
      await pump(tester, const CouncilHomeScreen(role: UserRole.TREASURER));
      // 서버가 없으면 예시 3건(모두 user 2 등록, 확정 2 · 대기 1)으로 센다
      expect(find.text('대기 1'), findsOneWidget);
      expect(find.text('반려 0'), findsOneWidget);
      expect(find.text('차단 0'), findsOneWidget);
    });

    void expectNoRegister(WidgetTester tester) {
      expect(find.text('지출 등록'), findsNothing);
      expect(find.text('수입 등록'), findsNothing);
      expect(find.textContaining('총무 전용'), findsNothing);
    }

    testWidgets('감사 홈에는 승인 대기·이의 답변·개정 승인·결산·QR 스캐너가 있고 등록 메뉴는 없다', (tester) async {
      serveEntries(6);
      await pump(tester, const CouncilHomeScreen(role: UserRole.AUDITOR));

      expect(find.text('승인 대기'), findsNWidgets(2), reason: '배너 + 메뉴');
      expect(find.text('대기 6건'), findsOneWidget);
      expect(find.text('미답변 이의 1건'), findsOneWidget);
      for (final t in ['이의 답변', '예산 개정 승인', '결산', 'QR 스캐너']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.text('예산 개정 서명'), findsNothing);
      expect(find.text('예산 편성·발행'), findsNothing, reason: '예산 편성·발행은 회장 서명');
      expect(find.textContaining('서명할 증액 요청'), findsNothing);
      expectNoRegister(tester);
    });

    testWidgets('회장 홈에는 서명할 증액 요청·이의 답변·개정 서명·예산 편성·발행이 있다 (PRD §4.5 · A4 · A8)', (tester) async {
      serveEntries(6);
      await pump(tester, const CouncilHomeScreen(role: UserRole.PRESIDENT));

      expect(find.text('승인 대기'), findsNWidgets(2), reason: '배너 + 메뉴');
      expect(find.text('대기 6건'), findsOneWidget);
      expect(find.text('서명할 증액 요청 1건'), findsOneWidget);
      expect(find.text('미답변 이의 1건'), findsOneWidget);
      for (final t in ['이의 답변', '예산 개정 서명', '예산 편성·발행', '결산', 'QR 스캐너']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.text('예산 개정 승인'), findsNothing);
      expectNoRegister(tester);
    });

    testWidgets('회장 홈의 예산 편성·발행은 예산 편성 화면으로 이어진다', (tester) async {
      await pump(tester, const CouncilHomeScreen(role: UserRole.PRESIDENT));
      await tester.ensureVisible(find.text('예산 편성·발행'));
      await tester.tap(find.text('예산 편성·발행'));
      await tester.pumpAndSettle();
      expect(find.byType(BudgetPlanScreen), findsOneWidget);
    });

    testWidgets('총무 홈의 내 등록 현황·예산 개정 요청은 화면으로 이어진다', (tester) async {
      await pump(tester, const CouncilHomeScreen(role: UserRole.TREASURER));
      await tester.ensureVisible(find.text('내 등록 현황'));
      await tester.tap(find.text('내 등록 현황'));
      await tester.pumpAndSettle();
      // 서버 목록을 읽는 화면 — 로그인 세션이 없는 테스트에서는 내 건을 찾을 수 없다고 알린다
      expect(find.byType(MyEntriesScreen), findsOneWidget);
      expect(find.byKey(const Key('my_entries_failed')), findsOneWidget);
    });

    testWidgets('감사 홈의 정정 승인은 화면으로 이어진다', (tester) async {
      await pump(tester, const CouncilHomeScreen(role: UserRole.AUDITOR));
      await tester.ensureVisible(find.text('정정 승인'));
      await tester.tap(find.text('정정 승인'));
      await tester.pumpAndSettle();
      expect(find.text('원본'), findsWidgets);
    });

    testWidgets('아직 만들지 않은 화면은 「준비 중」으로 안내한다', (tester) async {
      await pump(tester, const CouncilHomeScreen(role: UserRole.AUDITOR));
      await tester.ensureVisible(find.text('예산 개정 승인'));
      await tester.tap(find.text('예산 개정 승인'));
      await tester.pump();
      expect(find.text('예산 개정 승인 화면은 준비 중입니다.'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 3));
    });

    testWidgets('개발용 메뉴는 기본 빌드에 보이지 않는다', (tester) async {
      await pump(tester, const CouncilHomeScreen(role: UserRole.TREASURER));
      expect(find.textContaining('생체인증 테스트'), findsNothing);
      expect(find.text('실시간 연동'), findsNothing);
    });
  });

  test('미답변 경과일은 제기일부터 센다', () {
    expect(inquiryElapsedDays('2026-09-11', now: DateTime(2026, 9, 14)), 3);
    expect(inquiryElapsedDays('2026-09-11', now: DateTime(2026, 9, 11)), 0);
    expect(inquiryElapsedDays('2026-09-11', now: DateTime(2026, 9, 1)), 0, reason: '음수는 0');
    expect(inquiryElapsedDays('날짜 아님'), 0);
  });
}
