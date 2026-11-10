import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/enums.dart';
import '../../core/format.dart';
import '../../models/budget_model.dart';
import '../../models/entry_model.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../../services/entry_decision_service.dart';
import 'reason_dialog.dart';
import 'sending_dialog.dart';

/// 정정 승인 대상 한 건. 원본은 그대로 두고 증감분만 새 기록으로 올라온 것이다.
class CorrectionItem {
  final int id;
  final int createdBy;
  final String title; // 원본 내역 이름
  final String category;
  final CorrectionReason reason;

  /// 이 예산에서 정정 직전의 금액. 원본을 목록에서 찾지 못했으면 null (정정 후 금액도 알 수 없다).
  final int? original;
  final int delta; // 정정 증감분 (±)

  /// 해당 예산의 남은 금액. 수입이거나 예산을 읽지 못했으면 null — 그때는 화면이 미리 막지 않고 체인이 판정한다.
  final int? budgetRemaining;
  final String status; // 대기 | 확정 | 반려 | 재분류 진행 중
  final String? pairNote; // 재분류의 짝 정보

  /// 정정 내용(상세 사유) — 서버 건의 `purpose`.
  final String? note;

  /// 서버 건의 원본 응답 — 승인·반려 서명이 이 값으로 만들어진다. 목업은 null.
  final EntryModel? entry;

  /// 재분류 감액(−)인데 같은 원본의 증액(+)이 아직 확정되지 않았다 — 서버가 확정 순서를 강제해 400 으로 돌려보낸다
  /// (PRD §4.4, #81). 지문을 댄 뒤에 거부되지 않도록 서명을 받기 전에 막는다.
  final bool awaitsPlusFirst;

  const CorrectionItem({
    required this.id,
    required this.createdBy,
    required this.title,
    required this.category,
    required this.reason,
    required this.original,
    required this.delta,
    required this.budgetRemaining,
    this.status = '대기',
    this.pairNote,
    this.note,
    this.entry,
    this.awaitsPlusFirst = false,
  });

  int? get finalAmount => original == null ? null : original! + delta;

  /// 증액 정정인데 예산 잔량이 모자라면 확정할 수 없다 — 승인해도 대기로 남는다.
  bool get insufficient => delta > 0 && budgetRemaining != null && delta > budgetRemaining!;

  CorrectionItem copyWith({String? status}) => CorrectionItem(
        id: id,
        createdBy: createdBy,
        title: title,
        category: category,
        reason: reason,
        original: original,
        delta: delta,
        budgetRemaining: budgetRemaining,
        status: status ?? this.status,
        pairNote: pairNote,
        note: note,
        entry: entry,
        awaitsPlusFirst: awaitsPlusFirst,
      );
}

