import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/models/objection_model.dart';
import 'package:student_council_app/screens/student/objection_screen.dart';
import 'package:student_council_app/services/student_api_service.dart';

/// 제기한 이의가 화면을 나갔다 와도 남아 있는지 확인한다.
///
/// 서버에 `POST /objections` 가 아직 없어서 폴백으로 동작하는데, 예전 구현은
/// 객체를 만들어 돌려주기만 하고 아무 데도 담지 않아 **바로 사라졌다.**
/// 학생이 이의를 올렸는데 자기 화면에서도 안 보이는 상태였다.
void main() {
  // 서비스가 싱글턴이라 테스트 사이에 상태가 남는다. 각 테스트에서
  // 직접 올린 것만 세도록 기준값을 먼저 잡는다.
  late StudentApiService api;

  setUp(() {
    api = StudentApiService();
  });

  test('제기한 이의가 다시 조회할 때 남아 있다', () async {
    final before = await api.fetchObjections(entryId: 2);

    await api.raiseObjection(entryId: 2, content: '세부 품목 내역서를 확인할 수 있을까요?');

    final after = await api.fetchObjections(entryId: 2);
    expect(after.length, before.length + 1);
    expect(
      after.map((o) => o.content),
      contains('세부 품목 내역서를 확인할 수 있을까요?'),
    );
  });

  test('제기한 이의는 답변 대기 상태로 남는다', () async {
    final created = await api.raiseObjection(entryId: 4, content: '금액 확인 부탁드립니다');

    expect(created.status, ObjectionStatus.OPEN);
    expect(created.answer, isNull);
    expect(created.entryId, 4);
  });

  test('다른 항목의 이의는 섞이지 않는다', () async {
    await api.raiseObjection(entryId: 6, content: '포스터 인쇄 금액이 이상합니다');

    final forSix = await api.fetchObjections(entryId: 6);
    final forSeven = await api.fetchObjections(entryId: 7);

    expect(forSix.map((o) => o.content), contains('포스터 인쇄 금액이 이상합니다'));
    expect(forSeven.map((o) => o.content), isNot(contains('포스터 인쇄 금액이 이상합니다')));
  });

  test('id 가 기존 이의와 겹치지 않는다', () async {
    final a = await api.raiseObjection(entryId: 2, content: '첫 번째 질문입니다');
    final b = await api.raiseObjection(entryId: 2, content: '두 번째 질문입니다');

    final all = await api.fetchObjections();
    final ids = all.map((o) => o.id).toList();

    expect(a.id, isNot(b.id));
    expect(ids.toSet().length, ids.length, reason: 'id 가 중복되면 안 된다');
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

    // 제출은 실제 http 호출(및 그 폴백)을 타므로 가짜 시계 밖에서 돌려야 한다.
    await tester.runAsync(() async {
      await tester.tap(find.text('이의 제출'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    final raised = await StudentApiService().fetchObjections(entryId: 21);
    expect(raised, hasLength(1));
    expect(raised.single.content, typed);
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
