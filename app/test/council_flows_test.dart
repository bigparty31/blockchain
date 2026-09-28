import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/screens/council/approval_list_screen.dart';
import 'package:student_council_app/screens/council/input_rules.dart';
import 'package:student_council_app/services/api_service.dart';

/// 총무·감사 화면이 컨트랙트·해시 규칙을 지키는지 본다.
///
/// 사유 필수·KST 자정·BLOCKED 표시는 어기면 서버가 400 으로 거부하거나
/// 서명 뒤 `HASH_MISMATCH` 로 되돌아오는 규칙이다 (docs/HASHING.md).
void main() {
  group('InputRules — 한 줄 텍스트 (§1.1)', () {
    test('정상 입력은 통과한다', () {
      expect(InputRules.singleLine('한결문구', fieldName: '사용처'), isNull);
      expect(InputRules.singleLine('명찰 및 필기구 구매', fieldName: '항목명'), isNull);
    });

    test('빈 값·공백만 있으면 거부한다', () {
      expect(InputRules.singleLine('', fieldName: '사용처'), isNotNull);
      expect(InputRules.singleLine(null, fieldName: '사용처'), isNotNull);
      expect(InputRules.singleLine('   ', fieldName: '사용처'), isNotNull);
    });

    test('제어문자는 탭까지 전부 거부한다 (구분자 U+001F 충돌 차단)', () {
      expect(InputRules.singleLine('명찰\t필기구', fieldName: '항목명'), isNotNull);
      expect(InputRules.singleLine('명찰\n필기구', fieldName: '항목명'), isNotNull);
      expect(InputRules.singleLine('명찰\u001F필기구', fieldName: '항목명'), isNotNull);
    });

    test('보이지 않는 공백류(NBSP·ZWSP·전각공백·BOM)를 거부한다', () {
      for (final ch in [' ', '​', '　', '﻿']) {
        expect(InputRules.singleLine('한결$ch문구', fieldName: '사용처'), isNotNull,
            reason: 'U+${ch.runes.first.toRadixString(16)}');
      }
    });

    test('파이프는 허용한다 — 구분자가 U+001F 라 충돌하지 않는다', () {
      expect(InputRules.singleLine('명찰|필기구', fieldName: '항목명'), isNull);
    });
  });

  group('InputRules — 사유 (§3)', () {
    test('사유가 있으면 통과한다', () {
      expect(InputRules.requiredReason('영수증이 다른 거래의 것입니다'), isNull);
      expect(InputRules.requiredReason('첫 줄\r\n둘째 줄'), isNull, reason: 'CRLF 는 LF 로 바뀐 뒤 검사한다');
      expect(InputRules.requiredReason('탭\t허용'), isNull);
    });

    test('빈 값과 다듬은 뒤 빈 문자열은 거부한다', () {
      expect(InputRules.requiredReason(''), isNotNull);
      expect(InputRules.requiredReason(null), isNotNull);
      expect(InputRules.requiredReason('  \n\t '), isNotNull);
      expect(InputRules.requiredReason('\r\n'), isNotNull);
    });

    test('탭·LF 외 제어문자와 보이지 않는 공백은 거부한다', () {
      expect(InputRules.requiredReason('가\u000B나'), isNotNull); // VT
      expect(InputRules.requiredReason('가\u001F나'), isNotNull);
      expect(InputRules.requiredReason('가​나'), isNotNull);
      expect(InputRules.requiredReason(' '), isNotNull);
    });
  });

  group('InputRules — 금액 (§5)', () {
    test('양의 정수만 받는다', () {
      expect(InputRules.positiveAmount('35000', fieldName: '금액'), isNull);
      for (final bad in ['', '0', '00', '-100', '35,000', '3.5', '+100', '3만']) {
        expect(InputRules.positiveAmount(bad, fieldName: '금액'), isNotNull, reason: bad);
      }
    });
  });

  group('KST 자정 (§1.3)', () {
    test('사용일을 KST 자정 Unix 초로 바꾼다', () {
      expect(Hashing.kstMidnightOf(2026, 9, 8), 1788793200);
      expect(Hashing.kstMidnightOf(2026, 9, 6), 1788620400);
      expect(Hashing.isKstMidnight(Hashing.kstMidnightOf(2026, 12, 31)), isTrue);
    });

    test('기기 시간대와 무관하다 — 결과가 항상 54000 의 나머지를 낸다', () {
      for (var d = 1; d <= 28; d++) {
        expect(Hashing.kstMidnightOf(2026, 9, d) % 86400, 54000);
      }
    });
  });

  group('앱 더미 데이터가 규칙을 지킨다', () {
    test('occurredAt 이 전부 KST 자정이고 meta_hash 가 재계산 값과 같다', () async {
      // 테스트 환경에는 서버가 없어 fetchEntries 가 더미로 폴백한다.
      final entries = await ApiService().fetchEntries();
      expect(entries, isNotEmpty);
      for (final e in entries) {
        expect(Hashing.isKstMidnight(e.occurredAt), isTrue, reason: '#${e.id} occurredAt ${e.occurredAt}');
        expect(
          e.metaHash,
          Hashing.metaHash(
            amount: e.amount,
            counterparty: e.counterparty,
            purpose: e.purpose,
            occurredAt: e.occurredAt,
            receiptHash: e.receiptHash,
          ),
          reason: '#${e.id}',
        );
      }
    });
  });

  group('승인 화면', () {
    Future<void> pumpScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(411, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: ApprovalListScreen()));
      await tester.pumpAndSettle();
    }

    testWidgets('반려는 사유가 없으면 진행되지 않는다', (tester) async {
      await pumpScreen(tester);

      await tester.tap(find.text('반려').first);
      await tester.pumpAndSettle();
      expect(find.text('반려 사유'), findsOneWidget);

      // 빈 값
      await tester.tap(find.text('반려하기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('입력해 주세요'), findsOneWidget);
      expect(find.text('반려 사유'), findsOneWidget, reason: '다이얼로그가 닫히면 안 된다');

      // 공백·탭·개행만
      await tester.enterText(find.byType(TextFormField), '  \n\t ');
      await tester.tap(find.text('반려하기'));
      await tester.pumpAndSettle();
      expect(find.text('반려 사유'), findsOneWidget);

      // 사유가 있으면 반려된다
      await tester.enterText(find.byType(TextFormField), '영수증이 다른 거래의 것입니다');
      await tester.tap(find.text('반려하기'));
      await tester.pumpAndSettle();
      expect(find.text('반려 사유'), findsNothing);
      expect(find.textContaining('반려 처리되었습니다'), findsOneWidget);
    });

    testWidgets('OCR 경고가 있는 항목은 사유 없이 승인할 수 없다', (tester) async {
      await pumpScreen(tester);

      expect(find.textContaining('경고 무시 사유가 필요해요'), findsOneWidget);

      // 경고 항목은 목록의 세 번째 카드 (id 6)
      await tester.tap(find.text('승인 서명').at(2));
      await tester.pumpAndSettle();
      expect(find.text('경고 무시 승인 사유'), findsOneWidget);

      await tester.tap(find.text('다음'));
      await tester.pumpAndSettle();
      expect(find.text('집행 최종 승인'), findsNothing, reason: '사유 없이 서명 단계로 가면 안 된다');

      await tester.enterText(find.byType(TextFormField), 'OCR 금액 불일치, 영수증 원본 확인함');
      await tester.tap(find.text('다음'));
      await tester.pumpAndSettle();
      expect(find.text('집행 최종 승인'), findsOneWidget);
    });

    testWidgets('예산 부족으로 승인이 실패하면 PENDING 을 유지하고 반려로 안내한다', (tester) async {
      await pumpScreen(tester);
      final pendingBefore = find.text('승인 서명').evaluate().length;

      // 두 번째 카드 (id 4, 목업 실패)
      await tester.tap(find.text('승인 서명').at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('생체인증 승인'));
      await tester.pumpAndSettle();

      expect(find.text('승인에 실패했어요'), findsOneWidget);
      expect(find.textContaining('예산 잔량이 부족'), findsWidgets);
      expect(find.textContaining('PENDING'), findsOneWidget);

      // 나중에 — 상태 그대로
      await tester.tap(find.text('나중에'));
      await tester.pumpAndSettle();
      expect(find.text('승인 서명').evaluate().length, pendingBefore, reason: '실패해도 PENDING 유지');

      // 다시 실패시키고 반려로 넘긴다
      await tester.tap(find.text('승인 서명').at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('생체인증 승인'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('반려로 처리'));
      await tester.pumpAndSettle();

      expect(find.text('반려 사유'), findsOneWidget);
      final field = tester.widget<TextFormField>(find.byType(TextFormField));
      expect(field.controller!.text, contains('예산 잔량이 부족'), reason: '실패 사유가 미리 채워진다');

      await tester.tap(find.text('반려하기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('반려 처리되었습니다'), findsOneWidget);
    });
  });

  test('BlockReason 은 docs/enums.md 순서·표기를 따른다', () {
    expect(BlockReason.values.map((e) => e.code).toList(),
        ['BUDGET_EXCEEDED', 'BUDGET_EXPIRED', 'BUDGET_NOT_FOUND']);
    expect(BlockReason.fromCode('BUDGET_EXPIRED'), BlockReason.BUDGET_EXPIRED);
  });
}
