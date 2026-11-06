import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/enums.dart';
import '../../core/app_theme.dart';
import '../../core/format.dart';
import '../../core/hashing.dart';
import '../../models/entry_model.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../../services/entry_decision_service.dart';
import '../../services/entry_registration_service.dart';
import '../../services/notification_service.dart';
import 'reason_dialog.dart';
import 'receipt_view_dialog.dart';
import 'sending_dialog.dart';

/// OCR 이 경고인가 — `MISMATCH`·`DUPLICATE`·`UNREADABLE` 만 경고다 (PRD §6).
///
/// `MATCH`·`NO_NUMBER`(승인번호가 없는 계좌이체 등)와 OCR 을 돌리지 않은 건(null — 영수증 없는 수입)은
/// 정상이다. 서버도 같은 기준이라, null 을 경고로 보고 사유를 보내면 400 이 돌아온다.
bool _ocrIsWarning(OcrStatus? s) =>
    s == OcrStatus.MISMATCH || s == OcrStatus.DUPLICATE || s == OcrStatus.UNREADABLE;

/// 경고가 있는 항목인가 — OCR 이 경고이거나 카테고리 경고가 있으면 경고다.
/// 경고를 무시하고 승인하려면 사유가 필수다 (`hadWarning` + `warningReasonHash`).
/// OCR 불일치·중복뿐 아니라 카테고리 경고(`category_warning`)도 경고다 —
/// 빼면 카테고리 경고 건이 사유 없이 승인된다.
bool _hasWarning(Map<String, dynamic> item) =>
    _ocrIsWarning(item['ocrStatus'] as OcrStatus?) || item['categoryWarning'] == true;

/// 경고 원인 문구. OCR·카테고리가 겹치면 둘 다 적는다.
String _warningLabel(Map<String, dynamic> item) {
  final parts = <String>[
    if (item['ocrStatus'] == OcrStatus.DUPLICATE && item['duplicateOf'] != null)
      '영수증 중복(기존 #${item['duplicateOf']})'
    else if (_ocrIsWarning(item['ocrStatus'] as OcrStatus?))
      'OCR ${(item['ocrStatus'] as OcrStatus).label}',
    if (item['categoryWarning'] == true) '카테고리 경고',
  ];
  return parts.join('·');
}

