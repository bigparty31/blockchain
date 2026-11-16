import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/signing/eip712.dart';
import '../core/signing/budget_types.dart';
import '../core/signing/ledger_types.dart';
import 'auth_service.dart';

/// 서명 도메인을 받지 못했거나 믿을 수 없을 때.
class ChainDomainException implements Exception {
  final String message;
  const ChainDomainException(this.message);

  @override
  String toString() => 'ChainDomainException: $message';
}

/// `GET /chain/domains` — 컨트랙트별 EIP-712 서명 도메인.
///
/// **도메인을 코드에 박지 않는다.** 재배포하면 주소가 바뀌므로 서명할 때마다 서버에서 받는다.
/// 대신 두 가지로 검산한다.
///   1. 앱이 계산한 도메인 해시 = 서버가 준 `domainSeparator` (체인 id·주소를 잘못 쓴 것을 잡는다)
///   2. 빌드 때 기대값을 넣었으면 그 값과 비교 (PRD v0.14 §7.3) — 서버가 장악돼 다른 컨트랙트 도메인을
///      내려주는 경우를 잡는다. 기대값은 `--dart-define` 으로 넣고, 넣지 않으면 비교하지 않는다.
class ChainDomainService {
  ChainDomainService._();

  /// HTTP 클라이언트. 테스트에서 갈아끼운다.
  static http.Client client = http.Client();
  static const timeout = Duration(seconds: 5);

  /// 빌드 때 넣는 기대값 (`--dart-define=EXPECTED_CHAIN_ID=… --dart-define=EXPECTED_LEDGER_ADDRESS=0x…`).
  /// 비어 있으면(기본) 비교하지 않는다. 테스트에서 바꿀 수 있게 상수가 아니라 필드로 둔다.
  static int expectedChainId = const int.fromEnvironment('EXPECTED_CHAIN_ID');
  static String expectedLedgerAddress = const String.fromEnvironment('EXPECTED_LEDGER_ADDRESS');
  static String expectedBudgetAddress = const String.fromEnvironment('EXPECTED_BUDGET_ADDRESS');

  /// 모든 도메인 (컨트랙트 이름 → 도메인).
  static Future<Map<String, Eip712Domain>> fetchAll() async {
    final http.Response res;
    try {
      res = await client
          .get(Uri.parse('${ApiConfig.baseUrl}/chain/domains'), headers: AuthService().authHeaders)
          .timeout(timeout);
    } catch (_) {
      throw const ChainDomainException('서명 도메인을 받지 못했어요. 네트워크를 확인해 주세요.');
    }
    if (res.statusCode != 200) {
      throw ChainDomainException('서명 도메인을 받지 못했어요 (서버 ${res.statusCode}).');
    }
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final domains = body['domains'] as Map<String, dynamic>;
      return {
        for (final e in domains.entries) e.key: Eip712Domain.fromJson(e.value as Map<String, dynamic>),
      };
    } catch (_) {
      throw const ChainDomainException('서명 도메인 응답 형식이 올바르지 않아요.');
    }
  }

  /// 원장 도메인 — 등록·확정·반려 서명에 쓴다. 검산을 통과한 것만 돌려준다.
  static Future<Eip712Domain> ledger() async {
    final domain = (await fetchAll())[LedgerTypes.domainName];
    if (domain == null) throw const ChainDomainException('원장 서명 도메인이 서버에 없어요.');
    checkTrusted(domain, expectedAddress: expectedLedgerAddress);
    return domain;
  }

  /// 예산 도메인 — 발행(`IssueRequest`)·증액(`IncreaseRequest`) 서명에 쓴다. 검산을 통과한 것만 돌려준다.
  static Future<Eip712Domain> budget() async {
    final domain = (await fetchAll())[BudgetTypes.domainName];
    if (domain == null) throw const ChainDomainException('예산 서명 도메인이 서버에 없어요.');
    checkTrusted(domain, expectedAddress: expectedBudgetAddress);
    return domain;
  }

  /// 검산. 통과하지 못하면 던진다.
  static void checkTrusted(Eip712Domain domain, {String expectedAddress = ''}) {
    if (!domain.separatorMatches) {
      throw ChainDomainException('${domain.name} 도메인 해시가 체인 값과 달라요.');
    }
    if (expectedChainId != 0 && domain.chainId != expectedChainId) {
      throw ChainDomainException('${domain.name} 체인 id 가 앱에 넣은 값과 달라요.');
    }
    if (expectedAddress.isNotEmpty && domain.verifyingContract.toLowerCase() != expectedAddress.toLowerCase()) {
      throw ChainDomainException('${domain.name} 컨트랙트 주소가 앱에 넣은 값과 달라요.');
    }
  }
}
