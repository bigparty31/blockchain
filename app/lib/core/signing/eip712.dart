import 'dart:convert';
import 'dart:typed_data';

import 'package:web3dart/web3dart.dart' show keccak256;

/// EIP-712 구조화 서명 — **다이제스트 계산까지만** 한다. 키로 서명하는 것은 `signing_service.dart`.
///
/// 서버(`backend/app/chain/eip712.py`)·컨트랙트와 **같은 바이트**가 나와야 한다. 한 바이트라도 다르면
/// 서명은 만들어지는데 체인이 엉뚱한 주소를 복구해 `NotRegistrant`·`NotApprover` 로 되돌린다.
/// 검증은 `backend/tests/fixtures/eip712_vectors.json` 로 한다 (`test/signing_eip712_test.dart`).
///
///   digest = keccak256(0x19 0x01 ‖ domainSeparator ‖ hashStruct(message))

/// 서명 도메인 — `GET /chain/domains` 의 한 항목 (PRD v0.14 §9.2, 도메인은 컨트랙트마다 따로).
///
/// **코드에 박지 않는다.** 재배포하면 주소가 바뀌므로 매번 서버에서 받는다.
class Eip712Domain {
  final String name;
  final String version;
  final int chainId;
  final String verifyingContract;

  /// 서버가 함께 내려주는 컨트랙트의 `DOMAIN_SEPARATOR()`. [separatorMatches] 로 앱 계산값과 맞춰 본다.
  final String domainSeparator;

  const Eip712Domain({
    required this.name,
    required this.version,
    required this.chainId,
    required this.verifyingContract,
    required this.domainSeparator,
  });

  factory Eip712Domain.fromJson(Map<String, dynamic> json) => Eip712Domain(
        name: json['name'] as String,
        version: json['version'] as String,
        chainId: (json['chainId'] as num).toInt(),
        verifyingContract: json['verifyingContract'] as String,
        domainSeparator: json['domainSeparator'] as String,
      );

  static const _type = 'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)';

  /// 앱이 직접 계산한 도메인 해시.
  Uint8List separator() => keccak256(Eip712.concat([
        keccak256(Uint8List.fromList(utf8.encode(_type))),
        keccak256(Uint8List.fromList(utf8.encode(name))),
        keccak256(Uint8List.fromList(utf8.encode(version))),
        Eip712.encodeValue('uint256', chainId),
        Eip712.encodeValue('address', verifyingContract),
      ]));

  String separatorHex() => Eip712.toHex(separator());

  /// 앱 계산값이 서버가 준 `domainSeparator` 와 같은가. 다르면 체인 id·주소가 어긋난 것이라
  /// 서명해도 체인이 거부한다 — 서명 전에 막는다.
  bool get separatorMatches => separatorHex() == domainSeparator.toLowerCase();
}

/// 구조체의 필드 하나 (이름, Solidity 타입). 순서가 typehash 에 들어가므로 컨트랙트와 같은 순서로 둔다.
class Eip712Field {
  final String name;
  final String type;
  const Eip712Field(this.name, this.type);
}

/// 서명할 구조체 — 타입 이름, 필드 목록, 값.
class Eip712Message {
  final String primaryType;
  final List<Eip712Field> fields;
  final Map<String, Object?> values;

  const Eip712Message(this.primaryType, this.fields, this.values);

  /// `RecordRequest(uint256 id,bytes32 hash,...)` — 컨트랙트 typehash 의 원문.
  String get encodedType => '$primaryType(${fields.map((f) => '${f.type} ${f.name}').join(',')})';

  Uint8List typeHash() => keccak256(Uint8List.fromList(utf8.encode(encodedType)));

  Uint8List hashStruct() => keccak256(Eip712.concat([
        typeHash(),
        for (final f in fields) Eip712.encodeValue(f.type, _valueOf(f.name)),
      ]));