/// **목업** 승인 대상 목록 — 위젯 테스트·화면 캡처에서 [ApprovalListScreen.items] 로 넣는다.
/// 앱은 빌드와 상관없이 서버(`GET /entries`)를 읽는다 ([approvalItemFromEntry]).
List<Map<String, dynamic>> buildApprovalMockItems() => [
    {
      'id': 2,
      'createdBy': 2,
      'title': '청년피자 개강총회 다과 주문',
      'merchant': '청년피자',
      'amount': 120000,
      'category': '행사비',
      'date': '2026-09-10 18:30',
      'status': EntryStatus.PENDING,
      'ocrStatus': OcrStatus.MATCH,
      'receiptInfo': '신용카드 매출전표 (승인번호: 83921049)',
    },
    {
      'id': 4,
      'title': '학생회 간담회 음료 구매',
      'merchant': '스타벅스',
      'amount': 45000,
      'category': '운영비',
      'date': '2026-09-12 14:10',
      'status': EntryStatus.PENDING,
      'ocrStatus': OcrStatus.MATCH,
      'receiptInfo': '전자영수증 스캔본 (승인번호: 10492811)',
      // 목업: 등록 땐 잔량이 있었지만 다른 건이 먼저 확정돼 확정이 revert 되는 경우.
      // 서버 연동 후에는 확정 응답의 fail_reason 이 이 자리를 대신한다.
      'mockFailReason': 'InsufficientBudget',
    },
    {
      'id': 6,
      'title': '동아리 연합 행사 현수막 제작',
      'merchant': '한빛인쇄',
      'amount': 85000,
      'category': '행사비',
      'date': '2026-09-13 10:40',
      'status': EntryStatus.PENDING,
      'ocrStatus': OcrStatus.MISMATCH, // 경고 → 승인 시 사유 필수
      'receiptInfo': '카드 매출전표 (OCR 금액 80,000원)',
    },
    {
      'id': 7,
      'title': '학과 MT 레크리에이션 소품',
      'merchant': '다이소',
      'amount': 22000,
      'category': '운영비',
      'date': '2026-09-14 11:20',
      'status': EntryStatus.PENDING,
      'ocrStatus': OcrStatus.MATCH,
      'categoryWarning': true, // OCR 은 일치해도 카테고리 경고면 사유 필수
      'receiptInfo': '카드 매출전표 (승인번호: 55021877)',
    },
    {
      'id': 8,
      'title': '신입생 환영회 문구류 구매',
      'merchant': '한결문구',
      'amount': 35000,
      'category': '행사비',
      'date': '2026-09-15 09:50',
      'status': EntryStatus.PENDING,
      // 이미 확정된 #1 과 승인번호·결제일·금액이 같다 → 막지 않고 경고로 올라온다 (PRD §6)
      'ocrStatus': OcrStatus.DUPLICATE,
      'duplicateOf': 1,
      'receiptInfo': '카드 매출전표 (승인번호: 12345678 · 내역 #1 과 같음)',
    },
    {
      // 감사 이감사(3)가 총무이던 때 등록한 수입 건 — 3번 계정이 로그인하면 이 건은 승인·반려할 수 없다.
      'id': 9,
      'title': '학교 지원금',
      'merchant': '학생처',
      'amount': 2000000,
      'category': '지원금',
      'date': '2026-09-16 10:00',
      'status': EntryStatus.PENDING,
      'ocrStatus': OcrStatus.MATCH,
      'createdBy': 3,
      'receiptInfo': '수입 건 — 영수증 없음',
    },
    {
      'id': 1,
      'title': '한결문구 신입생 환영회 물품 구매',
      'merchant': '한결문구',
      'amount': 35000,
      'category': '행사비',
      'date': '2026-09-08 11:20',
      'status': EntryStatus.CONFIRMED,
      'ocrStatus': OcrStatus.MATCH,
      'receiptInfo': '간이과세 세금계산서',
    },
    ];

/// 서버 내역(`GET /entries`) 한 건을 승인 카드 재료로 바꾼다. 원본은 `'entry'` 에 그대로 둔다 —
/// 반려 서명은 이 원본 값으로 만든다 ([EntryDecisionService.reject]).
///
/// [categories] 는 예산 id → 이름 (`GET /budgets`). 못 읽었으면 `예산 #id` 로 적는다.
Map<String, dynamic> approvalItemFromEntry(EntryModel e, {Map<int, String> categories = const {}}) => {
      'id': e.id,
      'createdBy': e.createdBy,
      'title': e.purpose,
      'merchant': e.counterparty,
      'amount': e.amount,
      'category': e.kind == EntryKind.INCOME
          ? '수입'
          : e.budgetId == null
              ? '예산 미배정'
              : categories[e.budgetId] ?? '예산 #${e.budgetId}',
      'date': Fmt.date(e.occurredAt),
      'status': e.status,
      'ocrStatus': e.ocrStatus,
      'categoryWarning': e.categoryWarning,
      'receiptInfo': e.receiptHash == null ? '영수증 없음' : '영수증 첨부 (${Fmt.shortHash(e.receiptHash!)})',
      if (e.rejectReason != null) 'rejectReason': e.rejectReason,
      if (e.warningAckReason != null) 'warningAckReason': e.warningAckReason,
      'entry': e,
    };

/// 승인 화면에 보이는 상태 (탭 셋). `BLOCKED` 는 승인 대상이 아니다.
const _shownStatuses = {EntryStatus.PENDING, EntryStatus.CONFIRMED, EntryStatus.REJECTED};

