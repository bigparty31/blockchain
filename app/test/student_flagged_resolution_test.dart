import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/screens/student/entry_list_screen.dart';
import 'package:student_council_app/services/student_api_service.dart';

/// 「확인 필요」가 **비워질 수 있어야 한다.**
///
/// 경고(OCR 불일치·용도 불일치)는 확정 시점에 박히고 그 뒤로 바뀌지 않는다 —
/// 확정된 기록은 고치지 않기 때문이다(PRD 규칙 5). 그래서 경고만 보고 거르면
/// 한번 걸린 건이 학기 내내 남아 「확인 필요」가 누적 목록이 되고, 지금 당장
/// 이상한 건(변조 감지)이 묵은 기록에 묻힌다.
///
/// 해소 신호는 **이의 답변**이다. 온체인에 남는 공개 사실이라 학생이나 서버가
/// 임의로 지울 수 없다. 기록 자체(상세의 「경고 상태로 승인됨」 배지)는 그대로 남고,
/// 빠지는 것은 「확인이 필요하다」는 신호뿐이다.
void main() {
  const warned = '한결문구'; // OCR 불일치 상태로 확정된 건
  const plain = '대림전산'; // 경고 없는 건

  String entriesJson() => jsonEncode([
        {
          'id': 1,
          'term_id': 1,
          'term_code': 20262,
          'kind': 'EXPENSE',
          'amount': 35000,
          'counterparty': warned,
          'purpose': '사무용품 구입',
          'occurred_at': 1788793200,
          'ocr_status': 'MISMATCH',
          'category_warning': false,
          'status': 'CONFIRMED',
          'created_by': 2,
          'approved_by': 3,
        },
        {
          'id': 2,
          'term_id': 1,
          'term_code': 20262,
          'kind': 'EXPENSE',
          'amount': 450000,
          'counterparty': plain,
          'purpose': '자료집 인쇄',
          'occurred_at': 1788793200,
          'category_warning': false,
          'status': 'CONFIRMED',
          'created_by': 2,
          'approved_by': 3,
        },
      ]);

  String objectionsJson({required bool answered}) => jsonEncode([
        if (answered)
          {
            'id': 1,
            'entry_id': 1,
            'user_id': 1,
            'content': '영수증 금액이 다른 것 같습니다',
            'answer': '영수증 원본을 대조해 금액이 맞음을 확인했습니다',
            'answered_by': 3,
            'status': 'ANSWERED',
            'raised_at': 1788793200,
            'answered_at': 1788796800,
            'tx_raise': '0x${'1' * 64}',
            'tx_answer': '0x${'2' * 64}',
          },
      ]);

  /// 온체인 조회는 404 로 둔다 — 검증이 「부분 검증」에 머물러 변조로 잡히지
  /// 않는다. 이 시험이 보려는 것은 경고 건의 해소이지 변조 판정이 아니다.
  void serve({required bool answered}) {
    StudentApiService.client = MockClient((req) async {
      final path = req.url.path;
      const json = {'content-type': 'application/json; charset=utf-8'};
      if (path.endsWith('/entries')) {
        return http.Response(entriesJson(), 200, headers: json);
      }
      if (path.endsWith('/objections')) {
        return http.Response(objectionsJson(answered: answered), 200,
            headers: json);
      }
      if (path.endsWith('/users/wallets')) {
        return http.Response('{}', 200, headers: json);
      }
      return http.Response('{}', 404, headers: json);
    });
  }

  setUp(_mockSecureStorage);
  tearDown(() {
    _clearSecureStorageMock();
    StudentApiService.client = http.Client();
  });

  Future<void> openFlagged(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: EntryListScreen()));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.tap(find.text('확인 필요'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('답변 없는 경고 승인 건은 「확인 필요」에 남는다', (tester) async {
    serve(answered: false);
    await openFlagged(tester);

    expect(find.text(warned), findsOneWidget,
        reason: '아직 아무도 묻지 않은 경고 건은 학생이 눈여겨봐야 한다');
    expect(find.text(plain), findsNothing,
        reason: '경고도 변조도 없는 건이 섞이면 필터가 뜻을 잃는다');
  });

  testWidgets('이의에 답변이 달리면 경고 승인 건이 「확인 필요」에서 빠진다', (tester) async {
    serve(answered: true);
    await openFlagged(tester);

    expect(find.text(warned), findsNothing,
        reason: '답변을 받은 건까지 남으면 「확인 필요」가 영영 비워지지 않는다');
    expect(find.text(plain), findsNothing);
  });

  testWidgets('이의 목록을 못 읽으면 경고 건을 남긴다 — 조회 실패로 해소된 것처럼 보이면 안 된다',
      (tester) async {
    StudentApiService.client = MockClient((req) async {
      final path = req.url.path;
      const json = {'content-type': 'application/json; charset=utf-8'};
      if (path.endsWith('/entries')) {
        return http.Response(entriesJson(), 200, headers: json);
      }
      if (path.endsWith('/objections')) {
        return http.Response('{"detail":"서버 오류"}', 503, headers: json);
      }
      return http.Response('{}', 404, headers: json);
    });

    await openFlagged(tester);

    expect(find.text(warned), findsOneWidget,
        reason: '못 읽은 것은 「해소됨」이 아니다 — 비우는 쪽이 아니라 남기는 쪽으로 기운다');
  });
}

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

const _secureStorageChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