/// 서버 내역(`GET /entries`)에서 정정 건(`corrects_entry_id` 가 있는 건)을 골라 화면 재료로 바꾼다.
/// 대기 건이 앞에(등록 순), 처리된 건(확정·반려)이 뒤에(최근 순) 온다. 차단 건은 승인 대상이 아니라 뺀다.
///
/// [budgets] 는 예산 이름과 잔량을 위한 것이다. 못 읽었으면 비워서 넘긴다 — 이름은 `예산 #id`, 잔량은 모름이다.
List<CorrectionItem> correctionItemsFromEntries(List<EntryModel> entries, {List<BudgetModel> budgets = const []}) {
  final byId = {for (final e in entries) e.id: e};
  final budgetById = {for (final b in budgets) b.id: b};
  bool isCorrection(EntryModel e) => e.correctsEntryId != null && e.correctsEntryId != 0;

  /// 정정의 정정을 따라 올라가 맨 처음 원본을 찾는다. 원본이 목록에 없으면 찾은 데까지.
  EntryModel rootOf(EntryModel e) {
    var cur = e;
    final seen = <int>{};
    while (isCorrection(cur) && seen.add(cur.id)) {
      final next = byId[cur.correctsEntryId];
      if (next == null) break;
      cur = next;
    }
    return cur;
  }

  String nameOf(EntryModel e) {
    if (e.kind == EntryKind.INCOME) return '수입';
    final id = e.budgetId;
    if (id == null) return '예산 미배정';
    return budgetById[id]?.category ?? '예산 #$id';
  }

  String statusOf(EntryStatus s) => switch (s) {
        EntryStatus.PENDING => '대기',
        EntryStatus.CONFIRMED => '확정',
        EntryStatus.REJECTED => '반려',
        EntryStatus.BLOCKED => '차단',
      };

  CorrectionItem build(EntryModel e) {
    final root = rootOf(e);
    final orphan = identical(root, e); // 원본을 목록에서 찾지 못했다
    final reason = e.correctionReason ?? CorrectionReason.OTHER;

    // 이 예산에서 정정 직전의 금액 = 원본 + 이 건보다 먼저 확정된 같은 체인의 정정.
    // 재분류의 증액(+) 쪽은 다른 예산에 새로 생기는 금액이라 0 에서 시작한다.
    int? original;
    if (!orphan) {
      if (reason == CorrectionReason.RECLASSIFY && e.amount > 0) {
        original = 0;
      } else {
        var sum = root.amount;
        for (final c in entries) {
          if (c.id == e.id || c.id > e.id || !isCorrection(c) || c.status != EntryStatus.CONFIRMED) continue;
          if (c.correctionReason == CorrectionReason.RECLASSIFY && c.amount > 0) continue; // 다른 예산의 금액
          if (identical(rootOf(c), root)) sum += c.amount;
        }
        original = sum;
      }
    }

    // 재분류 짝 — 같은 원본의 다른 재분류 건.
    String? pairNote;
    var awaitsPlusFirst = false;
    var status = statusOf(e.status);
    if (reason == CorrectionReason.RECLASSIFY && !orphan) {
      // 감액(−)은 같은 원본에서 다른 예산으로 옮긴 증액(+)이 CONFIRMED 여야 확정된다.
      if (e.amount < 0) {
        awaitsPlusFirst = !entries.any((c) =>
            c.id != e.id &&
            isCorrection(c) &&
            c.correctionReason == CorrectionReason.RECLASSIFY &&
            c.amount > 0 &&
            c.status == EntryStatus.CONFIRMED &&
            identical(rootOf(c), root));
      }
      final siblings = entries.where((c) =>
          c.id != e.id &&
          isCorrection(c) &&
          c.correctionReason == CorrectionReason.RECLASSIFY &&
          identical(rootOf(c), root) &&
          c.status != EntryStatus.REJECTED &&
          c.status != EntryStatus.BLOCKED);
      if (siblings.isNotEmpty) {
        final other = siblings.first;
        final plus = e.amount > 0 ? e : other;
        final minus = e.amount > 0 ? other : e;
        final done = [e, other].where((x) => x.status == EntryStatus.CONFIRMED).length;
        String side(EntryModel x, String sign) => '${nameOf(x)} $sign${Fmt.plain(x.amount.abs())} ${statusOf(x.status)}';
        pairNote = '${side(plus, '+')} · ${side(minus, '−')} (짝 $done/2)';
        if (e.status == EntryStatus.PENDING) status = '재분류 진행 중';
      }
    }

    final budget = e.budgetId == null ? null : budgetById[e.budgetId];
    return CorrectionItem(
      id: e.id,
      createdBy: e.createdBy,
      title: orphan ? '원본 #${e.correctsEntryId} (불러오지 못했어요)' : root.purpose,
      category: nameOf(e),
      reason: reason,
      original: original,
      delta: e.amount,
      budgetRemaining: e.kind == EntryKind.INCOME ? null : budget?.remainingAmount,
      status: status,
      pairNote: pairNote,
      note: e.purpose.isEmpty ? null : e.purpose,
      entry: e,
      awaitsPlusFirst: awaitsPlusFirst,
    );
  }

  final shown = entries.where((e) => isCorrection(e) && e.status != EntryStatus.BLOCKED).toList();
  final waiting = shown.where((e) => e.status == EntryStatus.PENDING).toList()..sort((a, b) => a.id.compareTo(b.id));
  final done = shown.where((e) => e.status != EntryStatus.PENDING).toList()..sort((a, b) => b.id.compareTo(a.id));
  return [for (final e in [...waiting, ...done]) build(e)];
}

