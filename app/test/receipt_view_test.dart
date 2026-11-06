import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/screens/council/approval_list_screen.dart';
import 'package:student_council_app/screens/council/receipt_view_dialog.dart';

import 'support/registration.dart';

/// 승인 화면의 「영수증」 — 서버의 원본 파일을 받아 앱이 SHA-256 을 다시 계산해 기록된 해시와 맞춰 본다.
void main() {
  // 1x1 투명 PNG — Image.memory 가 실제로 해석할 수 있는 최소 이미지.
  final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');
  final pngHash = Hashing.fileHash(png);
  const path = '/receipts/abc.png';

  EntryModel entry({String? receiptHash, String? receiptPath = path, EntryKind kind = EntryKind.EXPENSE}) => EntryModel(
        id: 7,
        termId: 1,
        kind: kind,
        amount: 35000,
        counterparty: '한결문구',
        purpose: '신입생 환영회 명찰',
        budgetId: 1,
        occurredAt: 1790694000,
        receiptPath: receiptPath,
        receiptHash: receiptHash,
        metaHash: '0x00',
        status: EntryStatus.PENDING,
        createdBy: 2,
      );

  group('verifyReceipt — 앱이 받은 바이트로 해시를 다시 계산한다', () {
    test('기록된 해시와 같으면 matched — 파일을 함께 돌려준다', () async {
      final registrar = FakeRegistrar()..stored[path] = png;
      final v = await verifyReceipt(registrar, entry(receiptHash: pngHash));
      expect(v.check, ReceiptCheck.matched);
      expect(v.bytes, isNotNull);
      expect(registrar.downloads, [path]);
    });

    test('대문자·접두사 차이는 같은 해시다', () async {
      final registrar = FakeRegistrar()..stored[path] = png;
      final upper = '0x${pngHash.substring(2).toUpperCase()}';
      expect((await verifyReceipt(registrar, entry(receiptHash: upper))).check, ReceiptCheck.matched);
    });

    test('해시가 다르면 mismatched — 받은 파일은 돌려주지 않는다', () async {
      final registrar = FakeRegistrar()..stored[path] = [...png, 0];
      final v = await verifyReceipt(registrar, entry(receiptHash: pngHash));
      expect(v.check, ReceiptCheck.mismatched);
      expect(v.bytes, isNull, reason: '기록과 다른 파일을 화면에 올리지 않는다');
      expect(v.computedHash, isNot(pngHash));
    });

    test('못 받으면 unavailable — 일치로 두지 않는다', () async {
      final v = await verifyReceipt(FakeRegistrar(), entry(receiptHash: pngHash));
      expect(v.check, ReceiptCheck.unavailable);
    });

    test('해시나 경로가 없으면 받지 않는다', () async {
      final registrar = FakeRegistrar();
      expect((await verifyReceipt(registrar, entry(receiptHash: null))).check, ReceiptCheck.unavailable);
      expect((await verifyReceipt(registrar, entry(receiptHash: pngHash, receiptPath: null))).check, ReceiptCheck.unavailable);
      expect(registrar.downloads, isEmpty);
    });
  });

  group('승인 화면의 영수증 다이얼로그', () {
    Future<void> openReceipt(WidgetTester tester, FakeRegistrar registrar, EntryModel e) async {
      tester.view.physicalSize = const Size(411, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: ApprovalListScreen(
          role: UserRole.AUDITOR,
          currentUserId: 3,
          items: [approvalItemFromEntry(e)],
          registrar: registrar,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('영수증'));
      // 가짜 등록기는 바로 끝나지만 비동기라 한 번 더 돌린다
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('원본을 받아 해시가 같으면 이미지와 「바뀌지 않은 원본」을 보인다', (tester) async {
      final registrar = FakeRegistrar()..stored[path] = png;
      await openReceipt(tester, registrar, entry(receiptHash: pngHash));
      expect(find.byKey(const Key('receipt_image')), findsOneWidget);
      expect(find.byKey(const Key('receipt_hash_match')), findsOneWidget);
      expect(find.text('영수증 이미지 원본'), findsNothing, reason: '자리표시 아이콘이 아니다');
    });

    testWidgets('해시가 다르면 이미지를 그리지 않고 승인하지 말라고 알린다', (tester) async {
      final registrar = FakeRegistrar()..stored[path] = [...png, 0];
      await openReceipt(tester, registrar, entry(receiptHash: pngHash));
      expect(find.byKey(const Key('receipt_hash_mismatch')), findsOneWidget);
      expect(find.textContaining('승인하지 말고'), findsOneWidget);
      expect(find.byKey(const Key('receipt_image')), findsNothing);
      expect(find.byKey(const Key('receipt_hash_match')), findsNothing);
    });

    testWidgets('파일을 못 받으면 이유와 다시 시도를 보이고, 다시 시도로 회복한다', (tester) async {
      final registrar = FakeRegistrar();
      await openReceipt(tester, registrar, entry(receiptHash: pngHash));
      expect(find.byKey(const Key('receipt_unavailable')), findsOneWidget);
      expect(find.byKey(const Key('receipt_hash_match')), findsNothing, reason: '못 확인한 것을 일치로 보이지 않는다');

      registrar.stored[path] = png;
      await tester.tap(find.text('다시 시도'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('receipt_hash_match')), findsOneWidget);
    });

    testWidgets('영수증이 없는 수입 건은 파일을 받으러 가지 않는다', (tester) async {
      final registrar = FakeRegistrar();
      await openReceipt(tester, registrar, entry(receiptHash: null, receiptPath: null, kind: EntryKind.INCOME));
      expect(find.text('수입 건 — 영수증 없음'), findsOneWidget);
      expect(registrar.downloads, isEmpty);
    });

    testWidgets('이미지로 열 수 없는 파일은 해시가 맞아도 미리보기 불가로 안내한다', (tester) async {
      final notImage = utf8.encode('%PDF-1.4 not an image');
      final registrar = FakeRegistrar()..stored[path] = notImage;
      await openReceipt(tester, registrar, entry(receiptHash: Hashing.fileHash(notImage)));
      expect(find.byKey(const Key('receipt_hash_match')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('미리 볼 수 없는 파일 형식이에요'), findsOneWidget);
    });

    for (final scale in [1.0, 1.5]) {
      testWidgets('폭 360dp · 글자 ${(scale * 100).toInt()}% 에서 세 상태 모두 넘치지 않는다', (tester) async {
        for (final bytes in <List<int>?>[png, [...png, 0], null]) {
          final registrar = FakeRegistrar();
          if (bytes != null) registrar.stored[path] = bytes;
          tester.view.physicalSize = const Size(360, 1400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(MaterialApp(
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: ApprovalListScreen(
              role: UserRole.AUDITOR,
              currentUserId: 3,
              items: [approvalItemFromEntry(entry(receiptHash: pngHash))],
              registrar: registrar,
            ),
          ));
          await tester.pumpAndSettle();
          await tester.tap(find.text('영수증'));
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump();
          await tester.pump();
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('닫기'));
          await tester.pumpAndSettle();
        }
      });
    }

    testWidgets('목업 건(items 로 넣은 예시)은 서버를 부르지 않고 자리표시를 보인다', (tester) async {
      final registrar = FakeRegistrar();
      tester.view.physicalSize = const Size(411, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: ApprovalListScreen(role: UserRole.AUDITOR, currentUserId: 3, items: buildApprovalMockItems(), registrar: registrar),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('영수증').first);
      await tester.pumpAndSettle();
      expect(find.text('영수증 이미지 원본'), findsOneWidget);
      expect(registrar.downloads, isEmpty);
    });
  });
}
