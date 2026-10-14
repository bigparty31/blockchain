// 예산 편성(회장) 규칙 — 화면에서 떼어 낸 순수 로직.
//
// 근거: docs/CONTRACTS.md 「BudgetToken」, 스토리보드 15번.
// 위젯 없이 테스트할 수 있게 규칙을 여기 모았다. 규칙이 화면 코드에 흩어지면
// 같은 검사가 두 화면에서 어긋난다.

/// 컨트랙트 `MAX_AMOUNT` (1e15 원, contracts/deployments/localhost.json 의 `maxAmount`).
///
/// 넘으면 컨트랙트가 `FieldOutOfRange` 로 되돌린다. 서명·전송 전에 앱에서 먼저 막는다.
const int kMaxBudgetAmount = 1000000000000000;

/// 예산 카테고리 — 고정 8종. 자유 입력을 받지 않는다 (스토리보드 15 ②).
///
/// [label] 은 docs/CONTRACTS.md category 표(EXPENSE)와 **글자 하나까지** 같아야 한다.
/// 백엔드가 이 이름으로 keccak256 을 만들어 컨트랙트에 넘기므로, 철자가 다르면
/// 같은 항목이 다른 예산으로 갈라진다.
enum BudgetCategory {
  event('행사비'),
  project('사업비'),
  operation('운영비'),
  promotion('홍보비'),
  welfare('복지비'),
  meeting('회의비'),
  supplies('비품비'),
  reserve('예비비');

  final String label;
  const BudgetCategory(this.label);
}

/// 편성 중인 항목 한 줄 — 아직 체인에 올라가기 전의 입력값.
///
/// 값이 비어 있을 수 있어서(`null`) 필드가 전부 nullable 이다. 비어 있는지는
/// [BudgetPlanRules.problemsOf] 가 판단하고, 이 클래스는 값만 들고 있는다.
class BudgetDraftItem {
  /// 카테고리. 아직 안 골랐으면 null
  final BudgetCategory? category;

  /// 편성액(원 단위 정수). 입력란이 비었으면 null
  final int? amount;

  /// 집행 마감일. **달력 날짜만 의미가 있다** — 시·분·초와 시간대는 쓰지 않는다
  /// ([BudgetPlanRules.expiresAtSeconds] 가 KST 기준으로 환산한다)
  final DateTime? expiresOn;

  const BudgetDraftItem({this.category, this.amount, this.expiresOn});

  // copyWith(값 ?? 기존값) 방식은 "비우기"를 못 한다 — 편성액 입력란을 지우면 null 로 돌아가야 한다.
  // 그래서 필드마다 따로 만든다.
  BudgetDraftItem withCategory(BudgetCategory? v) =>
      BudgetDraftItem(category: v, amount: amount, expiresOn: expiresOn);

  BudgetDraftItem withAmount(int? v) =>
      BudgetDraftItem(category: category, amount: v, expiresOn: expiresOn);

  BudgetDraftItem withExpiresOn(DateTime? v) =>
      BudgetDraftItem(category: category, amount: amount, expiresOn: v);
}

/// 항목 하나에서 발견된 문제.
///
/// [blocking] 이 true 면 편성 확정을 막는다. false 는 알리기만 한다.
enum BudgetItemProblem {
  categoryMissing('카테고리를 골라 주세요', blocking: true),
  amountMissing('편성액을 입력해 주세요', blocking: true),
  amountTooLarge('편성액이 한도를 넘었어요', blocking: true),
  expiryMissing('집행 마감일을 골라 주세요', blocking: true),

  /// 컨트랙트는 한 학기·한 항목에 예산을 하나만 허용한다 (`BudgetAlreadyIssued`).
  /// 같은 카테고리를 두 줄 편성하면 앞 줄은 발행되고 뒷 줄만 되돌려져 **일부만 성공**한 채로 남는다.
  duplicateCategory('이미 편성한 카테고리예요', blocking: true),

  /// 스토리보드 15 ③: 과거 날짜는 "경고". 컨트랙트도 거부하지 않는다 (CONTRACTS.md 에 해당 에러가 없다).
  /// 다만 발행하면 되돌릴 수 없고 그 항목으로는 지출 등록이 바로 막히므로 확정 팝업에서 한 번 더 알린다.
  expiryInPast('마감일이 이미 지났어요. 이 항목으로는 지출을 등록할 수 없어요', blocking: false);

  final String message;
  final bool blocking;
  const BudgetItemProblem(this.message, {required this.blocking});
}

/// 예산 편성 검사·환산 규칙.
class BudgetPlanRules {
  BudgetPlanRules._();

  /// 지금 시각 → KST 달력 날짜(자정, UTC 로 표현).
  ///
  /// **기기 시간대를 쓰지 않는다.** 해외에서 열어도 KST 날짜 기준이어야 마감일 비교가 흔들리지 않는다
  /// (docs/HASHING.md §1.3 과 같은 원칙).
  static DateTime kstDate(DateTime now) {
    final kst = now.toUtc().add(const Duration(hours: 9));
    return DateTime.utc(kst.year, kst.month, kst.day);
  }

  /// 마감일(달력 날짜) → 서버에 보낼 Unix 초. **그 날 KST 23:59:59** 다.
  ///
  /// KST 23:59:59 = UTC 14:59:59 (같은 날짜). 목업 `expires_at` 1797260399 가
  /// 2026-12-14 23:59:59 KST 인 것과 같은 규칙이다. 마감일 하루 종일 지출 등록이 가능해야 해서
  /// 자정(00:00:00)이 아니라 하루의 끝으로 잡는다.
  ///
  /// [date] 가 기기 로컬 `DateTime` 이어도 연·월·일 필드(사용자가 달력에서 고른 날짜)만 쓴다.
  static int expiresAtSeconds(DateTime date) =>
      DateTime.utc(date.year, date.month, date.day, 14, 59, 59).millisecondsSinceEpoch ~/ 1000;

  /// 항목 목록 전체를 검사한다. 돌려주는 목록의 i 번째가 [items] 의 i 번째 항목의 문제다.
  ///
  /// 카테고리 중복은 **뒤에 나온 줄**에만 표시한다. 앞 줄까지 같이 막으면
  /// 사용자가 어느 쪽을 고쳐야 하는지 알 수 없다.
  static List<List<BudgetItemProblem>> check(
    List<BudgetDraftItem> items, {
    required DateTime todayKst,
  }) {
    final seen = <BudgetCategory>{};
    final result = <List<BudgetItemProblem>>[];

    for (final item in items) {
      final problems = <BudgetItemProblem>[];

      final category = item.category;
      if (category == null) {
        problems.add(BudgetItemProblem.categoryMissing);
      } else if (!seen.add(category)) {
        problems.add(BudgetItemProblem.duplicateCategory);
      }

      final amount = item.amount;
      if (amount == null || amount <= 0) {
        problems.add(BudgetItemProblem.amountMissing);
      } else if (amount > kMaxBudgetAmount) {
        problems.add(BudgetItemProblem.amountTooLarge);
      }

      final expiresOn = item.expiresOn;
      if (expiresOn == null) {
        problems.add(BudgetItemProblem.expiryMissing);
      } else if (DateTime.utc(expiresOn.year, expiresOn.month, expiresOn.day).isBefore(todayKst)) {
        problems.add(BudgetItemProblem.expiryInPast);
      }

      result.add(problems);
    }
    return result;
  }

  /// 확정을 막는 문제가 하나라도 있는가.
  static bool hasBlocking(List<BudgetItemProblem> problems) => problems.any((p) => p.blocking);
}
