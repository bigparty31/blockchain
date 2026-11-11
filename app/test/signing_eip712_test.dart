import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/signing/device_key.dart';
import 'package:student_council_app/core/signing/eip712.dart';
import 'package:student_council_app/core/signing/ledger_types.dart';
import 'package:student_council_app/core/signing/signing_service.dart';
import 'package:web3dart/web3dart.dart' as web3 show sign;

/// 앱 서명이 컨트랙트·서버와 **같은 바이트**를 내는가 — `backend/tests/fixtures/eip712_vectors.json`
/// (`contracts/scripts/eip712Vectors.ts`, ethers 로 생성) 으로 확인한다.
///
/// 지금 벡터는 원장(AccountingLedger) 도메인뿐이다. 예산·SBT 도메인 벡터가 생기면 여기에 더한다.
void main() {
  final vectorsFile = File('../backend/tests/fixtures/eip712_vectors.json');
  final json = jsonDecode(vectorsFile.readAsStringSync()) as Map<String, dynamic>;
  final domain = Eip712Domain.fromJson(json['domain'] as Map<String, dynamic>);
  final vectors = (json['vectors'] as List).cast<Map<String, dynamic>>();

  /// Hardhat 기본 계정 키 — 공개된 개발용 키다. 벡터의 서명자와 같은 키로 다시 서명해 본다.
  const hardhatKeys = {
    '0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc': '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a', // #2 총무
    '0x90f79bf6eb2c4f870365e785982e1f101e93b906': '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6', // #3 감사
  };

  List<Eip712Field> fieldsFor(String primaryType) => switch (primaryType) {
        'RecordRequest' => LedgerTypes.recordRequestFields,
        'ConfirmApproval' => LedgerTypes.confirmApprovalFields,
        'RejectDecision' => LedgerTypes.rejectDecisionFields,
        _ => throw ArgumentError(primaryType),
      };

  Eip712Message messageOf(Map<String, dynamic> v) => Eip712Message(
        v['primaryType'] as String,
        fieldsFor(v['primaryType'] as String),
        Map<String, Object?>.from(v['message'] as Map),
      );

  Map<String, dynamic> vector(String name) => vectors.firstWhere((v) => v['name'] == name);

  test('벡터가 원장 도메인 6건이다 (RecordRequest 3 · ConfirmApproval 2 · RejectDecision 1)', () {
    expect(domain.name, LedgerTypes.domainName);
    final types = vectors.map((v) => v['primaryType']).toList();
    expect(types.where((t) => t == 'RecordRequest'), hasLength(3));
    expect(types.where((t) => t == 'ConfirmApproval'), hasLength(2));
    expect(types.where((t) => t == 'RejectDecision'), hasLength(1));
  });

  test('앱이 계산한 도메인 해시 = 컨트랙트 DOMAIN_SEPARATOR()', () {
    expect(domain.separatorHex(), (json['domain'] as Map)['domainSeparator']);
    expect(domain.separatorMatches, isTrue);
  });

  test('도메인 주소나 체인 id 가 하나라도 다르면 검산에서 걸린다', () {
    final wrongChain = Eip712Domain(
      name: domain.name,
      version: domain.version,
      chainId: 80002, // Amoy
      verifyingContract: domain.verifyingContract,
      domainSeparator: domain.domainSeparator,
    );
    expect(wrongChain.separatorMatches, isFalse);
  });

  for (final v in vectors) {
    test('${v['name']} — 다이제스트·서명·서명자가 벡터와 같다', () {
      final digest = Eip712.digest(domain, messageOf(v));
      expect(Eip712.toHex(digest), v['digest']);

      final signer = (v['signer'] as String).toLowerCase();
      final pk = Eip712.hexToBytes(hardhatKeys[signer]!);
      expect(DeviceKey.addressOf(pk), signer, reason: '테스트 키가 벡터 서명자의 키여야 한다');

      // RFC 6979(결정적 k) + low-s 라 ethers 와 바이트까지 같다.
      expect(SigningService.encodeSignature(web3.sign(digest, pk)), v['signature']);
      expect(SigningService.recoverSigner(digest, v['signature'] as String), signer);
    });
  }

  test('entryCommit — 승인 서명이 묶는 등록값 = 벡터의 confirm_expense.entryCommit', () {
    final record = vector('record_expense')['message'] as Map<String, dynamic>;
    final commit = LedgerTypes.entryCommit(
      hash: record['hash'] as String,
      amount: record['amount'] as int,
      kind: record['kind'] == 0 ? EntryKind.INCOME : EntryKind.EXPENSE,
      term: record['term'] as int,
      occurredAt: record['occurredAt'] as int,
      budgetId: record['budgetId'] as int,
      correctsId: record['correctsId'] as int,
      registrant: vector('record_expense')['signer'] as String,
    );
    expect(commit, (vector('confirm_expense')['message'] as Map)['entryCommit']);
    expect(commit, (vector('reject_expense')['message'] as Map)['entryCommit']);
  });

  test('타입 있는 생성자로 만든 구조체도 같은 다이제스트를 낸다', () {
    final v = vector('record_negative_correction');
    final m = v['message'] as Map<String, dynamic>;
    final built = LedgerTypes.recordRequest(
      id: m['id'] as int,
      hash: m['hash'] as String,
      amount: m['amount'] as int, // 음수 — int256 2의 보수
      kind: m['kind'] == 0 ? EntryKind.INCOME : EntryKind.EXPENSE,
      term: m['term'] as int,
      occurredAt: m['occurredAt'] as int,
      budgetId: m['budgetId'] as int,
      correctsId: m['correctsId'] as int,
      deadline: m['deadline'] as int,
    );
    expect((m['amount'] as int).isNegative, isTrue);
    expect(Eip712.toHex(Eip712.digest(domain, built)), v['digest']);
  });

  group('범위를 넘는 값은 자르지 않고 던진다', () {
    test('uint8 · uint256 · int256', () {
      expect(() => Eip712.encodeValue('uint8', 256), throwsArgumentError);
      expect(() => Eip712.encodeValue('uint256', -1), throwsArgumentError);
      expect(() => Eip712.encodeValue('int256', BigInt.one << 255), throwsArgumentError);
      expect(Eip712.encodeValue('int256', -(BigInt.one << 255)), hasLength(32));
    });

    test('bytes32 · address 길이', () {
      expect(() => Eip712.encodeValue('bytes32', '0x1234'), throwsArgumentError);
      expect(() => Eip712.encodeValue('address', '0x1234'), throwsArgumentError);
      expect(() => Eip712.encodeValue('address', '3C44CdDdB6a900fa2b585dd299e03d12FA4293BC'), throwsArgumentError);
    });

    test('값이 빠진 필드', () {
      final m = Eip712Message('RejectDecision', LedgerTypes.rejectDecisionFields, const {'id': 1});
      expect(m.hashStruct, throwsArgumentError);
    });
  });
}
