import 'package:flutter/services.dart';
import 'package:local_auth/error_codes.dart' as auth_error;
import 'package:local_auth/local_auth.dart';

/// 서명 직전 본인 확인 결과 (PRD v0.14 §9.2 「지문·얼굴 인식을 못 쓸 때」).
enum DeviceAuthResult {
  success,

  /// 사용자가 취소했다. 아무것도 보내지 않는다.
  cancelled,

  /// 기기 잠금(PIN·패턴·암호) 자체가 없다 — 키 생성과 서명을 막고 설정을 안내한다.
  noDeviceLock,

  /// 시도 횟수 초과 — 잠금 안내 후 재시도.
  lockedOut,

  /// 생체인증이 영구 잠김 — 기기 PIN·패턴으로 풀어야 한다.
  permanentlyLockedOut,

  /// 그 밖의 실패 (플랫폼 오류 등).
  unavailable;

  /// 화면에 보여 줄 문구.
  String get message {
    switch (this) {
      case DeviceAuthResult.success:
        return '본인 확인이 끝났어요.';
      case DeviceAuthResult.cancelled:
        return '본인 확인을 취소해 서명하지 않았어요.';
      case DeviceAuthResult.noDeviceLock:
        return '기기 잠금(PIN·패턴·암호)이 없어 서명할 수 없어요. 휴대폰 설정에서 화면 잠금을 켜 주세요.';
      case DeviceAuthResult.lockedOut:
        return '본인 확인을 여러 번 실패해 잠시 잠겼어요. 잠시 후 다시 시도해 주세요.';
      case DeviceAuthResult.permanentlyLockedOut:
        return '생체인증이 잠겼어요. 기기 잠금을 PIN·패턴으로 한 번 푼 뒤 다시 시도해 주세요.';
      case DeviceAuthResult.unavailable:
        return '본인 확인을 할 수 없어요. 잠시 후 다시 시도해 주세요.';
    }
  }
}

/// 서명 직전 본인 확인. 테스트에서 가짜로 갈아끼운다.
abstract class DeviceAuthenticator {
  /// 기기 잠금(생체인증 또는 PIN·패턴)이 있는가. 없으면 키를 만들지 않는다.
  Future<bool> hasDeviceLock();

  Future<DeviceAuthResult> authenticate(String reason);
}

/// `local_auth` 구현 — 생체인증이 실패·미등록·고장이면 **기기 PIN·패턴으로 넘어간다**
/// (`biometricOnly: false`). 앱 전용 PIN 은 만들지 않는다 (PRD v0.14 §9.2).
///
/// 이 구조는 **앱 수준 잠금**이다. 키가 하드웨어 인증에 묶이는 것은 아니다 (PRD §13).
class LocalDeviceAuthenticator implements DeviceAuthenticator {
  final LocalAuthentication _auth;
  LocalDeviceAuthenticator([LocalAuthentication? auth]) : _auth = auth ?? LocalAuthentication();

  @override
  Future<bool> hasDeviceLock() async {
    try {
      return await _auth.isDeviceSupported();
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<DeviceAuthResult> authenticate(String reason) async {
    if (!await hasDeviceLock()) return DeviceAuthResult.noDeviceLock;
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: false, // 생체인증을 못 쓰면 기기 PIN·패턴으로
          stickyAuth: true, // 앱이 잠깐 백그라운드로 가도 취소하지 않는다
        ),
      );
      return ok ? DeviceAuthResult.success : DeviceAuthResult.cancelled;
    } on PlatformException catch (e) {
      return fromErrorCode(e.code);
    }
  }

  /// `local_auth` 오류 코드 → 결과. 테스트가 직접 부른다.
  static DeviceAuthResult fromErrorCode(String code) {
    switch (code) {
      case auth_error.passcodeNotSet:
      case auth_error.notAvailable:
        return DeviceAuthResult.noDeviceLock;
      case auth_error.lockedOut:
        return DeviceAuthResult.lockedOut;
      case auth_error.permanentlyLockedOut:
        return DeviceAuthResult.permanentlyLockedOut;
      default:
        return DeviceAuthResult.unavailable;
    }
  }
}
