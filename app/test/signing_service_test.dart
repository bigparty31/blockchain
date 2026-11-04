import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_auth/error_codes.dart' as auth_error;
import 'package:student_council_app/core/signing/device_auth.dart';
import 'package:student_council_app/core/signing/device_key.dart';
import 'package:student_council_app/core/signing/eip712.dart';
import 'package:student_council_app/core/signing/ledger_types.dart';
import 'package:student_council_app/core/signing/signing_service.dart';
import 'package:student_council_app/services/chain_domain_service.dart';

/// 가짜 본인 확인 — 몇 번 불렸는지 센다.
class FakeAuthenticator implements DeviceAuthenticator {
  final bool lock;
  final DeviceAuthResult result;
  int calls = 0;
  FakeAuthenticator({this.lock = true, this.result = DeviceAuthResult.success});

  @override
  Future<bool> hasDeviceLock() async => lock;

  @override
  Future<DeviceAuthResult> authenticate(String reason) async {
    calls++;
    return result;
  }
}

/// 서명 서비스 — 본인 확인·키 보관·도메인 검산 (PRD v0.14 §7.3 · §9.2).
void main() {
  final vectors = jsonDecode(File('../backend/tests/fixtures/eip712_vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final domainJson = vectors['domain'] as Map<String, dynamic>;
  final domain = Eip712Domain.fromJson(domainJson);
  final confirm = (vectors['vectors'] as List).cast<Map<String, dynamic>>().firstWhere((v) => v['name'] == 'confirm_expense');
  final confirmMessage = Eip712Message(
    'ConfirmApproval',
    LedgerTypes.confirmApprovalFields,
    Map<String, Object?>.from(confirm['message'] as Map),
  );
  const auditorKey = '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6'; // Hardhat #3

  setUp(() {
    DeviceKey.storage = MemoryKeyStorage();
    DeviceKey.allowDevKeyImport = true;
  });

  group('서명', () {
    test('Hardhat 감사 키로 서명하면 벡터와 같은 서명이 나온다', () async {
      await DeviceKey.importDevKey(auditorKey);
      final auth = FakeAuthenticator();
      final sig = await SigningService(authenticator: auth).sign(domain, confirmMessage, reason: '승인 서명');
      expect(sig, confirm['signature']);
      expect(auth.calls, 1);
    });

    test('본인 확인을 취소하면 서명하지 않는다', () async {
      await DeviceKey.importDevKey(auditorKey);
      final service = SigningService(authenticator: FakeAuthenticator(result: DeviceAuthResult.cancelled));
      await expectLater(
        service.sign(domain, confirmMessage, reason: '승인 서명'),
        throwsA(isA<SigningException>().having((e) => e.auth, 'auth', DeviceAuthResult.cancelled)),
      );
    });

    test('키가 없으면 본인 확인을 묻지도 않는다', () async {
      final auth = FakeAuthenticator();
      await expectLater(
        SigningService(authenticator: auth).sign(domain, confirmMessage, reason: '승인 서명'),
        throwsA(isA<SigningException>()),
      );
      expect(auth.calls, 0);
    });

    test('도메인 해시가 체인 값과 다르면 본인 확인 전에 막는다', () async {
      await DeviceKey.importDevKey(auditorKey);
      final tampered = Eip712Domain.fromJson({...domainJson, 'verifyingContract': '0x0000000000000000000000000000000000000001'});
      final auth = FakeAuthenticator();
      await expectLater(
        SigningService(authenticator: auth).sign(tampered, confirmMessage, reason: '승인 서명'),
        throwsA(isA<SigningException>()),
      );
      expect(auth.calls, 0);
    });
  });

  group('기기 키', () {
    test('기기 잠금이 없으면 키를 만들지 않는다', () async {
      final service = SigningService(authenticator: FakeAuthenticator(lock: false));
      await expectLater(
        service.createKey(),
        throwsA(isA<SigningException>().having((e) => e.auth, 'auth', DeviceAuthResult.noDeviceLock)),
      );
      expect(await DeviceKey.exists(), isFalse);
    });

    test('만든 키로 서명하면 그 주소가 복구된다', () async {
      final address = await SigningService(authenticator: FakeAuthenticator()).createKey();
      expect(address, matches(RegExp(r'^0x[0-9a-f]{40}$')));
      expect(await DeviceKey.address(), address);

      final sig = await SigningService(authenticator: FakeAuthenticator()).sign(domain, confirmMessage, reason: '승인 서명');
      expect(SigningService.recoverSigner(Eip712.digest(domain, confirmMessage), sig), address);
    });

    test('이미 키가 있으면 덮어쓰지 않는다 — 덮어쓰면 체인 롤과 주소가 어긋난다', () async {
      await DeviceKey.create(random: Random(1));
      final before = await DeviceKey.address();
      await expectLater(DeviceKey.create(random: Random(2)), throwsStateError);
      expect(await DeviceKey.address(), before);
    });

    test('개발 키 넣기는 개발 빌드에서만', () async {
      DeviceKey.allowDevKeyImport = false;
      await expectLater(DeviceKey.importDevKey(auditorKey), throwsStateError);
      expect(await DeviceKey.exists(), isFalse);
    });
  });

  group('본인 확인 오류 코드', () {
    test('local_auth 오류 → 결과', () {
      expect(LocalDeviceAuthenticator.fromErrorCode(auth_error.passcodeNotSet), DeviceAuthResult.noDeviceLock);
      expect(LocalDeviceAuthenticator.fromErrorCode(auth_error.notAvailable), DeviceAuthResult.noDeviceLock);
      expect(LocalDeviceAuthenticator.fromErrorCode(auth_error.lockedOut), DeviceAuthResult.lockedOut);
      expect(LocalDeviceAuthenticator.fromErrorCode(auth_error.permanentlyLockedOut), DeviceAuthResult.permanentlyLockedOut);
      expect(LocalDeviceAuthenticator.fromErrorCode('Something'), DeviceAuthResult.unavailable);
    });
  });

  group('GET /chain/domains', () {
    http.Response domainsResponse(Map<String, dynamic> ledger) => http.Response(
          jsonEncode({'chainId': ledger['chainId'], 'domains': {'AccountingLedger': ledger}}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );

    tearDown(() {
      ChainDomainService.client = http.Client();
      ChainDomainService.expectedChainId = 0;
      ChainDomainService.expectedLedgerAddress = '';
    });

    test('검산을 통과한 원장 도메인을 돌려준다', () async {
      ChainDomainService.client = MockClient((req) async {
        expect(req.url.path, '/chain/domains');
        return domainsResponse(domainJson);
      });
      final d = await ChainDomainService.ledger();
      expect(d.verifyingContract, domainJson['verifyingContract']);
    });

    test('서버가 준 도메인 해시와 앱 계산이 다르면 거부한다', () async {
      ChainDomainService.client = MockClient((_) async => domainsResponse({...domainJson, 'chainId': 1}));
      await expectLater(ChainDomainService.ledger(), throwsA(isA<ChainDomainException>()));
    });

    test('빌드 때 넣은 기대 주소와 다르면 거부한다 (PRD §7.3)', () async {
      ChainDomainService.client = MockClient((_) async => domainsResponse(domainJson));
      ChainDomainService.expectedLedgerAddress = '0x0000000000000000000000000000000000000001';
      await expectLater(ChainDomainService.ledger(), throwsA(isA<ChainDomainException>()));
    });

    test('서버 오류·연결 실패는 서명 도메인을 못 받은 것으로', () async {
      ChainDomainService.client = MockClient((_) async => http.Response('{}', 503));
      await expectLater(ChainDomainService.ledger(), throwsA(isA<ChainDomainException>()));
      ChainDomainService.client = MockClient((_) async => throw http.ClientException('연결 실패'));
      await expectLater(ChainDomainService.ledger(), throwsA(isA<ChainDomainException>()));
    });
  });
}
