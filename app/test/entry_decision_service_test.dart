import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/core/signing/device_auth.dart';
import 'package:student_council_app/core/signing/eip712.dart';
import 'package:student_council_app/core/signing/ledger_types.dart';
import 'package:student_council_app/core/signing/signing_service.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/services/auth_service.dart';
import 'package:student_council_app/services/chain_domain_service.dart';
import 'package:student_council_app/services/entry_decision_service.dart';

import 'support/session.dart';
import 'support/signing.dart';

/// 반려 — 기기 서명(EIP-712 RejectDecision) → `POST /entries/{id}/reject`.
void main() {
  final vectors = loadEip712Vectors();
  final domainJson = vectors['domain'] as Map<String, dynamic>;
  final domain = Eip712Domain.fromJson(domainJson);
  Map<String, dynamic> vector(String name) =>
      (vectors['vectors'] as List).cast<Map<String, dynamic>>().firstWhere((v) => v['name'] == name);

  const auditor = auditorAddress;
  const treasurer = treasurerAddress; // 등록자

  /// 등록 내용에서 meta_hash 를 계산해 넣은 대기 건 (총무 user 2 가 등록).
  EntryModel pending({int id = 7, int? termCode = 20262, String? metaHash, int createdBy = 2}) {
    const amount = 35000, occurredAt = 1790694000;
    const counterparty = '한결문구', purpose = '신입생 환영회 명찰';
    final receiptHash = '0x${'ab' * 32}';
    return EntryModel(
      id: id,
      termId: 1,
      termCode: termCode,
      kind: EntryKind.EXPENSE,
      amount: amount,
      counterparty: counterparty,
      purpose: purpose,
      budgetId: 1,
      occurredAt: occurredAt,
      receiptHash: receiptHash,
      metaHash: metaHash ??
          Hashing.metaHash(
            amount: amount,
            counterparty: counterparty,
            purpose: purpose,
            occurredAt: occurredAt,
            receiptHash: receiptHash,
          ),
      status: EntryStatus.PENDING,
      createdBy: createdBy,
    );
  }

  http.Response json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  late List<http.Request> posts;
  late Map<String, int> wallets;
  late http.Response Function(http.Request) onReject;
  late FakeAuthenticator auth;
  final now = DateTime.utc(2026, 11, 6, 9);

  EntryDecisionService service() =>
      EntryDecisionService(signer: SigningService(authenticator: auth), now: () => now);

  setUp(() async {
    await signInAs(UserRole.AUDITOR, userId: 3);
    await useAuditorDeviceKey();
    auth = FakeAuthenticator();
    posts = [];
    wallets = {treasurer: 2, auditor: 3};
    onReject = (_) => json({'id': 7, 'status': 'REJECTED', 'message': '반려됨'});
    final server = MockClient((req) async {
      if (req.method == 'GET' && req.url.path == '/chain/domains') {
        return json({'domains': {LedgerTypes.domainName: domainJson}});
      }
      if (req.method == 'GET' && req.url.path == '/users/wallets') return json(wallets);
      if (req.method == 'POST' && req.url.path == '/entries/7/reject') {
        posts.add(req);
        return onReject(req);
      }
      return http.Response('{}', 404);
    });
    ChainDomainService.client = server;
    EntryDecisionService.client = server;
  });

  tearDown(() async {
    ChainDomainService.client = http.Client();
    EntryDecisionService.client = http.Client();
    await signOutForTest();
  });

  test('반려 메시지는 컨트랙트 벡터(reject_expense)와 같은 서명이 된다', () async {
    final record = vector('record_expense')['message'] as Map<String, dynamic>;
    final entry = EntryModel(
      id: 2,
      termId: 1,
      termCode: record['term'] as int,
      kind: EntryKind.EXPENSE,
      amount: record['amount'] as int,
      counterparty: '',
      purpose: '',
      budgetId: record['budgetId'] as int,
      occurredAt: record['occurredAt'] as int,
      metaHash: record['hash'] as String,
      status: EntryStatus.PENDING,
      createdBy: 2,
    );
    final message = EntryDecisionService.rejectMessage(
      entry: entry,
      registrant: treasurer,
      reason: 'vector:reject-reason',
      deadline: 1790700000,
    );
    final sig = await SigningService(authenticator: auth).sign(domain, message, reason: '반려 서명');
    expect(sig, vector('reject_expense')['signature']);
  });

  test('반려하면 서버가 다시 만드는 RejectDecision 에 감사 키로 서명해 보낸다', () async {
    final entry = pending();
    await service().reject(entry, '  영수증 금액이 달라요\n');

    expect(posts, hasLength(1));
    final req = posts.single;
    expect(req.headers['Authorization'], 'Bearer token-3');
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    expect(body['reject_reason'], '영수증 금액이 달라요');
    expect(body['deadline'], now.millisecondsSinceEpoch ~/ 1000 + 600);

    // 서버(reject_entry)와 같은 방법으로 메시지를 만들고 서명자를 복구한다 — 등록자는 체인의 registrant
    final serverSide = LedgerTypes.rejectDecision(
      id: 7,
      entryCommit: LedgerTypes.entryCommit(
        hash: entry.metaHash,
        amount: 35000,
        kind: EntryKind.EXPENSE,
        term: 20262,
        occurredAt: 1790694000,
        budgetId: 1,
        correctsId: 0,
        registrant: treasurer,
      ),
      reasonHash: Hashing.textHash('영수증 금액이 달라요'),
      deadline: body['deadline'] as int,
    );
    expect(SigningService.recoverSigner(Eip712.digest(domain, serverSide), body['signature'] as String), auditor);
    expect(auth.calls, 1);
  });

  group('서명 전에 멈춘다 — 본인 확인도 묻지 않고 아무것도 보내지 않는다', () {
    Future<void> expectStops(Future<void> Function() run, EntryDecisionFailure failure) async {
      await expectLater(
        run(),
        throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', failure)),
      );
      expect(posts, isEmpty);
      expect(auth.calls, 0);
    }

    test('화면 값으로 다시 계산한 해시가 서버 meta_hash 와 다르면', () async {
      await expectStops(
        () => service().reject(pending(metaHash: '0x${'00' * 32}'), '사유'),
        EntryDecisionFailure.mismatch,
      );
    });

    test('학기 코드(term_code)가 없으면', () async {
      await expectStops(() => service().reject(pending(termCode: null), '사유'), EntryDecisionFailure.notReady);
    });

    test('등록자 지갑 주소가 없으면', () async {
      wallets = {auditor: 3};
      await expectStops(() => service().reject(pending(), '사유'), EntryDecisionFailure.notReady);
    });

    test('등록자 주소가 여러 개라 어느 것인지 모르면', () async {
      wallets = {treasurer: 2, '0x${'11' * 20}': 2, auditor: 3};
      await expectStops(() => service().reject(pending(), '사유'), EntryDecisionFailure.notReady);
    });

    test('정본화한 사유가 비어 있으면', () async {
      await expectStops(() => service().reject(pending(), ' \n\t '), EntryDecisionFailure.invalidReason);
    });
  });

  test('본인 확인을 취소하면 보내지 않는다', () async {
    auth = FakeAuthenticator(result: DeviceAuthResult.cancelled);
    await expectLater(
      service().reject(pending(), '사유'),
      throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.signing)),
    );
    expect(posts, isEmpty);
  });

  group('서버 응답', () {
    final cases = {
      400: EntryDecisionFailure.refused,
      403: EntryDecisionFailure.forbidden,
      404: EntryDecisionFailure.notFound,
      409: EntryDecisionFailure.conflict,
      503: EntryDecisionFailure.unknownOutcome,
    };
    for (final c in cases.entries) {
      test('${c.key} → ${c.value.name}', () async {
        onReject = (_) => json({'detail': '서버 설명 ${c.key}'}, c.key);
        await expectLater(
          service().reject(pending(), '사유'),
          throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', c.value)),
        );
      });
    }

    test('400·403 은 서버 설명을 그대로 보여 준다 (문구로 분기하지 않는다)', () async {
      onReject = (_) => json({'detail': '본인이 등록한 항목은 승인·반려할 수 없습니다.'}, 403);
      await expectLater(
        service().reject(pending(), '사유'),
        throwsA(isA<EntryDecisionException>()
            .having((e) => e.message, 'message', contains('본인이 등록한 항목은 승인·반려할 수 없습니다.'))),
      );
    });

    test('401 이면 세션을 비운다', () async {
      onReject = (_) => json({'detail': 'expired'}, 401);
      await expectLater(
        service().reject(pending(), '사유'),
        throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.unauthorized)),
      );
      expect(AuthService().session, isNull);
    });

    test('보낸 뒤 연결이 끊기면 결과를 모른다고 한다', () async {
      onReject = (_) => throw http.ClientException('connection reset');
      await expectLater(
        service().reject(pending(), '사유'),
        throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.unknownOutcome)),
      );
      expect(posts, hasLength(1));
    });
  });
}
