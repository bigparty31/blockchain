import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/screens/council/council_home_screen.dart';
import 'package:student_council_app/services/api_service.dart';

/// 총무·감사 홈의 승인 대기 건수.
///
/// 전에는 `'대기 3건'` 이 문자열 상수였다 — 0건이어도, 10건이어도 3건이라고
/// 말했다. 지어낸 숫자를 다시 만들지 않는 것이 이 테스트의 목적이다.
///
/// **0 건과 「모름」을 반드시 다르게 적는다.** 못 읽은 것을 「대기 없음」으로
/// 내리면, 승인을 기다리는 지출이 있는데도 감사가 할 일이 없다고 읽고 넘어간다.
void main() {
  /// `GET /entries` 응답을 만든다. status 가 null 이면 초안이다.
  String entriesJson(List<String?> statuses) {
    return jsonEncode([
      for (var i = 0; i < statuses.length; i++)
        {
          'id': i + 1,
          'term_id': 1,
          'kind': 'EXPENSE',
          'amount': 1000,
          'counterparty': '가게',
          'purpose': '구매',
          'occurred_at': 1788793200,
          'meta_hash': '0x00',
          'status': statuses[i],
          'created_by': 2,
        }
    ]);
  }

  /// **charset 을 반드시 붙인다.** 빼면 `http.Response` 가 본문을 latin1 로
  /// 인코딩하려다 한글('가게')에서 던지고, 조회가 실패로 보여 배지가 「확인 불가」가 된다.
  http.Response jsonResponse(String body, [int status = 200]) => http.Response(
        body,
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  MockClient entriesServer(String body, {int status = 200}) {
    return MockClient((req) async => jsonResponse(body, status));
  }

  tearDown(() {
    ApiService.client = http.Client();
  });

  group('fetchPendingCount', () {
    test('PENDING 만 센다', () async {
      ApiService.client = entriesServer(
        entriesJson(['PENDING', 'CONFIRMED', 'PENDING', 'REJECTED', 'BLOCKED']),
      );
      expect(await ApiService().fetchPendingCount(), 2);
    });

    test('0 건이면 0 이다 — null 이 아니다', () async {
      ApiService.client = entriesServer(entriesJson(['CONFIRMED', 'REJECTED']));
      expect(await ApiService().fetchPendingCount(), 0);
    });

    test('초안(status null)은 세지 않는다', () async {
      // 총무가 저장만 하고 체인에 올리지 않은 건은 승인 대상이 아니다.
      ApiService.client = entriesServer(entriesJson([null, null, 'PENDING']));
      expect(await ApiService().fetchPendingCount(), 1);
    });

    test('모르는 status 한 건 때문에 건수를 잃지 않는다', () async {
      ApiService.client = entriesServer(entriesJson(['PENDING', 'NOPE', 'PENDING']));
      expect(await ApiService().fetchPendingCount(), 2);
    });

    test('서버가 200 이 아니면 null — 0 으로 내리지 않는다', () async {
      ApiService.client = entriesServer('{}', status: 500);
      expect(await ApiService().fetchPendingCount(), isNull);
    });

    test('서버에 닿지 못하면 null — 더미를 세지 않는다', () async {
      // fetchEntries 의 더미에는 PENDING 이 한 건 있다. 그것을 세면 서버가
      // 꺼져 있을 때 「대기 1건」이 뜬다 — 고치려던 하드코딩과 같은 종류다.
      ApiService.client = MockClient((_) async => throw http.ClientException('연결 실패'));
      expect(await ApiService().fetchPendingCount(), isNull);
    });

    test('목록이 아닌 응답은 null', () async {
      ApiService.client = entriesServer('{"detail":"nope"}');
      expect(await ApiService().fetchPendingCount(), isNull);
    });
  });

  group('감사 홈 배지', () {
    Future<void> pumpHome(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: CouncilHomeScreen(role: UserRole.AUDITOR)),
      );
    }

    String badgeText(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('approval_pending_badge'))).data!;

    testWidgets('읽는 중에는 숫자를 지어내지 않는다', (tester) async {
      final gate = Completer<void>();
      ApiService.client = MockClient((_) async {
        await gate.future;
        return jsonResponse(entriesJson(['PENDING']));
      });

      await pumpHome(tester);
      await tester.pump();
      expect(badgeText(tester), '확인 중');

      gate.complete();
      await tester.pumpAndSettle();
      expect(badgeText(tester), '대기 1건');
    });

    testWidgets('서버 건수를 그대로 보여준다', (tester) async {
      ApiService.client = entriesServer(
        entriesJson(['PENDING', 'PENDING', 'PENDING', 'PENDING', 'CONFIRMED']),
      );
      await pumpHome(tester);
      await tester.pumpAndSettle();

      expect(badgeText(tester), '대기 4건');
      // 하드코딩이 돌아오면 이 단정이 잡는다.
      expect(find.text('대기 3건'), findsNothing);
    });

    testWidgets('0 건이면 「대기 없음」', (tester) async {
      ApiService.client = entriesServer(entriesJson(['CONFIRMED']));
      await pumpHome(tester);
      await tester.pumpAndSettle();
      expect(badgeText(tester), '대기 없음');
    });

    testWidgets('조회 실패는 「확인 불가」 — 「대기 없음」이 아니다', (tester) async {
      ApiService.client = MockClient((_) async => throw http.ClientException('연결 실패'));
      await pumpHome(tester);
      await tester.pumpAndSettle();

      expect(badgeText(tester), '확인 불가');
      expect(
        badgeText(tester),
        isNot('대기 없음'),
        reason: '못 읽은 것을 0 건으로 적으면 감사가 할 일이 없다고 읽는다',
      );
    });

    testWidgets('새로고침을 누르면 다시 읽는다', (tester) async {
      var calls = 0;
      // 승인이 하나 처리돼 2건 → 1건이 된 상황.
      ApiService.client = MockClient((_) async {
        calls++;
        final statuses = calls == 1 ? ['PENDING', 'PENDING'] : ['PENDING', 'CONFIRMED'];
        return jsonResponse(entriesJson(statuses));
      });

      await pumpHome(tester);
      await tester.pumpAndSettle();
      expect(badgeText(tester), '대기 2건');

      await tester.tap(find.byKey(const Key('council_refresh')));
      await tester.pumpAndSettle();

      expect(calls, 2);
      expect(badgeText(tester), '대기 1건');
    });

    testWidgets('총무 홈에는 승인 배지가 없다', (tester) async {
      ApiService.client = entriesServer(entriesJson(['PENDING']));
      await tester.pumpWidget(
        const MaterialApp(home: CouncilHomeScreen(role: UserRole.TREASURER)),
      );
      await tester.pumpAndSettle();

      // 승인은 감사·회장의 일이다 (등록자 ≠ 승인자).
      expect(find.byKey(const Key('approval_pending_badge')), findsNothing);
    });
  });
}
