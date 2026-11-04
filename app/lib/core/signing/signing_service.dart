import 'dart:typed_data';

import 'package:web3dart/web3dart.dart' as web3 show MsgSignature, ecRecover, publicKeyToAddress, sign;

import 'device_auth.dart';
import 'device_key.dart';
import 'eip712.dart';

/// 서명하지 못한 이유. [message] 를 그대로 화면에 띄운다.
class SigningException implements Exception {
  final String message;
  final DeviceAuthResult? auth;
  const SigningException(this.message, {this.auth});

  @override
  String toString() => 'SigningException: $message';
}

/// 임원 기기 서명 — 본인 확인 → 기기 키로 EIP-712 서명 (PRD v0.14 §9.2).
///
/// 서명값만 돌려준다. 서버에 보내는 것은 화면 쪽 일이다 (릴레이는 서버가 한다).
/// **실패하면 아무것도 돌려주지 않는다** — 반쯤 만든 서명이 나가는 일이 없게 [SigningException] 을 던진다.
class SigningService {
  final DeviceAuthenticator _auth;

  SigningService({DeviceAuthenticator? authenticator}) : _auth = authenticator ?? LocalDeviceAuthenticator();

  /// 이 기기에 서명 키를 만든다. 기기 잠금이 없으면 만들지 않는다 (PRD §9.2).
  Future<String> createKey() async {
    if (!await _auth.hasDeviceLock()) {
      throw SigningException(DeviceAuthResult.noDeviceLock.message, auth: DeviceAuthResult.noDeviceLock);
    }
    return DeviceKey.create();
  }

  /// [domain] 의 [message] 에 서명한다. `0x` + r(32) + s(32) + v(1) 의 65바이트 16진.
  ///
  /// 순서: 도메인 검산 → 키 확인 → 본인 확인 → 서명. 키가 없거나 도메인이 어긋나면 본인 확인을
  /// 묻지도 않는다 — 지문을 댄 뒤에 「서명할 수 없어요」가 뜨면 사용자는 무엇이 문제인지 모른다.
  Future<String> sign(Eip712Domain domain, Eip712Message message, {required String reason}) async {
    if (!domain.separatorMatches) {
      throw const SigningException('서명 도메인이 체인과 맞지 않아요. 서버 설정을 확인해 주세요.');
    }
    final pk = await DeviceKey.privateKey();
    if (pk == null) {
      throw const SigningException('이 기기에 서명 키가 없어요. 키를 먼저 만들어 주세요.');
    }
    final auth = await _auth.authenticate(reason);
    if (auth != DeviceAuthResult.success) throw SigningException(auth.message, auth: auth);

    return encodeSignature(web3.sign(Eip712.digest(domain, message), pk));
  }

  /// 서명값 → `0x` + r ‖ s ‖ v (ethers·서버 `normalize_signature` 와 같은 모양, v 는 27/28).
  static String encodeSignature(web3.MsgSignature sig) {
    String word(BigInt v) => v.toRadixString(16).padLeft(64, '0');
    return '0x${word(sig.r)}${word(sig.s)}${sig.v.toRadixString(16).padLeft(2, '0')}';
  }

  /// 서명값과 다이제스트로 서명자 주소를 복구한다 (소문자 `0x…`). 테스트와 자기 점검에 쓴다.
  static String recoverSigner(Uint8List digest, String signature) {
    final bytes = Eip712.hexToBytes(signature);
    if (bytes.length != 65) throw ArgumentError('서명은 65바이트여야 합니다');
    BigInt toInt(Uint8List b) => BigInt.parse(Eip712.toHex(b).substring(2), radix: 16);
    final sig = web3.MsgSignature(
      toInt(Uint8List.sublistView(bytes, 0, 32)),
      toInt(Uint8List.sublistView(bytes, 32, 64)),
      bytes[64],
    );
    return Eip712.toHex(web3.publicKeyToAddress(web3.ecRecover(digest, sig)));
  }
}
