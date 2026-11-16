import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/screens/council/approval_list_screen.dart';
import 'package:student_council_app/services/api_service.dart';

/// 총무가 수정을 요청한 건은 승인권자가 **확정할 수 없고 반려만 할 수 있다** (API §2.3, PRD §4.3 T4).
///
/// 서버는 이런 건의 확정을 막는다. 화면이 이를 모르면 감사가 「승인 서명」을 누르고 지문까지 찍은 뒤에야
/// 「다른 임원이 먼저 처리하고 있어요」라는 엉뚱한 안내를 받는다 (실서버에서 확인). 서명 전에 화면이 막는다.
EntryModel pending({int id = 1, int? revisionRequestedAt}) => EntryModel(
      id: id,
      termId: 1,
      kind: EntryKind.EXPENSE,
      amount: 50000,
      counterparty: '거래처$id',
      purpose: '목적$id',
      budgetId: 1,
      occurredAt: 1788793200,
      metaHash: '0x${'0' * 64}',
      status: EntryStatus.PENDING,
      createdBy: 2,
      revisionRequestedAt: revisionRequestedAt,
    );

void main() {
  setUp(() => ApiService.useDemoData = true);

  test('승인 항목에 「수정 요청 중」이 실린다 — 요청한 건만', () {
    expect(approvalItemFromEntry(pending(revisionRequestedAt: 1794187428))['revisionRequested'], isTrue);
    expect(approvalItemFromEntry(pending())['revisionRequested'], isNot(true));
  });

  group('승인 목록 카드', () {
    Future<void> pumpItem(WidgetTester tester, EntryModel e) async {
      tester.view.physicalSize = const Size(411, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: ApprovalListScreen(role: UserRole.AUDITOR, currentUserId: 4, items: [approvalItemFromEntry(e)]),
      ));
      await tester.pumpAndSettle();
    }

    // 눌리는 「승인 서명」 — 회색 비활성 버튼에는 InkWell 이 없다
    Finder approveButton() => find.ancestor(of: find.text('승인 서명'), matching: find.byType(InkWell));
    Finder rejectButton() => find.widgetWithText(OutlinedButton, '반려');

    testWidgets('수정 요청 중인 건은 이유를 알리고, 승인 서명은 막고, 반려는 열어 둔다', (tester) async {
      await pumpItem(tester, pending(revisionRequestedAt: 1794187428));
      expect(find.textContaining('수정을 요청했어요'), findsOneWidget);
      expect(find.text('승인 서명'), findsOneWidget, reason: '자리는 남기되');
      expect(approveButton(), findsNothing, reason: '눌리지 않는다');
      expect(rejectButton(), findsOneWidget);
      expect(tester.widget<OutlinedButton>(rejectButton()).onPressed, isNotNull, reason: '반려는 할 수 있다');
    });

    testWidgets('수정 요청이 없는 건은 그대로 승인할 수 있다', (tester) async {
      await pumpItem(tester, pending());
      expect(find.textContaining('수정을 요청했어요'), findsNothing);
      expect(approveButton(), findsOneWidget);
    });
  });
}
