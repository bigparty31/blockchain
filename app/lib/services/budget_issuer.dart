import '../core/budget_plan.dart';

/// 예산 발행(`BudgetToken.issue`)이 앱에서 나가는 **유일한 입구**.
///
/// 화면은 이 인터페이스만 안다. 실제 구현은 `server_budget_issuer.dart` 의 `ServerBudgetIssuer`
/// (회장 기기 키로 EIP-712 `IssueRequest` 서명 → 서버 → 릴레이어 → 체인)이고, [FakeBudgetIssuer] 는
/// 체인 없이 화면을 개발·테스트할 때 쓴다.
///
/// 백엔드의 `ChainClient` / `FakeChainClient` 와 같은 패턴이다.
abstract class BudgetIssuer {
  /// [items] 를 한 줄씩 발행하고, **항목마다 결과 하나**를 같은 순서로 돌려준다.
  ///
  /// 항목 하나가 한 번의 트랜잭션이라 중간에 일부만 성공할 수 있다. 그래서 전체를
  /// 성공/실패 하나로 뭉뚱그리지 않고 항목별로 돌려준다.
  ///
  /// 시작도 못 하는 경우(지갑 미연결·회장 아님)는 항목을 하나도 보내기 전에
  /// [BudgetIssueException] 을 던진다. **그 밖의 예외는 던지지 않는다** — 실패는 항목별 결과로 돌려준다.
  ///
  /// [termId] 는 서버의 학기 id. null 이면 발행기가 현재 학기를 서버에서 찾는다.
  Future<List<BudgetIssueOutcome>> issueAll({
    int? termId,
    required List<BudgetDraftItem> items,
  });

  /// 「응답 없음」이던 [items] 가 체인에 기록됐는지 **확인만** 한다 — 서명하지 않고 아무것도 보내지 않는다 (#120 리뷰).
  ///
  /// 항목마다 결과 하나를 같은 순서로 돌려준다:
  ///  - [BudgetIssueStatus.alreadyIssued] — 체인에 있다 (체인 값과 함께)
  ///  - [BudgetIssueStatus.rejected] — 체인에 없고 서버도 보낸 기록을 지웠다. 고쳐서 다시 확정할 수 있다
  ///  - [BudgetIssueStatus.noResponse] — 아직 모른다 (처리 중이거나 확인 실패). 이유는 [BudgetIssueOutcome.message]
  ///
  /// 시작도 못 하면(회장 아님) [BudgetIssueException] 을 던진다. 그 밖의 예외는 던지지 않는다.
  Future<List<BudgetIssueOutcome>> checkAll({
    int? termId,
    required List<BudgetDraftItem> items,
  });
}

/// 발행을 시작조차 못 하는 이유. 던져지면 어떤 항목도 체인에 나가지 않았다.
enum BudgetIssueFailure {
  /// 회장 지갑이 연결되지 않았다 → "지갑 연결하기" 안내 (스토리보드 15 ⑤ 실패 (2))
  walletNotConnected,

  /// 회장 계정이 아니다 (403). 이 화면은 회장에게만 보여야 해서 정상 경로에서는 안 나온다 —
  /// 화면 접근 제어가 뚫렸을 때를 위한 마지막 방어선이다 (실패 (1))
  notPresident,
}

class BudgetIssueException implements Exception {
  final BudgetIssueFailure failure;
  const BudgetIssueException(this.failure);

  @override
  String toString() => 'BudgetIssueException($failure)';
}

/// 항목 하나의 발행 결과.
enum BudgetIssueStatus {
  /// 체인에 기록됐다
  issued,

  /// 같은 (학기, 카테고리) 예산이 이미 있다 (`BudgetAlreadyIssued`).
  /// 앞서 응답이 없던 시도가 사실은 성공했을 때도 여기로 온다
  alreadyIssued,

  /// 체인이 거부했다. 이유는 [BudgetIssueOutcome.message]
  rejected,

  /// 보냈는데 응답이 없다. **성공인지 실패인지 화면이 모른다** (스토리보드 15 ⑤ 실패 (3))
  noResponse,
}

class BudgetIssueOutcome {
  final BudgetIssueStatus status;
  final String? message;

  /// [BudgetIssueStatus.alreadyIssued] 일 때 **체인에 실제로 있는** 편성액·만료 시각(Unix 초).
  /// 입력값과 다를 수 있다 — 화면은 이 값으로 줄을 바꿔 보여 준다. 모르면 null.
  final int? issuedAmount;
  final int? issuedExpiresAt;

