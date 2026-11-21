import 'eip712.dart';

/// 이의 제기(`ObjectionRegistry`) 도메인으로 서명하는 구조체 — 임원(감사·회장)의 이의 답변(`AnswerRequest`).
///
/// 필드 이름·순서·타입은 `contracts/interfaces/IObjectionRegistry.sol` 의 typehash
/// `AnswerRequest(uint256 objectionId,bytes32 answerHash,uint256 deadline)` 와 같다. 하나라도 다르면 다른
/// 다이제스트가 되어 체인이 `InvalidSignature` 로 거부한다.
///
/// **컨트랙트가 되돌릴 값은 여기서 먼저 던진다.** 서명한 뒤에 체인이 거부하면 사용자는 왜 안 되는지 알 수 없다.
class ObjectionTypes {
  ObjectionTypes._();

  static const domainName = 'ObjectionRegistry';

  static const answerRequestFields = [
    Eip712Field('objectionId', 'uint256'),
    Eip712Field('answerHash', 'bytes32'),
    Eip712Field('deadline', 'uint256'),
  ];

  static final _bytes32 = RegExp(r'^0x[0-9a-fA-F]{64}$');

  /// [objectionId] 번 이의에 대한 답변 [answerHash](본문 정본의 SHA-256)에 [deadline] 까지 유효한 서명을 한다.
  static Eip712Message answerRequest({
    required int objectionId,
    required String answerHash,
    required int deadline,
  }) {
    if (objectionId < 1) {
      throw ArgumentError.value(objectionId, 'objectionId', '이의 번호는 1 이상이어야 한다');
    }
    if (!_bytes32.hasMatch(answerHash)) {
      throw ArgumentError.value(answerHash, 'answerHash', '답변 해시는 0x + 64자리 16진수여야 한다');
    }
    if (deadline < 0) {
      throw ArgumentError.value(deadline, 'deadline', '서명 시한은 0 이상이어야 한다');
    }
    return Eip712Message('AnswerRequest', answerRequestFields, {
      'objectionId': objectionId,
      'answerHash': answerHash,
      'deadline': deadline,
    });
  }
}
