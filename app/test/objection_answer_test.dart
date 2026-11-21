import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/core/signing/eip712.dart';
import 'package:student_council_app/core/signing/objection_types.dart';
import 'package:student_council_app/core/signing/signing_service.dart';
import 'package:student_council_app/models/objection_model.dart';
import 'package:student_council_app/screens/council/inquiry_response_screen.dart';
import 'package:student_council_app/services/objection_answer_service.dart';
import 'package:student_council_app/services/signed_post.dart';

import 'support/objection_fake.dart';
import 'support/session.dart';

/// 임원 이의 답변 — 서명 구조체가 컨트랙트와 같은가, 서명 흐름이 docs/API.md 대로 나가는가,
/// 화면이 서버 목록을 보이고 답변을 기록하는가.
void main() {
  final domain = Eip712Domain.fromJson(const {
    'name': 'ObjectionRegistry',
    'version': '1',
    'chainId': 31337,
    'verifyingContract': '0x5FC8d32690cc91D4c39d9d3abcBD16989F875707',
    'domainSeparator': '0x416805697be1ff041a4ce947f9cbc23108bba4e7fde1ccf4ab4145ae330f9dfc',
  });

  group('AnswerRequest 서명값', () {
    test('백엔드(eth_account)가 같은 값으로 만든 EIP-712 다이제스트와 같다', () {
      final message = ObjectionTypes.answerRequest(
        objectionId: 1,
        answerHash: '0x0824cb64fa9655840f817533243f2ec42a4b15c6a67df984f5af774a4809f4a5',
        deadline: 1795269659,
      );
      final digest = Eip712.digest(domain, message);
      final hex = '0x${digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
      // 같은 도메인·값을 backend/app/chain/eip712.py 로 계산한 값 — 필드 이름·순서·타입이 컨트랙트와 같다는 근거
      expect(hex, '0x30b7e857c4d383952ad2481a21066a96c4d336f9c405d399308398e64ecc60f4');
    });

    test('체인이 되돌릴 값은 서명하기 전에 막는다', () {
      const hash = '0x0824cb64fa9655840f817533243f2ec42a4b15c6a67df984f5af774a4809f4a5';
      expect(() => ObjectionTypes.answerRequest(objectionId: 0, answerHash: hash, deadline: 1), throwsArgumentError);
      expect(() => ObjectionTypes.answerRequest(objectionId: 1, answerHash: '0x12', deadline: 1), throwsArgumentError);
      expect(() => ObjectionTypes.answerRequest(objectionId: 1, answerHash: hash, deadline: -1), throwsArgumentError);
    });
  });

  group('ObjectionAnswerService', () {
    const answer = '행사 물품 구매 영수증 기준 금액입니다.';
    final answerHash = Hashing.textHash(Hashing.canonicalText(answer));
    final objection = ObjectionModel(
      id: 3,
      entryId: 6,
      userId: 1,
      content: '이 지출이 궁금합니다.',
      status: ObjectionStatus.OPEN,
      raisedAt: 1795269058,
    );

    late List<http.Request> posts;
    late List<Eip712Message> signed;

    http.Response json(Object body, [int code = 200]) =>
        http.Response(jsonEncode(body), code, headers: {'content-type': 'application/json; charset=utf-8'});

    MockClient server({String? hashOverride, http.Response Function(http.Request req)? onAnswer}) {
      posts = [];
      return MockClient((req) async {
        if (req.method == 'POST') posts.add(req);
        if (req.url.path == '/objections/3/prepare-answer') {
          return json({
            'objection_id': 3,
            'answer_hash': hashOverride ?? answerHash,
            'deadline': 1795269659,
            'domain': {},
            'types': {},
            'message': {},
          });
        }
        if (req.url.path == '/objections/3/answer') {
          return onAnswer?.call(req) ??
              json({
                'id': 3,
                'entry_id': 6,
                'user_id': 1,
                'content': '이 지출이 궁금합니다.',
                'answer': answer,
                'answered_by': 3,
                'status': 'ANSWERED',
                'raised_at': 1795269058,
                'answered_at': 1795269100,
                'tx_raise': '0xaa',
                'tx_answer': '0xbb',
              });
        }
        if (req.url.path == '/objections') {
          return json([
            {
              'id': 3,
              'entry_id': 6,
              'user_id': 1,
              'content': '이 지출이 궁금합니다.',
              'status': 'OPEN',
              'raised_at': 1795269058,
            }
          ]);
        }
        return json({}, 404);
      });
    }

    ObjectionAnswerService service({Object? signError}) {
      signed = [];
      return ObjectionAnswerService(
        domain: () async => domain,
        sign: (d, m, {required reason}) async {
          if (signError != null) throw signError;
          expect(d, same(domain));
          signed.add(m);
          return '0xsig';
        },
      );
    }

    setUp(() async => signInAs(UserRole.AUDITOR, userId: 3));
    tearDown(() async {
      ObjectionAnswerService.client = http.Client();
      await signOutForTest();
    });

    test('서버 해시를 내 계산과 맞춘 뒤 서명하고, 서명과 함께 /answer 로 보낸다', () async {
      ObjectionAnswerService.client = server();
      final saved = await service().answer(objection, '  $answer');

      expect(signed, hasLength(1));
      expect(signed.single.primaryType, 'AnswerRequest');
      expect(signed.single.values['objectionId'], 3);
      expect(signed.single.values['answerHash'], answerHash);
      expect(posts.map((r) => r.url.path), ['/objections/3/prepare-answer', '/objections/3/answer']);
      final body = jsonDecode(posts.last.body) as Map<String, dynamic>;
      expect(body['signature'], '0xsig');
      expect(body['answer_hash'], answerHash);
      expect(body['deadline'], 1795269659);
      expect(saved.status, ObjectionStatus.ANSWERED);
      expect(saved.answer, answer);
    });

    test('서버가 준 해시가 내가 적은 답변의 해시와 다르면 서명하지 않는다', () async {
      ObjectionAnswerService.client = server(hashOverride: '0x${'ab' * 32}');
      await expectLater(
        service().answer(objection, answer),
        throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.mismatch)),
      );
      expect(signed, isEmpty, reason: '쓰지 않은 말의 해시에 임원이 서명하게 된다');
      expect(posts.map((r) => r.url.path), ['/objections/3/prepare-answer'], reason: '/answer 는 보내지 않았다');
    });

    test('빈 답변은 서버에도 가지 않는다', () async {
      ObjectionAnswerService.client = server();
      await expectLater(
        service().answer(objection, '   \n '),
        throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.invalidReason)),
      );
      expect(posts, isEmpty);
    });

    test('본인 확인을 취소하면 /answer 를 보내지 않는다', () async {
      ObjectionAnswerService.client = server();
      await expectLater(
        service(signError: const SigningException('본인 확인을 취소했어요.')).answer(objection, answer),
        throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.signing)),
      );
      expect(posts.map((r) => r.url.path), ['/objections/3/prepare-answer']);
    });

    test('서버가 답변을 거부하면(400) 서버 설명을 붙여 알린다', () async {
      ObjectionAnswerService.client = server(onAnswer: (_) => json({'detail': '이미 답변된 이의 제기입니다.'}, 400));
      await expectLater(
        service().answer(objection, answer),
        throwsA(isA<EntryDecisionException>()
            .having((e) => e.failure, 'failure', EntryDecisionFailure.refused)
            .having((e) => e.message, 'message', contains('이미 답변된'))),
      );
    });

    test('목록은 서버 응답을 모델로 읽는다', () async {
      ObjectionAnswerService.client = server();
      final list = await service().list();
      expect(list.single.id, 3);
      expect(list.single.status, ObjectionStatus.OPEN);
    });

    test('목록을 못 읽으면 예시로 메우지 않고 던진다', () async {
      ObjectionAnswerService.client = MockClient((_) async => json({}, 503));
      await expectLater(
        service().list(),
        throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.notReady)),
      );
    });
  });

  group('이의 답변 화면 (서버 연동)', () {
    Future<void> pumpScreen(WidgetTester tester, ObjectionAnswerApi api) async {
      tester.view.physicalSize = const Size(411, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: InquiryResponseScreen(api: api)));
      await tester.pumpAndSettle();
    }

    ObjectionModel open(int id, {String content = '질문입니다.'}) => ObjectionModel(
          id: id,
          entryId: 6,
          userId: 1,
          content: content,
          status: ObjectionStatus.OPEN,
          raisedAt: 1795269058,
        );

    testWidgets('서버 목록을 보이고, 답변하면 서버가 돌려준 값으로 완료가 된다', (tester) async {
      final api = FakeObjectionApi([open(3, content: '이 지출이 궁금합니다.')]);
      await pumpScreen(tester, api);

      expect(find.text('이 지출이 궁금합니다.'), findsOneWidget);
      expect(find.text('답변 대기'), findsWidgets);
      await tester.tap(find.text('답변 작성하기'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '영수증 기준 금액입니다.');
      await tester.tap(find.text('답변 등록'));
      await tester.pumpAndSettle();

      expect(api.answered, ['영수증 기준 금액입니다.']);
      expect(find.textContaining('답변이 등록되었습니다'), findsOneWidget);
      expect(find.text('답변 작성하기'), findsNothing, reason: '답변한 이의에는 다시 답변할 수 없다');
      expect(find.text('영수증 기준 금액입니다.'), findsOneWidget, reason: '서버가 돌려준 답변이 카드에 보인다');
    });

    testWidgets('서명이 거부되면 입력과 창을 그대로 두고 이유를 보인다', (tester) async {
      final api = FakeObjectionApi([open(3)])..answerError = const EntryDecisionException(EntryDecisionFailure.signing, '본인 확인을 취소했어요.');
      await pumpScreen(tester, api);
      await tester.tap(find.text('답변 작성하기'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '답변');
      await tester.tap(find.text('답변 등록'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('answer_error')), findsOneWidget);
      expect(find.text('본인 확인을 취소했어요.'), findsOneWidget);
      expect(find.text('답변 등록'), findsOneWidget, reason: '창이 열려 있어 다시 누를 수 있다');
      expect(find.text('답변이 등록되었습니다.'), findsNothing);
    });

    testWidgets('목록을 못 읽으면 예시 대신 이유와 다시 시도를 보이고, 다시 시도하면 불러온다', (tester) async {
      final api = FakeObjectionApi([open(3)])..listError = const EntryDecisionException(EntryDecisionFailure.notReady, '이의 목록을 불러오지 못했어요.');
      await pumpScreen(tester, api);

      expect(find.byKey(const Key('inquiry_load_error')), findsOneWidget);
      expect(find.text('답변 작성하기'), findsNothing);

      api.listError = null;
      await tester.tap(find.text('다시 시도'));
      await tester.pumpAndSettle();
      expect(find.text('답변 작성하기'), findsOneWidget);
    });

    testWidgets('이의가 없으면 빈 화면 안내를 보인다', (tester) async {
      await pumpScreen(tester, FakeObjectionApi([]));
      expect(find.text('해당 이의 내역이 없습니다'), findsOneWidget);
    });

    Future<void> openAndType(WidgetTester tester, String text) async {
      await tester.tap(find.text('답변 작성하기'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), text);
    }

    testWidgets('서명·기록 중에는 시스템 뒤로가기로도 창이 닫히지 않고, 끝나면 결과가 보인다', (tester) async {
      final api = FakeObjectionApi([open(3)])..gate = Completer<void>();
      await pumpScreen(tester, api);
      await openAndType(tester, '답변');
      await tester.tap(find.text('답변 등록'));
      await tester.pump();

      expect(find.text('서명·기록 중…'), findsOneWidget);
      final app = tester.state(find.byType(WidgetsApp)) as WidgetsBindingObserver;
      await app.didPopRoute(); // Android 뒤로가기
      await tester.pump();
      expect(find.text('서명·기록 중…'), findsOneWidget, reason: '뒤로가기로 닫히면 결과 메시지를 아무도 못 본다');

      api.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('서명·기록 중…'), findsNothing);
      expect(find.textContaining('답변이 등록되었습니다'), findsOneWidget);
    });

    testWidgets('결과를 모르는 실패인데 다시 읽어 보니 이미 기록돼 있으면 창을 닫는다', (tester) async {
      final api = FakeObjectionApi([open(3)])
        ..answerError = const EntryDecisionException(EntryDecisionFailure.unknownOutcome, '이의 답변 결과를 확인하지 못했어요.')
        ..recordBeforeError = true;
      await pumpScreen(tester, api);
      final before = api.listCalls;
      await openAndType(tester, '답변');
      await tester.tap(find.text('답변 등록'));
      await tester.pumpAndSettle();

      expect(api.listCalls, before + 1, reason: '목록을 새로 읽었다');
      expect(find.text('답변 등록'), findsNothing, reason: '이미 ANSWERED 라 다시 누를 수 없다(409 방지) — 창이 닫혔다');
      expect(find.textContaining('이미 기록되어 있어요'), findsOneWidget);
      expect(find.text('답변 작성하기'), findsNothing);
    });

    testWidgets('결과를 모르는 실패인데 아직 대기면 입력을 둔 채 이유를 보인다', (tester) async {
      final api = FakeObjectionApi([open(3)])
        ..answerError = const EntryDecisionException(EntryDecisionFailure.unknownOutcome, '이의 답변 결과를 확인하지 못했어요.');
      await pumpScreen(tester, api);
      await openAndType(tester, '답변');
      await tester.tap(find.text('답변 등록'));
      await tester.pumpAndSettle();

      expect(find.text('이의 답변 결과를 확인하지 못했어요.'), findsOneWidget);
      expect(find.text('답변 등록'), findsOneWidget, reason: '대기 그대로라 다시 보낼 수 있다');
    });

    testWidgets('로그인이 끝났으면(401) 목록을 다시 읽지 않고 창을 닫는다', (tester) async {
      final api = FakeObjectionApi([open(3)])
        ..answerError = const EntryDecisionException(EntryDecisionFailure.unauthorized, '로그인이 끝났어요. 다시 로그인해 주세요.');
      await pumpScreen(tester, api);
      final before = api.listCalls;
      await openAndType(tester, '답변');
      await tester.tap(find.text('답변 등록'));
      await tester.pumpAndSettle();

      expect(api.listCalls, before, reason: '세션이 없는데 다시 읽어 봐야 같은 401 이다');
      expect(find.text('답변 등록'), findsNothing);
      expect(find.textContaining('로그인이 끝났어요'), findsOneWidget);
    });

    testWidgets('답변은 5000자까지 — 넘으면 서버에 보내기 전에 알린다', (tester) async {
      final api = FakeObjectionApi([open(3)]);
      await pumpScreen(tester, api);
      await openAndType(tester, '가' * 5001);
      await tester.tap(find.text('답변 등록'));
      await tester.pumpAndSettle();
      expect(find.text('답변은 5000자까지 쓸 수 있어요'), findsOneWidget);
      expect(api.answered, isEmpty);

      await tester.enterText(find.byType(TextFormField), '가' * 5000);
      await tester.tap(find.text('답변 등록'));
      await tester.pumpAndSettle();
      expect(api.answered, hasLength(1), reason: '정확히 5000자는 보낸다');
    });
  });
}
