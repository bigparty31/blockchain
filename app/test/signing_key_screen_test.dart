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
    expect(await DeviceKey.address(), auditorAddress);
    expect(find.text(auditorAddress), findsOneWidget);
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
