import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/screens/student/entry_list_screen.dart';
import 'package:student_council_app/services/student_api_service.dart';

/// 이슈 #109 — 새로고침 이전의 검증 결과가 현재 기록에 정상 배지를 붙이는 회귀.
///
/// 검증은 목록을 먼저 그리려고 `await` 하지 않고 시작한다. 그래서 새로고침하면
/// **이전 검증 루프가 아직 돌고 있다.** 늦게 도착한 옛 결과가 같은 id 의 새 결과를
/// 덮어쓰면, 금액이 바뀐 기록에 이전 조회의 「검증됨」이 그대로 붙는다 —
/// **변조 경고가 사라지고 「확인 필요」 필터에서도 빠진다.**
///
/// 화면은 멀쩡해 보이고 숫자도 보이는데 배지만 거짓말을 하는 상태라, 눈으로는
/// 잡히지 않는다.
void main() {
  const counterparty = '한결문구';
  const purpose = '명찰 제작';
  const occurredAt = 1788793200;

  /// 체인에 올라간 값은 **100 짜리 해시**다. 서버가 200 이라고 말하기 시작하면
  /// 재계산한 해시가 어긋나 「변조 감지」가 되어야 한다.
  final chainHash = Hashing.metaHash(
    amount: 100,
    counterparty: counterparty,
    purpose: purpose,
    occurredAt: occurredAt,
  );

  String entriesJson(int amount) => jsonEncode([
        {
          'id': 1,
          'term_id': 1,
          'term_code': 20262,
          'kind': 'INCOME',
          'amount': amount,
          'counterparty': counterparty,
          'purpose': purpose,
          'occurred_at': occurredAt,
          'meta_hash': chainHash,
          'status': 'CONFIRMED',
          'created_by': 2,
          'approved_by': 3,
        }
      ]);

  String onChainJson() => jsonEncode({
        'hash': chainHash,
        'amount': 100,
        'kind': 'INCOME',
        'status': 'CONFIRMED',
        'occurred_at': occurredAt,
        'term': 20262,
        'budget_id': 0,
        'corrects_id': 0,
        'registrant': '0x0000000000000000000000000000000000000001',
        'approver': '0x0000000000000000000000000000000000000002',
        'had_warning': false,
        'reason_hash': '0x${'0' * 64}',
      });

  // 보안 저장소 채널이 없으면 `_load` 의 markEntriesSeen 이 네이티브를 기다리다
  // 영영 안 끝나고 화면이 로딩에 멈춘다 (student_unavailable_states_test 와 같은 이유).
  setUp(_mockSecureStorage);
  tearDown(() {
    _clearSecureStorageMock();
    StudentApiService.client = http.Client();
  });

  testWidgets('새로고침 뒤 늦게 도착한 옛 검증 결과가 현재 배지를 덮어쓰지 않는다',
      (tester) async {
    // 서버가 말하는 금액. 2단계에서 200 으로 바꾼다 (DB 직접 변조를 흉내).
    var servedAmount = 100;

    // 첫 번째 온체인 조회만 붙잡아 둔다 — 그 사이에 새로고침이 끼어든다.
    final firstOnChain = Completer<void>();
    var onChainCalls = 0;

    StudentApiService.client = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/entries')) {
        return http.Response(entriesJson(servedAmount), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      if (path.contains('/onchain')) {
        onChainCalls++;
        if (onChainCalls == 1) await firstOnChain.future; // 늦게 오는 옛 응답
        return http.Response(onChainJson(), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      if (path.endsWith('/users/wallets')) {
        return http.Response('{}', 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return http.Response('{}', 404,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });

    await tester.pumpWidget(const MaterialApp(home: EntryListScreen()));

    // **pumpAndSettle 을 쓰지 않는다.** 가짜 시계를 끝까지 돌리면 HTTP 3초 타임아웃이
    // 먼저 터져서, 붙잡아 둔 응답이 「못 읽음」으로 끝나 경쟁 자체가 사라진다.
    Future<void> tick([int times = 6]) async {
      for (var i = 0; i < times; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    await tick();
    expect(find.text('검증 중'), findsOneWidget,
        reason: '첫 검증이 온체인 응답에 붙잡혀 있어야 이 시나리오가 성립한다');
    expect(find.text('+₩ 100'), findsOneWidget);

    // 서버가 금액을 바꾼 뒤 새로고침 — 두 번째 검증은 막히지 않고 끝난다.
    servedAmount = 200;
    tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator)).show();
    await tick(10);

    expect(find.text('+₩ 200'), findsOneWidget, reason: '목록은 새 금액으로 바뀐다');
    expect(find.text('변조 감지'), findsOneWidget,
        reason: '금액이 체인과 달라졌으므로 변조로 떠야 한다');

    // 이제 **옛 세대**의 응답이 도착한다. 그 결과는 버려져야 한다.
    firstOnChain.complete();
    await tick(10);

    expect(find.text('변조 감지'), findsOneWidget,
        reason: '늦게 온 옛 결과가 현재 기록의 변조 경고를 지우면 안 된다');
    expect(find.text('검증됨'), findsNothing,
        reason: '보이는 금액은 200 인데 배지만 100 기준으로 통과하면 배지가 거짓말을 한다');
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