/// 로그인한 사람이 이 건의 등록자인가. 등록자는 자기 건을 승인·반려할 수 없다 —
/// 컨트랙트가 `SelfApproval` 로 되돌리지만 화면이 먼저 막는다 (스토리보드 12-E).
bool isOwnEntry(Map<String, dynamic> item, int? currentUserId) =>
    currentUserId != null && item['createdBy'] == currentUserId;

/// 홈 화면 배너에 쓰는 승인 대기 건수.
int approvalMockPendingCount() =>
    buildApprovalMockItems().where((e) => e['status'] == EntryStatus.PENDING).length;

/// [이승호 담당: app/lib/screens/council/]
/// 3. 승인 대기 목록 화면 (감사 / 회장)
///
/// 감사·회장만 열 수 있다. 로그인하지 않았거나 총무·학생이면 [_NoAccess] 를 보여 준다 (홈에서 메뉴를 숨기는 것과 별개로,
/// 경로로 직접 들어와도 막는다). **로그인했으면 세션([AuthService.session])의 역할·id 만 믿는다** — [role]·[currentUserId]
/// 인자로 다른 역할을 주장할 수 없다. 인자는 로그인 없이 화면을 그리는 위젯 테스트용이다.
class ApprovalListScreen extends StatefulWidget {
  final UserRole? role;
  final int? currentUserId;

  /// 목록 재료 (위젯 테스트·화면 캡처용 — [buildApprovalMockItems]). 주지 않으면 서버(`GET /entries`)에서 읽는다.
  final List<Map<String, dynamic>>? items;

  /// 반려 서명·전송. 테스트에서 가짜 본인 확인을 넣는다.
  final EntryDecisionService? decisions;

  /// 영수증 원본을 받아 오는 입구 (`GET /receipts/{파일}`). 테스트에서 가짜를 넣는다.
  final EntryRegistrar? registrar;

  const ApprovalListScreen({super.key, this.role, this.currentUserId, this.items, this.decisions, this.registrar});

  /// 화면에 적용되는 역할. 로그인했으면 세션 역할이고, 인자는 세션이 없을 때만 쓴다.
  UserRole? get effectiveRole => AuthService().session?.role ?? role;

  /// 화면에 적용되는 사용자 id. 본인 등록 건 판정에 쓴다. 역할과 같은 규칙이다.
  int? get effectiveUserId => AuthService().session?.userId ?? currentUserId;

  bool get allowed => effectiveRole == UserRole.AUDITOR || effectiveRole == UserRole.PRESIDENT;

  @override
  State<ApprovalListScreen> createState() => _ApprovalListScreenState();
}

