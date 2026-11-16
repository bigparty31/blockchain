import 'dart:convert';
import 'dart:io';

import 'package:student_council_app/core/signing/device_auth.dart';
import 'package:student_council_app/core/signing/device_key.dart';

/// 서명 테스트 공용 — Hardhat 계정과 EIP-712 벡터 (`backend/tests/fixtures/eip712_vectors.json`).
const auditorKey = '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6'; // Hardhat #3
const auditorAddress = '0x90f79bf6eb2c4f870365e785982e1f101e93b906';
const treasurerAddress = '0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc'; // Hardhat #2

/// 벡터 파일 전체. 테스트는 `app/` 에서 돈다.
Map<String, dynamic> loadEip712Vectors() =>
    jsonDecode(File('../backend/tests/fixtures/eip712_vectors.json').readAsStringSync()) as Map<String, dynamic>;

/// 기기 키를 메모리 보관소로 바꾸고 감사(Hardhat #3) 키를 넣는다.
Future<void> useAuditorDeviceKey() async {
  DeviceKey.storage = MemoryKeyStorage();
  DeviceKey.allowDevKeyImport = true;
  await DeviceKey.importDevKey(auditorKey);
}

/// 가짜 본인 확인 — 몇 번 불렸는지 센다.
class FakeAuthenticator implements DeviceAuthenticator {
  final DeviceAuthResult result;

  /// 기기 잠금(PIN·패턴·생체)이 설정돼 있는가. 없으면 키를 만들지 않는다 (PRD §9.2).
  final bool lock;
  int calls = 0;
  FakeAuthenticator({this.result = DeviceAuthResult.success, this.lock = true});

  @override
  Future<bool> hasDeviceLock() async => lock;

  @override
  Future<DeviceAuthResult> authenticate(String reason) async {
    calls++;
    return result;
  }
}
