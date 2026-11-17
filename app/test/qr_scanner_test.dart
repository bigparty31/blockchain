import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/models/event_model.dart';
import 'package:student_council_app/screens/council/qr_scanner_screen.dart';
import 'package:student_council_app/services/api_service.dart';
import 'package:student_council_app/services/event_service.dart';

import 'support/session.dart';

/// QR 스캐너 (A12) — docs/API.md 「행사·입장」.
///
/// 입장 판정 다섯 가지는 모두 200 이다. 앱은 판정을 바꾸지 않고 그대로 보여 준다.
/// 특히 UNVERIFIABLE 은 미납이 아니다 — 「회원권 없음」으로 보이면 안 된다.
void main() {
  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

  const terms = [
    {'id': 7, 'term_code': 20262},
    {'id': 3, 'term_code': 20261},
  ];
  const festival = {'id': 11, 'term_id': 7, 'name': '해오름제', 'held_at': '2026-11-20T09:00:00Z'};

  Map<String, Object?> outcome(String result, {String? at}) => {
        'result': result,
        'event_id': 11,
        'user_id': result == 'UNKNOWN_STUDENT' ? null : 3,
        'student_no': result == 'UNKNOWN_STUDENT' ? null : '20240003',
        'name': result == 'UNKNOWN_STUDENT' ? null : '김학생',
        'checked_in_at': at,
      };

  late List<http.Request> requests;

  /// [checkIn] 이 입장 요청마다 돌려줄 응답을 정한다.
  void serve({List<Map<String, Object?>> events = const [festival], required http.Response Function() checkIn}) {
    requests = [];
    EventService.client = MockClient((req) async {
      requests.add(req);
      if (req.url.path == '/terms') return json(terms);
      if (req.url.path == '/events' && req.method == 'GET') return json(events);
      if (req.url.path == '/events' && req.method == 'POST') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        return json({'id': 12, 'term_id': body['term_id'], 'name': body['name'], 'held_at': body['held_at']}, 201);
      }
      if (req.url.path == '/events/11/check-in' || req.url.path == '/events/12/check-in') return checkIn();
      return json({}, 404);
    });
  }

  List<http.Request> checkIns() => [for (final r in requests) if (r.url.path.endsWith('/check-in')) r];

  setUp(() => signInAs(UserRole.AUDITOR));
  tearDown(() async {
    EventService.client = http.Client();
    await signOutForTest();
  });

  group('isStudentQr — 서버 parse_qr 와 같은 모양만', () {
    test('학생 회원권 QR', () {
      expect(isStudentQr('SCA:2026-2:U000003'), isTrue);
      expect(isStudentQr('  SCA:2026-2:U3\n'), isTrue, reason: '앞뒤 공백은 서버처럼 무시');
    });
    test('다른 QR 은 거른다', () {
      for (final s in ['', 'https://example.com', 'SCA:2026-2:3', 'SCA:2026-2:U', 'SCA::U1', 'SCA:2026-2:U1234567890123', 'sca:2026-2:U1']) {
        expect(isStudentQr(s), isFalse, reason: s);
      }
    });
  });

  group('EventService', () {
    test('termId 는 현재 학기 코드의 id 를 쓴다 (학기 코드 ≠ id)', () async {
      serve(checkIn: () => json({}));
      expect(await EventService().termId(), 7);
    });

    test('현재 학기가 없으면 다른 학기를 대신 쓰지 않는다', () async {
      serve(checkIn: () => json({}));
      expect(() => EventService(termCode: 20271).termId(), throwsA(isA<ApiUnavailable>()));
    });

    test('행사 등록은 이름을 다듬고 시각을 UTC 로 보낸다', () async {
      serve(checkIn: () => json({}));
      final heldAt = DateTime.parse('2026-11-20T18:00:00+09:00');
      final e = await EventService().create(termId: 7, name: '  해오름제  ', heldAt: heldAt);
      final body = jsonDecode(requests.last.body) as Map<String, dynamic>;
      expect(body, {'term_id': 7, 'name': '해오름제', 'held_at': '2026-11-20T09:00:00.000Z'});
      expect(e.id, 12);
      expect(e.heldAt.isAtSameMomentAs(heldAt), isTrue);
    });

    test('빈 이름·100자 초과는 보내지 않는다', () async {
      serve(checkIn: () => json({}));
      final t = DateTime.utc(2026, 11, 20);
      expect(() => EventService().create(termId: 7, name: '   ', heldAt: t), throwsA(isA<EventActionFailed>()));
      expect(() => EventService().create(termId: 7, name: 'x' * 101, heldAt: t), throwsA(isA<EventActionFailed>()));
      expect(requests, isEmpty);
    });

    test('입장 판정 다섯 가지를 그대로 읽는다', () async {
      for (final r in CheckInResult.values) {
        serve(checkIn: () => json(outcome(r.code, at: '2026-11-20T09:05:00Z')));
        final o = await EventService().checkIn(eventId: 11, payload: 'SCA:2026-2:U000003');
        expect(o.result, r);
      }
      expect(jsonDecode(checkIns().single.body), {'qr_payload': 'SCA:2026-2:U000003'});
    });

    test('학생 QR 이 아니면 서버에 보내지 않는다', () async {
      serve(checkIn: () => json(outcome('ADMITTED')));
      expect(() => EventService().checkIn(eventId: 11, payload: 'https://example.com'), throwsA(isA<EventActionFailed>()));
      expect(requests, isEmpty);
    });

    test('모르는 판정·DB 오류·403 은 입장으로 보지 않는다', () async {
      serve(checkIn: () => json(outcome('MAYBE')));
      await expectLater(EventService().checkIn(eventId: 11, payload: 'SCA:2026-2:U3'), throwsA(isA<EventActionFailed>()));
      serve(checkIn: () => json({'detail': 'db'}, 503));
      await expectLater(EventService().checkIn(eventId: 11, payload: 'SCA:2026-2:U3'), throwsA(isA<EventActionFailed>()));
      serve(checkIn: () => json({'detail': 'officer only'}, 403));
      await expectLater(EventService().checkIn(eventId: 11, payload: 'SCA:2026-2:U3'), throwsA(isA<ApiForbidden>()));
    });
  });

  group('QrScannerScreen', () {
    /// 카메라 대신 — 누르면 [payload] 를 읽은 것처럼 넘긴다.
    QrScannerBuilder fakeCamera(String payload) => (context, onCode) => Center(
          child: ElevatedButton(onPressed: () => onCode(payload), child: const Text('QR 비추기')),
        );

    Future<void> open(WidgetTester tester, {String payload = 'SCA:2026-2:U000003'}) async {
      tester.view.physicalSize = const Size(411, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: QrScannerScreen(scanner: fakeCamera(payload))));
      await tester.pumpAndSettle();
    }

    Future<void> pickFestival(WidgetTester tester) async {
      await tester.tap(find.text('해오름제'));
      await tester.pumpAndSettle();
    }

    Future<void> scan(WidgetTester tester) async {
      await tester.tap(find.text('QR 비추기'));
      await tester.pumpAndSettle();
    }

    testWidgets('행사 목록은 KST 로 보이고, 고르면 스캐너가 열린다', (tester) async {
      serve(checkIn: () => json(outcome('ADMITTED')));
      await open(tester);
      expect(find.text('2026-11-20 18:00'), findsOneWidget, reason: '09:00Z = 18:00 KST');
      await pickFestival(tester);
      expect(find.text('QR 비추기'), findsOneWidget);
      expect(find.text('이번에 입장 0명'), findsOneWidget);
    });

    testWidgets('입장: 이름·학번을 크게 보이고 입장 수를 센다', (tester) async {
      serve(checkIn: () => json(outcome('ADMITTED', at: '2026-11-20T09:05:00Z')));
      await open(tester);
      await pickFestival(tester);
      await scan(tester);
      expect(find.text('입장 확인'), findsOneWidget);
      expect(find.text('김학생 · 20240003'), findsOneWidget);
      expect(find.text('이번에 입장 1명'), findsOneWidget);
    });

    testWidgets('카메라가 같은 QR 을 계속 읽어도 한 번만 보낸다. 「다음 학생」 뒤에는 다시 보낸다', (tester) async {
      serve(checkIn: () => json(outcome('ADMITTED')));
      await open(tester);
      await pickFestival(tester);
      await scan(tester);
      await scan(tester);
      await scan(tester);
      expect(checkIns(), hasLength(1));
      await tester.tap(find.text('다음 학생'));
      await tester.pumpAndSettle();
      await scan(tester);
      expect(checkIns(), hasLength(2));
    });

    testWidgets('이미 입장: 처음 입장 시각(KST)을 보이고, 입장 수는 늘지 않는다', (tester) async {
      serve(checkIn: () => json(outcome('ALREADY_CHECKED_IN', at: '2026-11-20T09:05:00Z')));
      await open(tester);
      await pickFestival(tester);
      await scan(tester);
      expect(find.text('이미 입장했어요'), findsOneWidget);
      expect(find.text('처음 입장: 2026-11-20 18:05'), findsOneWidget);
      expect(find.text('이번에 입장 0명'), findsOneWidget);
    });

    testWidgets('회원권 없음·없는 학생은 거부로 보인다', (tester) async {
      serve(checkIn: () => json(outcome('NOT_MEMBER')));
      await open(tester);
      await pickFestival(tester);
      await scan(tester);
      expect(find.text('회원권이 없어요'), findsOneWidget);

      serve(checkIn: () => json(outcome('UNKNOWN_STUDENT')));
      await tester.tap(find.text('다음 학생'));
      await tester.pumpAndSettle();
      await scan(tester);
      expect(find.text('등록되지 않은 학생이에요'), findsOneWidget);
    });

    testWidgets('확인 불가는 미납으로 보이지 않고, 「다시 확인」으로 같은 QR 을 다시 보낸다', (tester) async {
      var replies = [outcome('UNVERIFIABLE'), outcome('ADMITTED')];
      serve(checkIn: () => json(replies.removeAt(0)));
      await open(tester);
      await pickFestival(tester);
      await scan(tester);
      expect(find.text('회원권을 확인하지 못했어요'), findsOneWidget);
      expect(find.text('회원권이 없어요'), findsNothing);
      await tester.tap(find.text('다시 확인'));
      await tester.pumpAndSettle();
      expect(find.text('입장 확인'), findsOneWidget);
      expect(checkIns(), hasLength(2));
    });

    testWidgets('서버 오류는 판정이 아니라 「확인하지 못했어요」로 보인다', (tester) async {
      serve(checkIn: () => json({'detail': 'db'}, 503));
      await open(tester);
      await pickFestival(tester);
      await scan(tester);
      expect(find.text('확인하지 못했어요'), findsOneWidget);
      expect(find.text('다시 확인'), findsOneWidget);
      expect(find.text('입장 확인'), findsNothing);
    });

    testWidgets('학생 QR 이 아니면 서버에 보내지 않는다', (tester) async {
      serve(checkIn: () => json(outcome('ADMITTED')));
      await open(tester, payload: 'https://example.com/receipt');
      await pickFestival(tester);
      await scan(tester);
      expect(find.text('학생 회원권 QR 이 아니에요'), findsOneWidget);
      expect(checkIns(), isEmpty);
    });

    testWidgets('카메라를 못 쓰면 QR 문자열을 직접 넣어도 된다', (tester) async {
      serve(checkIn: () => json(outcome('ADMITTED')));
      await open(tester);
      await pickFestival(tester);
      await tester.enterText(find.byKey(const Key('manual_qr')), 'SCA:2026-2:U000003');
      await tester.tap(find.widgetWithText(OutlinedButton, '확인'));
      await tester.pumpAndSettle();
      expect(find.text('입장 확인'), findsOneWidget);
      expect(jsonDecode(checkIns().single.body), {'qr_payload': 'SCA:2026-2:U000003'});
    });

    testWidgets('행사가 없으면 추가해서 바로 스캔한다', (tester) async {
      serve(events: const [], checkIn: () => json(outcome('ADMITTED')));
      await open(tester);
      expect(find.textContaining('행사가 아직 없어요'), findsOneWidget);
      await tester.tap(find.text('행사 추가'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('event_name')), '총회');
      await tester.tap(find.text('추가'));
      await tester.pumpAndSettle();
      expect(find.text('총회'), findsOneWidget, reason: '앱바 제목');
      expect(find.text('QR 비추기'), findsOneWidget);
    });

    testWidgets('학기 정보를 못 받으면 알리고 다시 불러올 수 있다', (tester) async {
      requests = [];
      EventService.client = MockClient((req) async => json({}, 503));
      await open(tester);
      expect(find.text('다시 불러오기'), findsOneWidget);
    });
  });
}
