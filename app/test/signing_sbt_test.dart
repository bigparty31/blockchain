import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/signing/device_key.dart';
import 'package:student_council_app/core/signing/eip712.dart';
import 'package:student_council_app/core/signing/sbt_types.dart';
import 'package:student_council_app/core/signing/signing_service.dart';
import 'package:web3dart/web3dart.dart' as web3 show keccak256, sign;

/// 회원권(`MembershipSBT`) 도메인 서명이 컨트랙트 명세와 **같은 바이트**를 내는가.
///
/// 명세는 `contracts/interfaces/IMembershipSBT.sol`(develop)의 `MintBatchRequest`·`BurnRequest` typehash 와
/// 「address[] 는 keccak256(abi.encodePacked(recipients))」 규칙이다. 컨트랙트 구현·`eip712_vectors.json` 의
/// SBT 벡터가 아직 없어서, 벡터는 **ethers v6 `TypedDataEncoder`**(6.17.0)로 같은 명세를 따라 계산한 값이다.
/// 컨트랙트 구현과 서버 벡터가 나오면 아래 값이 그것과도 같은지 한 번 더 대조한다.
void main() {
  const domainJson = {
    'name': 'MembershipSBT',
    'version': '1',
    'chainId': 31337,
    'verifyingContract': '0x5FbDB2315678afecb367f032d93F642f64180aa3',
    'domainSeparator': '0xd3c1b9a74f9f561108bd72b12aadd592342d9ca8407481a74fd0ed64526b6c9e',
  };
  final domain = Eip712Domain.fromJson(domainJson);

  const a = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8'; // Hardhat #1 — 회장
  const b = '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC'; // Hardhat #2 — 총무
  const zero = '0x0000000000000000000000000000000000000000';

  const mintTypeHash = '0x620f04a17a5f2f8a289a03481dac82a7c3b175e44bca7a2570577d168d69b466';
  const burnTypeHash = '0x7299d54d04209a7e78c217caa5027b5c1349202ce875bbcec8c586812b8a2295';

  /// (이름, 구조체, typeHash, hashStruct, digest) — ethers `TypedDataEncoder` 출력.
  final vectors = <(String, Eip712Message Function(), String, String, String)>[
    (
      'mint_two',
      () => SbtTypes.mintBatchRequest(recipients: [a, b], term: 20262, nonce: 0, deadline: 1800000000),
      mintTypeHash,
      '0x517da5df26741c52cf927a6c9248a2016926b513dd1807e53f03606589ea287d',
      '0x5bce7e4bd78a350f2b4e1526aee7f3035403fb899fb071e9e9871c486fa353fc',
    ),
    (
      'mint_one',
      () => SbtTypes.mintBatchRequest(recipients: [a], term: 20262, nonce: 5, deadline: 1800000000),
      mintTypeHash,
      '0x63d4c6363292a95eb8483f3bbe5edb432a7e4ccdfebb31fb1781c259e72abc2c',
      '0x2da8f124f50058a816eec68a8bb2a93cb54a23345a769d3f7754bae90016de49',
    ),
    (
      'burn_withdrawal',
      () => SbtTypes.burnRequest(holder: a, term: 20262, reason: 'WITHDRAWAL', nonce: 3, deadline: 1800000000),
      burnTypeHash,
      '0xc8f4c28e9c28be9f51f1b77b57b2749fb9525a2cc25ded1513ca4ac8a893891f',
      '0x756e037dad6ac5560efe40b25577ae41d6be9b6720ce12cd02b7864218b3f792',
    ),
    (
      'burn_refund',
      () => SbtTypes.burnRequest(holder: b, term: 20261, reason: 'REFUND', nonce: 0, deadline: 1799999999),
      burnTypeHash,
      '0x5d2e48ed6a48f8a5588f7a41253c51c061f179b39bd171536f6ba71d9681ec4c',
      '0x604cabc5a635cc92044cbe4c4695d182f75c648d1867ab8d0f624c5c71b1a3b9',
    ),
  ];

  group('address[] 인코딩 (EIP-712 배열 규칙)', () {
    Uint8List word(String addr) => Eip712.encodeValue('address', addr);

    test('원소를 32바이트로 채워 이어 붙인 것의 keccak256 이다', () {
      final expected = web3.keccak256(Eip712.concat([word(a), word(b)]));
      expect(Eip712.toHex(Eip712.encodeValue('address[]', [a, b])), Eip712.toHex(expected));
    });

    test('빈 배열은 빈 바이트의 keccak256 이다', () {
      expect(Eip712.toHex(Eip712.encodeValue('address[]', <String>[])), Eip712.toHex(web3.keccak256(Uint8List(0))));
    });

    test('순서가 바뀌면 다른 값이다 — 서명이 같은 수령자 목록을 가리켜야 한다', () {
      expect(Eip712.toHex(Eip712.encodeValue('address[]', [a, b])) == Eip712.toHex(Eip712.encodeValue('address[]', [b, a])),
          isFalse);
    });

    test('목록이 아니거나 원소가 주소가 아니면 던진다 — 조용히 자르거나 건너뛰지 않는다', () {
      expect(() => Eip712.encodeValue('address[]', a), throwsArgumentError);
      expect(() => Eip712.encodeValue('address[]', [a, '0x1234']), throwsArgumentError);
      expect(() => Eip712.encodeValue('address[]', [a, 7]), throwsA(anything));
    });
  });

  test('앱이 계산한 SBT 도메인 해시 = DOMAIN_SEPARATOR()', () {
    expect(domain.separatorMatches, isTrue);
    expect(SbtTypes.domainName, 'MembershipSBT');
  });

  for (final (name, build, typeHash, hashStruct, digest) in vectors) {
    test('$name — typeHash·hashStruct·다이제스트가 ethers 벡터와 같다', () {
      final message = build();
      expect(Eip712.toHex(message.typeHash()), typeHash);
      expect(Eip712.toHex(message.hashStruct()), hashStruct);
      expect(Eip712.toHex(Eip712.digest(domain, message)), digest);
    });
  }

  test('typehash 원문이 컨트랙트(IMembershipSBT.sol)와 같다', () {
    expect(vectors[0].$2().encodedType, 'MintBatchRequest(address[] recipients,uint256 term,uint256 nonce,uint256 deadline)');
    expect(vectors[2].$2().encodedType,
        'BurnRequest(address holder,uint256 term,uint8 reason,uint256 nonce,uint256 deadline)');
  });

  test('서명하면 서명자가 복구된다 — 회장 키', () {
    const presidentKey = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d';
    final d = Eip712.digest(domain, vectors[0].$2());
    final pk = Eip712.hexToBytes(presidentKey);
    final sig = SigningService.encodeSignature(web3.sign(d, pk));
    expect(SigningService.recoverSigner(d, sig), a.toLowerCase());
    expect(DeviceKey.addressOf(pk), a.toLowerCase());
  });

  group('보내기 전 검사 — 컨트랙트가 revert 할 요청은 서명하게 두지 않는다', () {
    test('수령자는 1~100명이다 (빈 배열·101명 거부, 100명은 허용)', () {
      expect(() => SbtTypes.mintBatchRequest(recipients: [], term: 20262, nonce: 0, deadline: 1), throwsArgumentError);
      final hundred = [for (var i = 1; i <= 100; i++) '0x${i.toRadixString(16).padLeft(40, '0')}'];
      expect(SbtTypes.mintBatchRequest(recipients: hundred, term: 20262, nonce: 0, deadline: 1).values['recipients'],
          hasLength(100));
      expect(() => SbtTypes.mintBatchRequest(recipients: [...hundred, a], term: 20262, nonce: 0, deadline: 1),
          throwsArgumentError);
    });

    test('0 주소가 하나라도 있으면 거부한다', () {
      expect(() => SbtTypes.mintBatchRequest(recipients: [a, zero], term: 20262, nonce: 0, deadline: 1), throwsArgumentError);
      expect(() => SbtTypes.burnRequest(holder: zero, term: 20262, reason: 'REFUND', nonce: 0, deadline: 1),
          throwsArgumentError);
    });

    test('학기 코드는 0 이 될 수 없다 (TermRequired)', () {
      expect(() => SbtTypes.mintBatchRequest(recipients: [a], term: 0, nonce: 0, deadline: 1), throwsArgumentError);
      expect(() => SbtTypes.burnRequest(holder: a, term: 0, reason: 'REFUND', nonce: 0, deadline: 1), throwsArgumentError);
    });

    test('소각 사유는 docs/enums.md burn_reason 의 두 값만, 순서대로 0·1 이다', () {
      expect(SbtTypes.burnReasonCodes, {'REFUND': 0, 'WITHDRAWAL': 1});
      for (final bad in ['', 'refund', 'OTHER', 'EXPELLED']) {
        expect(() => SbtTypes.burnRequest(holder: a, term: 20262, reason: bad, nonce: 0, deadline: 1), throwsArgumentError,
            reason: bad);
      }
      expect(SbtTypes.burnRequest(holder: a, term: 20262, reason: 'WITHDRAWAL', nonce: 0, deadline: 1).values['reason'], 1);
    });
  });
}
