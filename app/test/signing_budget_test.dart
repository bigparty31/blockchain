import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/signing/budget_types.dart';
import 'package:student_council_app/core/signing/device_key.dart';
import 'package:student_council_app/core/signing/eip712.dart';
import 'package:student_council_app/core/signing/signing_service.dart';
import 'package:student_council_app/services/chain_domain_service.dart';
import 'package:web3dart/web3dart.dart' as web3 show sign;

/// 예산(`BudgetToken`) 도메인 서명이 컨트랙트·서버와 **같은 바이트**를 내는가.
///
/// 벡터는 `contracts/scripts/eip712Vectors.ts`(ethers)가 만든 `backend/tests/fixtures/eip712_vectors.json` 의
/// `budgetDomain`·`budgetVectors` 다 (#37, develop). 이 브랜치의 fixture 는 #37 이전 것이라 같은 값을 여기에 옮겨 두고,
/// fixture 에 예산 벡터가 있으면(develop 과 합쳐진 뒤) 두 값이 같은지도 대조한다 — 서버 쪽 벡터가 바뀌면 여기서 깨진다.
void main() {
  const budgetDomainJson = {
    'name': 'BudgetToken',
    'version': '1',
    'chainId': 31337,
    'verifyingContract': '0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512',
    'domainSeparator': '0x1f2905a02b6b82de113d21bf22f98674232314b3d02d77ab6f4bdf7e0c252699',
  };
  final domain = Eip712Domain.fromJson(budgetDomainJson);

  const president = '0x70997970c51812dc3a010c7d01b50e0d17dc79c8'; // Hardhat #1 — 회장
  const auditor = '0x90f79bf6eb2c4f870365e785982e1f101e93b906'; // Hardhat #3 — 감사
  const hardhatKeys = {
    president: '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d',
    auditor: '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6',
  };

  final increaseMessage = BudgetTypes.increaseRequest(
    budgetId: 1,
    amount: 500000,
    reasonHash: BudgetTypes.reasonHashOf('vector:increase-reason'),
    version: 1,
    deadline: 1790700000,
  );

  /// `budgetVectors` 와 같은 값 — (이름, 구조체, 다이제스트, 서명자, 서명).
  final vectors = [
    (
      'issue_budget',
      BudgetTypes.issueRequest(
        budgetId: 1,
        term: 20262,
        category: BudgetTypes.categoryHash('행사비'),
        amount: 2000000,
        expiresAt: 1797177600,
        deadline: 1790700000,
      ),
      '0xe69f6024fa903e5813cec5cd174c7755aadb49cf22cec4b1e84ed7e9ef02d97e',
      president,
      '0x13515aa7a0df3a3134e5ecccebbdf09ecf092d08ecee1392b0b5f4c1a1976837451cb90653ef7d1215d127860892123b79c33699763e9664110e20274419de6c1c',
    ),
    (
      'increase_president',
      increaseMessage,
      '0xda299823017fbe77baf15d86b5c9f9295ac08f69342a7603ec39ac4d1334eff6',
      president,
      '0x579cf718fa14a4b4cc4b0f8c156ff78525b29cfe92c25b8e16e92b752bcdb3346eee8b0603ae993352b641b37dcd0d9200452f3a09a3d11f81e90c83dd9f9c0c1c',
    ),
    (
      'increase_auditor',
      increaseMessage,
      '0xda299823017fbe77baf15d86b5c9f9295ac08f69342a7603ec39ac4d1334eff6',
      auditor,
      '0x3ff4ba3ccb72ba19c3325456e24c4d18b89fd72530c661c7e10efda7c82619bc29cdf89742ef5695c204b89a64be9ca559b4de449364d20e04d7fe207842c20c1c',
    ),
  ];

  test('앱이 계산한 예산 도메인 해시 = 컨트랙트 DOMAIN_SEPARATOR()', () {
    expect(domain.separatorMatches, isTrue);
  });

  for (final (name, message, digest, signer, signature) in vectors) {
    test('$name — 다이제스트·서명·서명자가 벡터와 같다', () {
      final d = Eip712.digest(domain, message);
      expect(Eip712.toHex(d), digest);
      final pk = Eip712.hexToBytes(hardhatKeys[signer]!);
      expect(DeviceKey.addressOf(pk), signer, reason: '테스트 키가 벡터 서명자의 키여야 한다');
      expect(SigningService.encodeSignature(web3.sign(d, pk)), signature);
      expect(SigningService.recoverSigner(d, signature), signer);
    });
  }

  test('회장과 감사는 같은 증액 구조체에 서명한다 — 다이제스트가 하나다', () {
    expect(vectors[1].$3, vectors[2].$3);
  });

  test('typehash 원문이 컨트랙트와 같다', () {
    expect(
      BudgetTypes.issueRequest(budgetId: 0, term: 0, category: '0x${'0' * 64}', amount: 0, expiresAt: 0, deadline: 0)
          .encodedType,
      'IssueRequest(uint256 budgetId,uint256 term,bytes32 category,uint256 amount,uint256 expiresAt,uint256 deadline)',
    );
    expect(
      increaseMessage.encodedType,
      'IncreaseRequest(uint256 budgetId,uint256 amount,bytes32 reasonHash,uint256 version,uint256 deadline)',
    );
  });

  group('category — keccak256(utf8(항목명)), 승인된 표의 이름만', () {
    test('서버 테스트와 같은 값 (test_budget_relay.py)', () {
      expect(BudgetTypes.categoryHash('학생회비'), '0x30196e0702394f886c610dd63afe744491e2280bc4cb254069b0f6bb4e673015');
      expect(BudgetTypes.categoryHash('행사비'), '0x813d3904998cb03bb83478bc9ef8d8773f1ea9f2eefdb23e69b21648ce468b32');
    });

    test('표에 없는 이름·보이지 않는 문자가 섞인 이름은 거부한다 — 고쳐서 해시하지 않는다', () {
      for (final bad in ['행사', ' 행사비', '행사비 ', '행사\u200b비', '행사비\u0000', '']) {
        expect(() => BudgetTypes.categoryHash(bad), throwsArgumentError, reason: jsonEncode(bad));
      }
    });
  });

  test('증액 사유 해시는 정본화한 사유의 SHA-256 이다 — 줄바꿈·앞뒤 공백 차이로 갈라지지 않는다', () {
    final canonical = BudgetTypes.reasonHashOf('참가인원 증가\n견적서 기준');
    expect(BudgetTypes.reasonHashOf('  참가인원 증가\r\n견적서 기준  '), canonical);
    expect(BudgetTypes.reasonHashOf('vector:increase-reason'),
        '0xb9efac70e1e438ed7712086ad27f19d0a013c811e512c1d238a669b26e75c570');
  });

  test('fixture 에 예산 벡터가 있으면 여기 값과 같다', () {
    final file = File('../backend/tests/fixtures/eip712_vectors.json');
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final fixture = json['budgetVectors'] as List?;
    if (fixture == null) {
      markTestSkipped('이 브랜치의 fixture 는 #37 이전이라 예산 벡터가 없다');
      return;
    }
    expect(Map<String, Object?>.from(json['budgetDomain'] as Map), budgetDomainJson);
    for (final (name, message, digest, signer, signature) in vectors) {
      final v = fixture.cast<Map<String, dynamic>>().firstWhere((v) => v['name'] == name);
      expect(v['primaryType'], message.primaryType, reason: name);
      expect(Map<String, Object?>.from(v['message'] as Map), message.values, reason: name);
      expect(v['digest'], digest, reason: name);
      expect((v['signer'] as String).toLowerCase(), signer, reason: name);
      expect(v['signature'], signature, reason: name);
    }
  });

  group('GET /chain/domains — 예산 도메인', () {
    http.Response domainsResponse(Map<String, dynamic> budget) => http.Response(
          jsonEncode({'chainId': 31337, 'domains': {'BudgetToken': budget}}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );

    tearDown(() {
      ChainDomainService.client = http.Client();
      ChainDomainService.expectedBudgetAddress = '';
    });

    test('검산을 통과한 예산 도메인을 돌려준다', () async {
      ChainDomainService.client = MockClient((_) async => domainsResponse(budgetDomainJson));
      final d = await ChainDomainService.budget();
      expect(d.verifyingContract, budgetDomainJson['verifyingContract']);
    });

    test('도메인 해시가 맞지 않거나 기대 주소와 다르면 거부한다', () async {
      ChainDomainService.client = MockClient((_) async => domainsResponse({...budgetDomainJson, 'chainId': 1}));
      await expectLater(ChainDomainService.budget(), throwsA(isA<ChainDomainException>()));
      ChainDomainService.client = MockClient((_) async => domainsResponse(budgetDomainJson));
      ChainDomainService.expectedBudgetAddress = '0x0000000000000000000000000000000000000001';
      await expectLater(ChainDomainService.budget(), throwsA(isA<ChainDomainException>()));
    });

    test('서버에 예산 도메인이 없으면 서명하지 않는다', () async {
      ChainDomainService.client = MockClient((_) async => http.Response(
            jsonEncode({'chainId': 31337, 'domains': <String, Object>{}}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));
      await expectLater(ChainDomainService.budget(), throwsA(isA<ChainDomainException>()));
    });
  });
}