/// **목업** 정정 승인 대상 — 위젯 테스트·화면 캡처에서 [CorrectionApprovalScreen.items] 로 넣는다.
/// 앱은 서버(`GET /entries`)를 읽는다 ([correctionItemsFromEntries]).
List<CorrectionItem> buildCorrectionMockItems() => const [
      CorrectionItem(
        id: 21,
        createdBy: 2,
        title: '한결문구 신입생 환영회 물품 구매',
        category: '행사비',
        reason: CorrectionReason.INPUT_ERROR,
        original: 35000,
        delta: 5000,
        budgetRemaining: 2470000,
      ),
      CorrectionItem(
        id: 22,
        createdBy: 2,
        title: '청년피자 개강총회 다과 주문',
        category: '행사비',
        reason: CorrectionReason.REFUND,
        original: 120000,
        delta: -20000,
        budgetRemaining: 2470000,
      ),
      CorrectionItem(
        id: 23,
        createdBy: 2,
        title: '학과 MT 레크리에이션 소품',
        category: '운영비',
        reason: CorrectionReason.RECLASSIFY,
        original: 22000,
        delta: -22000,
        budgetRemaining: 1000000,
        status: '재분류 진행 중',
        pairNote: '사업비 +22,000 확정 · 운영비 −22,000 대기 (짝 1/2)',
      ),
      CorrectionItem(
        id: 24,
        createdBy: 2,
        title: '동아리 연합 행사 현수막 제작',
        category: '사업비',
        reason: CorrectionReason.RECEIPT_RECHECK,
        original: 85000,
        delta: 1600000,
        budgetRemaining: 1465000,
      ),
      CorrectionItem(
        id: 25,
        createdBy: 3,
        title: '학교 지원금 입금 확인',
        category: '지원금',
        reason: CorrectionReason.INPUT_ERROR,
        original: 2000000,
        delta: -50000,
        budgetRemaining: 0,
      ),
    ];

/// [이승호 담당: app/lib/screens/council/]
/// 정정 승인 화면 (스토리보드 13) — 감사·회장이 정정 건을 원본과 대조해 승인·반려한다.
///
/// - 원본 금액 · 정정 증감분 · 정정 후 금액을 나란히 보여 준다.
/// - 등록자와 승인자가 같으면 승인·반려할 수 없다.
/// - 증액 정정이 예산 잔량을 넘으면 승인해도 확정되지 않고 대기로 남는다.
/// - 재분류는 짝이 되는 두 건이 모두 확정될 때까지 「재분류 진행 중」이다.
class CorrectionApprovalScreen extends StatefulWidget {
  final UserRole? role;
  final int? currentUserId;

  /// 목록 재료 (위젯 테스트·화면 캡처용 — [buildCorrectionMockItems]). 주지 않으면 서버(`GET /entries`)에서 읽는다.
  final List<CorrectionItem>? items;

  /// 승인·반려 서명·전송. 테스트에서 가짜 본인 확인을 넣는다.
  final EntryDecisionService? decisions;

  /// **로그인했으면 세션([AuthService.session])의 역할·id 만 믿는다** — [role]·[currentUserId] 인자로
  /// 다른 역할을 주장할 수 없다. 인자는 로그인 없이 화면을 그리는 위젯 테스트용이다.
  const CorrectionApprovalScreen({super.key, this.role, this.currentUserId, this.items, this.decisions});

  UserRole? get effectiveRole => AuthService().session?.role ?? role;
  int? get effectiveUserId => AuthService().session?.userId ?? currentUserId;

  bool get allowed => effectiveRole == UserRole.AUDITOR || effectiveRole == UserRole.PRESIDENT;

  @override
  State<CorrectionApprovalScreen> createState() => _CorrectionApprovalScreenState();
}

class _CorrectionApprovalScreenState extends State<CorrectionApprovalScreen> {
  /// 서버에서 읽는가 — 목록 재료를 받지 않았으면 언제나 그렇다. 서버를 못 읽어도 목업으로 메우지 않는다.
  late final bool _fromServer = widget.items == null;

  late List<CorrectionItem> _items = List.of(widget.items ?? const []);

  late final EntryDecisionService _decisions = widget.decisions ?? EntryDecisionService();

  /// 서버 목록을 읽는 중인가 / 마지막 읽기가 실패한 이유.
  late bool _loading = _fromServer && widget.allowed;
  String? _loadError;

