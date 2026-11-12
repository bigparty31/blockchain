/// 개발·통합 시험용 **공개된** Hardhat 기본 계정 키 (PRD v0.14 §9.2 — ~11/9 통합은 Hardhat 키로 한다).
///
/// 누구나 아는 값이라 실제 자산이 걸린 체인에서는 쓰면 안 된다. 앱은 개발 빌드(`DEV_TOOLS`)에서만 이 키를 넣을 수
/// 있다 ([DeviceKey.allowDevKeyImport]). 시드 임원 계정의 지갑 주소와 짝이다 (backend `app/auth/users.py`).
class DevKey {
  final String label;
  final String privateKey;
  const DevKey(this.label, this.privateKey);
}

class DevKeys {
  DevKeys._();

  static const president = DevKey('회장 · Hardhat #1 (20240004)', '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d');
  static const treasurer = DevKey('총무 · Hardhat #2 (20240002)', '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a');
  static const auditor = DevKey('감사 · Hardhat #3 (20240003)', '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6');
  static const auditor2 = DevKey('감사 2 · Hardhat #5 (20240005)', '0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba');

  static const all = [treasurer, auditor, president, auditor2];
}
