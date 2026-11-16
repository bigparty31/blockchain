import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/signing/dev_keys.dart';
import 'package:student_council_app/core/signing/device_key.dart';
import 'package:student_council_app/core/signing/eip712.dart';
import 'package:student_council_app/core/signing/signing_service.dart';
import 'package:student_council_app/screens/council/council_home_screen.dart';
import 'package:student_council_app/screens/council/signing_key_screen.dart';
import 'package:student_council_app/services/api_service.dart';

import 'support/signing.dart';

/// 서명 키 화면 — 이 기기의 키 상태(보드 ⑥)와 시연 기기 주소 제출(보드 11/9), 개발 빌드의 Hardhat 키.
void main() {
  setUp(() {
    DeviceKey.storage = MemoryKeyStorage();
    DeviceKey.allowDevKeyImport = false; // 기본 빌드
    ApiService.useDemoData = true;
  });

  Future<void> pump(WidgetTester tester, {FakeAuthenticator? auth}) async {
    tester.view.physicalSize = const Size(411, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: SigningKeyScreen(signing: SigningService(authenticator: auth ?? FakeAuthenticator())),
    ));
    await tester.pumpAndSettle();
  }

  test('공개 Hardhat 개발 키는 시드 임원 계정의 지갑 주소와 같다 (backend app/auth/users.py)', () {
    String addr(String k) => DeviceKey.addressOf(Eip712.hexToBytes(k));
    expect(addr(DevKeys.president.privateKey), '0x70997970c51812dc3a010c7d01b50e0d17dc79c8'); // 20240004
    expect(addr(DevKeys.treasurer.privateKey), treasurerAddress); // 20240002
    expect(addr(DevKeys.auditor.privateKey), auditorAddress); // 20240003
    expect(addr(DevKeys.auditor2.privateKey), '0x9965507d1a55bcc2695c58ba16fb37d819b0a4dc'); // 20240005
  });

  testWidgets('키가 없으면 없다고 보여 주고, 만들면 이 기기 주소를 보여 준다', (tester) async {
    await pump(tester);
    expect(find.text('이 기기에 서명 키가 없어요'), findsOneWidget);

    await tester.tap(find.text('새 서명 키 만들기'));
    await tester.pumpAndSettle();
    final address = await DeviceKey.address();
    expect(address, isNotNull);
    expect(find.text(address!), findsOneWidget);
    expect(find.text('새 서명 키 만들기'), findsNothing, reason: '있는 키를 덮어쓰면 체인 롤과 주소가 어긋난다');
  });

  testWidgets('기기 잠금이 없으면 키를 만들지 않고 이유를 보여 준다', (tester) async {
    await pump(tester, auth: FakeAuthenticator(lock: false));
    await tester.tap(find.text('새 서명 키 만들기'));
    await tester.pumpAndSettle();
    expect(await DeviceKey.exists(), isFalse);
    expect(find.textContaining('잠금'), findsWidgets);
  });

  testWidgets('기본 빌드에는 개발 키 넣기가 없다', (tester) async {
    await pump(tester);
    expect(find.text('개발용 Hardhat 키 넣기'), findsNothing);
  });

  testWidgets('개발 빌드에서는 역할별 Hardhat 키를 넣을 수 있다 — 넣으면 그 주소로 바뀐다', (tester) async {
    DeviceKey.allowDevKeyImport = true;
    await DeviceKey.importDevKey(DevKeys.treasurer.privateKey);
    await pump(tester);
    expect(find.text(treasurerAddress), findsOneWidget);

    await tester.ensureVisible(find.text(DevKeys.auditor.label));
    await tester.tap(find.text(DevKeys.auditor.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text('바꾸기')); // 이미 키가 있으면 한 번 묻는다
    await tester.pumpAndSettle();
    expect(await DeviceKey.address(), auditorAddress);
    expect(find.text(auditorAddress), findsOneWidget);
  });

  group('개발 키 넣기는 기존 키를 함부로 지우지 않는다 (#69 리뷰)', () {
    testWidgets('키가 이미 있으면 확인 창이 뜨고, 취소하면 키는 그대로다', (tester) async {
      DeviceKey.allowDevKeyImport = true;
      await DeviceKey.importDevKey(DevKeys.treasurer.privateKey);
      await pump(tester);
      await tester.ensureVisible(find.text(DevKeys.auditor.label));
      await tester.tap(find.text(DevKeys.auditor.label));
      await tester.pumpAndSettle();
      expect(find.text('서명 키를 바꿀까요?'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(await DeviceKey.address(), treasurerAddress);
      expect(find.text(treasurerAddress), findsOneWidget);
    });

    testWidgets('키가 없으면 묻지 않고 바로 넣는다', (tester) async {
      DeviceKey.allowDevKeyImport = true;
      await pump(tester);
      await tester.ensureVisible(find.text(DevKeys.auditor.label));
      await tester.tap(find.text(DevKeys.auditor.label));
      await tester.pumpAndSettle();
      expect(find.text('서명 키를 바꿀까요?'), findsNothing);
      expect(await DeviceKey.address(), auditorAddress);
    });

    testWidgets('저장이 실패해도 기존 키는 남는다 — 먼저 지우지 않는다', (tester) async {
      DeviceKey.allowDevKeyImport = true;
      final storage = _FailingWriteStorage();
      DeviceKey.storage = storage;
      storage.value = DevKeys.treasurer.privateKey; // 이미 있는 키
      await pump(tester);
      storage.failWrites = true;
      await tester.ensureVisible(find.text(DevKeys.auditor.label));
      await tester.tap(find.text(DevKeys.auditor.label));
      await tester.pumpAndSettle();
      await tester.tap(find.text('바꾸기'));
      await tester.pumpAndSettle();
      expect(storage.value, DevKeys.treasurer.privateKey, reason: '쓰기에 실패하면 기존 키가 그대로 남아야 한다');
      expect(find.textContaining('저장 실패'), findsOneWidget);
    });
  });

  testWidgets('임원 홈에는 서명 키 메뉴가 있다', (tester) async {
    for (final role in [UserRole.TREASURER, UserRole.AUDITOR, UserRole.PRESIDENT]) {
      tester.view.physicalSize = const Size(411, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: CouncilHomeScreen(key: ValueKey(role), role: role)));
      await tester.pumpAndSettle();
      expect(find.text('서명 키'), findsOneWidget, reason: role.code);
    }
  });
}

/// 쓰기만 실패하는 저장소 — 지우고 쓰는 순서면 기존 키가 사라진다.
class _FailingWriteStorage extends MemoryKeyStorage {
  bool failWrites = false;

  @override
  Future<void> write(String privateKeyHex) async {
    if (failWrites) throw ArgumentError('저장 실패');
    return super.write(privateKeyHex);
  }
}
