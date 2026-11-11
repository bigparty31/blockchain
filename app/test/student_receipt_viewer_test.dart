import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/app_theme.dart';
import 'package:student_council_app/core/entry_merge.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/screens/student/entry_detail_screen.dart';

/// 영수증 확대 보기 (스토리보드 4 ③ 「누르면 확대보기 → 전체 화면 이미지」).
///
/// 카드 안 썸네일은 `BoxFit.cover` 로 잘려 있어서, 영수증의 품목·금액 줄이
/// 화면에 안 나오는 사진이 많다. 그 줄이 곧 이의 제기의 근거라 **확대가 없으면
/// 이 화면이 근거를 보여주지 못한다.** 눈으로는 「이미지가 있다」까지만 보이고
/// 눌리는지는 안 보여서 여기서 못박는다.
///
/// **범위 한계** — 위젯 테스트의 가짜 시계 아래에서는 영수증 다운로드
/// (`fetchReceiptBytes`) 의 Future 가 끝나지 않아 `_receiptBytes` 가 계속 null 이고,
/// 확대 화면이 받는 provider 는 `NetworkImage` 다. 그래서 「검증에 쓴 **바이트**를
/// 그대로 띄운다」까지는 못 잡고, 「상세 화면이 쓰는 provider 를 **그대로 넘긴다**」
/// 를 잡는다 — 경로로 다시 받는 구현으로 되돌리면 이 테스트가 깨진다.
void main() {
  testWidgets('영수증을 누르면 전체 화면으로 열린다', (tester) async {
    await _pumpDetailWithReceipt(tester);

    expect(find.byType(ReceiptViewerScreen), findsNothing);

    await tester.tap(_receiptImage, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(ReceiptViewerScreen), findsOneWidget,
        reason: '스토리보드 4 ③ — 썸네일을 누르면 전체 화면이 열려야 한다');
  });

  testWidgets('확대 화면은 상세 화면이 쓰는 provider 를 그대로 받는다', (tester) async {
    await _pumpDetailWithReceipt(tester);

    // 카드가 그리고 있는 바로 그 provider.
    final cardImage = tester.widget<Image>(_receiptImage).image;

    await tester.tap(_receiptImage, warnIfMissed: false);
    await tester.pumpAndSettle();

    final viewer = tester.widget<ReceiptViewerScreen>(
      find.byType(ReceiptViewerScreen),
    );
    expect(viewer.image, same(cardImage),
        reason: '확대 화면이 경로로 다시 받으면 검증한 파일과 띄운 파일이 갈린다');

    // 확대 화면도 같은 provider 로 그린다 (받아만 두고 안 쓰면 뜻이 없다).
    final shown = tester.widget<Image>(find.descendant(
      of: find.byType(ReceiptViewerScreen),
      matching: find.byType(Image),
    ));
    expect(shown.image, same(cardImage));
  });

  testWidgets('닫으면 상세 화면으로 돌아온다', (tester) async {
    await _pumpDetailWithReceipt(tester);

    await tester.tap(_receiptImage, warnIfMissed: false);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    expect(find.byType(ReceiptViewerScreen), findsNothing,
        reason: '스토리보드 4 ③ 「되돌림: 닫으면 상세 화면」');
    expect(find.byType(EntryDetailScreen), findsOneWidget);
  });
}

/// 상세 화면 안의 영수증 썸네일. 학생 상세 화면에서 `Image` 는 이것뿐이다.
///
/// 탭은 `warnIfMissed: false` 로 보낸다 — 테스트에서는 이미지가 디코드되기 전이라
/// `Image` 의 렌더박스가 자리만 잡은 상태이고, 탭을 받는 것은 그 바로 위의
/// `GestureDetector` 다. 탭이 실제로 닿는지는 「확대 화면이 열렸는가」로 확인된다.
final Finder _receiptImage = find.descendant(
  of: find.byType(EntryDetailScreen),
  matching: find.byType(Image),
);

Future<void> _pumpDetailWithReceipt(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.themeData,
    home: EntryDetailScreen(chain: EntryChain(original: _entry())),
  ));
  await tester.pump();

  // 영수증 카드는 화면 아래쪽에 있다. `ListView` 는 보이는 만큼만 만들기 때문에
  // 끌어올리지 않으면 트리에 아예 없다.
  await tester.dragUntilVisible(
    find.text('영수증'),
    find.byType(Scrollable).first,
    const Offset(0, -300),
  );
  await tester.pump();
}

EntryModel _entry() {
  final occurredAt = Hashing.kstMidnightOf(2026, 9, 20);
  return EntryModel(
    id: 31,
    termId: 1,
    kind: EntryKind.EXPENSE,
    amount: 35000,
    counterparty: '한결문구',
    purpose: '신입생 환영회 문구류',
    occurredAt: occurredAt,
    metaHash: Hashing.metaHash(
      amount: 35000,
      counterparty: '한결문구',
      purpose: '신입생 환영회 문구류',
      occurredAt: occurredAt,
    ),
    status: EntryStatus.CONFIRMED,
    createdBy: 2,
    approvedBy: 3,
    receiptPath: '/receipts/31.jpg',
  );
}
