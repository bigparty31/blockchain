import 'dart:convert';

import 'package:web3dart/web3dart.dart' show keccak256;

import '../hashing.dart';
import 'eip712.dart';

/// 예산(`BudgetToken`) 도메인으로 서명하는 구조체 — 발행(`IssueRequest`, 회장)과 증액(`IncreaseRequest`, 회장·감사).
///
/// 필드 이름·순서·타입은 `IBudgetToken.sol` 의 typehash, `backend/app/chain/eip712.py` 의 `ISSUE_REQUEST_FIELDS`·
/// `INCREASE_REQUEST_FIELDS` 와 같다. 하나라도 다르면 다른 다이제스트가 되어 체인이 `InvalidSignature` 로 거부한다.
/// 회수(`ReclaimRequest`)는 P2 라 아직 넣지 않았다 (벡터도 없다).
class BudgetTypes {
  BudgetTypes._();

  static const domainName = 'BudgetToken';

  /// 회장 — 학기 초 항목별 예산 발행.
  static const issueRequestFields = [
    Eip712Field('budgetId', 'uint256'),
    Eip712Field('term', 'uint256'),
    Eip712Field('category', 'bytes32'),
    Eip712Field('amount', 'uint256'),
    Eip712Field('expiresAt', 'uint256'),
    Eip712Field('deadline', 'uint256'),
  ];

  /// 회장(요청 서명)과 감사(승인 서명)가 **같은 값**에 서명한다 — 증액.
  static const increaseRequestFields = [
    Eip712Field('budgetId', 'uint256'),
    Eip712Field('amount', 'uint256'),
    Eip712Field('reasonHash', 'bytes32'),
    Eip712Field('version', 'uint256'),
    Eip712Field('deadline', 'uint256'),
  ];

  /// 승인된 항목 이름 — `docs/CONTRACTS.md` category 표, 서버 `APPROVED_CATEGORIES` 와 같다.
  /// 표가 바뀌면 같이 고친다 (팀장 승인).
  static const approvedCategories = {
    '학생회비', '지원금', '후원금', '이자수입', '행사비', '사업비', '운영비', '홍보비', '복지비', '회의비', '비품비', '예비비',
  };

  /// `IssueRequest.category` = `keccak256(utf8(항목명))`.
  ///
  /// **표에 있는 이름만 받는다.** 서버와 같은 규칙이다 — 보이지 않는 문자(U+200B 등)가 섞인 이름은 같아 보여도 다른
  /// 예산이 된다. 이름을 고쳐 주지 않는다 — 고쳐서 해시하면 사람이 본 값과 서명한 값이 달라진다.
  static String categoryHash(String name) {
    if (!approvedCategories.contains(name)) {
      throw ArgumentError.value(name, 'name', '승인된 항목 표(docs/CONTRACTS.md)에 없는 이름이다');
    }
    return Eip712.toHex(keccak256(utf8.encode(name)));
  }

  /// `IncreaseRequest.reasonHash` = 정본화한 사유의 SHA-256 (서버 `text_hash(canonical_text(reason))`, API §3).
  /// 서버가 저장한 사유(`reason`)로 계산해야 회장·감사 서명과 서버 릴레이가 같은 값을 가리킨다.
  static String reasonHashOf(String reason) => Hashing.textHash(Hashing.canonicalText(reason));

  static Eip712Message issueRequest({
    required int budgetId,
    required int term,
    required String category,
    required int amount,
    required int expiresAt,
    required int deadline,
  }) =>
      Eip712Message('IssueRequest', issueRequestFields, {
        'budgetId': budgetId,
        'term': term,
        'category': category,
        'amount': amount,
        'expiresAt': expiresAt,
        'deadline': deadline,
      });

  /// [amount] 는 **증액분**이다 (바뀐 뒤 총액 아님). [version] 은 회장이 서명할 때의 온체인 예산 버전이고, 감사도 회장이
  /// 서명한 값(`signed_version`·`signature_deadline`)을 그대로 쓴다 — 다르면 두 서명이 다른 구조체를 가리킨다.
  static Eip712Message increaseRequest({
    required int budgetId,
    required int amount,
    required String reasonHash,
    required int version,
    required int deadline,
  }) =>
      Eip712Message('IncreaseRequest', increaseRequestFields, {
        'budgetId': budgetId,
        'amount': amount,
        'reasonHash': reasonHash,
        'version': version,
        'deadline': deadline,
      });
}
