import 'package:flutter/foundation.dart';

import '../../core/budget_plan.dart';
import '../../services/budget_issuer.dart';

/// 화면 전체가 지금 어떤 단계인가.
enum BudgetPlanPhase {
  /// 편집 가능 (이미 발행된 줄만 잠긴다)
  editing,

  /// 발행 중 — 입력·버튼 전부 잠금. 다시 누르기를 막는다 (스토리보드 15 D)
  processing,

  /// 모든 줄이 발행됨 — 읽기 전용 (스토리보드 15 E)
  issued,
}

/// 한 줄의 발행 상태.
enum BudgetLineState {
  /// 아직 안 보냄. 편집 가능
  draft,

  /// 체인에 기록됨. 잠김
  issued,

  /// 체인이 거부함. 고쳐서 다시 보낼 수 있다
  rejected,

  /// 보냈는데 응답이 없음. **성공했는지 모른다** — 고치거나 다시 보내면 안 된다
  noResponse,
}

/// 편성 화면의 한 줄: 입력값 + 발행 상태.
class BudgetLine {
  final BudgetDraftItem item;
  final BudgetLineState state;

  /// 거부·이미 발행됨 같은 상태에 붙는 설명
  final String? message;

  const BudgetLine(this.item, {this.state = BudgetLineState.draft, this.message});

  bool get isIssued => state == BudgetLineState.issued;

  /// 입력값을 고치면 이전 거부 상태는 의미가 없어서 draft 로 되돌린다.
  BudgetLine withItem(BudgetDraftItem next) => BudgetLine(next);

  BudgetLine withOutcome(BudgetIssueOutcome outcome) {
    final next = switch (outcome.status) {
      BudgetIssueStatus.issued || BudgetIssueStatus.alreadyIssued => BudgetLineState.issued,
      BudgetIssueStatus.rejected => BudgetLineState.rejected,
      BudgetIssueStatus.noResponse => BudgetLineState.noResponse,
    };
    final note = outcome.status == BudgetIssueStatus.alreadyIssued ? '이미 발행되어 있어요' : outcome.message;
    return BudgetLine(item, state: next, message: note);
  }
}

/// 예산 편성 화면의 상태와 동작. 위젯 없이 테스트할 수 있게 화면에서 떼어 냈다.
class BudgetPlanController extends ChangeNotifier {
  BudgetPlanController({
    required BudgetIssuer issuer,
    required int termId,
    DateTime Function()? clock,
  })  : _issuer = issuer,
        _termId = termId,
        _clock = clock ?? DateTime.now;

  final BudgetIssuer _issuer;
  final int _termId;
  final DateTime Function() _clock;

  final List<BudgetLine> _lines = [];
  BudgetPlanPhase _phase = BudgetPlanPhase.editing;
  BudgetIssueFailure? _blockedBy;
  bool _disposed = false;

  List<BudgetLine> get lines => List.unmodifiable(_lines);
  BudgetPlanPhase get phase => _phase;

  /// 발행을 시작도 못 한 이유 (지갑 미연결 등). 없으면 null
  BudgetIssueFailure? get blockedBy => _blockedBy;

  /// 응답이 없는 줄이 있다 — 성공인지 모르는 상태라 확정 버튼을 잠근다 (스토리보드 15 ⑤ 실패 (3))
  bool get hasPendingResponse => _lines.any((l) => l.state == BudgetLineState.noResponse);

  /// 항목은 카테고리 수(8)를 넘길 수 없다 — 한 카테고리에 예산은 하나뿐이다.
  bool get canAddLine => _phase == BudgetPlanPhase.editing && _lines.length < BudgetCategory.values.length;

  List<BudgetItemProblem> problemsOf(int index) => _check()[index];

  /// 이 줄의 드롭다운에 보여줄 카테고리 — 다른 줄이 이미 쓴 것은 뺀다.
  /// 중복을 에러로 알리기 전에 아예 못 고르게 하는 쪽이 사용자에게 덜 불친절하다.
  List<BudgetCategory> availableCategories(int index) {
    final usedElsewhere = <BudgetCategory>{
      for (var i = 0; i < _lines.length; i++)
        if (i != index && _lines[i].item.category != null) _lines[i].item.category!,
    };
    return [for (final c in BudgetCategory.values) if (!usedElsewhere.contains(c)) c];
  }

