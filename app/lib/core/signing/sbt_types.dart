import 'eip712.dart';

/// 회원권(`MembershipSBT`) 도메인으로 서명하는 구조체 — 발행(`MintBatchRequest`)과 소각(`BurnRequest`), 회장·감사.
///
/// 필드 이름·순서·타입은 `contracts/interfaces/IMembershipSBT.sol` 의 typehash 와 같다. 하나라도 다르면 다른
/// 다이제스트가 되어 체인이 `InvalidSignature` 로 거부한다. 이 파일은 **서명할 값을 만들기까지**다 — 서명 호출,
/// 서버로 보내기, `GET /chain/domains` 의 SBT 도메인 연결은 컨트랙트 구현과 서버 API 가 나온 뒤에 붙인다.
///
/// **컨트랙트가 되돌릴 요청은 여기서 먼저 던진다.** 서명한 뒤에 체인이 거부하면 사용자는 왜 안 되는지 알 수 없다
/// (수령자 1~100명, 0 주소 금지, 학기 코드 0 금지 — 인터페이스 `@dev`).
class SbtTypes {
  SbtTypes._();

  static const domainName = 'MembershipSBT';

  /// 한 배치의 수령자 상한 (`IMembershipSBT` — 1~100명).
  static const maxBatch = 100;

  static const mintBatchRequestFields = [
    Eip712Field('recipients', 'address[]'),
    Eip712Field('term', 'uint256'),
    Eip712Field('nonce', 'uint256'),
    Eip712Field('deadline', 'uint256'),
  ];

  static const burnRequestFields = [
    Eip712Field('holder', 'address'),
    Eip712Field('term', 'uint256'),
    Eip712Field('reason', 'uint8'),
    Eip712Field('nonce', 'uint256'),
    Eip712Field('deadline', 'uint256'),
  ];

  /// `docs/enums.md` burn_reason — 컨트랙트 `BurnReason` 순서 그대로 (REFUND 0, WITHDRAWAL 1).
  static const burnReasonCodes = <String, int>{'REFUND': 0, 'WITHDRAWAL': 1};

  /// 수령자 [recipients] 에게 [term] 학기 회원권을 한 번에 발행. [nonce] 는 서명자별 다음 값(발행·소각 공유)이다.
  static Eip712Message mintBatchRequest({
    required List<String> recipients,
    required int term,
    required int nonce,
    required int deadline,
  }) {
    if (recipients.isEmpty || recipients.length > maxBatch) {
      throw ArgumentError.value(recipients.length, 'recipients', '수령자는 1~$maxBatch명이어야 한다');
    }
    for (final r in recipients) {
      _requireAddress(r, 'recipients');
    }
    _requireTerm(term);
    return Eip712Message('MintBatchRequest', mintBatchRequestFields, {
      'recipients': recipients,
      'term': term,
      'nonce': nonce,
      'deadline': deadline,
    });
  }

  /// [holder] 의 [term] 학기 회원권 소각. [reason] 은 `REFUND`·`WITHDRAWAL`.
  static Eip712Message burnRequest({
    required String holder,
    required int term,
    required String reason,
    required int nonce,
    required int deadline,
  }) {
    _requireAddress(holder, 'holder');
    _requireTerm(term);
    final code = burnReasonCodes[reason];
    if (code == null) {
      throw ArgumentError.value(reason, 'reason', '소각 사유는 ${burnReasonCodes.keys.join('·')} 중 하나다');
    }
    return Eip712Message('BurnRequest', burnRequestFields, {
      'holder': holder,
      'term': term,
      'reason': code,
      'nonce': nonce,
      'deadline': deadline,
    });
  }

  static void _requireTerm(int term) {
    if (term <= 0) throw ArgumentError.value(term, 'term', '학기 코드는 0 일 수 없다 (TermRequired)');
  }

  static void _requireAddress(String address, String name) {
    final bytes = Eip712.hexToBytes(address); // 형식이 틀리면 여기서 던진다
    if (bytes.length != 20) throw ArgumentError.value(address, name, '주소는 20바이트여야 한다');
    if (bytes.every((b) => b == 0)) throw ArgumentError.value(address, name, '0 주소는 쓸 수 없다');
  }
}
