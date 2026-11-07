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
  Future<(int, SubmitOutcome)> register({required EntryKind kind, required int amount, int? budgetId}) async {
    await loginAs('20240002', _treasurerKey);
    final tag = DateTime.now().microsecondsSinceEpoch;
    final draft = EntryDraft(
      kind: kind,
      termId: 1,
      amount: amount,
      counterparty: 'e2e 거래처 $tag',
      purpose: 'e2e ${kind.code} $tag',
      budgetId: budgetId,
      occurredAt: Hashing.kstMidnightOf(2026, 11, 6),
      receiptHash: kind == EntryKind.EXPENSE ? Hashing.fileHash(utf8.encode('receipt $tag')) : null,
    );
    final registrar = EntryRegistrationService(signer: SigningService(authenticator: FakeAuthenticator()));
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
}
