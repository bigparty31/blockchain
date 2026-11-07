@Tags(['e2e'])
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:student_council_app/core/api_config.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/core/signing/device_key.dart';
import 'package:student_council_app/core/signing/eip712.dart';
import 'package:student_council_app/core/signing/signing_service.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/services/auth_service.dart';
import 'package:student_council_app/services/budget_revision_service.dart';
import 'package:student_council_app/services/chain_domain_service.dart';
import 'package:student_council_app/services/entry_decision_service.dart';
import 'package:student_council_app/services/entry_registration_service.dart';
import 'package:web3dart/web3dart.dart' as web3 show sign;

import '../support/signing.dart';

/// **실체인 통합 시험** — 로컬 개발 스택(Hardhat 노드 + 서버 + Postgres)에 앱 서비스 코드 그대로 붙인다.
/// 보드 완료 기준: 「실제 체인에서 확정」·「등록이 체인에 기록됨」·「폰 2대로 같은 건을 동시 승인 → 한 건만 확정」.
///
/// 기본 `flutter test` 에서는 건너뛴다. 스택을 띄운 뒤 이렇게 돌린다 (docs/DEV_STACK.md):
///
///   flutter test test/e2e --dart-define=E2E=true \
///     --dart-define=COUNCIL_API_URL=http://127.0.0.1:18000 --dart-define=STUDENT_API_URL=http://127.0.0.1:18000
///
/// 시드 계정·Hardhat 키는 개발 전용 공개값이다 (backend/README.md).
const _e2e = bool.fromEnvironment('E2E');
const _password = 'userPassword123!';
const _treasurerKey = '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a'; // Hardhat #2 — 20240002 총무
const _presidentKey = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d'; // Hardhat #1 — 20240004 회장