  Object _valueOf(String name) {
    if (!values.containsKey(name) || values[name] == null) {
      throw ArgumentError('$primaryType.$name 값이 없습니다');
    }
    return values[name]!;
  }
}

class Eip712 {
  Eip712._();

  /// 서명되는 32바이트.
  static Uint8List digest(Eip712Domain domain, Eip712Message message) => keccak256(concat([
        Uint8List.fromList(const [0x19, 0x01]),
        domain.separator(),
        message.hashStruct(),
      ]));

  /// 값 하나를 32바이트 워드로 (EIP-712 encodeData · `abi.encode` 의 정적 타입 규칙).
  ///
  /// 범위를 넘는 값은 조용히 자르지 않고 던진다 — 잘린 값으로 서명하면 화면에 보인 값과 다른 것에
  /// 서명하게 된다.
  static Uint8List encodeValue(String type, Object value) {
    if (type == 'bool') {
      if (value is! bool) throw ArgumentError('bool 이 아닙니다: $value');
      return word(value ? BigInt.one : BigInt.zero);
    }
    if (type == 'address') {
      final bytes = hexToBytes(value as String);
      if (bytes.length != 20) throw ArgumentError('주소는 20바이트여야 합니다: $value');
      return Uint8List(32)..setRange(12, 32, bytes);
    }
    if (type == 'bytes32') {
      final bytes = hexToBytes(value as String);
      if (bytes.length != 32) throw ArgumentError('bytes32 는 32바이트여야 합니다: $value');
      return bytes;
    }
    if (type == 'string') {
      return keccak256(Uint8List.fromList(utf8.encode(value as String)));
    }
    final uint = RegExp(r'^uint(\d+)$').firstMatch(type);
    if (uint != null) {
      final bits = int.parse(uint.group(1)!);
      final v = _toBigInt(value);
      if (v.isNegative || v.bitLength > bits) throw ArgumentError('$type 범위를 넘습니다: $value');
      return word(v);
    }
    final sint = RegExp(r'^int(\d+)$').firstMatch(type);
    if (sint != null) {
      final bits = int.parse(sint.group(1)!);
      final v = _toBigInt(value);
      final limit = BigInt.one << (bits - 1);
      if (v < -limit || v >= limit) throw ArgumentError('$type 범위를 넘습니다: $value');
      // 2의 보수 — 음수 정정 금액(int256)이 여기로 온다.
      return word(v.isNegative ? (BigInt.one << 256) + v : v);
    }
    throw ArgumentError('지원하지 않는 타입: $type');
  }

  /// 부호 없는 정수를 32바이트 빅엔디언으로.
  static Uint8List word(BigInt v) {
    final out = Uint8List(32);
    var x = v;
    for (var i = 31; i >= 0; i--) {
      out[i] = (x & BigInt.from(0xff)).toInt();
      x = x >> 8;
    }
    return out;
  }

  static BigInt _toBigInt(Object value) {
    if (value is BigInt) return value;
    if (value is int) return BigInt.from(value);
    if (value is String) return BigInt.parse(value);
    throw ArgumentError('정수가 아닙니다: $value');
  }

  static Uint8List concat(List<Uint8List> parts) {
    final out = BytesBuilder(copy: false);
    for (final p in parts) {
      out.add(p);
    }
    return out.toBytes();
  }

  /// `0x` 로 시작하는 16진 문자열 → 바이트. 홀수 길이·16진이 아닌 문자는 던진다.
  static Uint8List hexToBytes(String hex) {
    if (!hex.startsWith('0x')) throw ArgumentError('0x 로 시작해야 합니다: $hex');
    final body = hex.substring(2);
    if (body.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(body)) {
      throw ArgumentError('16진 문자열이 아닙니다: $hex');
    }
    return Uint8List.fromList([
      for (var i = 0; i < body.length; i += 2) int.parse(body.substring(i, i + 2), radix: 16),
    ]);
  }

  /// 바이트 → `0x` + 소문자 16진.
  static String toHex(Uint8List bytes) =>
      '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}
