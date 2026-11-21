import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/models/objection_model.dart';
import 'package:student_council_app/screens/student/objection_screen.dart';
import 'package:student_council_app/services/student_api_service.dart';

/// 이의 제기가 **서버에 그대로 가는지**만 본다.
///
/// 예전에는 서버에 `POST /objections` 가 없어서 세션 동안 로컬 사본을 들고 있었고,
/// 이 파일은 그 사본이 화면을 나갔다 와도 남아 있는지를 봤다. #128 로 엔드포인트가
/// 생긴 뒤 그 사본을 지웠다 — 접수되지 않은 이의가 「접수되었습니다」로 뜨는 길이고,
/// 목록의 정본은 서버 하나여야 한다. 제기한 이의가 다시 보이는지는 이제 서버가
/// 답할 몫이다 (`GET /objections`).
///
/// 남은 성질은 **앱이 본문을 건드리지 않는다**는 것이다.
void main() {
  late List<String> postedBodies;

  setUp(() {
    postedBodies = [];
    StudentApiService.client = MockClient((req) async {
      if (req.method == 'POST' && req.url.path == '/objections') {
        postedBodies.add(req.body);
        final sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'id': 1,
            'entry_id': sent['entry_id'],
            'user_id': 3,
            'content': sent['content'],
            'status': 'OPEN',
            'raised_at': 1794841200,
          }),
          201,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('[]', 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
  });

  tearDown(() async {
    StudentApiService.client = http.Client();
    await StudentApiService().resetSessionState();
  });

  test('접수된 이의는 서버 응답을 그대로 돌려준다 — 로컬 사본을 만들지 않는다', () async {
    final created = await StudentApiService()
        .raiseObjection(entryId: 4, content: '금액 확인 부탁드립니다');

    expect(created.id, 1);
    expect(created.entryId, 4);
    expect(created.status, ObjectionStatus.OPEN);
    expect(created.answer, isNull);
  });

  testWidgets('본문을 앱이 다듬지 않고 원문 그대로 보낸다', (tester) async {
    // 본문의 정본화·해시는 백엔드가 저장 시점에 한 번만 한다
    // (HASHING.md §1.1 파트별 표, student_screens.md §3.4).
    // 앱이 먼저 다듬으면, 지금은 로직이 같아 결과가 같더라도 한쪽만 바뀌는 순간
    // 학생이 실제로 친 원문과 저장·해시되는 값이 조용히 갈린다.
    const typed = '  영수증 품목과 지출 목적이 맞지 않습니다  \n';
    expect(Hashing.canonicalText(typed), isNot(typed),
        reason: '다듬으면 값이 달라지는 입력이어야 검사에 뜻이 있다');

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ObjectionScreen(entry: _entry(21)),
              ),
            ),
            child: const Text('열기'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), typed);

    // 제출 버튼은 화면 아래에 있어 그냥 tap 하면 헛친다.
    await tester.ensureVisible(find.text('이의 제출'));
    await tester.pumpAndSettle();

    // 제출은 실제 http 호출을 타므로 가짜 시계 밖에서 돌려야 한다.
    await tester.runAsync(() async {
      await tester.tap(find.text('이의 제출'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    expect(postedBodies, hasLength(1));
    final sent = jsonDecode(postedBodies.single) as Map<String, dynamic>;
    expect(sent['content'], typed);
    expect(sent['entry_id'], 21);
  });
}

/// 이의 대상이 될 최소한의 항목.
EntryModel _entry(int id) {
  final occurredAt = Hashing.kstMidnightOf(2026, 9, 10);
  return EntryModel(
    id: id,
    termId: 1,
    kind: EntryKind.EXPENSE,
    amount: 35000,
    counterparty: '한결문구',
    purpose: '신입생 환영회 명찰 및 필기구 구매',
    occurredAt: occurredAt,
    metaHash: Hashing.metaHash(
      amount: 35000,
      counterparty: '한결문구',
      purpose: '신입생 환영회 명찰 및 필기구 구매',
      occurredAt: occurredAt,
    ),
    status: EntryStatus.CONFIRMED,
    createdBy: 2,
    approvedBy: 3,
  );
}