void main() {
  // 실서버와 HTTP 를 주고받는다 — 위젯 테스트 바인딩(네트워크 차단)을 쓰지 않는다.
  setUpAll(() {
    AuthService.store = MemoryTokenStore();
    DeviceKey.storage = MemoryKeyStorage();
    DeviceKey.allowDevKeyImport = true;
  });

  final base = ApiConfig.councilBaseUrl;

  Future<void> loginAs(String studentNo, String deviceKey) async {
    await AuthService().logout();
    AuthService().resetAttempts();
    await AuthService().login(studentNo, _password);
    await DeviceKey.delete();
    await DeviceKey.importDevKey(deviceKey);
  }

  Future<EntryModel> readEntry(int id) async {
    final res = await http.get(Uri.parse('$base/entries/$id'), headers: AuthService().authHeaders);
    expect(res.statusCode, 200, reason: res.body);
    return EntryModel.fromJson(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
  }

  /// 총무가 등록해 체인에 올린다. 이름이 겹치지 않게 시각을 붙인다 (영수증 중복 검사·눈으로 찾기).
  Future<(int, SubmitOutcome)> register({required EntryKind kind, required int amount, int? budgetId, List<int>? receiptBytes}) async {
    await loginAs('20240002', _treasurerKey);
    final tag = DateTime.now().microsecondsSinceEpoch;
    final registrar = EntryRegistrationService(signer: SigningService(authenticator: FakeAuthenticator()));
    // 지출 영수증 — 원본을 먼저 올린다(#66). 업로드 API 가 없는 서버(#66 머지 전)는 404 라 해시만 보낸다
    final receipt = receiptBytes ?? (kind == EntryKind.EXPENSE ? utf8.encode('receipt $tag') : null);
    ReceiptUpload? upload;
    if (receipt != null) {
      try {
        upload = await registrar.uploadReceipt(receipt, filename: 'receipt.jpg');
      } on EntryDecisionException catch (e) {
        if (e.failure != EntryDecisionFailure.notFound) rethrow;
      }
    }
    final draft = EntryDraft(
      kind: kind,
      termId: 1,
      amount: amount,
      counterparty: 'e2e 거래처 $tag',
      purpose: 'e2e ${kind.code} $tag',
      budgetId: budgetId,
      occurredAt: Hashing.kstMidnightOf(2026, 11, 6),
      receiptHash: receipt == null ? null : Hashing.fileHash(receipt),
      receiptPath: upload?.path,
    );
    final id = await registrar.saveDraft(draft);
    return (id, await registrar.submit(id, draft));
  }

  final decisions = EntryDecisionService(signer: SigningService(authenticator: FakeAuthenticator()));

  test('수입 등록이 체인에 PENDING 으로 기록되고, 감사 승인으로 CONFIRMED 가 된다', () async {
    final (id, outcome) = await register(kind: EntryKind.INCOME, amount: 120000);
    expect(outcome.status, EntryStatus.PENDING);

    await loginAs('20240003', auditorKey);
    final pending = await readEntry(id);
    expect(pending.status, EntryStatus.PENDING);
    expect(pending.txPending, isNotNull, reason: '등록 트랜잭션');

    await decisions.confirm(pending);
    final confirmed = await readEntry(id);
    expect(confirmed.status, EntryStatus.CONFIRMED);
    expect(confirmed.approvedBy, 3);
    expect(confirmed.txConfirm, isNotNull, reason: '확정 트랜잭션');
  }, skip: !_e2e);

  test('지출 등록이 체인에 PENDING 으로 기록되고, 감사 반려로 REJECTED 가 된다', () async {
    final (id, outcome) = await register(kind: EntryKind.EXPENSE, amount: 30000, budgetId: 1);
    expect(outcome.status, EntryStatus.PENDING);

    await loginAs('20240003', auditorKey);
    await decisions.reject(await readEntry(id), '  e2e 반려 — 영수증 금액 불일치\n');
    final rejected = await readEntry(id);
    expect(rejected.status, EntryStatus.REJECTED);
    expect(rejected.rejectReason, 'e2e 반려 — 영수증 금액 불일치');
  }, skip: !_e2e);

  test('예산을 넘는 지출은 revert 가 아니라 BLOCKED 로 기록된다', () async {
    final (_, outcome) = await register(kind: EntryKind.EXPENSE, amount: 999000000, budgetId: 3);
    expect(outcome.status, EntryStatus.BLOCKED);
    expect(outcome.blockReason, BlockReason.BUDGET_EXCEEDED);
  }, skip: !_e2e);

  test('감사와 회장이 같은 건을 동시에 승인하면 한 건만 확정된다 (폰 2대 시연)', () async {
    final (id, _) = await register(kind: EntryKind.INCOME, amount: 50000);

    // 회장 — 두 번째 폰. 세션·기기 키가 앱에 하나뿐이라 토큰과 서명을 직접 만든다
    final presidentLogin = await http.post(
      Uri.parse('$base/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'student_no': '20240004', 'password': _password}),
    );
    expect(presidentLogin.statusCode, 200, reason: presidentLogin.body);
    final presidentToken = (jsonDecode(presidentLogin.body) as Map<String, dynamic>)['access_token'] as String;

    // 감사 — 첫 번째 폰 (앱 서비스 그대로)
    await loginAs('20240003', auditorKey);
    final entry = await readEntry(id);
    final domain = await ChainDomainService.ledger();
    final deadline = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600;
    final presidentMessage = EntryDecisionService.confirmMessage(
      entry: entry,
      registrant: treasurerAddress,
      deadline: deadline,
    );
    final presidentSig = SigningService.encodeSignature(
      web3.sign(Eip712.digest(domain, presidentMessage), Eip712.hexToBytes(_presidentKey)),
    );
    Future<String> presidentConfirm() async {
      final res = await http.post(
        Uri.parse('$base/entries/$id/confirm'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $presidentToken'},
        body: jsonEncode({'signature': presidentSig, 'deadline': deadline}),
      );
      return 'president ${res.statusCode}';
    }

    Future<String> auditorConfirm() async {
      try {
        await decisions.confirm(entry);
        return 'auditor 200';
      } on EntryDecisionException catch (e) {
        return 'auditor ${e.failure.name}';
      }
    }

    final results = await Future.wait([auditorConfirm(), presidentConfirm()]);
    final wins = results.where((r) => r.endsWith(' 200')).length;
    expect(wins, 1, reason: '$results');

    final finalEntry = await readEntry(id);
    expect(finalEntry.status, EntryStatus.CONFIRMED);
    expect([3, 4], contains(finalEntry.approvedBy));
    // ignore: avoid_print
    print('동시 승인 결과: $results → approved_by=${finalEntry.approvedBy}');
  }, skip: !_e2e);

  /// 업로드 API(#66)가 있는 서버인가 — 없으면 영수증 시험은 건너뛴다.
  Future<bool> serverHasReceipts() async {
    final res = await http.get(Uri.parse('$base/openapi.json'));
    return res.statusCode == 200 && utf8.decode(res.bodyBytes).contains('"/receipts"');
  }

  group('영수증 원본 (#66)', () {
    test('올린 원본을 서버가 바이트 그대로 보관한다 — 내려받은 파일의 해시가 같다', () async {
      if (!await serverHasReceipts()) return markTestSkipped('서버에 /receipts 가 없다 (#66 전)');
      await loginAs('20240002', _treasurerKey);
      final bytes = [0xFF, 0xD8, 0xFF, 0xE0, ...utf8.encode('jpeg-ish ${DateTime.now().microsecondsSinceEpoch}'), 0x00, 0xFF];
      final registrar = EntryRegistrationService(signer: SigningService(authenticator: FakeAuthenticator()));
      final up = await registrar.uploadReceipt(bytes, filename: 'receipt.jpg');
      expect(up.hash, Hashing.fileHash(bytes));

      final res = await http.get(Uri.parse('$base${up.path}'));
      expect(res.statusCode, 200, reason: res.body);
      expect(Hashing.fileHash(res.bodyBytes), up.hash, reason: '재인코딩·회전 없이 원본 그대로');
    }, skip: !_e2e);

    test('업로드 없이 해시만 보내면 서버가 400 으로 막는다 — 그래서 앱은 초안 전에 올린다', () async {
      if (!await serverHasReceipts()) return markTestSkipped('서버에 /receipts 가 없다 (#66 전)');
      await loginAs('20240002', _treasurerKey);
      final registrar = EntryRegistrationService(signer: SigningService(authenticator: FakeAuthenticator()));
      final orphan = utf8.encode('never uploaded ${DateTime.now().microsecondsSinceEpoch}');
      await expectLater(
        registrar.saveDraft(EntryDraft(
          kind: EntryKind.EXPENSE,
          termId: 1,
          amount: 1000,
          counterparty: 'e2e 해시만',
          purpose: 'e2e orphan',
          budgetId: 1,
          occurredAt: Hashing.kstMidnightOf(2026, 11, 6),
          receiptHash: Hashing.fileHash(orphan),
        )),
        throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.refused)),
      );
    }, skip: !_e2e);

    test('같은 영수증으로 두 번 등록하면 막지 않고 DUPLICATE 경고로 기록된다', () async {
      if (!await serverHasReceipts()) return markTestSkipped('서버에 /receipts 가 없다 (#66 전)');
      final same = utf8.encode('duplicate receipt ${DateTime.now().microsecondsSinceEpoch}');
      final (first, o1) = await register(kind: EntryKind.EXPENSE, amount: 1000, budgetId: 1, receiptBytes: same);
      final (second, o2) = await register(kind: EntryKind.EXPENSE, amount: 1000, budgetId: 1, receiptBytes: same);
      expect(o1.status, EntryStatus.PENDING);
      expect(o2.status, EntryStatus.PENDING, reason: '409 로 막지 않는다 (#66 B4)');
      expect((await readEntry(first)).ocrStatus, isNot(OcrStatus.DUPLICATE));
      expect((await readEntry(second)).ocrStatus, OcrStatus.DUPLICATE, reason: '승인자 화면에 경고로 보인다');
    }, skip: !_e2e);
  });

  test('확정 시점에 예산이 모자라면 400 + fail_reason=InsufficientBudget 으로 돌아온다 (#65) — 새로 띄운 스택 기준', () async {
    // 운영비(#3, 1,000,000원)에 70만 원 두 건 — 등록 때는 각각 잔량 안이라 PENDING, 첫 건 확정 뒤 둘째는 잔량 부족
    final (a, oa) = await register(kind: EntryKind.EXPENSE, amount: 700000, budgetId: 3);
    if (oa.status == EntryStatus.BLOCKED) return markTestSkipped('운영비 예산이 이미 소모됐다 — 스택을 초기화하고 돌린다');
    final (b, ob) = await register(kind: EntryKind.EXPENSE, amount: 700000, budgetId: 3);
    expect(ob.status, EntryStatus.PENDING);

    await loginAs('20240003', auditorKey);
    await decisions.confirm(await readEntry(a));
    await expectLater(
      decisions.confirm(await readEntry(b)),
      throwsA(isA<EntryDecisionException>()
          .having((e) => e.failure, 'failure', EntryDecisionFailure.refused)
          .having((e) => e.failReason, 'failReason', 'InsufficientBudget')),
    );
    expect((await readEntry(b)).status, EntryStatus.PENDING, reason: '확정 실패는 revert — 반려로 넘길 수 있다');
  }, skip: !_e2e);

  group('정정 · 다시 등록 · 증액 요청 (보드 11/7)', () {
    EntryRegistrationService registrar() =>
        EntryRegistrationService(signer: SigningService(authenticator: FakeAuthenticator()));

    test('확정된 지출을 감액 정정하면 원본을 가리키는 음수 항목이 체인에 올라가고, 승인으로 확정된다', () async {
      final (original, o) = await register(kind: EntryKind.EXPENSE, amount: 30000, budgetId: 1);
      expect(o.status, EntryStatus.PENDING);
      await loginAs('20240003', auditorKey);
      await decisions.confirm(await readEntry(original));
      final src = await readEntry(original);
      expect(src.status, EntryStatus.CONFIRMED);

      // 정정 화면과 같은 초안 — 원본의 종류·학기·거래처·사용일·예산, 증감분, 상세 사유는 목적 칸 (HASHING 샘플 3)
      await loginAs('20240002', _treasurerKey);
      final reg = registrar();
      final evidence = utf8.encode('correction evidence ${DateTime.now().microsecondsSinceEpoch}');
      final up = await serverHasReceipts() ? await reg.uploadReceipt(evidence, filename: 'receipt.jpg') : null;
      final draft = EntryDraft(
        kind: src.kind,
        termId: src.termId,
        amount: -10000,
        counterparty: src.counterparty,
        purpose: 'e2e 입력 오류 정정',
        budgetId: src.budgetId,
        occurredAt: src.occurredAt,
        receiptHash: up?.hash,
        receiptPath: up?.path,
        correctsEntryId: src.id,
        correctionReason: CorrectionReason.INPUT_ERROR,
      );
      final id = await reg.saveDraft(draft);
      final outcome = await reg.submit(id, draft);
      expect(outcome.status, EntryStatus.PENDING, reason: '서명의 correctsId·음수 금액을 체인이 받았다');

      await loginAs('20240003', auditorKey);
      final pending = await readEntry(id);
      expect(pending.correctsEntryId, original);
      expect(pending.correctionReason, CorrectionReason.INPUT_ERROR);
      expect(pending.amount, -10000);
      await decisions.confirm(pending);
      expect((await readEntry(id)).status, EntryStatus.CONFIRMED, reason: '감액 정정 확정 — 예산으로 refund');
    }, skip: !_e2e);

    test('반려된 지출을 같은 영수증으로 다시 등록하면 새 번호로 PENDING — 영수증은 서버에서 받아 해시를 대조한다', () async {
      if (!await serverHasReceipts()) return markTestSkipped('서버에 /receipts 가 없다 (#66 전)');
      final (old, _) = await register(kind: EntryKind.EXPENSE, amount: 20000, budgetId: 1);
      await loginAs('20240003', auditorKey);
      await decisions.reject(await readEntry(old), 'e2e 반려 — 금액 확인');
      final rejected = await readEntry(old);
      expect(rejected.status, EntryStatus.REJECTED);

      await loginAs('20240002', _treasurerKey);
      final reg = registrar();
      final bytes = await reg.downloadReceipt(rejected.receiptPath!);
      expect(bytes, isNotNull);
      expect(Hashing.fileHash(bytes!), rejected.receiptHash, reason: '서버가 준 해시를 믿지 않고 받은 바이트로 확인한다');

      final draft = EntryDraft(
        kind: rejected.kind,
        termId: rejected.termId,
        amount: 18000, // 고친 금액
        counterparty: rejected.counterparty,
        purpose: rejected.purpose,
        budgetId: rejected.budgetId,
        occurredAt: rejected.occurredAt,
        receiptHash: rejected.receiptHash,
        receiptPath: rejected.receiptPath,
      );
      final id = await reg.saveDraft(draft);
      final outcome = await reg.submit(id, draft);
      expect(id, isNot(old));
      expect(outcome.status, EntryStatus.PENDING);
      final again = await readEntry(id);
      expect(again.amount, 18000);
      expect((await readEntry(old)).status, EntryStatus.REJECTED, reason: '이전 기록은 그대로 남는다');
      // 같은 영수증 해시가 반려 건에 이미 있다 — 서버(#66)가 이것도 중복으로 보는지 기록해 둔다
      // ignore: avoid_print
      print('다시 등록한 #$id 의 ocr_status = ${again.ocrStatus?.code}');
    }, skip: !_e2e);

    test('차단된 지출을 근거로 증액을 요청하면 PENDING 요청이 생기고 차단 지출과 연결된다', () async {
      final (blocked, o) = await register(kind: EntryKind.EXPENSE, amount: 999000000, budgetId: 3);
      expect(o.status, EntryStatus.BLOCKED);

      await loginAs('20240002', _treasurerKey);
      final budgets = jsonDecode(utf8.decode(
              (await http.get(Uri.parse('$base/budgets'), headers: AuthService().authHeaders)).bodyBytes))
          as List<dynamic>;
      final b3 = budgets.cast<Map<String, dynamic>>().firstWhere((b) => b['id'] == 3);
      final requestId = await BudgetRevisionService().requestIncrease(IncreaseRequestDraft(
        termId: b3['term_id'] as int,
        category: b3['category'] as String,
        budgetId: 3,
        amount: 500000,
        reason: 'e2e 증액 — 무대 장비 대여료 인상\n견적서 기준',
        blockedEntryId: blocked,
      ));

      final res = await http.get(Uri.parse('$base/budget-revisions/$requestId'), headers: AuthService().authHeaders);
      expect(res.statusCode, 200, reason: res.body);
      final r = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      expect(r['status'], 'PENDING', reason: '회장 서명을 기다린다');
      expect(r['blocked_entry_id'], blocked);
      expect(r['requested_amount'], 500000, reason: '증액분');
      expect(r['budget_id'], 3);
    }, skip: !_e2e);
  });
}