  /// 겹친 읽기 중 마지막 응답만 반영한다.
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    if (_fromServer && widget.allowed) _load(initial: true);
  }

  /// 서버에서 정정 건을 다시 읽는다. 실패하면 목록을 비우지 않고 실패를 적는다 — 보이는 상태가 최신이 아닐 수 있다.
  Future<void> _load({bool initial = false}) async {
    final seq = ++_loadSeq;
    if (!initial) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    // 예산 이름·잔량은 없어도 목록은 보여 줄 수 있다 — 못 읽으면 `예산 #id`, 잔량은 모름으로 둔다.
    final budgets = ApiService().fetchBudgets().catchError((Object _) => <BudgetModel>[]);
    try {
      final entries = await ApiService().fetchEntries();
      final list = await budgets;
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _items = correctionItemsFromEntries(entries, budgets: list);
        _loading = false;
        _loadError = null;
      });
    } on ApiUnavailable catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _loading = false;
        _loadError = e.message;
      });
    }
  }

  void _replace(CorrectionItem old, CorrectionItem next) {
    setState(() => _items[_items.indexOf(old)] = next);
  }

  void _toast(String text, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  Future<void> _approve(CorrectionItem e) async {
    // 재분류는 증액(+)을 먼저 확정해야 감액(−)을 확정할 수 있다 — 서명을 받기 전에 알린다.
    if (e.awaitsPlusFirst) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('먼저 확정할 건이 있어요', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          content: const Text('재분류는 새 예산의 증액(+) 건을 먼저 확정한 뒤에 원래 예산의 감액(−) 건을 확정할 수 있어요. '
              '증액 건을 먼저 승인해 주세요.'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('확인'))],
        ),
      );
      return;
    }

    // 증액 정정이 잔량을 넘으면 확정이 되지 않는다 — 서명을 받기 전에 알린다 (대기 그대로).
    if (e.insufficient) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('확정할 수 없어요', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          content: Text('${e.category} 예산 잔량(${Fmt.won(e.budgetRemaining!)})이 증액분(${Fmt.won(e.delta)})보다 적어요. '
              '이 건은 대기로 남아 있어요. 예산을 늘리거나 반려해 주세요.'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('확인'))],
        ),
      );
      return;
    }

    // 경고가 있는 건(영수증 판독 불일치·중복, 카테고리 경고)은 사유를 먼저 받는다 — 서버 건만.
    final entry = e.entry;
    String? warningReason;
    if (entry != null && EntryDecisionService.hadWarning(entry)) {
      warningReason = await showReasonDialog(
        context,
        title: '경고 무시 승인 사유',
        description: '등록 내용에 확인이 필요한 항목(영수증 판독·카테고리 경고)이 있습니다. 그래도 승인하려면 사유를 남겨 주세요.',
        confirmLabel: '다음',
        accent: AppTheme.pending,
        icon: Icons.warning_amber_rounded,
      );
      if (warningReason == null || !mounted) return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFF6C63FF)]),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.fingerprint_rounded, color: Colors.white, size: 44),
              ),
              const SizedBox(height: 16),
              const Text('정정 승인', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textMain)),
              const SizedBox(height: 4),
              const Text('생체인증으로 블록체인 서명', style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: AppTheme.bgPage, borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv('대상', e.title),
                    _kv('증감분', _signed(e.delta)),
                    _kv('정정 후', e.finalAmount == null ? '—' : Fmt.won(e.finalAmount!)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppTheme.divider),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text('취소', style: TextStyle(color: AppTheme.textSub)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: GradientButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      label: '생체인증 승인',
                      icon: Icons.fingerprint_rounded,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;

    if (entry != null) {
      await _confirmOnServer(e, entry, warningReason);
      return;
    }

    // 목업 건 — 서버 없이 화면에서만 바꾼다.
    _replace(e, e.copyWith(status: '확정'));
    _toast(
      e.reason == CorrectionReason.RECLASSIFY
          ? '[${e.title}] 재분류 정정 2건이 모두 확정되었습니다.'
          : '[${e.title}] 정정 승인 완료!',
      AppTheme.success,
    );
  }

  /// 서버 건 승인 — 기기 서명 → `POST /entries/{id}/confirm`.
  ///
  /// 체인·서버가 거부하면(400) 항목은 `PENDING` 그대로라 예산 사유일 때 반려로 넘길 수 있다.
  /// 그 밖의 실패는 알리고 목록을 다시 읽는다 — 409·결과 모름이면 다른 임원의 처리가 반영됐을 수 있다.
  Future<void> _confirmOnServer(CorrectionItem e, EntryModel entry, String? warningReason) async {
    final failed = await sendWithBlocking(
      context,
      '정정 승인 서명을 보내는 중이에요…',
      () => _decisions.confirm(entry, warningReason: warningReason),
    );
    if (!mounted) return;

    if (failed != null) {
      if (failed.failure == EntryDecisionFailure.refused) {
        await _showConfirmFailure(e, failed);
      } else {
        _toast(failed.message, AppTheme.expense);
      }
      // 401 이면 세션이 비워져 로그인 화면으로 간다 — 다시 읽을 것이 없다
      if (mounted && failed.failure != EntryDecisionFailure.unauthorized) _load();
      return;
    }
    _toast('[${e.title}] 정정 승인 완료!', AppTheme.success);
    _load();
  }

  /// 확정 실패 안내. 예산 사유(`InsufficientBudget`·`BudgetExpired`)면 반려로 넘길 수 있고, 아니면 다시 서명할 일이다.
  /// 서버 문구를 해석해 분기하지 않는다 — 실패 코드(`fail_reason`)로만 나눈다.
  Future<void> _showConfirmFailure(CorrectionItem e, EntryDecisionException failed) async {
    final budgetReason = failed.failReason == null ? null : budgetFailReasons[failed.failReason];
    final goReject = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('승인에 실패했어요', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        content: Text(
          '${budgetReason ?? failed.message}\n\n'
          '${budgetReason != null ? '이 건은 아직 대기 상태예요. 확정할 수 없으므로 반려로 처리해 주세요.' : '이 건은 아직 대기 상태예요. 잠시 뒤 다시 서명해 주세요.'}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('나중에')),
          if (budgetReason != null)
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('반려로 처리')),
        ],
      ),
    );
    if (goReject == true && mounted) {
      await _reject(e, initialReason: '$budgetReason. 확정할 수 없어 반려합니다.');
    }
  }

  Future<void> _reject(CorrectionItem e, {String? initialReason}) async {
    final reason = await showReasonDialog(
      context,
      title: '정정 반려 사유',
      description: '[${e.title}] 정정을 반려합니다. 반려하면 되돌릴 수 없어요.',
      confirmLabel: '반려하기',
      initialText: initialReason,
    );
    if (reason == null || !mounted) return;

    final entry = e.entry;
    if (entry != null) {
      // 성공이든 실패든 끝나면 목록을 다시 읽는다 — 409·결과 모름이면 다른 임원의 처리가 반영됐을 수 있다.
      final failed = await sendWithBlocking(context, '반려 서명을 보내는 중이에요…', () => _decisions.reject(entry, reason));
      if (!mounted) return;
      if (failed != null) {
        _toast(failed.message, AppTheme.expense);
        if (failed.failure != EntryDecisionFailure.unauthorized) _load();
        return;
      }
      _toast('[${e.title}] 정정이 반려되었습니다.', AppTheme.expense);
      _load();
      return;
    }

    // 목업 건 — 서버 없이 화면에서만 바꾼다.
    _replace(e, e.copyWith(status: '반려'));
    _toast('[${e.title}] 정정이 반려되었습니다.', AppTheme.expense);
  }

  String _signed(int v) => v >= 0 ? '+${Fmt.won(v)}' : Fmt.won(v);

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: '$k: ', style: const TextStyle(color: AppTheme.textSub, fontSize: 13)),
            TextSpan(text: v, style: const TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w600, fontSize: 13)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (!widget.allowed) return const _NoAccess();
    final waiting = _items.where((e) => e.status == '대기' || e.status == '재분류 진행 중').length;
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: Column(
          children: [
            const Text('정정 승인', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 16)),
            Text('대기 $waiting건', style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
        backgroundColor: const Color(0xFF8B5CF6),
        foregroundColor: Colors.white,
        centerTitle: true,
        actions: [
          if (_fromServer)
            IconButton(
              tooltip: '새로고침',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_items.isEmpty && _loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 40, color: AppTheme.textSub),
              const SizedBox(height: 12),
              Text(_loadError!,
                key: const Key('corrections_failed'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, height: 1.4, color: AppTheme.textMain),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('다시 시도'),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty && _loading) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return const Center(
        child: Text('정정 건이 없어요', key: Key('corrections_empty'), style: TextStyle(color: AppTheme.textSub, fontSize: 15)),
      );
    }
    final list = ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) => _card(_items[i]),
    );
    if (_loadError == null) return list;
    // 목록은 있는데 새로 읽지 못했다 — 보이는 상태가 최신이 아닐 수 있다
    return Column(
      children: [
        Material(
          color: const Color(0xFFFFF3E0),
          child: InkWell(
            onTap: _load,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.sync_problem_rounded, size: 16, color: Colors.orange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('$_loadError 보이는 상태가 최신이 아닐 수 있어요. 눌러서 다시 읽기',
                      style: const TextStyle(fontSize: 11, height: 1.3, color: Color(0xFF7C4700)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: list),
      ],
    );
  }

  Widget _card(CorrectionItem e) {
    final own = widget.effectiveUserId != null && e.createdBy == widget.effectiveUserId;
    final done = e.status == '확정' || e.status == '반려';
    final statusColor = switch (e.status) {
      '확정' => AppTheme.success,
      '반려' => AppTheme.expense,
      '재분류 진행 중' => AppTheme.info,
      _ => AppTheme.pending,
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: AppTheme.softShadow),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: statusColor.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
                child: Text(e.status, style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${e.reason.label} · ${e.category}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSub), overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(e.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppTheme.textMain)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppTheme.bgPage, borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                _amountCol('원본', e.original == null ? '—' : Fmt.won(e.original!), AppTheme.textMain),
                _amountCol('증감분', _signed(e.delta), e.delta >= 0 ? AppTheme.income : AppTheme.expense),
                _amountCol('정정 후', e.finalAmount == null ? '—' : Fmt.won(e.finalAmount!), AppTheme.primary),
              ],
            ),
          ),
          if (e.note != null) ...[
            const SizedBox(height: 8),
            Text('정정 내용 · ${e.note}', style: const TextStyle(fontSize: 12, height: 1.4, color: AppTheme.textSub)),
          ],
          if (e.pairNote != null) ...[
            const SizedBox(height: 8),
            Text('재분류 · ${e.pairNote}', style: const TextStyle(fontSize: 12, height: 1.4, color: AppTheme.info)),
          ],
          if (e.awaitsPlusFirst && !done) ...[
            const SizedBox(height: 8),
            const Text('증액(+) 건을 먼저 확정해야 이 감액(−) 건을 확정할 수 있어요',
                style: TextStyle(fontSize: 12, height: 1.4, color: AppTheme.expense)),
          ],
          if (e.insufficient && !done) ...[
            const SizedBox(height: 8),
            Text('${e.category} 잔량(${Fmt.won(e.budgetRemaining!)}) 부족 — 승인해도 대기로 남아요',
              style: const TextStyle(fontSize: 12, height: 1.4, color: AppTheme.expense)),
          ],
          const SizedBox(height: 12),
          if (done)
            const SizedBox.shrink()
          else if (own)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: const Color(0xFFE5E7EB), borderRadius: BorderRadius.circular(10)),
              child: const Text('본인이 등록한 건은 승인·반려할 수 없어요', style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _reject(e),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.expense,
                      side: const BorderSide(color: AppTheme.expense),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('반려'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: GradientButton(
                    onPressed: () => _approve(e),
                    label: '승인',
                    icon: Icons.fingerprint_rounded,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _amountCol(String label, String value, Color color) => Expanded(
        child: Column(
          children: [
            Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSub)),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
            ),
          ],
        ),
      );
}

/// 정정 승인 권한이 없는 사람이 들어왔을 때.
class _NoAccess extends StatelessWidget {
  const _NoAccess();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: const Text('정정 승인', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: const Color(0xFF8B5CF6),
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_rounded, size: 40, color: AppTheme.textSub),
              SizedBox(height: 12),
              Text('이 작업을 할 권한이 없습니다.',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.textMain)),
              SizedBox(height: 6),
              Text('정정 승인·반려는 감사·회장만 할 수 있어요.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSub), textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
