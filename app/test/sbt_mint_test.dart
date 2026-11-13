import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/roster_parser.dart';
import 'package:student_council_app/core/signing/eip712.dart';
import 'package:student_council_app/core/signing/sbt_types.dart';
import 'package:student_council_app/core/signing/signing_service.dart';
import 'package:student_council_app/models/sbt_mint_model.dart';
import 'package:student_council_app/screens/council/sbt_mint_screen.dart';
import 'package:student_council_app/services/sbt_mint_service.dart';
import 'package:web3dart/web3dart.dart' as web3 show sign;

import 'support/session.dart';

/// 회원권 일괄 발행 (A3) — 명단 읽기 · 응답 해석 · 준비→서명→제출 · 화면 흐름.
void main() {
  // signing_sbt_test 와 같은 도메인 (ethers 로 계산한 domainSeparator)
  final domain = Eip712Domain.fromJson(const {
    'name': 'MembershipSBT',
    'version': '1',
    'chainId': 31337,
    'verifyingContract': '0x5FbDB2315678afecb367f032d93F642f64180aa3',
    'domainSeparator': '0xd3c1b9a74f9f561108bd72b12aadd592342d9ca8407481a74fd0ed64526b6c9e',
  });

  // Hardhat #1 — 회장 지갑
  const presidentKey = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d';
  const president = '0x70997970c51812dc3a010c7d01b50e0d17dc79c8';
  // Hardhat #2 — 다른 키
  const otherKey = '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a';

  const alice = '0x90F79bf6EB2c4f870365E785982E1f101E93b906';
  const bob = '0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65';

  Future<String> Function(Eip712Domain, Eip712Message, {required String reason}) signerWith(String key) =>
      (d, m, {required reason}) async => SigningService.encodeSignature(web3.sign(Eip712.digest(d, m), Eip712.hexToBytes(key)));

  Map<String, dynamic> target(String no, String name, String address, {String status = 'PENDING', int? token, int? membership}) => {
        'student_no': no,
        'user_id': int.parse(no.substring(no.length - 2)),
        'name': name,
        'address': address,
        'status': status,
        'token_id': token,
        'membership_id': membership,
      };

  Map<String, dynamic> batchJson({
    int id = 7,
    String status = 'PREPARED',
    List<Map<String, dynamic>>? targets,
    List<String>? recipients,
    List<Map<String, dynamic>> excluded = const [],
    String? reason,
    int nonce = 3,
  }) {
    final t = targets ?? [target('20240011', '김하나', alice), target('20240012', '이두리', bob)];
    return {
      'id': id,
      'term_id': 1,
      'term_code': 20262,
      'status': status,
      'signer_address': president,
      'nonce': nonce,
      'recipients': recipients ?? [for (final x in t) x['address']],
      'deadline': null,
      'tx_hash': null,
      'reason': reason,
      'targets': t,
      'excluded': excluded,
      'message': 'ok',
    };
  }

  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

  group('명단 읽기', () {
    test('제목 줄에 학번 칸이 있으면 그 칸만 읽는다 — 납부일 8자리를 학번으로 오인하지 않는다', () {
      final r = RosterParser.parseText('이름,납부일,학번\n김하나,20261102,20240011\n이두리,20261103,20240012\n');
      expect(r.studentNos, ['20240011', '20240012']);
      expect(r.unreadLines, 0);
    });

    test('제목 줄이 없으면 줄마다 첫 숫자 칸 · 중복 제거 · 엑셀 표기·BOM 벗김', () {
      final r = RosterParser.parseText('﻿20240011\n="20240012"\n"20240011"\n안녕\n\n20240013\t김\n');
      expect(r.studentNos, ['20240011', '20240012', '20240013']);
      expect(r.duplicates, 1);
      expect(r.unreadLines, 1);
    });

    test('CP949 로 깨진 한글 제목 — 바이트로 읽어도 학번은 그대로 나온다', () {
      final bytes = [0xC7, 0xD0, 0xB9, 0xF8, 0x0A, ...utf8.encode('20240011\n20240012\n')];
      expect(RosterParser.parseBytes(bytes).studentNos, ['20240011', '20240012']);
    });

    test('student_no 영문 제목도 알아본다', () {
      expect(RosterParser.parseText('name;student_no\n김;20240011').studentNos, ['20240011']);
    });
  });

  group('응답 해석', () {
    test('정상 응답', () {
      final b = MintBatch.fromJson(batchJson(excluded: [
        {'student_no': '20240099', 'name': null, 'status': 'NOT_FOUND'},
      ]));
      expect(b.recipients, [alice, bob]);
      expect(b.status, MintBatchStatus.prepared);
      expect(b.excluded.single.reasonLabel, '등록되지 않은 학번');
    });

    test('targets 와 recipients 순서가 어긋나면 받지 않는다 — 본 것과 다른 것에 서명하게 된다', () {
      expect(() => MintBatch.fromJson(batchJson(recipients: [bob, alice])), throwsFormatException);
      expect(() => MintBatch.fromJson(batchJson(recipients: [alice])), throwsFormatException);
    });

    test('서명할 값을 기본값으로 메우지 않는다', () {
      for (final key in ['nonce', 'term_code', 'signer_address', 'recipients']) {
        final j = batchJson()..remove(key);
        expect(() => MintBatch.fromJson(j), throwsFormatException, reason: key);
      }
      expect(() => MintBatch.fromJson(batchJson(status: 'DONE')), throwsFormatException);
    });

    test('체인에는 들어갔지만 DB 기록이 없는 학생은 확인 필요로 본다', () {
      final b = MintBatch.fromJson(batchJson(status: 'MINTED', targets: [
        target('20240011', '김하나', alice, status: 'MINTED', token: 1, membership: 10),
        target('20240012', '이두리', bob, status: 'MINTED', token: 2),
      ]));
      expect(b.mintedCount, 2);
      expect([for (final t in b.targets) t.needsCheck], [false, true]);
    });
  });

  group('서비스', () {
    final now = DateTime.utc(2026, 11, 12, 9);
    late List<http.Request> sent;

    setUp(() async {
      await signInAs(UserRole.PRESIDENT);
      sent = [];
    });
    tearDown(() async {
      SbtMintService.client = http.Client();
      await signOutForTest();
    });

    SbtMintService service({String key = presidentKey}) =>
        SbtMintService(sign: signerWith(key), domain: () async => domain, now: () => now);

    test('서명은 받은 recipients 그대로, 서명자를 확인한 뒤 제출한다', () async {
      SbtMintService.client = MockClient((req) async {
        sent.add(req);
        return json(batchJson(status: 'MINTED', targets: [
          target('20240011', '김하나', alice, status: 'MINTED', token: 1, membership: 10),
          target('20240012', '이두리', bob, status: 'SKIPPED', token: 2, membership: 11),
        ]));
      });
      final result = await service().signAndSubmit(MintBatch.fromJson(batchJson()));
      expect(result.status, MintBatchStatus.minted);

      final req = sent.single;
      expect(req.url.path, '/memberships/mint-batches/7/submit');
      expect(req.headers['Authorization'], 'Bearer token-2');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final deadline = now.add(SbtMintService.signatureTtl).millisecondsSinceEpoch ~/ 1000;
      expect(body['deadline'], deadline);
      // 서버가 할 검산을 똑같이 해 본다: 이 값들로 만든 다이제스트에서 회장 주소가 나와야 한다
      // 순서·nonce·학기가 하나라도 다르면 다른 주소가 나온다
      final digest = Eip712.digest(
        domain,
        SbtTypes.mintBatchRequest(recipients: [alice, bob], term: 20262, nonce: 3, deadline: deadline),
      );
      expect(SigningService.recoverSigner(digest, body['signature'] as String), president);
    });

    test('다른 키로 서명했으면 보내지 않는다', () async {
      SbtMintService.client = MockClient((req) async {
        sent.add(req);
        return json(batchJson());
      });
      await expectLater(
        service(key: otherKey).signAndSubmit(MintBatch.fromJson(batchJson())),
        throwsA(isA<MintFailed>().having((e) => e.kind, 'kind', MintFailure.wrongKey)),
      );
      expect(sent, isEmpty);
    });

    test('도메인을 못 믿으면 서명하지 않는다', () async {
      var signed = false;
      final s = SbtMintService(
        sign: (d, m, {required reason}) async {
          signed = true;
          return '0x';
        },
        domain: () async => throw Exception('bad'),
      );
      await expectLater(s.signAndSubmit(MintBatch.fromJson(batchJson())),
          throwsA(isA<MintFailed>().having((e) => e.kind, 'kind', MintFailure.notReady)));
      expect(signed, isFalse);
    });

    test('제출 응답이 없으면 「결과 모름」 — 다시 보내라고 하지 않는다', () async {
      SbtMintService.client = MockClient((req) async => throw http.ClientException('끊김'));
      await expectLater(
        service().signAndSubmit(MintBatch.fromJson(batchJson())),
        throwsA(isA<MintFailed>().having((e) => e.kind, 'kind', MintFailure.unknownOutcome)),
      );
    });

    test('제출 5xx 는 결과 모름, 409 는 충돌, 403 은 권한', () async {
      for (final (code, kind) in [
        (500, MintFailure.unknownOutcome),
        (409, MintFailure.conflict),
        (403, MintFailure.forbidden),
        (503, MintFailure.unavailable),
      ]) {
        SbtMintService.client = MockClient((req) async => json({'detail': '이유'}, code));
        await expectLater(
          service().signAndSubmit(MintBatch.fromJson(batchJson())),
          throwsA(isA<MintFailed>().having((e) => e.kind, 'kind', kind)),
          reason: '$code',
        );
      }
    });

    test('준비 — 0명이면 학생별 제외 사유를 넘긴다', () async {
      SbtMintService.client = MockClient((req) async {
        sent.add(req);
        return json({
          'detail': {
            'message': '발행할 학생이 없습니다',
            'excluded': [
              {'student_no': '20240011', 'name': '김하나', 'status': 'ALREADY_MEMBER'},
            ],
          },
        }, 400);
      });
      await expectLater(
        service().prepare(termId: 1, studentNos: ['20240011']),
        throwsA(isA<MintFailed>()
            .having((e) => e.kind, 'kind', MintFailure.nobody)
            .having((e) => e.excluded.single.reasonLabel, 'reason', '이미 보유')),
      );
      expect(jsonDecode(sent.single.body), {'term_id': 1, 'student_nos': ['20240011']});
    });

    test('준비는 1~100명만 보낸다', () async {
      SbtMintService.client = MockClient((req) async {
        sent.add(req);
        return json(batchJson(), 201);
      });
      await expectLater(service().prepare(termId: 1, studentNos: const []), throwsA(isA<MintFailed>()));
      await expectLater(
          service().prepare(termId: 1, studentNos: [for (var i = 0; i < 101; i++) '${20240000 + i}']),
          throwsA(isA<MintFailed>()));
      expect(sent, isEmpty);
    });

    test('학기 id 는 현재 학기 코드로 찾고, 없으면 다른 학기를 쓰지 않는다', () async {
      SbtMintService.client = MockClient((req) async => json([
            {'id': 4, 'term_code': 20261},
            {'id': 5, 'term_code': 20262},
          ]));
      expect(await SbtMintService(termCode: 20262).termId(), 5);
      await expectLater(SbtMintService(termCode: 20271).termId(), throwsA(isA<MintFailed>()));
    });
  });

  group('화면', () {
    late List<String> calls;
    late Map<String, dynamic> Function() submitReply;

    setUp(() async {
      await signInAs(UserRole.PRESIDENT);
      calls = [];
      submitReply = () => batchJson(status: 'MINTED', targets: [
            target('20240011', '김하나', alice, status: 'MINTED', token: 1, membership: 10),
            target('20240012', '이두리', bob, status: 'MINTED', token: 2, membership: 11),
          ]);
      SbtMintService.client = MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        final p = req.url.path;
        if (p == '/terms') {
          return json([
            {'id': 1, 'term_code': 20262},
          ]);
        }
        if (p == '/memberships/mint-batches') return json(batchJson(), 201);
        if (p.endsWith('/submit')) return json(submitReply());
        if (p == '/memberships/mint-batches/7') return json(submitReply());
        return http.Response('{}', 404);
      });
    });
    tearDown(() async {
      SbtMintService.client = http.Client();
      await signOutForTest();
    });

    Widget app() => MaterialApp(
          home: SbtMintScreen(
            service: SbtMintService(
              sign: signerWith(presidentKey),
              domain: () async => domain,
            ),
            picker: () async => utf8.encode('학번,이름\n20240011,김하나\n20240012,이두리\n20240012,이두리\n'),
          ),
        );

    Future<void> tap(WidgetTester tester, String key) async {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    testWidgets('파일 → 준비 → 확인 → 서명·제출 → 결과', (tester) async {
      await tester.pumpWidget(app());
      await tap(tester, 'sbt_pick_file');
      expect(find.text('학번 2명 · 중복 1건 뺌'), findsOneWidget);

      await tap(tester, 'sbt_prepare');
      expect(find.text('김하나 · 20240011'), findsOneWidget);
      expect(find.textContaining('서명은 학번이 아니라'), findsOneWidget);

      // 취소하면 서명도 제출도 하지 않는다
      await tap(tester, 'sbt_sign');
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.endsWith('/submit')), isEmpty, reason: '취소했는데 보냈다');

      await tap(tester, 'sbt_sign');
      expect(find.textContaining('지갑 주소 2개'), findsOneWidget); // 확인 대화상자
      expect(calls.where((c) => c.endsWith('/submit')), isEmpty, reason: '확인 전에는 보내지 않는다');
      await tap(tester, 'sbt_confirm');

      expect(calls, ['GET /terms', 'POST /memberships/mint-batches', 'POST /memberships/mint-batches/7/submit']);
      expect(find.text('발행 완료 — 새로 2명'), findsOneWidget);
      expect(find.byKey(const Key('sbt_sign')), findsNothing);
    });

    testWidgets('결과를 모르면 「결과 확인」만 — 다시 서명 버튼은 없다', (tester) async {
      submitReply = () => batchJson(status: 'NO_RESPONSE');
      await tester.pumpWidget(app());
      await tap(tester, 'sbt_pick_file');
      await tap(tester, 'sbt_prepare');
      await tap(tester, 'sbt_sign');
      await tap(tester, 'sbt_confirm');

      expect(find.byKey(const Key('sbt_check')), findsOneWidget);
      expect(find.byKey(const Key('sbt_sign')), findsNothing);
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('sbt_pick_file'))).onPressed, isNull,
          reason: '결과를 모르는 묶음이 있는 동안 명단을 바꾸지 못한다');

      submitReply = () => batchJson(status: 'MINTED', targets: [
            target('20240011', '김하나', alice, status: 'MINTED', token: 1, membership: 10),
            target('20240012', '이두리', bob, status: 'SKIPPED', token: 2, membership: 11),
          ]);
      await tap(tester, 'sbt_check');
      expect(calls.last, 'GET /memberships/mint-batches/7');
      expect(calls.where((c) => c.endsWith('/submit')).length, 1, reason: '같은 서명을 두 번 보내지 않는다');
      expect(find.text('발행 완료 — 새로 1명, 이미 보유 1명'), findsOneWidget);
    });

    testWidgets('서명 만료로 거부되면 같은 요청에 다시 서명, nonce 가 바뀌었으면 다시 준비', (tester) async {
      submitReply = () => batchJson(status: 'REJECTED', reason: 'SignatureExpired');
      await tester.pumpWidget(app());
      await tap(tester, 'sbt_pick_file');
      await tap(tester, 'sbt_prepare');
      await tap(tester, 'sbt_sign');
      await tap(tester, 'sbt_confirm');
      expect(find.textContaining('서명 유효 시간이 지나'), findsOneWidget);
      expect(find.byKey(const Key('sbt_sign')), findsOneWidget);

      submitReply = () => batchJson(status: 'REJECTED', reason: 'InvalidNonce');
      await tap(tester, 'sbt_sign');
      await tap(tester, 'sbt_confirm');
      expect(find.byKey(const Key('sbt_sign')), findsNothing);
      await tap(tester, 'sbt_reprepare');
      expect(calls.where((c) => c == 'POST /memberships/mint-batches').length, 2);
      expect(find.byKey(const Key('sbt_sign')), findsOneWidget);
    });

    testWidgets('100명이 넘으면 100명씩 차례로 준비한다', (tester) async {
      final prepared = <List<dynamic>>[];
      SbtMintService.client = MockClient((req) async {
        final p = req.url.path;
        if (p == '/terms') {
          return json([
            {'id': 1, 'term_code': 20262},
          ]);
        }
        if (p == '/memberships/mint-batches') {
          prepared.add((jsonDecode(req.body) as Map)['student_nos'] as List);
          return json(batchJson(), 201);
        }
        if (p.endsWith('/submit')) return json(submitReply());
        return http.Response('{}', 404);
      });
      await tester.pumpWidget(MaterialApp(
        home: SbtMintScreen(
          service: SbtMintService(sign: signerWith(presidentKey), domain: () async => domain),
          picker: () async => utf8.encode([for (var i = 0; i < 150; i++) '${20250000 + i}'].join('\n')),
        ),
      ));
      await tap(tester, 'sbt_pick_file');
      expect(find.textContaining('100명씩 2번에 나눠 발행'), findsOneWidget);
      await tap(tester, 'sbt_prepare');
      await tap(tester, 'sbt_sign');
      await tap(tester, 'sbt_confirm');
      await tap(tester, 'sbt_next');
      expect(prepared.map((l) => l.length), [100, 50]);
      expect(prepared[1].first, '20250100');
      expect(find.text('2. 발행 (2/2)'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('sbt_done_summary')), 300,
          scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
      expect(find.text('1묶음 · 새로 발행 2명 · 이미 보유 0명'), findsOneWidget);
    });

    testWidgets('발행할 학생이 없으면 제외 사유를 보여 준다', (tester) async {
      SbtMintService.client = MockClient((req) async {
        if (req.url.path == '/terms') {
          return json([
            {'id': 1, 'term_code': 20262},
          ]);
        }
        return json({
          'detail': {
            'message': '없음',
            'excluded': [
              {'student_no': '20240011', 'name': '김하나', 'status': 'ALREADY_MEMBER'},
              {'student_no': '20240012', 'name': null, 'status': 'NOT_FOUND'},
            ],
          },
        }, 400);
      });
      await tester.pumpWidget(app());
      await tap(tester, 'sbt_pick_file');
      await tap(tester, 'sbt_prepare');
      expect(find.text('이미 보유'), findsOneWidget);
      expect(find.text('등록되지 않은 학번'), findsOneWidget);
      expect(find.byKey(const Key('sbt_sign')), findsNothing);
    });
  });
}
