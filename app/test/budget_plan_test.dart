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

    test('이미 발행된 예산이 입력값과 다르면 체인의 금액·마감일로 바꿔 보인다', () async {
      final chainExpiry = BudgetPlanRules.expiresAtSeconds(DateTime(2027, 2, 28));
      final c = build(FakeBudgetIssuer(forcedOutcomes: {
        BudgetCategory.event: BudgetIssueOutcome.existing(amount: 1000000, expiresAt: chainExpiry),
      }));
      addFilled(c, BudgetCategory.event, amount: 2000000);

      await c.confirm();

      final line = c.lines.single;
      expect(line.state, BudgetLineState.issued);
      expect(line.item.amount, 1000000);
      expect(BudgetPlanRules.expiresAtSeconds(line.item.expiresOn!), chainExpiry);
      expect(line.message, contains('체인의 값'));
    });

    test('체인 값이 입력과 같으면 안내는 그대로', () async {
      final c = build(FakeBudgetIssuer(forcedOutcomes: {
        BudgetCategory.event: BudgetIssueOutcome.existing(
            amount: 1000000, expiresAt: BudgetPlanRules.expiresAtSeconds(DateTime(2026, 12, 14))),
      }));
      addFilled(c, BudgetCategory.event);

      await c.confirm();

      expect(c.lines.single.message, '이미 발행되어 있어요');
    });

    group('결과 확인 (#120 리뷰)', () {
      /// 행사비·사업비를 확정했는데 행사비만 응답이 없던 상태를 만든다
      Future<(BudgetPlanController, FakeBudgetIssuer)> pendingEvent({
        Map<BudgetCategory, BudgetIssueOutcome>? checks,
      }) async {
        final issuer = FakeBudgetIssuer(
          forcedOutcomes: {BudgetCategory.event: BudgetIssueOutcome.noResponse},
          checkOutcomes: checks,
        );
        final c = build(issuer);
        addFilled(c, BudgetCategory.event);
        addFilled(c, BudgetCategory.project, amount: 500000);
        await c.confirm();
        expect(c.lines.map((l) => l.state), [BudgetLineState.noResponse, BudgetLineState.issued]);
        return (c, issuer);
      }

      test('응답 없는 줄이 있을 때만 누를 수 있다', () async {
        final c = build(FakeBudgetIssuer());
        addFilled(c, BudgetCategory.event);
        expect(c.canCheck, isFalse);
        final (pending, _) = await pendingEvent();
        expect(pending.canCheck, isTrue);
      });

      test('체인에 있으면 발행됨 — 체인 값으로 잠기고 전부 발행이면 읽기 전용', () async {
        final expires = BudgetPlanRules.expiresAtSeconds(DateTime(2026, 12, 20));
        final (c, issuer) = await pendingEvent(checks: {
          BudgetCategory.event: BudgetIssueOutcome.existing(amount: 1200000, expiresAt: expires),
        });

        await c.checkPending();

        expect(c.lines[0].state, BudgetLineState.issued);
        expect(c.lines[0].item.amount, 1200000, reason: '입력값이 아니라 체인 값');
        expect(c.lines[0].item.expiresOn, DateTime.utc(2026, 12, 20));
        expect(c.phase, BudgetPlanPhase.issued);
        // 확인만 했다 — 다시 보내지 않았다
        expect(issuer.sent, [BudgetCategory.event, BudgetCategory.project]);
        expect(issuer.checked, [BudgetCategory.event], reason: '발행된 줄은 확인하지 않는다');
      });

      test('체인에 없고 보낸 기록도 없으면 거부 — 고쳐서 다시 확정할 수 있다', () async {
        final (c, issuer) = await pendingEvent(checks: {
          BudgetCategory.event: const BudgetIssueOutcome(BudgetIssueStatus.rejected, message: '체인 기록이 확인되지 않았어요'),
        });

        await c.checkPending();

        expect(c.lines[0].state, BudgetLineState.rejected);
        expect(c.isEditable(0), isTrue);
        expect(c.canConfirm, isTrue);

        issuer.forcedOutcomes.clear();
        await c.confirm();
        expect(c.phase, BudgetPlanPhase.issued);
        expect(issuer.sent, [BudgetCategory.event, BudgetCategory.project, BudgetCategory.event]);
      });

      test('아직 모르면 잠금을 유지하고 이유를 붙인다', () async {
        final (c, _) = await pendingEvent();

        await c.checkPending();

        expect(c.lines[0].state, BudgetLineState.noResponse);
        expect(c.lines[0].message, '아직 체인에서 확인되지 않았어요');
        expect(c.canConfirm, isFalse);
        expect(c.isEditable(0), isFalse);
        expect(c.canCheck, isTrue, reason: '나중에 다시 확인할 수 있다');
      });

      test('확인 중에는 다시 누르기·확정이 막히고 checking 이 켜진다', () async {
        final (c, issuer) = await pendingEvent();
        final first = c.checkPending();
        expect(c.phase, BudgetPlanPhase.processing);
        expect(c.checking, isTrue);
        expect(c.canCheck, isFalse);
        await c.checkPending(); // 무시된다
        await first;
        expect(issuer.checked, [BudgetCategory.event], reason: '한 번만 확인');
        expect(c.checking, isFalse);
      });

      test('예상 못 한 오류(결과 수 불일치)도 던지지 않고 응답 없음을 유지한다 (#125 리뷰)', () async {
        final issuer = _ShortCheckIssuer(forcedOutcomes: {BudgetCategory.event: BudgetIssueOutcome.noResponse});
        final c = build(issuer);
        addFilled(c, BudgetCategory.event);
        await c.confirm();

        await c.checkPending(); // 던지면 여기서 테스트가 실패한다

        expect(c.lines.single.state, BudgetLineState.noResponse);
        expect(c.lines.single.message, contains('확인하지 못했어요'));
        expect(c.phase, BudgetPlanPhase.editing);
        expect(c.checking, isFalse);
        expect(c.canCheck, isTrue);
      });

      test('회장이 아니면 줄은 그대로 두고 이유만 보인다', () async {
        final (c, issuer) = await pendingEvent();
        issuer.isPresident = false;
        await c.checkPending();
        expect(c.blockedBy, BudgetIssueFailure.notPresident);
        expect(c.lines[0].state, BudgetLineState.noResponse);
        expect(c.phase, BudgetPlanPhase.editing);
      });
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

/// 확인 결과를 항목 수보다 적게 돌려주는 고장 난 발행기 — 컨트롤러가 던지지 않는지 본다
class _ShortCheckIssuer extends FakeBudgetIssuer {
  _ShortCheckIssuer({super.forcedOutcomes});

  @override
  Future<List<BudgetIssueOutcome>> checkAll({int? termId, required List<BudgetDraftItem> items}) async => [];
}