class _ApprovalListScreenState extends State<ApprovalListScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;

  /// 서버 목록은 열려 있는 동안 15초마다 다시 읽는다 (보드 ② — 다른 임원의 처리가 화면에 늦게 보이지 않게).
  Timer? _poll;

  /// 서버에서 읽는가 — 목록 재료를 받지 않았으면 언제나 그렇다. **개발 빌드(DEV_TOOLS)도 서버를 읽는다** —
  /// Hardhat 키를 넣을 수 있는 빌드가 그것뿐이라, 여기서 목업을 띄우면 통합 시험에서 실서버 승인을 할 수 없다.
  /// 서버를 못 읽을 때의 시연용 더미는 [ApiService] 가 조회에서만 준다.
  late final bool _fromServer = widget.items == null;

  late List<Map<String, dynamic>> _items = widget.items ?? [];

  late final EntryDecisionService _decisions = widget.decisions ?? EntryDecisionService();

  late final EntryRegistrar _registrar = widget.registrar ?? EntryRegistrationService();

  /// 서버 목록을 읽는 중인가 / 마지막 읽기가 실패한 이유.
  late bool _loading = _fromServer;
  String? _loadError;

  /// 겹친 읽기 중 마지막 응답만 반영한다 (홈의 승인 대기 건수와 같은 방식).
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    if (_fromServer && widget.allowed) {
      _load(initial: true);
      _poll = Timer.periodic(NotificationService.pollInterval, (_) => _load(silent: true));
      WidgetsBinding.instance.addObserver(this);
    }
  }

  /// 앱으로 돌아오면 다시 읽는다 — 백그라운드에 있던 동안의 처리는 화면에 없다.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _fromServer) _load(silent: true);
  }

  /// 서버에서 목록을 다시 읽는다. 실패하면 목록을 비우지 않고 실패를 적는다 — 보이는 상태가
  /// 최신이 아닐 수 있다는 것을 화면이 알린다. 목업으로 메우지 않는다.
  /// [silent] 면 「읽는 중」으로 바꾸지 않는다 — 15초마다 새로고침 버튼이 깜빡이지 않게.
  Future<void> _load({bool initial = false, bool silent = false}) async {
    final seq = ++_loadSeq;
    if (!initial && !silent) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    // 예산 이름은 없어도 목록은 보여 줄 수 있다 — 못 읽으면 `예산 #id` 로 적는다.
    final categories = ApiService()
        .fetchBudgets()
        .then((budgets) => {for (final b in budgets) b.id: b.category})
        .catchError((Object _) => <int, String>{});
    try {
      final entries = await ApiService().fetchEntries();
      final names = await categories;
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _items = [
          for (final e in entries)
            if (_shownStatuses.contains(e.status)) approvalItemFromEntry(e, categories: names),
        ];
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

  void _snack(String text, Color color) {
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

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    super.dispose();
  }

  /// 영수증 원본 — 서버 건은 파일을 받아 기록된 해시와 맞춰 보이고, 해시가 다르면 파일을 보여 주지 않는다.
  void _showReceiptDialog(Map<String, dynamic> item) {
    showDialog<void>(
      context: context,
      builder: (_) => ReceiptViewDialog(item: item, registrar: _registrar),
    );
  }

  /// 승인 진입점. 경고가 있으면 사유를 먼저 받는다 (빈 값은 서버가 400).
  Future<void> _onApprove(Map<String, dynamic> item) async {
    String? warningReason;
    if (_hasWarning(item)) {
      warningReason = await showReasonDialog(
        context,
        title: '경고 무시 승인 사유',
        description: '${_warningLabel(item)} — 등록 내용에 확인이 필요한 항목이 있습니다. '
            '그래도 승인하려면 사유를 남겨 주세요.',
        confirmLabel: '다음',
        accent: AppTheme.pending,
        icon: Icons.warning_amber_rounded,
      );
      if (warningReason == null || !mounted) return;
    }
    _onApproveWithBiometric(item, warningReason);
  }

  void _onApproveWithBiometric(Map<String, dynamic> item, String? warningReason) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 지문 아이콘 애니메이션
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF8B5CF6), Color(0xFF6C63FF)],
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.primary.withOpacity(0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: const Icon(Icons.fingerprint_rounded, color: Colors.white, size: 44),
              ),
              const SizedBox(height: 16),
              const Text('집행 최종 승인',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textMain),
              ),
              const SizedBox(height: 4),
              const Text('생체인증으로 블록체인 서명',
                style: TextStyle(fontSize: 13, color: AppTheme.textSub),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.bgPage,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailRow(icon: Icons.description_rounded, label: '대상', value: item['title']),
                    _DetailRow(icon: Icons.monetization_on_rounded, label: '금액', value: '${item['amount']}원 (${item['category']})'),
                    // 서명 대상 — 승인자가 무엇에 서명하는지 보고 서명한다 (entryCommit: 종류·날짜·예산·등록자)
                    _DetailRow(icon: Icons.event_rounded, label: '사용일', value: '${item['date']}'.split(' ').first),
                    // 서버 건은 이름이 응답에 없어 user id 로 적는다 (목업 건만 이름)
                    _DetailRow(
                      icon: Icons.person_rounded,
                      label: '등록자',
                      value: item['entry'] is EntryModel ? '사용자 #${item['createdBy']}' : '김총무',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFFFCC80)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_rounded, color: Colors.orange, size: 18),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '생체인증 완료 시 스마트 컨트랙트에 영구 기록됩니다.',
                        style: TextStyle(fontSize: 12, height: 1.4, color: Color(0xFF7C4700)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
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
                    flex: 3, // 취소 1 : 승인 3 — 1:1 이면 411dp 에서 '생체인증 승인' 버튼이 넘친다
                    child: GradientButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        final entry = item['entry'];
                        if (entry is EntryModel) {
                          _confirmOnServer(item, entry, warningReason);
                          return;
                        }
                        // 목업 건 — 서버 없이 화면에서만 바꾼다. 실패 경로는 mockFailReason 으로 흉내 낸다.
                        final failReason = item['mockFailReason'] as String?;
                        if (failReason != null) {
                          _showApprovalFailure(item, failReason);
                          return;
                        }
                        setState(() {
                          item['status'] = EntryStatus.CONFIRMED;
                          if (warningReason != null) item['warningAckReason'] = warningReason;
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Row(
                              children: [
                                const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
                                const SizedBox(width: 10),
                                Expanded(child: Text('[${item['title']}] 승인 완료!')),
                              ],
                            ),
                            backgroundColor: AppTheme.success,
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            margin: const EdgeInsets.all(16),
                          ),
                        );
                      },
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
  }

  /// 확정 실패 안내. 항목은 `PENDING` 그대로다 (컨트랙트: 확정 실패 시 전체 revert).
  /// 예산 문제(`InsufficientBudget`·`BudgetExpired`)면 반려 흐름으로 넘긴다.
  ///
  /// 서버 건은 실패 코드(`fail_reason`, #65)로 나눈다 — 예산 사유일 때만 반려로 넘기고, 다른 코드면 다시 서명할 일이라
  /// 반려를 권하지 않는다. 코드가 없는 서버(#65 이전)면 [serverMessage](서버 설명)를 보여 주고 사람이 읽고 정한다
  /// — 어느 쪽이든 앱이 문구를 해석해 분기하지 않는다.
  Future<void> _showApprovalFailure(Map<String, dynamic> item, String? failReason, {String? serverMessage}) async {
    final budgetReason = failReason == null ? null : budgetFailReasons[failReason];
    final unknownCause = failReason == null && serverMessage != null;
    final offerReject = budgetReason != null || unknownCause;
    final goReject = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.expense.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.error_outline_rounded, color: AppTheme.expense, size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('승인에 실패했어요',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.textMain),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _DetailRow(icon: Icons.description_rounded, label: '대상', value: item['title']),
              _DetailRow(
                icon: Icons.report_gmailerrorred_rounded,
                label: '사유',
                value: budgetReason ?? serverMessage ?? '체인이 확정을 거부했어요 ($failReason)',
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.bgPage,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  budgetReason != null
                      ? '이 항목은 아직 승인 대기(PENDING) 상태예요. 등록할 때는 잔량이 있었지만 '
                          '다른 건이 먼저 확정되면서 예산이 부족해졌을 수 있어요. '
                          '확정할 수 없으므로 반려로 처리해 주세요.'
                      : unknownCause
                          ? '이 항목은 아직 승인 대기(PENDING) 상태예요. 위 사유가 예산 부족·집행 기간 지남처럼 '
                              '확정할 수 없는 이유라면 반려로 처리해 주세요.'
                          : '이 항목은 아직 승인 대기(PENDING) 상태예요. 잠시 뒤 다시 서명해 주세요.',
                  style: const TextStyle(fontSize: 12, height: 1.5, color: AppTheme.textMain),
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
                      child: const Text('나중에', style: TextStyle(color: AppTheme.textSub)),
                    ),
                  ),
                  if (offerReject) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: GradientButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        label: '반려로 처리',
                        gradient: const LinearGradient(colors: [AppTheme.expense, Color(0xFFFB7185)]),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (goReject == true && mounted) {
      await _onReject(
        item,
        initialReason: budgetReason != null ? '$budgetReason. 확정할 수 없어 반려합니다.' : '승인이 거부되어 확정할 수 없어 반려합니다.',
      );
    }
  }

  /// 반려 — 사유 필수. 빈 값이면 서버가 400 이므로 입력 단계에서 막는다.
  Future<void> _onReject(Map<String, dynamic> item, {String? initialReason}) async {
    final reason = await showReasonDialog(
      context,
      title: '반려 사유',
      description: '[${item['title']}] 을(를) 반려합니다. 반려하면 되돌릴 수 없어요.',
      confirmLabel: '반려하기',
      initialText: initialReason,
    );
    if (reason == null || !mounted) return;
    final entry = item['entry'];
    if (entry is EntryModel) {
      await _rejectOnServer(item, entry, reason);
      return;
    }
    // 목업 건 — 서버 없이 화면에서만 바꾼다
    setState(() {
      item['status'] = EntryStatus.REJECTED;
      item['rejectReason'] = reason;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('[${item['title']}] 반려 처리되었습니다.'),
        backgroundColor: AppTheme.expense,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  /// 서버 건 승인 — 기기 서명 → `POST /entries/{id}/confirm`.
  ///
  /// 체인·서버가 거부하면(400) 항목은 `PENDING` 그대로라 실패 안내에서 반려로 넘길 수 있다.
  /// 그 밖의 실패는 알리고 목록을 다시 읽는다 — 409·결과 모름이면 다른 임원의 처리가 반영됐을 수 있다.
  Future<void> _confirmOnServer(Map<String, dynamic> item, EntryModel entry, String? warningReason) async {
    final failed = await sendWithBlocking(
      context,
      '승인 서명을 보내는 중이에요…',
      () => _decisions.confirm(entry, warningReason: warningReason),
    );
    if (!mounted) return;

    if (failed != null) {
      if (failed.failure == EntryDecisionFailure.refused) {
        await _showApprovalFailure(item, failed.failReason, serverMessage: failed.message);
      } else {
        _snack(failed.message, AppTheme.expense);
      }
      // 401 이면 세션이 비워져 로그인 화면으로 간다 — 다시 읽을 것이 없다
      if (mounted && failed.failure != EntryDecisionFailure.unauthorized) _load();
      return;
    }
    setState(() {
      item['status'] = EntryStatus.CONFIRMED;
      if (warningReason != null) item['warningAckReason'] = Hashing.canonicalText(warningReason);
    });
    _snack('[${item['title']}] 승인 완료!', AppTheme.success);
    _load();
  }

  /// 서버 건 반려 — 기기 서명 → `POST /entries/{id}/reject`.
  ///
  /// 성공이든 실패든 끝나면 목록을 다시 읽는다. 실패 이유는 상태 코드로만 나뉘고(서버 문구로
  /// 분기하지 않는다), 409·결과 모름이면 다른 임원의 처리나 앞선 시도가 반영됐을 수 있어서다.
  Future<void> _rejectOnServer(Map<String, dynamic> item, EntryModel entry, String reason) async {
    final failed = await sendWithBlocking(context, '반려 서명을 보내는 중이에요…', () => _decisions.reject(entry, reason));
    if (!mounted) return;

    if (failed != null) {
      _snack(failed.message, AppTheme.expense);
      // 401 이면 세션이 비워져 로그인 화면으로 간다 — 다시 읽을 것이 없다
      if (failed.failure != EntryDecisionFailure.unauthorized) _load();
      return;
    }
    setState(() {
      item['status'] = EntryStatus.REJECTED;
      item['rejectReason'] = Hashing.canonicalText(reason);
    });
    _snack('[${item['title']}] 반려 처리되었습니다.', AppTheme.expense);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.allowed) return const _NoAccess();
    final pendingCount = _items.where((e) => e['status'] == EntryStatus.PENDING).length;

    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: Column(
          children: [
            const Text('승인 대기',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 16),
            ),
            Text('감사 · 회장 전용',
              style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 11),
            ),
          ],
        ),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF8B5CF6), Color(0xFFEC4899)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        actions: [
          if (_fromServer)
            IconButton(
              tooltip: '새로고침',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          indicatorColor: Colors.white,
          indicatorWeight: 3,
          dividerColor: Colors.white24,
          tabs: [
            Tab(
              child: Row(
                children: [
                  const Text('승인 대기'),
                  if (pendingCount > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('$pendingCount',
                        style: const TextStyle(color: Color(0xFF8B5CF6), fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Tab(text: '승인 완료'),
            const Tab(text: '반려됨'),
          ],
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_items.isEmpty && _loadError != null) {
      return _LoadFailed(message: _loadError!, onRetry: _load);
    }
    if (_items.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final tabs = TabBarView(
      controller: _tabController,
      children: [
        _buildListByStatus(EntryStatus.PENDING),
        _buildListByStatus(EntryStatus.CONFIRMED),
        _buildListByStatus(EntryStatus.REJECTED),
      ],
    );
    if (_loadError == null) return tabs;
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
        Expanded(child: tabs),
      ],
    );
  }

  Widget _buildListByStatus(EntryStatus status) {
    final filtered = _items.where((e) => e['status'] == status).toList();

    if (filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppTheme.primaryLight,
                shape: BoxShape.circle,
              ),
              child: Icon(
                status == EntryStatus.PENDING
                    ? Icons.hourglass_empty_rounded
                    : status == EntryStatus.CONFIRMED
                        ? Icons.check_circle_rounded
                        : Icons.cancel_rounded,
                color: AppTheme.primary,
                size: 36,
              ),
            ),
            const SizedBox(height: 16),
            Text('${status.label} 항목이 없습니다',
              style: const TextStyle(color: AppTheme.textSub, fontSize: 15),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: filtered.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final item = filtered[index];
        return _ApprovalCard(
          item: item,
          status: status,
          onReceipt: () => _showReceiptDialog(item),
          own: isOwnEntry(item, widget.effectiveUserId),
          onApprove: () => _onApprove(item),
          onReject: () => _onReject(item),
        );
      },
    );
  }
}

/// 승인 권한이 없는 사람이 승인 화면에 들어왔을 때 (서버의 403 과 같은 뜻).
class _NoAccess extends StatelessWidget {
  const _NoAccess();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: const Text('승인 대기', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
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
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.textMain),
              ),
              SizedBox(height: 6),
              Text('승인·반려는 감사·회장만 할 수 있어요.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSub),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 서버 목록을 처음부터 읽지 못했을 때. 목업으로 메우지 않는다 (PRD v0.14 §7.3).
class _LoadFailed extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _LoadFailed({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 40, color: AppTheme.textSub),
            const SizedBox(height: 12),
            Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, height: 1.4, color: AppTheme.textMain),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('다시 시도'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 누를 수 없는 회색 버튼 (본인 등록 건).
class _DisabledAction extends StatelessWidget {
  final String label;
  const _DisabledAction({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: const Color(0xFFE5E7EB), borderRadius: BorderRadius.circular(10)),
      child: Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final EntryStatus status;
  final bool own;
  final VoidCallback onReceipt, onApprove, onReject;

  const _ApprovalCard({
    required this.item,
    required this.status,
    this.own = false,
    required this.onReceipt,
    required this.onApprove,
    required this.onReject,
  });

  Color get _categoryColor {
    switch (item['category'] as String) {
      case '행사비': return AppTheme.primary;
      case '운영비': return AppTheme.income;
      default: return AppTheme.success;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppTheme.softShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                StatusBadge(label: item['category'], color: _categoryColor),
                const SizedBox(width: 8),
                // Flexible: 큰 글자·좁은 화면에서 날짜가 넘치지 않고 줄바꿈된다
                Flexible(
                  child: Text(item['date'],
                    textAlign: TextAlign.end,
                    style: const TextStyle(color: AppTheme.textSub, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(item['title'],
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textMain),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.storefront_rounded, size: 14, color: AppTheme.textSub),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(item['merchant'],
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppTheme.textSub, fontSize: 13),
                  ),
                ),
                const SizedBox(width: 12),
                const Icon(Icons.monetization_on_rounded, size: 14, color: AppTheme.textSub),
                const SizedBox(width: 4),
                Text('${item['amount']}원',
                  style: const TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ],
            ),
            if (status == EntryStatus.PENDING && _hasWarning(item)) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFFFCC80)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${_warningLabel(item)} — 승인하려면 경고 무시 사유가 필요해요',
                        style: const TextStyle(fontSize: 11, height: 1.3, color: Color(0xFF7C4700)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (status == EntryStatus.CONFIRMED && item['warningAckReason'] != null) ...[
              const SizedBox(height: 10),
              Text('경고 무시 사유: ${item['warningAckReason']}',
                style: const TextStyle(fontSize: 11, height: 1.4, color: AppTheme.textSub),
              ),
            ],
            if (status == EntryStatus.REJECTED && item['rejectReason'] != null) ...[
              const SizedBox(height: 10),
              Text('반려 사유: ${item['rejectReason']}',
                style: const TextStyle(fontSize: 11, height: 1.4, color: AppTheme.textSub),
              ),
            ],
            const SizedBox(height: 14),
            const Divider(color: AppTheme.divider, height: 1),
            const SizedBox(height: 12),

            if (status == EntryStatus.PENDING && own) ...[
              Text('등록자와 승인자가 같아 처리할 수 없어요',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.textSub),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onReceipt,
                      icon: const Icon(Icons.receipt_long_rounded, size: 15),
                      label: const Text('영수증', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.primary,
                        side: const BorderSide(color: AppTheme.divider),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(child: _DisabledAction(label: '반려')),
                  const SizedBox(width: 8),
                  const Expanded(flex: 2, child: _DisabledAction(label: '승인 서명')),
                ],
              ),
            ] else if (status == EntryStatus.PENDING)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onReceipt,
                      icon: const Icon(Icons.receipt_long_rounded, size: 15),
                      label: const Text('영수증', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.primary,
                        side: const BorderSide(color: AppTheme.divider),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onReject,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.expense,
                        side: const BorderSide(color: Color(0xFFFFCDD2)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      child: const Text('반려', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF8B5CF6), Color(0xFF6C63FF)],
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: onApprove,
                          borderRadius: BorderRadius.circular(10),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 10),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.fingerprint_rounded, color: Colors.white, size: 16),
                                SizedBox(width: 6),
                                Text('승인 서명', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              )
            else if (status == EntryStatus.CONFIRMED)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onReceipt,
                      icon: const Icon(Icons.receipt_long_rounded, size: 15),
                      label: const Text('영수증', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.primary,
                        side: const BorderSide(color: AppTheme.divider),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: AppTheme.success.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.link_rounded, size: 16, color: AppTheme.success),
                          SizedBox(width: 6),
                          Text('블록체인 등록 완료', style: TextStyle(color: AppTheme.success, fontWeight: FontWeight.bold, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ],
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.expense.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.cancel_rounded, size: 16, color: AppTheme.expense),
                    SizedBox(width: 6),
                    Text('반려 처리됨', style: TextStyle(color: AppTheme.expense, fontWeight: FontWeight.bold, fontSize: 12)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label, value;
  const _DetailRow({required this.icon, required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 15, color: AppTheme.primary),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(color: AppTheme.textSub, fontSize: 12)),
          Expanded(child: Text(value, style: const TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w600, fontSize: 12))),
        ],
      ),
    );
  }
}
