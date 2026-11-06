import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/core/signing/ledger_types.dart';
import 'package:student_council_app/core/signing/signing_service.dart';
import 'package:student_council_app/screens/council/approval_list_screen.dart';
import 'package:student_council_app/services/api_service.dart';
import 'package:student_council_app/services/auth_service.dart';
import 'package:student_council_app/services/chain_domain_service.dart';
import 'package:student_council_app/services/entry_decision_service.dart';

import 'support/session.dart';
import 'support/signing.dart';

/// 승인 화면 — 서버의 대기 건을 읽고, 승인·반려를 서명해 `POST /entries/{id}/confirm`·`/reject` 로 보낸다.
void main() {
  final domainJson = loadEip712Vectors()['domain'] as Map<String, dynamic>;

  http.Response json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  /// 서버 `EntryResponse` 모양. meta_hash 는 등록 내용으로 계산해 넣는다.
  Map<String, dynamic> entry(int id,
      {required int createdBy, required String purpose, String status = 'PENDING', String? rejectReason, String? ocrStatus}) {
    const amount = 35000, occurredAt = 1790694000, counterparty = '한결문구';
    return {
      'id': id,
      'term_id': 1,
      'term_code': 20262,
      'kind': 'EXPENSE',
      'amount': amount,
      'counterparty': counterparty,
      'purpose': purpose,
      'budget_id': 1,
      'occurred_at': occurredAt,
      'receipt_hash': null,
      'meta_hash': Hashing.metaHash(amount: amount, counterparty: counterparty, purpose: purpose, occurredAt: occurredAt),
      'ocr_status': ocrStatus,
      'category_warning': false,
      'status': status,
      'created_by': createdBy,
      'reject_reason': rejectReason,
    };
  }

  late List<http.Request> posts;
  late List<http.Request> confirms;
  late http.Response Function() onConfirm;
  late bool confirmed;
  String? ocr7;
  /// 단건 재조회만 다른 상태를 돌려준다 — 목록을 읽은 뒤 다른 임원이 먼저 처리한 경우.
  String? singleStatus7;
  late int entryReads;
  late http.Response Function() onEntries;
  late http.Response Function() onReject;
  late bool rejected;

  setUp(() async {
    await signInAs(UserRole.AUDITOR, userId: 3);
    ApiService.useDemoData = false;
    await useAuditorDeviceKey();
    posts = [];
    confirms = [];
    entryReads = 0;
    rejected = false;
    confirmed = false;
    ocr7 = null;
    singleStatus7 = null;
    onEntries = () => json([
          entry(7, createdBy: 2, purpose: '신입생 환영회 명찰', ocrStatus: ocr7,
              status: rejected ? 'REJECTED' : confirmed ? 'CONFIRMED' : 'PENDING',
              rejectReason: rejected ? '금액이 영수증과 달라요' : null),
          entry(8, createdBy: 3, purpose: '감사 본인이 등록한 건'),
        ]);
    onReject = () => json({'id': 7, 'status': 'REJECTED', 'message': '반려됨'});
    onConfirm = () => json({'id': 7, 'status': 'CONFIRMED', 'tx_confirm': '0x${'cd' * 32}', 'message': '확정됨'});
    final server = MockClient((req) async {
      // 서명 직전 재조회 — 지금 목록에서 그 건을 찾아 돌려준다
      final single = RegExp(r'^/entries/(\d+)$').firstMatch(req.url.path);
      if (req.method == 'GET' && single != null) {
        final list = onEntries();
        if (list.statusCode != 200) return list;
        final id = int.parse(single.group(1)!);
        for (final e in (jsonDecode(list.body) as List).cast<Map<String, dynamic>>()) {
          if (e['id'] == id) return json(id == 7 && singleStatus7 != null ? {...e, 'status': singleStatus7} : e);
        }
        return json({'detail': 'not found'}, 404);
      }
      switch ('${req.method} ${req.url.path}') {
        case 'GET /entries':
          entryReads++;
          return onEntries();
        case 'GET /budgets':
          return json([
            {'id': 1, 'term_id': 1, 'category': '행사비', 'planned_amount': 1000000, 'remaining_amount': 900000},
          ]);
        case 'GET /chain/domains':
          return json({'domains': {LedgerTypes.domainName: domainJson}});
        case 'GET /users/wallets':
          return json({treasurerAddress: 2, auditorAddress: 3});
        case 'POST /entries/7/reject':
          posts.add(req);
          final res = onReject();
          if (res.statusCode == 200) rejected = true;
          return res;
        case 'POST /entries/7/confirm':
          confirms.add(req);
          final res = onConfirm();
          if (res.statusCode == 200) confirmed = true;
          return res;
      }
      return http.Response('{}', 404);
    });
    ApiService.client = server;
    ChainDomainService.client = server;
    EntryDecisionService.client = server;
  });

  tearDown(() async {
    ApiService.client = http.Client();
    ChainDomainService.client = http.Client();
    EntryDecisionService.client = http.Client();
    await signOutForTest();
  });

  /// 실제 비동기(가짜 서버 응답)가 끝날 때까지 프레임을 돌린다.
  Future<void> waitUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(done(), isTrue, reason: '기다리던 상태가 오지 않았다');
    await tester.pumpAndSettle();
  }

  bool shows(Finder f) => f.evaluate().isNotEmpty;

  Future<void> pump(WidgetTester tester, {GlobalKey<NavigatorState>? navigatorKey}) async {
    tester.view.physicalSize = const Size(411, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      home: ApprovalListScreen(
        decisions: EntryDecisionService(
          signer: SigningService(authenticator: FakeAuthenticator()),
          now: () => DateTime.utc(2026, 11, 6, 9),
        ),
      ),
    ));
  }

  Future<void> rejectFirst(WidgetTester tester, String reason) async {
    await tester.tap(find.widgetWithText(OutlinedButton, '반려'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), reason);
    await tester.tap(find.text('반려하기'));
  }

  testWidgets('개발 빌드(DEV_TOOLS — 더미 켜짐)에서도 서버가 있으면 서버 목록을 쓴다 — Hardhat 키 통합 시험은 이 빌드로 한다', (tester) async {
    ApiService.useDemoData = true;
    await pump(tester);
    await waitUntil(tester, () => shows(find.text('신입생 환영회 명찰')));
    expect(find.text('청년피자 개강총회 다과 주문'), findsNothing); // 목업 목록
  });

  testWidgets('서버의 대기 건을 보여 주고 목업 건은 섞지 않는다', (tester) async {
    await pump(tester);
    await waitUntil(tester, () => shows(find.text('신입생 환영회 명찰')));
    expect(find.text('감사 본인이 등록한 건'), findsOneWidget);
    expect(find.text('청년피자 개강총회 다과 주문'), findsNothing); // 목업 목록
    expect(find.text('행사비'), findsWidgets); // budget_id → 예산 이름
  });

  testWidgets('반려하면 서명해 보내고, 다시 읽은 목록에서 반려됨 탭으로 옮겨 간다', (tester) async {
    await pump(tester);
    await waitUntil(tester, () => shows(find.text('신입생 환영회 명찰')));

    await rejectFirst(tester, '금액이 영수증과 달라요');
    await waitUntil(tester, () => shows(find.text('[신입생 환영회 명찰] 반려 처리되었습니다.')));

    expect(posts, hasLength(1));
    expect((jsonDecode(posts.single.body) as Map)['reject_reason'], '금액이 영수증과 달라요');

    await tester.tap(find.text('반려됨'));
    await tester.pumpAndSettle();
    expect(find.text('신입생 환영회 명찰'), findsOneWidget);
    expect(find.text('반려 사유: 금액이 영수증과 달라요'), findsOneWidget);
  });

  testWidgets('반려가 409 면 서버가 준 상황을 알리고 목록을 다시 읽는다', (tester) async {
    onReject = () => json({'detail': '확정 처리 중인 내역은 반려할 수 없습니다.'}, 409);
    await pump(tester);
    await waitUntil(tester, () => shows(find.text('신입생 환영회 명찰')));
    final readsBefore = entryReads;

    await rejectFirst(tester, '중복 영수증');
    await waitUntil(tester, () => shows(find.textContaining('다른 임원이 이 건을 먼저 처리하고 있어요')));

    expect(entryReads, greaterThan(readsBefore));
    expect(find.text('[신입생 환영회 명찰] 반려 처리되었습니다.'), findsNothing);
    expect(find.text('신입생 환영회 명찰'), findsOneWidget); // 대기 탭에 그대로
  });

  testWidgets('반려 중 401 로 로그인 화면으로 보내지면, 보내는 중 다이얼로그를 닫다가 그 화면을 닫지 않는다', (tester) async {
    onReject = () => json({'detail': 'token expired'}, 401);
    // main.dart 의 _forceLogin 과 같은 이동 — 쌓인 화면(다이얼로그 포함)을 모두 버린다
    final navigatorKey = GlobalKey<NavigatorState>();
    AuthService().onUnauthorized = () => navigatorKey.currentState!.pushAndRemoveUntil(
          MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('로그인 화면'))),
          (_) => false,
        );
    addTearDown(() => AuthService().onUnauthorized = null);

    await pump(tester, navigatorKey: navigatorKey);
    await waitUntil(tester, () => shows(find.text('신입생 환영회 명찰')));
    await rejectFirst(tester, '사유');
    await waitUntil(tester, () => posts.isNotEmpty && shows(find.text('로그인 화면')));

    // 전환이 끝난 뒤에도 로그인 화면이 남아 있고, 승인 화면·다이얼로그는 지워졌다
    expect(find.text('로그인 화면'), findsOneWidget);
    expect(find.byType(ApprovalListScreen), findsNothing);
    expect(find.text('반려 서명을 보내는 중이에요…'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('목록을 못 읽으면 목업으로 메우지 않고 실패를 보여 준다 — 다시 시도로 회복한다', (tester) async {
    onEntries = () => json({'detail': 'db down'}, 503);
    await pump(tester);
    await waitUntil(tester, () => shows(find.text('다시 시도')));
    expect(find.textContaining('불러오지 못했어요'), findsOneWidget);
    expect(find.text('청년피자 개강총회 다과 주문'), findsNothing);

    onEntries = () => json([entry(7, createdBy: 2, purpose: '신입생 환영회 명찰')]);
    await tester.tap(find.text('다시 시도'));
    await waitUntil(tester, () => shows(find.text('신입생 환영회 명찰')));
  });

  /// 눌리는 「승인 서명」 버튼 — 본인 등록 건(#8)의 회색 버튼은 InkWell 이 없다.
  Finder approveButton() => find.ancestor(of: find.text('승인 서명'), matching: find.byType(InkWell));

  testWidgets('승인하면 생체인증 다이얼로그를 거쳐 서명해 보내고, 다시 읽은 목록에서 승인 완료 탭으로 옮겨 간다', (tester) async {
    await pump(tester);
    await waitUntil(tester, () => shows(find.text('신입생 환영회 명찰')));

    await tester.tap(approveButton());
    await tester.pumpAndSettle();
    expect(find.text('집행 최종 승인'), findsOneWidget);
    expect(find.text('김총무'), findsNothing); // 목업 등록자 이름을 서버 건에 붙이지 않는다
    await tester.tap(find.text('생체인증 승인'));
    await waitUntil(tester, () => shows(find.text('[신입생 환영회 명찰] 승인 완료!')));

    expect(confirms, hasLength(1));
    expect((jsonDecode(confirms.single.body) as Map).containsKey('warning_reason'), isFalse);
    expect(posts, isEmpty);

    await tester.tap(find.text('승인 완료'));
    await tester.pumpAndSettle();
    expect(find.text('신입생 환영회 명찰'), findsOneWidget);
  });

  testWidgets('경고 건은 경고 무시 사유를 받아 함께 보낸다', (tester) async {
    ocr7 = 'MISMATCH';
    await pump(tester);
    await waitUntil(tester, () => shows(find.text('신입생 환영회 명찰')));

    await tester.tap(approveButton());
    await tester.pumpAndSettle();
    expect(find.text('경고 무시 승인 사유'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '현장 영수증 재확인함');
    await tester.tap(find.text('다음'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('생체인증 승인'));
    await waitUntil(tester, () => confirms.isNotEmpty && shows(find.text('[신입생 환영회 명찰] 승인 완료!')));

    expect((jsonDecode(confirms.single.body) as Map)['warning_reason'], '현장 영수증 재확인함');
  });

  testWidgets('승인이 거부되면(400) 서버 설명을 보여 주고, 반려로 넘겨 서명해 보낼 수 있다', (tester) async {
    onConfirm = () => json({'detail': '온체인 승인이 거부되었습니다 (InsufficientBudget).'}, 400);
    await pump(tester);
    await waitUntil(tester, () => shows(find.text('신입생 환영회 명찰')));

    await tester.tap(approveButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('생체인증 승인'));
    await waitUntil(tester, () => shows(find.text('승인에 실패했어요')));
    expect(find.textContaining('InsufficientBudget'), findsOneWidget);
    expect(find.text('[신입생 환영회 명찰] 승인 완료!'), findsNothing);

    await tester.tap(find.text('반려로 처리'));
    await tester.pumpAndSettle();
    expect(find.text('반려 사유'), findsOneWidget);
    await tester.tap(find.text('반려하기')); // 미리 채운 사유 그대로
    await waitUntil(tester, () => shows(find.text('[신입생 환영회 명찰] 반려 처리되었습니다.')));
    expect(posts, hasLength(1));
    expect((jsonDecode(posts.single.body) as Map)['reject_reason'], isNotEmpty);
  });

  testWidgets('승인이 409 면 알리고 목록을 다시 읽는다', (tester) async {
    onConfirm = () => json({'detail': '반려 처리 중인 내역은 확정할 수 없습니다.'}, 409);
    await pump(tester);
    await waitUntil(tester, () => shows(find.text('신입생 환영회 명찰')));
    final readsBefore = entryReads;

    await tester.tap(approveButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('생체인증 승인'));
    await waitUntil(tester, () => shows(find.textContaining('다른 임원이 이 건을 먼저 처리하고 있어요')));

    expect(entryReads, greaterThan(readsBefore));
    expect(find.text('승인에 실패했어요'), findsNothing);
  });

  testWidgets('승인 화면은 15초마다 목록을 다시 읽는다', (tester) async {
    await pump(tester);
    await waitUntil(tester, () => shows(find.text('신입생 환영회 명찰')));
    final before = entryReads;

    await tester.pump(const Duration(seconds: 16));
    await waitUntil(tester, () => entryReads > before);
  });

  testWidgets('앱으로 돌아오면 목록을 다시 읽는다', (tester) async {
    await pump(tester);
    await waitUntil(tester, () => shows(find.text('신입생 환영회 명찰')));
    final before = entryReads;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await waitUntil(tester, () => entryReads > before);
  });

  testWidgets('서명 직전에 다시 읽었더니 다른 임원이 먼저 확정했으면 서명하지 않고 알린 뒤 목록을 다시 읽는다', (tester) async {
    singleStatus7 = 'CONFIRMED';
    await pump(tester);
    await waitUntil(tester, () => shows(find.text('신입생 환영회 명찰')));
    final before = entryReads;

    await tester.tap(approveButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('생체인증 승인'));
    await waitUntil(tester, () => shows(find.textContaining('이 건은 이미')));

    expect(confirms, isEmpty);
    expect(entryReads, greaterThan(before));
  });
}