  const BudgetIssueOutcome(this.status, {this.message, this.issuedAmount, this.issuedExpiresAt});

  /// 이미 발행된 예산 — 서버가 알려 준 체인 값과 함께.
  const BudgetIssueOutcome.existing({int? amount, int? expiresAt})
      : this(BudgetIssueStatus.alreadyIssued, issuedAmount: amount, issuedExpiresAt: expiresAt);

  static const issued = BudgetIssueOutcome(BudgetIssueStatus.issued);
  static const alreadyIssued = BudgetIssueOutcome(BudgetIssueStatus.alreadyIssued);
  static const noResponse = BudgetIssueOutcome(BudgetIssueStatus.noResponse);
}

/// 체인에 아무것도 보내지 않는 가짜 발행기. 화면 개발·테스트용이다.
///
/// **이 구현으로 "발행됐다"고 보여도 체인에는 아무것도 기록되지 않는다.**
/// 이 구현을 쓰는 화면은 그 사실을 사용자에게 보여줘야 한다.
class FakeBudgetIssuer implements BudgetIssuer {
  FakeBudgetIssuer({
    this.delay = Duration.zero,
    this.walletConnected = true,
    this.isPresident = true,
    Map<BudgetCategory, BudgetIssueOutcome>? forcedOutcomes,
    Map<BudgetCategory, BudgetIssueOutcome>? checkOutcomes,
  })  : forcedOutcomes = forcedOutcomes ?? {},
        checkOutcomes = checkOutcomes ?? {};

  /// 한 번 발행하는 데 걸리는 시간. "처리 중" 화면을 눈으로 확인할 때 늘린다
  final Duration delay;

  bool walletConnected;
  bool isPresident;

  /// 카테고리별로 결과를 강제한다 — 일부만 성공·무응답 같은 실패 경로를 재현할 때 쓴다
  final Map<BudgetCategory, BudgetIssueOutcome> forcedOutcomes;

  /// 카테고리별 「결과 확인」 결과. 없으면 「아직 모름」 — 응답 없던 시도가 끝났는지 가짜는 알 수 없다
  final Map<BudgetCategory, BudgetIssueOutcome> checkOutcomes;

  /// [checkAll] 이 확인한 카테고리. 확인이 아무것도 보내지 않는지([sent] 그대로) 테스트에서 본다
  final List<BudgetCategory> checked = [];

  /// [issueAll] 이 불린 횟수. 중복 호출이 막혔는지 테스트에서 센다
  int callCount = 0;

  /// 지금까지 "보낸" 카테고리를 순서대로 기록한다. 다시 시도할 때 이미 발행된 줄이
  /// 또 나가지 않는지 테스트에서 본다
  final List<BudgetCategory> sent = [];

  // 가짜라서 학기는 구분하지 않는다. 진짜는 (term, category) 가 키다.
  final Set<BudgetCategory> _issued = {};

  @override
  Future<List<BudgetIssueOutcome>> issueAll({
    int? termId,
    required List<BudgetDraftItem> items,
  }) async {
    callCount++;
    if (!walletConnected) throw const BudgetIssueException(BudgetIssueFailure.walletNotConnected);
    if (!isPresident) throw const BudgetIssueException(BudgetIssueFailure.notPresident);

    await Future<void>.delayed(delay);
    return [for (final item in items) _issueOne(item)];
  }

  @override
  Future<List<BudgetIssueOutcome>> checkAll({
    int? termId,
    required List<BudgetDraftItem> items,
  }) async {
    if (!isPresident) throw const BudgetIssueException(BudgetIssueFailure.notPresident);
    await Future<void>.delayed(delay);
    final outcomes = <BudgetIssueOutcome>[];
    for (final item in items) {
      final category = item.category!;
      checked.add(category);
      outcomes.add(checkOutcomes[category] ??
          const BudgetIssueOutcome(BudgetIssueStatus.noResponse, message: '아직 체인에서 확인되지 않았어요'));
    }
    return outcomes;
  }

  BudgetIssueOutcome _issueOne(BudgetDraftItem item) {
    // 컨트롤러가 빈 항목을 걸러서 보내므로 null 일 수 없다. 어기면 바로 터지게 둔다.
    final category = item.category!;
    sent.add(category);
    final forced = forcedOutcomes[category];
    if (forced != null) return forced;
    return _issued.add(category) ? BudgetIssueOutcome.issued : BudgetIssueOutcome.alreadyIssued;
  }
}
