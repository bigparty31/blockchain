import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/core/signing/device_auth.dart';
import 'package:student_council_app/core/signing/device_key.dart';
import 'package:student_council_app/core/signing/eip712.dart';
import 'package:student_council_app/core/signing/ledger_types.dart';
import 'package:student_council_app/core/signing/signing_service.dart';
import 'package:student_council_app/services/chain_domain_service.dart';
import 'package:student_council_app/services/entry_registration_service.dart';

import 'support/session.dart';
import 'support/signing.dart';

const _treasurerKey = '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a'; // Hardhat #2

/// 총무 등록 — 초안(`POST /entries`) → 기기 서명(EIP-712 RecordRequest) → 제출(`POST /entries/{id}/submit`).
void main() {
  final domainJson = loadEip712Vectors()['domain'] as Map<String, dynamic>;
  final domain = Eip712Domain.fromJson(domainJson);

  http.Response json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  final receiptHash = '0x${'cd' * 32}';
  final receiptBytes = utf8.encode('receipt original bytes \x00\xff jpeg');

  EntryDraft expense({String counterparty = ' 한결문구 ', String purpose = '신입생 환영회 명찰', int? budgetId = 1}) =>
      EntryDraft(
        kind: EntryKind.EXPENSE,
        termId: 1,
        amount: 35000,
        counterparty: counterparty,
        purpose: purpose,
        budgetId: budgetId,
        occurredAt: 1790694000,
        receiptHash: receiptHash,
      );

  late List<http.Request> drafts;
  late List<http.Request> submits;
  late List<http.Request> uploads;
  late http.Response Function(List<int> body) onUpload;
  late http.Response Function() onDraft;
  late http.Response Function() onSubmit;
  late http.Response Function() onTerm;
  late http.Response Function(String path) onDownload;
  late FakeAuthenticator auth;
  final now = DateTime.utc(2026, 11, 6, 9);

  EntryRegistrationService service() =>
      EntryRegistrationService(signer: SigningService(authenticator: auth), now: () => now);

  setUp(() async {
    await signInAs(UserRole.TREASURER, userId: 2);
    DeviceKey.storage = MemoryKeyStorage();
    DeviceKey.allowDevKeyImport = true;
    await DeviceKey.importDevKey(_treasurerKey);
    auth = FakeAuthenticator();
    drafts = [];
    submits = [];
    onDraft = () => json({'id': 11, 'message': '초안'}, 201);
    onSubmit = () => json({'id': 11, 'status': 'PENDING', 'tx_pending': '0x${'ab' * 32}', 'message': 'ok'});
    onTerm = () => json({'id': 1, 'term_code': 20262, 'name': '2026-2', 'started_at': '2026-09-01T00:00:00', 'ended_at': '2027-02-28T00:00:00'});
    uploads = [];
    onDownload = (_) => http.Response('', 404); // 옛 서버 — GET /receipts 가 없다
    // 서버(#66 receipts.py)처럼 받은 바이트를 그대로 해시한다 — 여기서는 multipart 본문 안의 파일 바이트를 꺼내지 않고,
    // 테스트가 보낸 원본을 알고 있으므로 그 해시를 돌려준다
    onUpload = (_) => json({'receipt_hash': Hashing.fileHash(receiptBytes), 'receipt_path': '/receipts/${Hashing.fileHash(receiptBytes).substring(2)}.jpg', 'filename': 'receipt.jpg', 'size': receiptBytes.length}, 201);
    final server = MockClient((req) async {
      switch ('${req.method} ${req.url.path}') {
        case 'POST /entries':
          drafts.add(req);
          return onDraft();
        case 'POST /entries/11/submit':
          submits.add(req);
          return onSubmit();
        case 'POST /receipts':
          uploads.add(req);
          return onUpload(req.bodyBytes);
        case 'GET /terms/1':
          return onTerm();
        case 'GET /chain/domains':
          return json({'domains': {LedgerTypes.domainName: domainJson}});
      }
      if (req.method == 'GET' && req.url.path.startsWith('/receipts/')) return onDownload(req.url.path);
      return http.Response('{}', 404);
    });
    EntryRegistrationService.client = server;
    ChainDomainService.client = server;
  });

  tearDown(() async {
    EntryRegistrationService.client = http.Client();
    ChainDomainService.client = http.Client();
    await signOutForTest();
  });

  test('초안은 정본화한 거래처·목적으로 보내고 발급된 id 를 돌려준다', () async {
    final id = await service().saveDraft(expense());
    expect(id, 11);
    final body = jsonDecode(drafts.single.body) as Map<String, dynamic>;
    expect(body['counterparty'], '한결문구'); // 앞뒤 U+0020 제거 (HASHING §1.1)
    expect(body['kind'], 'EXPENSE');
    expect(body['budget_id'], 1);
    expect(body['receipt_hash'], receiptHash);
    expect(drafts.single.headers['Authorization'], 'Bearer token-2');
  });

  test('제출은 서버가 DB 값으로 다시 만드는 RecordRequest 에 총무 키로 서명해 보낸다', () async {
    final outcome = await service().submit(11, expense());
    expect(outcome.status, EntryStatus.PENDING);

    final body = jsonDecode(submits.single.body) as Map<String, dynamic>;
    expect(body['deadline'], now.millisecondsSinceEpoch ~/ 1000 + 600);
    // 서버 submit_entry 와 같은 방법 — meta_hash 는 정본화한 텍스트로 계산, term 은 학기 코드
    final serverSide = LedgerTypes.recordRequest(
      id: 11,
      hash: Hashing.metaHash(
        amount: 35000,
        counterparty: '한결문구',
        purpose: '신입생 환영회 명찰',
        occurredAt: 1790694000,
        receiptHash: receiptHash,
      ),
      amount: 35000,
      kind: EntryKind.EXPENSE,
      term: 20262,
      occurredAt: 1790694000,
      budgetId: 1,
      correctsId: 0,
      deadline: body['deadline'] as int,
    );
    expect(SigningService.recoverSigner(Eip712.digest(domain, serverSide), body['signature'] as String), treasurerAddress);
    expect(auth.calls, 1);
  });

  test('정정은 원본 id 를 corrects_entry_id 로 보내고, 서명의 correctsId 도 원본 id 다 — 금액은 음수 증감분', () async {
    final correction = EntryDraft(
      kind: EntryKind.EXPENSE,
      termId: 1,
      amount: -20000,
      counterparty: '한결문구',
      purpose: '입력 오류 정정',
      budgetId: 1,
      occurredAt: 1788793200,
      correctsEntryId: 1,
      correctionReason: CorrectionReason.INPUT_ERROR,
    );
    // HASHING 샘플 3 — 정정, 금액 음수
    expect(correction.metaHash, '0xebd26de486f8caba6e4d24662acd1cc671be1c9c60cfd3048da527c9a351ca73');

    await service().saveDraft(correction);
    final draft = jsonDecode(drafts.single.body) as Map<String, dynamic>;
    expect(draft['amount'], -20000);
    expect(draft['corrects_entry_id'], 1);
    expect(draft['correction_reason'], 'INPUT_ERROR');

    await service().submit(11, correction);
    final body = jsonDecode(submits.single.body) as Map<String, dynamic>;
    final serverSide = LedgerTypes.recordRequest(
      id: 11,
      hash: correction.metaHash,
      amount: -20000,
      kind: EntryKind.EXPENSE,
      term: 20262,
      occurredAt: 1788793200,
      budgetId: 1,
      correctsId: 1,
      deadline: body['deadline'] as int,
    );
    expect(SigningService.recoverSigner(Eip712.digest(domain, serverSide), body['signature'] as String), treasurerAddress);
  });

  test('정정이 아니면 정정 칸을 보내지 않는다', () async {
    await service().saveDraft(expense());
    final body = jsonDecode(drafts.single.body) as Map<String, dynamic>;
    expect(body.containsKey('corrects_entry_id'), isFalse);
    expect(body.containsKey('correction_reason'), isFalse);
  });

  test('예산 문제면 BLOCKED 와 차단 사유를 돌려준다 (revert 가 아니라 기록된다)', () async {
    onSubmit = () => json({'id': 11, 'status': 'BLOCKED', 'block_reason': 'BUDGET_EXCEEDED', 'message': '차단'});
    final outcome = await service().submit(11, expense());
    expect(outcome.status, EntryStatus.BLOCKED);
    expect(outcome.blockReason, BlockReason.BUDGET_EXCEEDED);
  });

  test('모르는 차단 사유는 「잔량 부족」으로 지어내지 않고 결과를 알 수 없다고 한다 (#69 리뷰)', () async {
    onSubmit = () => json({'id': 11, 'status': 'BLOCKED', 'block_reason': 'BUDGET_FROZEN', 'message': '차단'});
    await expectLater(
      service().submit(11, expense()),
      throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.unknownOutcome)),
    );
  });

  testWidgets('초안 저장은 제출처럼 쓰기 시간(45초)을 기다린다 — 5초에 끊으면 응답이 유실될 때 초안이 둘 생긴다 (#69 리뷰)', (tester) async {
    EntryRegistrationService.client = MockClient((req) async {
      await Future<void>.delayed(const Duration(seconds: 10)); // 느린 서버
      return onDraft();
    });
    int? id;
    Object? error;
    service().saveDraft(expense()).then((v) => id = v, onError: (Object e) => error = e);
    await tester.pump(const Duration(seconds: 11));
    expect(error, isNull, reason: '10초 걸려도 45초 안이면 응답을 받는다');
    expect(id, 11);
  });

  test('BLOCKED 인데 차단 사유가 없으면 결과를 모른다고 한다 — 사유를 지어내지 않는다', () async {
    onSubmit = () => json({'id': 11, 'status': 'BLOCKED', 'message': '차단'});
    await expectLater(
      service().submit(11, expense()),
      throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.unknownOutcome)),
    );
  });

  test('학기 코드를 못 읽으면 본인 확인을 묻지 않고 멈춘다', () async {
    onTerm = () => json({'detail': 'down'}, 503);
    await expectLater(
      service().submit(11, expense()),
      throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.notReady)),
    );
    expect(submits, isEmpty);
    expect(auth.calls, 0);
  });

  test('본인 확인을 취소하면 제출하지 않는다', () async {
    auth = FakeAuthenticator(result: DeviceAuthResult.cancelled);
    await expectLater(
      service().submit(11, expense()),
      throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.signing)),
    );
    expect(submits, isEmpty);
  });

  test('서명이 맞지 않는 등 서버가 거부하면(400) 서버 설명을 보여 준다', () async {
    onSubmit = () => json({'detail': '서명자가 등록자와 일치하지 않습니다.'}, 400);
    await expectLater(
      service().submit(11, expense()),
      throwsA(isA<EntryDecisionException>()
          .having((e) => e.failure, 'failure', EntryDecisionFailure.refused)
          .having((e) => e.message, 'message', contains('서명자가 등록자와 일치하지 않습니다.'))),
    );
  });

  test('같은 영수증이 이미 있으면(409) 서버 설명을 그대로 보여 준다', () async {
    onDraft = () => json({'detail': '이미 등록된 영수증입니다 (내역 ID: 3, 승인번호: 1234).'}, 409);
    await expectLater(
      service().saveDraft(expense()),
      throwsA(isA<EntryDecisionException>()
          .having((e) => e.failure, 'failure', EntryDecisionFailure.conflict)
          .having((e) => e.message, 'message', contains('내역 ID: 3'))),
    );
  });

  test('수입은 예산 없이 보낸다 — 서버가 예산 연결을 400 으로 막는다', () async {
    await service().saveDraft(EntryDraft(
      kind: EntryKind.INCOME,
      termId: 1,
      amount: 5000000,
      counterparty: '학생처',
      purpose: '학교 지원금',
      occurredAt: 1790694000,
    ));
    final body = jsonDecode(drafts.single.body) as Map<String, dynamic>;
    expect(body.containsKey('budget_id'), isFalse);
    expect(body.containsKey('receipt_hash'), isFalse);
  });

  group('영수증 원본 업로드 (POST /receipts, #66)', () {
    test('원본 바이트를 multipart(file)로 그대로 올리고, 서버 해시가 원본과 같으면 경로를 돌려준다', () async {
      final up = await service().uploadReceipt(receiptBytes, filename: 'receipt.jpg');
      expect(up.hash, Hashing.fileHash(receiptBytes));
      expect(up.path, '/receipts/${Hashing.fileHash(receiptBytes).substring(2)}.jpg');

      final req = uploads.single;
      expect(req.headers['Authorization'], 'Bearer token-2');
      expect(req.headers['content-type'], startsWith('multipart/form-data'));
      final body = latin1.decode(req.bodyBytes);
      expect(body, contains('name="file"; filename="receipt.jpg"'));
      expect(body, contains(latin1.decode(receiptBytes)), reason: '재인코딩 없이 원본 바이트 그대로');
    });

    test('서버가 계산한 해시가 원본과 다르면 멈춘다 — 다른 파일이 저장됐다', () async {
      onUpload = (_) => json({'receipt_hash': '0x${'11' * 32}', 'receipt_path': '/receipts/x.jpg', 'filename': 'r.jpg', 'size': 1}, 201);
      await expectLater(
        service().uploadReceipt(receiptBytes, filename: 'receipt.jpg'),
        throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.mismatch)),
      );
    });

    test('업로드가 거부되면(400) 서버 설명을 보여 준다', () async {
      onUpload = (_) => json({'detail': '빈 파일은 업로드할 수 없습니다.'}, 400);
      await expectLater(
        service().uploadReceipt(receiptBytes, filename: 'receipt.jpg'),
        throwsA(isA<EntryDecisionException>()
            .having((e) => e.failure, 'failure', EntryDecisionFailure.refused)
            .having((e) => e.message, 'message', contains('빈 파일은 업로드할 수 없습니다.'))),
      );
    });

    test('올린 영수증을 파일 이름으로 다시 내려받는다 — 없으면(옛 서버) null', () async {
      final path = '/receipts/${Hashing.fileHash(receiptBytes).substring(2)}.jpg';
      expect(await service().downloadReceipt(path), isNull);
      onDownload = (p) => p == path ? http.Response.bytes(receiptBytes, 200) : http.Response('', 404);
      expect(await service().downloadReceipt(path), receiptBytes);
      expect(await service().downloadReceipt('/receipts/'), isNull, reason: '파일 이름이 없으면 묻지 않는다');
    });

    test('초안에 업로드한 receipt_path 를 함께 보낸다 — 서버는 파일 없는 해시를 400 으로 막는다', () async {
      final up = await service().uploadReceipt(receiptBytes, filename: 'receipt.jpg');
      await service().saveDraft(EntryDraft(
        kind: EntryKind.EXPENSE,
        termId: 1,
        amount: 35000,
        counterparty: '한결문구',
        purpose: '명찰',
        budgetId: 1,
        occurredAt: 1790694000,
        receiptHash: up.hash,
        receiptPath: up.path,
      ));
      final body = jsonDecode(drafts.single.body) as Map<String, dynamic>;
      expect(body['receipt_hash'], up.hash);
      expect(body['receipt_path'], up.path);
    });
  });
}
