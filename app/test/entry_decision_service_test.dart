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

/// 반려·승인 — 기기 서명(EIP-712 RejectDecision·ConfirmApproval) → `POST /entries/{id}/reject`·`/confirm`.
void main() {
  final vectors = loadEip712Vectors();
  final domainJson = vectors['domain'] as Map<String, dynamic>;
  final domain = Eip712Domain.fromJson(domainJson);
  Map<String, dynamic> vector(String name) =>
      (vectors['vectors'] as List).cast<Map<String, dynamic>>().firstWhere((v) => v['name'] == name);

  const auditor = auditorAddress;
  const treasurer = treasurerAddress; // 등록자

  /// 등록 내용에서 meta_hash 를 계산해 넣은 대기 건 (총무 user 2 가 등록).
  EntryModel pending({
    int id = 7,
    int? termCode = 20262,
    String? metaHash,
    int createdBy = 2,
    bool categoryWarning = false,
    OcrStatus? ocrStatus = OcrStatus.MATCH,
  }) {
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
      ocrStatus: ocrStatus,
      categoryWarning: categoryWarning,
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
  late http.Response Function(http.Request) onConfirm;
  late List<http.Request> confirms;
  late FakeAuthenticator auth;

  /// 서명 직전 재조회(GET /entries/7)가 돌려줄 건. [use] 로 화면에 보인 건과 같게 맞춘다.
  late EntryModel serverEntry;
  Map<String, dynamic>? freshOverride;
  int freshStatus = 200;
  EntryModel use(EntryModel e) => serverEntry = e;

  /// 서버 `EntryResponse` 모양.
  Map<String, dynamic> responseOf(EntryModel e) => {
        'id': e.id, 'term_id': e.termId, 'term_code': e.termCode, 'kind': e.kind.code, 'amount': e.amount,
        'counterparty': e.counterparty, 'purpose': e.purpose, 'budget_id': e.budgetId, 'occurred_at': e.occurredAt,
        'receipt_hash': e.receiptHash, 'meta_hash': e.metaHash, 'ocr_status': e.ocrStatus?.code,
        'category_warning': e.categoryWarning, 'status': e.status.code, 'created_by': e.createdBy,
        'corrects_entry_id': e.correctsEntryId,
      };
  final now = DateTime.utc(2026, 11, 6, 9);

  EntryDecisionService service() =>
      EntryDecisionService(signer: SigningService(authenticator: auth), now: () => now);

  setUp(() async {
    await signInAs(UserRole.AUDITOR, userId: 3);
    await useAuditorDeviceKey();
    auth = FakeAuthenticator();
    posts = [];
    serverEntry = pending();
    freshOverride = null;
    freshStatus = 200;
    wallets = {treasurer: 2, auditor: 3};
    onReject = (_) => json({'id': 7, 'status': 'REJECTED', 'message': '반려됨'});
    confirms = [];
    onConfirm = (_) => json({'id': 7, 'status': 'CONFIRMED', 'tx_confirm': '0x${'cd' * 32}', 'message': '확정됨'});
    final server = MockClient((req) async {
      if (req.method == 'GET' && req.url.path == '/chain/domains') {
        return json({'domains': {LedgerTypes.domainName: domainJson}});
      }
      if (req.method == 'GET' && req.url.path == '/users/wallets') return json(wallets);
      if (req.method == 'GET' && req.url.path == '/entries/7') {
        return freshStatus == 200 ? json(freshOverride ?? responseOf(serverEntry)) : json({'detail': 'x'}, freshStatus);
      }
      if (req.method == 'POST' && req.url.path == '/entries/7/reject') {
        posts.add(req);
        return onReject(req);
      }
      if (req.method == 'POST' && req.url.path == '/entries/7/confirm') {
        confirms.add(req);
        return onConfirm(req);
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

  group('승인', () {
    /// 벡터의 등록값 — hash 는 sha256("vector:expense") 라 등록 내용에서 계산한 값이 아니다.
    EntryModel vectorEntry({bool categoryWarning = false}) {
      final record = vector('record_expense')['message'] as Map<String, dynamic>;
      return EntryModel(
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
        categoryWarning: categoryWarning,
        status: EntryStatus.PENDING,
        createdBy: 2,
      );
    }

    test('승인 메시지는 컨트랙트 벡터(confirm_expense)와 같은 서명이 된다', () async {
      final message = EntryDecisionService.confirmMessage(
        entry: vectorEntry(),
        registrant: treasurer,
        deadline: 1790700000,
      );
      final sig = await SigningService(authenticator: auth).sign(domain, message, reason: '승인 서명');
      expect(sig, vector('confirm_expense')['signature']);
    });

    test('경고 무시 승인은 벡터(confirm_with_warning)와 같은 서명이 된다', () async {
      final message = EntryDecisionService.confirmMessage(
        entry: vectorEntry(categoryWarning: true),
        registrant: treasurer,
        warningReason: 'vector:warning-reason',
        deadline: 1790700000,
      );
      final sig = await SigningService(authenticator: auth).sign(domain, message, reason: '승인 서명');
      expect(sig, vector('confirm_with_warning')['signature']);
    });

    /// 서버(confirm_entry)와 같은 방법으로 ConfirmApproval 을 만들어 서명자를 복구한다.
    String signerOf(http.Request req, EntryModel entry, {String? warningReason}) {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final serverSide = LedgerTypes.confirmApproval(
        id: 7,
        hash: entry.metaHash,
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
        hadWarning: warningReason != null,
        warningReasonHash: warningReason == null ? '0x${'00' * 32}' : Hashing.textHash(warningReason),
        deadline: body['deadline'] as int,
      );
      return SigningService.recoverSigner(Eip712.digest(domain, serverSide), body['signature'] as String);
    }

    test('경고 없는 건은 사유 없이 서명해 보낸다', () async {
      final entry = pending();
      await service().confirm(entry);

      final body = jsonDecode(confirms.single.body) as Map<String, dynamic>;
      expect(body.containsKey('warning_reason'), isFalse); // 경고가 아닌데 보내면 서버가 400
      expect(body['deadline'], now.millisecondsSinceEpoch ~/ 1000 + 600);
      expect(confirms.single.headers['Authorization'], 'Bearer token-3');
      expect(signerOf(confirms.single, entry), auditor);
    });

    test('경고 건은 정본화한 사유를 보내고 그 해시에 서명한다', () async {
      final entry = use(pending(ocrStatus: OcrStatus.DUPLICATE));
      await service().confirm(entry, warningReason: '  같은 영수증이지만 분할 결제라 승인\r\n');

      final body = jsonDecode(confirms.single.body) as Map<String, dynamic>;
      expect(body['warning_reason'], '같은 영수증이지만 분할 결제라 승인');
      expect(signerOf(confirms.single, entry, warningReason: '같은 영수증이지만 분할 결제라 승인'), auditor);
    });

    test('NO_NUMBER·OCR 없음은 경고가 아니다 — 사유를 보내지 않는다', () async {
      await service().confirm(use(pending(ocrStatus: OcrStatus.NO_NUMBER)));
      await service().confirm(use(pending(ocrStatus: null)));
      for (final req in confirms) {
        expect((jsonDecode(req.body) as Map).containsKey('warning_reason'), isFalse);
      }
    });

    test('경고 건인데 사유가 비면 서명하지 않는다', () async {
      await expectLater(
        service().confirm(pending(categoryWarning: true), warningReason: '  \n'),
        throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.invalidReason)),
      );
      expect(confirms, isEmpty);
      expect(auth.calls, 0);
    });

    test('화면 값으로 다시 계산한 해시가 다르면 승인 서명도 하지 않는다', () async {
      await expectLater(
        service().confirm(pending(metaHash: '0x${'00' * 32}')),
        throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.mismatch)),
      );
      expect(confirms, isEmpty);
      expect(auth.calls, 0);
    });

    test('체인이 확정을 거부하면(400) 서버 설명을 보여 준다', () async {
      onConfirm = (_) => json({'detail': '온체인 승인이 거부되었습니다 (InsufficientBudget).'}, 400);
      await expectLater(
        service().confirm(pending()),
        throwsA(isA<EntryDecisionException>()
            .having((e) => e.failure, 'failure', EntryDecisionFailure.refused)
            .having((e) => e.message, 'message', contains('InsufficientBudget'))),
      );
    });
  });

  group('서명 직전 재조회 (보드 ②) — 화면과 서버의 지금 값이 다르면 본인 확인도 묻지 않고 멈춘다', () {
    Future<void> expectStops(Future<void> Function() run, EntryDecisionFailure failure) async {
      await expectLater(
        run(),
        throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', failure)),
      );
      expect(posts, isEmpty);
      expect(confirms, isEmpty);
      expect(auth.calls, 0);
    }

    test('다른 임원이 먼저 확정했으면', () async {
      freshOverride = {...responseOf(pending()), 'status': 'CONFIRMED'};
      await expectStops(() => service().confirm(pending()), EntryDecisionFailure.changed);
    });

    test('등록 내용(금액)이 화면과 달라졌으면', () async {
      freshOverride = {...responseOf(pending()), 'amount': 36000};
      await expectStops(() => service().reject(pending(), '사유'), EntryDecisionFailure.changed);
    });

    test('경고 여부가 달라졌으면 — 서버가 다른 hadWarning 으로 커밋을 만든다', () async {
      freshOverride = {...responseOf(pending()), 'category_warning': true};
      await expectStops(() => service().confirm(pending()), EntryDecisionFailure.changed);
    });

    // 승인 창을 연 뒤 총무가 수정을 요청하면, 목록의 값만 믿고 서명한 뒤에야 서버가 거절해 이유를 알 수 없다 (#92 리뷰).
    test('서명 직전 재조회에서 수정 요청이 걸려 있으면 승인은 멈춘다', () async {
      freshOverride = {...responseOf(pending()), 'revision_requested_at': 1790700000};
      await expectStops(() => service().confirm(pending()), EntryDecisionFailure.changed);
    });

    test('수정 요청이 걸려 있어도 반려는 서명해 보낼 수 있다', () async {
      freshOverride = {...responseOf(pending()), 'revision_requested_at': 1790700000};
      await service().reject(pending(), '사유');
      expect(posts, hasLength(1));
      expect(auth.calls, greaterThan(0));
    });

    test('다시 읽지 못하면', () async {
      freshStatus = 503;
      await expectStops(() => service().confirm(pending()), EntryDecisionFailure.notReady);
    });
  });

  group('#65 응답 필드 — registrant·fail_reason', () {
    test('재조회 응답에 registrant 가 있으면 그 주소로 entryCommit 을 만든다 — /users/wallets 를 쓰지 않는다', () async {
      wallets = {}; // 역매핑으로는 등록자를 못 찾는다
      freshOverride = {...responseOf(pending()), 'registrant': '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC'}; // 체인은 EIP-55
      await service().confirm(pending());

      final body = jsonDecode(confirms.single.body) as Map<String, dynamic>;
      final serverSide = LedgerTypes.confirmApproval(
        id: 7,
        hash: pending().metaHash,
        entryCommit: LedgerTypes.entryCommit(
          hash: pending().metaHash,
          amount: 35000,
          kind: EntryKind.EXPENSE,
          term: 20262,
          occurredAt: 1790694000,
          budgetId: 1,
          correctsId: 0,
          registrant: treasurer,
        ),
        hadWarning: false,
        warningReasonHash: '0x${'00' * 32}',
        deadline: body['deadline'] as int,
      );
      expect(SigningService.recoverSigner(Eip712.digest(domain, serverSide), body['signature'] as String), auditor);
    });

    test('400 에 fail_reason 이 있으면 예외에 실어 준다 — 문구가 아니라 코드로 판단한다', () async {
      onConfirm = (_) => json({'detail': '온체인 승인이 거부되었습니다 (InsufficientBudget).', 'fail_reason': 'InsufficientBudget'}, 400);
      await expectLater(
        service().confirm(pending()),
        throwsA(isA<EntryDecisionException>()
            .having((e) => e.failure, 'failure', EntryDecisionFailure.refused)
            .having((e) => e.failReason, 'failReason', 'InsufficientBudget')),
      );
    });

    test('fail_reason 이 없는 400(옛 서버·검증 오류)은 failReason 이 null 이다', () async {
      onConfirm = (_) => json({'detail': '서명자가 승인권자와 일치하지 않습니다.'}, 400);
      await expectLater(
        service().confirm(pending()),
        throwsA(isA<EntryDecisionException>().having((e) => e.failReason, 'failReason', isNull)),
      );
    });
  });
}

