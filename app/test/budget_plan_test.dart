import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/budget_plan.dart';
import 'package:student_council_app/screens/president/budget_plan_controller.dart';
import 'package:student_council_app/services/budget_issuer.dart';

/// 예산 편성 규칙과 컨트롤러를 본다 (스토리보드 15, docs/CONTRACTS.md 「BudgetToken」).
///
/// 이 화면에서 틀리면 되돌릴 수 없다 — 발행된 예산은 수정·삭제가 없다.
/// 그래서 "막아야 할 것을 막는지"를 중심으로 본다.
void main() {
  // 테스트 기준일: 2026-10-06 12:00 KST (= 03:00 UTC)
  DateTime fixedNow() => DateTime.utc(2026, 10, 6, 3);
  final today = DateTime.utc(2026, 10, 6);
  final futureDate = DateTime(2026, 12, 14);

  group('BudgetPlanRules — KST 환산', () {
    test('마감일은 그 날 KST 23:59:59 의 Unix 초다 — 목업 expires_at 과 같다', () {
      // backend/app/routers/budgets.py: 1797260399 = 2026-12-14 23:59:59 KST
      expect(BudgetPlanRules.expiresAtSeconds(DateTime(2026, 12, 14)), 1797260399);
    });

    test('기기 시간대가 달라도 달력 날짜가 같으면 같은 값이다', () {
      expect(
        BudgetPlanRules.expiresAtSeconds(DateTime.utc(2026, 12, 14)),
        BudgetPlanRules.expiresAtSeconds(DateTime(2026, 12, 14)),
      );
    });

    test('KST 날짜는 자정(UTC 15:00)에 바뀐다', () {
      expect(BudgetPlanRules.kstDate(DateTime.utc(2026, 12, 13, 14, 59, 59)), DateTime.utc(2026, 12, 13));
      expect(BudgetPlanRules.kstDate(DateTime.utc(2026, 12, 13, 15, 0, 0)), DateTime.utc(2026, 12, 14));
    });
  });

  group('BudgetPlanRules — 항목 검사', () {
    test('빈 항목은 카테고리·편성액·마감일 셋 다 막는다', () {
      final problems = BudgetPlanRules.check([const BudgetDraftItem()], todayKst: today).single;
      expect(problems, [
        BudgetItemProblem.categoryMissing,
        BudgetItemProblem.amountMissing,
        BudgetItemProblem.expiryMissing,
      ]);
      expect(BudgetPlanRules.hasBlocking(problems), isTrue);
    });

    test('편성액 0 은 비어 있는 것과 같다', () {
      final item = BudgetDraftItem(category: BudgetCategory.event, amount: 0, expiresOn: futureDate);
      final problems = BudgetPlanRules.check([item], todayKst: today).single;
      expect(problems, [BudgetItemProblem.amountMissing]);
    });

    test('편성액은 컨트랙트 한도(1e15)까지만 — 한도 그대로는 통과, 1 넘으면 막는다', () {
      BudgetDraftItem withAmount(int v) =>
          BudgetDraftItem(category: BudgetCategory.event, amount: v, expiresOn: futureDate);
      expect(BudgetPlanRules.check([withAmount(kMaxBudgetAmount)], todayKst: today).single, isEmpty);
      expect(
        BudgetPlanRules.check([withAmount(kMaxBudgetAmount + 1)], todayKst: today).single,
        [BudgetItemProblem.amountTooLarge],
      );
    });

    test('같은 카테고리는 뒤에 나온 줄만 막는다 (BudgetAlreadyIssued 예방)', () {
      final a = BudgetDraftItem(category: BudgetCategory.event, amount: 100, expiresOn: futureDate);
      final b = BudgetDraftItem(category: BudgetCategory.event, amount: 200, expiresOn: futureDate);
      final result = BudgetPlanRules.check([a, b], todayKst: today);
      expect(result[0], isEmpty);
      expect(result[1], [BudgetItemProblem.duplicateCategory]);
    });

    test('과거 마감일은 경고일 뿐 막지 않는다 — 오늘은 과거가 아니다', () {
      BudgetDraftItem on(DateTime d) => BudgetDraftItem(category: BudgetCategory.event, amount: 100, expiresOn: d);

      final yesterday = BudgetPlanRules.check([on(DateTime(2026, 10, 5))], todayKst: today).single;
      expect(yesterday, [BudgetItemProblem.expiryInPast]);
      expect(BudgetPlanRules.hasBlocking(yesterday), isFalse);

      expect(BudgetPlanRules.check([on(DateTime(2026, 10, 6))], todayKst: today).single, isEmpty);
    });
  });

  group('BudgetPlanController', () {
    BudgetPlanController build(FakeBudgetIssuer issuer) =>
        BudgetPlanController(issuer: issuer, termId: 1, clock: fixedNow);

    /// 한 줄을 추가하고 전부 채운다. 추가한 줄의 index 를 돌려준다.
    int addFilled(BudgetPlanController c, BudgetCategory category, {int amount = 1000000}) {
      c.addLine();
      final i = c.lines.length - 1;
      c.setCategory(i, category);
      c.setAmount(i, amount);
      c.setExpiresOn(i, futureDate);
      return i;
    }

    test('처음엔 줄이 없고 확정할 수 없다', () {
      final c = build(FakeBudgetIssuer());
      expect(c.lines, isEmpty);
      expect(c.canConfirm, isFalse);
      expect(c.canAddLine, isTrue);
    });

    test('줄이 하나라도 덜 채워져 있으면 확정할 수 없다', () {
      final c = build(FakeBudgetIssuer());
      addFilled(c, BudgetCategory.event);
      expect(c.canConfirm, isTrue);

      c.addLine(); // 빈 줄
      expect(c.canConfirm, isFalse);
    });

    test('다른 줄이 쓴 카테고리는 고를 수 없고, 자기 것은 계속 보인다', () {
      final c = build(FakeBudgetIssuer());
      addFilled(c, BudgetCategory.event);
      addFilled(c, BudgetCategory.project);

      expect(c.availableCategories(0), contains(BudgetCategory.event));
      expect(c.availableCategories(0), isNot(contains(BudgetCategory.project)));
      expect(c.availableCategories(1), isNot(contains(BudgetCategory.event)));
    });

    test('줄은 카테고리 수(8)를 넘길 수 없다', () {
      final c = build(FakeBudgetIssuer());
      for (final category in BudgetCategory.values) {
        addFilled(c, category);
      }
      expect(c.lines.length, 8);
      expect(c.canAddLine, isFalse);

      c.addLine();
      expect(c.lines.length, 8);
    });

    test('확정하면 전부 발행되고 읽기 전용이 된다', () async {
      final issuer = FakeBudgetIssuer();
      final c = build(issuer);
      addFilled(c, BudgetCategory.event);
      addFilled(c, BudgetCategory.project);

      await c.confirm();

      expect(c.phase, BudgetPlanPhase.issued);
      expect(c.lines.every((l) => l.isIssued), isTrue);
      expect(c.isEditable(0), isFalse);
      expect(c.canAddLine, isFalse);
      expect(c.canConfirm, isFalse);
      expect(issuer.sent, [BudgetCategory.event, BudgetCategory.project]);
    });

    test('확정 버튼을 연달아 눌러도 발행은 한 번만 나간다 (가장 위험한 예외)', () async {
      final issuer = FakeBudgetIssuer(delay: const Duration(milliseconds: 20));
      final c = build(issuer);
      addFilled(c, BudgetCategory.event);

      // 첫 호출이 응답을 기다리는 동안 두 번째가 들어온다 — await 없이 연달아 부른다
      final first = c.confirm();
      final second = c.confirm();
      await Future.wait([first, second]);

      expect(issuer.callCount, 1);
      expect(issuer.sent, [BudgetCategory.event]);
      expect(c.phase, BudgetPlanPhase.issued);
    });

    test('발행 중에는 입력·삭제·추가·확정이 전부 잠긴다', () async {
      final c = build(FakeBudgetIssuer(delay: const Duration(milliseconds: 20)));
      addFilled(c, BudgetCategory.event);

      final pending = c.confirm();
      expect(c.phase, BudgetPlanPhase.processing);

      c.setAmount(0, 1);
      c.removeLine(0);
      c.addLine();
      expect(c.lines.length, 1);
      expect(c.lines.single.item.amount, 1000000);
      expect(c.canConfirm, isFalse);

      await pending;
    });

    test('지갑이 없으면 한 줄도 보내지 않고, 연결한 뒤 다시 확정할 수 있다', () async {
      final issuer = FakeBudgetIssuer(walletConnected: false);
      final c = build(issuer);
      addFilled(c, BudgetCategory.event);

      await c.confirm();
      expect(c.blockedBy, BudgetIssueFailure.walletNotConnected);
      expect(c.phase, BudgetPlanPhase.editing);
      expect(c.lines.single.state, BudgetLineState.draft);
      expect(issuer.sent, isEmpty);

      issuer.walletConnected = true;
      await c.confirm();
      expect(c.blockedBy, isNull);
      expect(c.phase, BudgetPlanPhase.issued);
    });

    test('일부만 성공하면 성공한 줄은 잠기고 실패한 줄만 고쳐서 다시 보낸다', () async {
      final issuer = FakeBudgetIssuer(forcedOutcomes: {
        BudgetCategory.project: const BudgetIssueOutcome(BudgetIssueStatus.rejected, message: '체인이 거부했어요'),
      });
      final c = build(issuer);
      addFilled(c, BudgetCategory.event);
      addFilled(c, BudgetCategory.project);

      await c.confirm();
      expect(c.phase, BudgetPlanPhase.editing); // 전부 성공한 게 아니라서 읽기 전용이 아니다
      expect(c.lines[0].state, BudgetLineState.issued);
      expect(c.lines[1].state, BudgetLineState.rejected);
      expect(c.lines[1].message, '체인이 거부했어요');
      expect(c.isEditable(0), isFalse); // 발행된 줄은 못 고친다
      expect(c.isEditable(1), isTrue);

      // 거부된 줄을 고치면 draft 로 돌아가고, 다시 확정하면 그 줄만 나간다
      issuer.forcedOutcomes.clear();
      c.setAmount(1, 500000);
      expect(c.lines[1].state, BudgetLineState.draft);
      await c.confirm();

      expect(c.phase, BudgetPlanPhase.issued);
      expect(issuer.sent, [BudgetCategory.event, BudgetCategory.project, BudgetCategory.project]);
    });

    test('응답이 없으면 성공인지 모르므로 고치지도 다시 보내지도 못한다', () async {
      final issuer = FakeBudgetIssuer(forcedOutcomes: {
        BudgetCategory.event: BudgetIssueOutcome.noResponse,
      });
      final c = build(issuer);
      addFilled(c, BudgetCategory.event);

      await c.confirm();

      expect(c.lines.single.state, BudgetLineState.noResponse);
      expect(c.hasPendingResponse, isTrue);
      expect(c.phase, BudgetPlanPhase.editing);
      expect(c.canConfirm, isFalse);
      expect(c.isEditable(0), isFalse);
    });

    test('이미 발행돼 있다는 응답은 발행된 것으로 본다', () async {
      final c = build(FakeBudgetIssuer(forcedOutcomes: {
        BudgetCategory.event: BudgetIssueOutcome.alreadyIssued,
      }));
      addFilled(c, BudgetCategory.event);

      await c.confirm();

      expect(c.lines.single.state, BudgetLineState.issued);
      expect(c.lines.single.message, '이미 발행되어 있어요');
      expect(c.phase, BudgetPlanPhase.issued);
    });

    test('발행 중에 화면을 닫아도(dispose) 응답이 돌아올 때 터지지 않는다', () async {
      final c = build(FakeBudgetIssuer(delay: const Duration(milliseconds: 20)));
      addFilled(c, BudgetCategory.event);

      final pending = c.confirm();
      c.dispose();

      await expectLater(pending, completes);
    });
  });
}