  /// 이 줄을 고치거나 지울 수 있는가. 발행된 줄과 응답 없는 줄은 안 된다.
  bool isEditable(int index) {
    if (_phase != BudgetPlanPhase.editing) return false;
    final state = _lines[index].state;
    return state == BudgetLineState.draft || state == BudgetLineState.rejected;
  }

  /// 편성 확정 버튼이 눌릴 수 있는가 — "항목이 1개 이상이고 모두 채워졌을 때" (스토리보드 15 ⑤)
  bool get canConfirm {
    if (_phase != BudgetPlanPhase.editing) return false;
    if (hasPendingResponse) return false;

    final problems = _check();
    var targets = 0;
    for (var i = 0; i < _lines.length; i++) {
      if (_lines[i].isIssued) continue;
      targets++;
      if (BudgetPlanRules.hasBlocking(problems[i])) return false;
    }
    return targets > 0;
  }

  void addLine() {
    if (!canAddLine) return;
    _lines.add(const BudgetLine(BudgetDraftItem()));
    _notify();
  }

  void removeLine(int index) {
    if (!isEditable(index)) return;
    _lines.removeAt(index);
    _notify();
  }

  void setCategory(int index, BudgetCategory? value) => _edit(index, (it) => it.withCategory(value));
  void setAmount(int index, int? value) => _edit(index, (it) => it.withAmount(value));
  void setExpiresOn(int index, DateTime? value) => _edit(index, (it) => it.withExpiresOn(value));

  /// 편성 확정. 아직 발행되지 않은 줄을 한꺼번에 보낸다.
  ///
  /// **중복 호출 차단이 이 화면에서 가장 위험한 예외다** (스토리보드 15).
  /// 아래에서 `await` 보다 **먼저, 같은 동기 구간에서** [_phase] 를 processing 으로 바꾼다.
  /// 순서가 바뀌면 첫 호출이 응답을 기다리는 사이 들어온 두 번째 호출이 [canConfirm] 을 통과한다.
  Future<void> confirm() async {
    if (!canConfirm) return;

    _phase = BudgetPlanPhase.processing;
    _blockedBy = null;
    _notify();

    final targets = [
      for (var i = 0; i < _lines.length; i++)
        if (!_lines[i].isIssued) i,
    ];

    try {
      final outcomes = await _issuer.issueAll(
        termId: _termId,
        items: [for (final i in targets) _lines[i].item],
      );
      if (outcomes.length != targets.length) {
        throw StateError('발행 결과 ${outcomes.length}개가 항목 ${targets.length}개와 맞지 않아요');
      }
      for (var k = 0; k < targets.length; k++) {
        _lines[targets[k]] = _lines[targets[k]].withOutcome(outcomes[k]);
      }
    } on BudgetIssueException catch (e) {
      // 한 줄도 나가지 않았다. 줄은 그대로 두고 이유만 보여준다.
      _blockedBy = e.failure;
    } finally {
      // 예외가 어디서 나든 processing 에 영원히 갇히지 않게 항상 단계를 되돌린다.
      _phase = _lines.every((l) => l.isIssued) ? BudgetPlanPhase.issued : BudgetPlanPhase.editing;
      _notify();
    }
  }

  List<List<BudgetItemProblem>> _check() => BudgetPlanRules.check(
        [for (final l in _lines) l.item],
        todayKst: BudgetPlanRules.kstDate(_clock()),
      );

  void _edit(int index, BudgetDraftItem Function(BudgetDraftItem) change) {
    if (!isEditable(index)) return;
    _lines[index] = _lines[index].withItem(change(_lines[index].item));
    _notify();
  }

  // 발행 중에 화면을 닫으면 응답이 돌아왔을 때 이미 dispose 된 뒤다.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
