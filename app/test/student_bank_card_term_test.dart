import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/app_theme.dart';
import 'package:student_council_app/core/entry_merge.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/screens/student/student_home_screen.dart';
import 'package:student_council_app/services/student_api_service.dart';

/// 학생 홈 계좌 대조 카드는 **스냅샷과 같은 학기**의 장부 잔액과 비교한다 (#117 리뷰).
///
/// 스냅샷은 학기마다 올라오고 서버의 잔액 불일치 알림도 그 학기만 더한다. 카드가 전 학기
/// 합계와 비교하면 학기가 둘 이상일 때 알림과 카드가 서로 다른 말을 한다.
void main() {
  // 1학기: 수입 100,000 / 2학기: 수입 50,000 · 지출 20,000 · 대기 지출 5,000 → 2학기 장부 30,000
  final entries = [
    _entry(1, termId: 1, kind: 'INCOME', amount: 100000),
    _entry(2, termId: 2, kind: 'INCOME', amount: 50000),
    _entry(3, termId: 2, kind: 'EXPENSE', amount: 20000),
    _entry(4, termId: 2, kind: 'EXPENSE', amount: 5000, status: 'PENDING'),
  ];

  group('EntryMerge.ledgerBalanceOfTerm', () {
    final models = [for (final e in entries) EntryModel.fromJson(e)];

    test('그 학기 확정 내역만 더한다', () {
      expect(EntryMerge.ledgerBalanceOfTerm(models, 2), 30000);
      expect(EntryMerge.ledgerBalanceOfTerm(models, 1), 100000);
      expect(EntryMerge.ledgerBalanceOfTerm(models, 3), 0);
    });

    test('전 학기 합계(화면 위쪽 잔액)는 그대로다', () {
      expect(EntryMerge.ledgerBalance(models), 130000);
    });
  });

  group('학생 홈 계좌 대조 카드 — 학기가 둘일 때', () {
    setUp(_mockSecureStorage);
    tearDown(() {
      _clearSecureStorageMock();
      StudentApiService.client = http.Client();
    });

    void serve({required int bankBalance}) {
      StudentApiService.client = MockClient((req) async {
        final p = req.url.path;
        if (p.endsWith('/entries')) return _json(entries);
        if (p.endsWith('/budgets')) return _json([]);
        if (p.endsWith('/snapshots/latest')) {
          return _json({'id': 7, 'term_id': 2, 'bank_balance': bankBalance, 'snapshot_at': 1795000000, 'unrecorded': []});
        }
        return http.Response('{}', 404);
      });
    }

    testWidgets('2학기 계좌가 2학기 장부와 같으면 일치 — 1학기 수입을 섞지 않는다', (tester) async {
      serve(bankBalance: 30000);
      await _pumpHome(tester);
      expect(find.text('장부와 계좌가 일치합니다'), findsOneWidget);
      expect(find.text('장부와 계좌가 맞지 않습니다'), findsNothing);
    });

    testWidgets('계좌가 전 학기 합계와 같아도 2학기 장부와 다르면 불일치', (tester) async {
      serve(bankBalance: 130000);
      await _pumpHome(tester);
      expect(find.text('장부와 계좌가 맞지 않습니다'), findsOneWidget);
    });
  });
}

Map<String, dynamic> _entry(int id,
        {required int termId, required String kind, required int amount, String status = 'CONFIRMED'}) =>
    {
      'id': id,
      'term_id': termId,
      'kind': kind,
      'amount': amount,
      'counterparty': '거래처$id',
      'purpose': '목적$id',
      'occurred_at': 1788793200,
      'meta_hash': '0x${'0' * 64}',
      'status': status,
      'created_by': 2,
    };

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

/// `flutter_secure_storage` 채널을 가짜로 받는다 — 없으면 `lastSeenEntryId()` 가 끝나지 않아
/// 화면이 로딩에 멈춘다 (student_unavailable_states_test.dart 와 같다).
void _mockSecureStorage() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureStorageChannel, (call) async {
    return switch (call.method) {
      'read' => null,
      'readAll' => <String, String>{},
      'containsKey' => false,
      _ => null,
    };
  });
}

void _clearSecureStorageMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureStorageChannel, null);
}

const _secureStorageChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

Future<void> _pumpHome(WidgetTester tester) async {
  tester.view.physicalSize = const Size(411, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.themeData, home: const StudentHomeScreen()));
  // 조회 타임아웃 타이머가 남아 있어 pumpAndSettle 은 쓰지 않는다
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
