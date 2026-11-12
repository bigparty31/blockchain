import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web3dart/web3dart.dart'
    show generateNewPrivateKey, padUint8ListTo32, privateKeyBytesToPublic, publicKeyToAddress, unsignedIntToBytes;

import '../dev_flags.dart';
import 'eip712.dart';

/// 임원 서명 키 보관소. 테스트에서 [MemoryKeyStorage] 로 갈아끼운다.
abstract class KeyStorage {
  Future<String?> read();
  Future<void> write(String privateKeyHex);
  Future<void> delete();
}

/// 기기 보안 저장소 (`flutter_secure_storage` — Android Keystore·iOS Keychain 으로 암호화).
class SecureKeyStorage implements KeyStorage {
  static const _key = 'council_signing_key_v1';
  final FlutterSecureStorage _storage;
  const SecureKeyStorage([this._storage = const FlutterSecureStorage()]);

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String privateKeyHex) => _storage.write(key: _key, value: privateKeyHex);

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

class MemoryKeyStorage implements KeyStorage {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String privateKeyHex) async => value = privateKeyHex;

  @override
  Future<void> delete() async => value = null;
}

/// 임원(총무·감사·회장)의 기기 키 (PRD v0.14 §9.2).
///
/// - **키는 이 기기 밖으로 나가지 않는다.** 서버가 임원 키를 가지면 승인 없이 확정 기록을 올릴 수 있다.
/// - 키를 만들거나 쓰기 전 본인 확인은 `SigningService` 가 한다. 여기는 보관만 한다.
/// - 주소는 서버에 등록하지 않는다. 발표용 배포 때 이 주소를 `RoleManager` 초기 롤로 넣는다 (§9.2).
class DeviceKey {
  DeviceKey._();

  static KeyStorage storage = const SecureKeyStorage();

  /// 개발·통합(~11/9)에는 Hardhat 키를 넣어 쓴다 (PRD v0.14 §9.2). 발표·배포 빌드에서는 막는다.
  static bool allowDevKeyImport = kDevTools;

  static Future<bool> exists() async => (await storage.read()) != null;

  /// 이 기기 키의 주소 (소문자 `0x…`). 키가 없으면 null.
  static Future<String?> address() async {
    final pk = await privateKey();
    return pk == null ? null : addressOf(pk);
  }

  /// 새 키를 만든다. 이미 있으면 덮어쓰지 않는다 — 덮어쓰면 체인 롤과 주소가 어긋나 서명이 전부 거부된다.
  static Future<String> create({Random? random}) async {
    if (await exists()) throw StateError('이 기기에는 이미 서명 키가 있습니다');
    final k = generateNewPrivateKey(random ?? Random.secure());
    final pk = padUint8ListTo32(unsignedIntToBytes(k));
    await storage.write(Eip712.toHex(pk));
    return addressOf(pk);
  }

  /// 개발용 — Hardhat 계정 키를 넣는다. 발표·배포 빌드에서는 던진다.
  static Future<String> importDevKey(String privateKeyHex) async {
    if (!allowDevKeyImport) throw StateError('개발 빌드(DEV_TOOLS)에서만 키를 넣을 수 있습니다');
    final pk = Eip712.hexToBytes(privateKeyHex);
    if (pk.length != 32) throw ArgumentError('개인키는 32바이트여야 합니다');
    await storage.write(Eip712.toHex(pk));
    return addressOf(pk);
  }

  static Future<Uint8List?> privateKey() async {
    final hex = await storage.read();
    return hex == null ? null : Eip712.hexToBytes(hex);
  }

  static Future<void> delete() => storage.delete();

  static String addressOf(Uint8List privateKey) =>
      Eip712.toHex(publicKeyToAddress(privateKeyBytesToPublic(privateKey)));
}
