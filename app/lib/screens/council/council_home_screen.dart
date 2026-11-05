import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/enums.dart';
import '../../core/app_theme.dart';
import '../../core/dev_flags.dart';
import '../../core/format.dart';
import '../../core/logout_action.dart';
import '../../models/balance_model.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../../services/notification_service.dart';
import 'notification_inbox_screen.dart';
import 'expense_create_screen.dart';
import 'income_create_screen.dart';
import 'approval_list_screen.dart';
import 'budget_revision_screen.dart';
import 'correction_approval_screen.dart';
import 'correction_screen.dart';
import 'my_entries_screen.dart';
import 'inquiry_response_screen.dart';
import 'hardware_test_screen.dart';
import '../president/budget_plan_screen.dart';

/// [이승호 담당: app/lib/screens/council/]
/// 역할별 홈 (스토리보드 0).
///
/// 기록을 만드는 사람(총무)과 확정하는 사람(감사·회장)을 화면에서 가른다.
/// - 총무: 지출·수입 등록, 내 등록 현황, 정정 등록, 예산 개정 요청. **승인·이의 답변은 두지 않는다.**
/// - 감사: 승인 대기, 정정 승인, 이의 답변, 예산 개정 승인, 결산, QR 스캐너.
/// - 회장: 승인 대기, 정정 승인, 이의 답변, 예산 개정 서명, 예산 편성·발행, 결산, QR 스캐너. 등록 메뉴는 둘 다 두지 않는다.
class CouncilHomeScreen extends StatefulWidget {
  final UserRole role;
  const CouncilHomeScreen({super.key, this.role = UserRole.TREASURER});

  @override
  State<CouncilHomeScreen> createState() => _CouncilHomeScreenState();
}

/// 홈이 상태를 갖는 이유 — **승인 대기 건수는 계속 바뀐다.**
///
/// 총무가 지출을 등록하면 늘고, 다른 감사가 먼저 승인하면 줄어든다. 고정값을 두면
/// 0건이어도 몇 건이 있다고 말한다. 서버 건수를 읽고, 화면에서 돌아올 때와
/// 새로고침을 누를 때 다시 읽는다.
class _CouncilHomeScreenState extends State<CouncilHomeScreen> with WidgetsBindingObserver {
  /// 화면에 적용되는 역할. **로그인했으면 세션 역할만 믿는다** — 인자로 다른 역할을 주장해
  /// 메뉴를 바꿀 수 없다. 인자는 로그인 없이 화면을 그리는 위젯 테스트용이다.
  UserRole get role => AuthService().session?.role ?? widget.role;

  /// 장부 잔액. **고정 숫자를 두지 않는다** — 서버에서 읽고, 못 읽으면 [_balanceError] 를 적는다
  /// (PRD v0.14 §7.3). 둘 다 null 이면 「확인 중」이다.
  BalanceModel? _balance;
  String? _balanceError;

  /// 승인 대기 건수. **null 은 0 이 아니라 「모름」이다** ([ApiService.fetchPendingCount]).
  int? _pendingCount;
  bool _loading = true;

  /// 안 읽은 알림 수. null 은 「모름」이다 ([NotificationService.unreadCount]).
  int? _unread;

  /// 홈이 열려 있는 동안 15초마다 다시 읽는다 (PRD v0.14 §4.8 · §4.9).
  Timer? _poll;

  /// 읽기가 겹치면 **마지막에 보낸 것**만 반영한다. 15초 폴링·새로고침·앱 복귀·화면 복귀가
  /// 겹치면 먼저 보낸 요청이 늦게 도착해 새 숫자를 옛 숫자로 덮을 수 있다.
  int _pendingSeq = 0;
  int _unreadSeq = 0;
  int _balanceSeq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshAll();
    _poll = Timer.periodic(NotificationService.pollInterval, (_) => _refreshAll(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 앱으로 돌아오면 다시 읽는다.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshAll(silent: true);
  }

  /// 승인 대기 건수와 안 읽은 알림 수를 함께 다시 읽는다.
  /// [silent] 면 배지를 「확인 중」으로 바꾸지 않는다 — 15초마다 배지가 깜빡이지 않게.
  Future<void> _refreshAll({bool silent = false}) =>
      Future.wait([_load(silent: silent), _loadUnread(), _loadBalance()]);

  Future<void> _loadBalance() async {
    final seq = ++_balanceSeq;
    BalanceModel? balance;
    String? error;
    try {
      balance = await ApiService().fetchBalance();
    } on ApiUnavailable catch (e) {
      // 못 읽었으면 지난 숫자도 지운다 — 언제 값인지 모르는 잔액을 지금 잔액처럼 두지 않는다.
      error = e.message;
    }
    if (!mounted || seq != _balanceSeq) return; // 더 나중에 보낸 읽기가 있다
    setState(() {
      _balance = balance;
      _balanceError = error;
    });
  }

  Future<void> _load({bool silent = false}) async {
    // 총무 홈에는 승인 대기 배너가 없다. 안 보여 줄 숫자를 세려고 15초마다
    // 내역 전체(GET /entries)를 받지 않는다. 새로고침이 「읽는 중」에 묶이지 않게 끈다.
    if (!_isApprover) {
      if (_loading && mounted) setState(() => _loading = false);
      return;
    }
    final seq = ++_pendingSeq;
    if (!silent && mounted) setState(() => _loading = true);
    final count = await ApiService().fetchPendingCount();
    if (!mounted || seq != _pendingSeq) return; // 더 나중에 보낸 읽기가 있다
    setState(() {
      _pendingCount = count;
      _loading = false;
    });
  }

  Future<void> _loadUnread() async {
    final seq = ++_unreadSeq;
    final count = await NotificationService.unreadCount();
    if (mounted && seq == _unreadSeq) setState(() => _unread = count);
  }

  /// 다른 화면에 갔다 돌아오면 다시 읽는다 — 승인하고 왔는데 숫자가 그대로면
  /// 감사는 방금 처리한 건이 안 들어간 줄로 읽는다.
  Future<void> _openAndReload(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    if (mounted) await _refreshAll();
  }

  // 역할별 타이틀 및 설정
  String get _portalTitle {
    switch (role) {
      case UserRole.AUDITOR:
        return '학생회 감사 포털';
      case UserRole.PRESIDENT:
        return '학생회장 결재 포털';
      case UserRole.TREASURER:
      default:
        return '학생회 회계 포털';
    }
  }

  String get _roleSubtitle {
    switch (role) {
      case UserRole.AUDITOR:
        return '감사 전용 (온체인 결재 및 장부 무결성 검증)';
      case UserRole.PRESIDENT:
        return '학생회장 전용 (최종 승인 및 예산 총괄)';
      case UserRole.TREASURER:
      default:
        return '총무 전용 (등록 · 정정 · 예산 개정 요청)';
    }
  }

  String get _badgeText {
    switch (role) {
      case UserRole.AUDITOR:
        return '감사 모드';
      case UserRole.PRESIDENT:
        return '학생회장 모드';
      case UserRole.TREASURER:
      default:
        return '총무 모드';
    }
  }

  bool get _isApprover => role == UserRole.AUDITOR || role == UserRole.PRESIDENT;
  bool get _isPresident => role == UserRole.PRESIDENT;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      body: CustomScrollView(
        slivers: [
          // ── 그라디언트 AppBar ──────────────────────────────
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            backgroundColor: AppTheme.primary,
            foregroundColor: Colors.white,
            actions: [
              _NotificationBell(
                unread: _unread,
                onTap: () => _openAndReload(NotificationInboxScreen(role: role)),
              ),
              // 대기 건수는 다른 사람이 등록·승인하면 바뀐다. 갱신할 길이 없으면
              // 감사는 낡은 숫자를 보고 이미 처리된 건에 서명을 보내 409 를 맞는다.
              IconButton(
                key: const Key('council_refresh'),
                onPressed: _loading ? null : _refreshAll,
                icon: const Icon(Icons.refresh_rounded),
                tooltip: '새로고침',
              ),
              // 임원 세션이 기기에 남은 채 다음 사람이 앱을 켜면 등록·승인 화면까지 열린다.
              const LogoutAction(),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(gradient: AppTheme.headerGradient),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.verified_rounded, size: 14, color: Colors.white),
                                  const SizedBox(width: 4),
                                  Text(_badgeText, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _portalTitle,
                          style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: -0.5),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _roleSubtitle,
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // ── 본문 ───────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. 장부 잔액 카드
                  _BalanceCard(balance: _balance, error: _balanceError),
                  const SizedBox(height: 16),

                  // 2. 역할별 핵심 업무 최상단 강조 영역
                  if (_isApprover) ...[
                    // 감사/회장: 처리할 건수를 먼저 보여 준다
                    _ApprovalHighlightBanner(
                      pendingCount: _pendingCount,
                      loading: _loading,
                      onTap: () => _openAndReload(ApprovalListScreen(role: role)),
                    ),
                    const SizedBox(height: 12),
                    if (_isPresident) ...[
                      _SignRequestBanner(
                        count: budgetRevisionMockSignCount(),
                        onTap: () => _notice(context, Icons.construction_rounded, '예산 개정 서명 화면은 준비 중입니다.'),
                      ),
                      const SizedBox(height: 12),
                    ],
                    _UnansweredBanner(
                      count: inquiryMockUnansweredCount(),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const InquiryResponseScreen()),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ] else ...[
                    // 총무: 지출 & 수입 등록, 내 등록 건 상태
                    _TreasurerQuickActions(context: context),
                    const SizedBox(height: 12),
                    const _MyEntryStatus(),
                    const SizedBox(height: 20),
                  ],

                  // 3. 실기 검증 메뉴 — 개발용. 발표·배포 빌드에는 없다 (kDevTools)
                  if (kDevTools) ...[
                    _HardwareBanner(context: context),
                    const SizedBox(height: 24),
                  ],

                  // 4. 전체 업무 메뉴
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '전체 업무 목록',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textMain,
                          letterSpacing: -0.3,
                        ),
                      ),
                      Text(
                        _isApprover ? '승인·반려 권한' : '등록 권한',
                        style: TextStyle(fontSize: 12, color: AppTheme.primary, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 메뉴 그리드 (2열)
                  _buildMenuGrid(context),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<_MenuData> get _menus => _isApprover
      ? [
          _MenuData(
            title: '승인 대기',
            subtitle: '생체인증 서명으로 승인·반려',
            icon: Icons.fingerprint_rounded,
            badge: '핵심 결재',
            gradient: LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFFEC4899)]),
            target: ApprovalListScreen(role: role),
          ),
          _MenuData(
            title: '정정 승인',
            subtitle: '원본과 정정 증감분 대조',
            icon: Icons.rule_rounded,
            badge: '대조 후 서명',
            gradient: LinearGradient(colors: [Color(0xFFF59E0B), Color(0xFFEF4444)]),
            target: CorrectionApprovalScreen(role: role),
          ),
          _MenuData(
            title: '이의 답변',
            subtitle: '학생 이의 확인 및 답변',
            icon: Icons.question_answer_rounded,
            badge: '답변 작성',
            gradient: LinearGradient(colors: [Color(0xFF10B981), Color(0xFF06B6D4)]),
            target: InquiryResponseScreen(),
          ),
          if (_isPresident) ...[
            _MenuData(
              title: '예산 개정 서명',
              subtitle: '총무 증액 요청에 회장 요청 서명',
              icon: Icons.trending_up_rounded,
              badge: '준비 중',
              gradient: LinearGradient(colors: [Color(0xFF3B82F6), Color(0xFF6C63FF)]),
            ),
            // 회장에게만 보인다. 감사 계정에는 회색도 아니고 아예 없다 (스토리보드 15).
            // 회장 하단 내비게이션이 정해지면(중간발표 이후) 그쪽으로 옮긴다.
            _MenuData(
              title: '예산 편성·발행',
              subtitle: '학기 초 항목별 편성·발행, 마감 후 회수',
              icon: Icons.account_balance_wallet_rounded,
              badge: '회장 서명',
              gradient: LinearGradient(colors: [Color(0xFF14B8A6), Color(0xFF06B6D4)]),
              target: BudgetPlanScreen(role: role),
            ),
          ] else
            _MenuData(
              title: '예산 개정 승인',
              subtitle: '회장 요청 서명 후 감사 승인 서명',
              icon: Icons.trending_up_rounded,
              badge: '준비 중',
              gradient: LinearGradient(colors: [Color(0xFF3B82F6), Color(0xFF6C63FF)]),
            ),
          _MenuData(
            title: '결산',
            subtitle: '요약 카드·메타지표·PDF 내보내기',
            icon: Icons.assessment_rounded,
            badge: '준비 중',
            gradient: LinearGradient(colors: [Color(0xFFF59E0B), Color(0xFFFB923C)]),
          ),
          _MenuData(
            title: 'QR 스캐너',
            subtitle: '행사 입장 시 SBT 보유 확인',
            icon: Icons.qr_code_scanner_rounded,
            badge: '준비 중',
            gradient: LinearGradient(colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)]),
          ),
        ]
      : const [
          _MenuData(
            title: '지출 등록',
            subtitle: '영수증 촬영·첨부 및 지출 등록',
            icon: Icons.receipt_long_rounded,
            badge: '영수증 필수',
            gradient: LinearGradient(colors: [Color(0xFF6C63FF), Color(0xFF9B59D6)]),
            target: ExpenseCreateScreen(),
          ),
          _MenuData(
            title: '수입 등록',
            subtitle: '학생회비·지원금 입금 내역',
            icon: Icons.savings_rounded,
            badge: '예산 검사 없음',
            gradient: LinearGradient(colors: [Color(0xFF06B6D4), Color(0xFF0EA5E9)]),
            target: IncomeCreateScreen(),
          ),
          _MenuData(
            title: '내 등록 현황',
            subtitle: '초안·대기·확정·반려·차단',
            icon: Icons.list_alt_rounded,
            badge: '상태별 확인',
            gradient: LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFF6C63FF)]),
            target: MyEntriesScreen(),
          ),
          _MenuData(
            title: '정정 등록',
            subtitle: '확정 건의 증감분을 새로 기록',
            icon: Icons.edit_note_rounded,
            badge: '정정 요청',
            gradient: LinearGradient(colors: [Color(0xFFF59E0B), Color(0xFFEF4444)]),
            target: CorrectionScreen(),
          ),
          _MenuData(
            title: '예산 개정 요청',
            subtitle: '차단된 지출을 근거로 증액 요청',
            icon: Icons.trending_up_rounded,
            badge: '증액만 가능',
            gradient: LinearGradient(colors: [Color(0xFF3B82F6), Color(0xFF6C63FF)]),
            target: BudgetRevisionScreen(),
          ),
        ];

  void _notice(BuildContext context, IconData icon, String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
          ],
        ),
        backgroundColor: AppTheme.textMain,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildMenuGrid(BuildContext context) {
    final menus = _menus;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1.05,
      ),
      itemCount: menus.length,
      itemBuilder: (context, index) {
        final m = menus[index];
        return _MenuCard(
          data: m,
          onTap: () {
            final target = m.target;
            if (target == null) {
              _notice(context, Icons.construction_rounded, '${m.title} 화면은 준비 중입니다.');
            } else {
              Navigator.push(
                context,
                PageRouteBuilder(
                  pageBuilder: (_, a, __) => target,
                  transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
                  transitionDuration: const Duration(milliseconds: 300),
                ),
              ).then((_) {
                if (mounted) _refreshAll();
              });
            }
          },
        );
      },
    );
  }
}

// ── 감사/회장 전용 승인 대기 VIP 배너 ──────────────────────────
class _ApprovalHighlightBanner extends StatelessWidget {
  /// 승인 대기 건수. **null 은 「모름」이다** (조회 실패) — 0 건과 다르게 적는다.
  final int? pendingCount;

  /// 아직 읽는 중.
  final bool loading;
  final VoidCallback onTap;
  const _ApprovalHighlightBanner({required this.pendingCount, required this.loading, required this.onTap});

  /// 배지 문구. 네 상태를 **모두 다르게** 적는다 — 못 읽은 것을 「대기 없음」으로
  /// 적으면 승인을 기다리는 지출이 있는데도 감사가 할 일이 없다고 읽고 넘어간다.
  String get _badgeLabel {
    if (loading) return '확인 중';
    final count = pendingCount;
    if (count == null) return '확인 불가';
    if (count == 0) return '대기 없음';
    return '대기 $count건';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF8B5CF6), Color(0xFFEC4899)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF8B5CF6).withOpacity(0.35),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.star_rounded, size: 14, color: Colors.white),
                      SizedBox(width: 4),
                      Text('먼저 처리할 일', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _badgeLabel,
                    key: const Key('approval_pending_badge'),
                    style: const TextStyle(color: Color(0xFF8B5CF6), fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              '승인 대기',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 4),
            Text(
              '총무가 등록한 건을 검토하고 지문/Face ID 서명으로 승인·반려합니다.',
              style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.9), height: 1.4),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.fingerprint_rounded, color: Colors.white, size: 18),
                  SizedBox(width: 6),
                  Text('검토하러 가기', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  SizedBox(width: 4),
                  Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 알림 종 · 안 읽은 수 뱃지 ──────────────────────────────────
class _NotificationBell extends StatelessWidget {
  /// 안 읽은 수. null 은 「모름」 — 숫자를 지어내지 않고 뱃지를 달지 않는다.
  final int? unread;
  final VoidCallback onTap;
  const _NotificationBell({required this.unread, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final n = unread;
    return IconButton(
      key: const Key('notification_bell'),
      onPressed: onTap,
      tooltip: n == null ? '알림 (안 읽은 수를 확인하지 못했어요)' : '알림 · 안 읽음 $n건',
      icon: Badge(
        key: const Key('notification_unread_badge'),
        isLabelVisible: n != null && n > 0,
        label: Text(n != null && n > 99 ? '99+' : '${n ?? 0}'),
        child: const Icon(Icons.notifications_rounded),
      ),
    );
  }
}

// ── 감사/회장: 미답변 이의 건수 ─────────────────────────────────
class _UnansweredBanner extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _UnansweredBanner({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: count > 0 ? AppTheme.expense.withOpacity(0.35) : AppTheme.divider),
          boxShadow: AppTheme.softShadow,
        ),
        child: Row(
          children: [
            Icon(Icons.mark_unread_chat_alt_rounded, color: count > 0 ? AppTheme.expense : AppTheme.textSub, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                count > 0 ? '미답변 이의 $count건' : '미답변 이의가 없습니다',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.textMain),
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppTheme.textSub),
          ],
        ),
      ),
    );
  }
}

/// 회장 홈 배너용 예시 — 총무가 올린 증액 요청 중 회장 서명 대기 건수.
int budgetRevisionMockSignCount() => 1;

// ── 회장: 서명할 증액 요청 건수 ─────────────────────────────────
class _SignRequestBanner extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _SignRequestBanner({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: count > 0 ? AppTheme.primary.withOpacity(0.35) : AppTheme.divider),
          boxShadow: AppTheme.softShadow,
        ),
        child: Row(
          children: [
            Icon(Icons.draw_rounded, color: count > 0 ? AppTheme.primary : AppTheme.textSub, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                count > 0 ? '서명할 증액 요청 $count건' : '서명할 증액 요청이 없습니다',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.textMain),
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppTheme.textSub),
          ],
        ),
      ),
    );
  }
}

// ── 총무: 내 등록 건 상태 (대기 · 반려 · 차단) ─────────────────────
class _MyEntryStatus extends StatefulWidget {
  const _MyEntryStatus();

  @override
  State<_MyEntryStatus> createState() => _MyEntryStatusState();
}

class _MyEntryStatusState extends State<_MyEntryStatus> {
  int? _pending, _rejected, _blocked;

  /// 내역을 못 읽은 이유. 건수를 「-」로 두고 이유를 적는다 — 0 건으로 내리지 않는다.
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries = await ApiService().fetchEntries();
      if (!mounted) return;
      int count(EntryStatus st) => entries.where((e) => e.status == st).length;
      setState(() {
        _error = null;
        _pending = count(EntryStatus.PENDING);
        _rejected = count(EntryStatus.REJECTED);
        _blocked = count(EntryStatus.BLOCKED);
      });
    } on ApiUnavailable catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, int? n, Color color) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
          child: Text('$label ${n ?? '-'}', style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold)),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppTheme.softShadow,
      ),
      // Wrap: 좁은 화면·큰 글자에서 칩이 다음 줄로 내려간다
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          const Text('내 등록 건', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppTheme.textMain)),
          chip('대기', _pending, AppTheme.pending),
          chip('반려', _rejected, AppTheme.expense),
          chip('차단', _blocked, AppTheme.textSub),
          if (_error != null)
            Text(_error!,
                key: const Key('my_entry_status_failed'),
                style: const TextStyle(fontSize: 12, color: AppTheme.expense)),
        ],
      ),
    );
  }
}

// ── 총무 전용 지출 & 수입 등록 퀵 액션 배너 ─────────────────
class _TreasurerQuickActions extends StatelessWidget {
  final BuildContext context;
  const _TreasurerQuickActions({required this.context});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: AppTheme.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.bolt_rounded, color: AppTheme.primary, size: 20),
              SizedBox(width: 6),
              Text(
                '총무 핵심 집행 업무',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppTheme.textMain),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              // 지출 등록 강조 카드
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ExpenseCreateScreen()),
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      gradient: AppTheme.primaryGradient,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.primary.withOpacity(0.25),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.receipt_long_rounded, color: Colors.white, size: 24),
                        SizedBox(height: 10),
                        Text('지출 등록', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                        SizedBox(height: 2),
                        Text('영수증 촬영·첨부', style: TextStyle(color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // 수입 등록 강조 카드
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const IncomeCreateScreen()),
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      gradient: AppTheme.incomeGradient,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.income.withOpacity(0.25),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.savings_rounded, color: Colors.white, size: 24),
                        SizedBox(height: 10),
                        Text('수입 등록', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                        SizedBox(height: 2),
                        Text('학생회비 수납 기록', style: TextStyle(color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 장부 잔액 카드. 서버 값([balance])만 보여 준다 — 못 읽었으면 [error] 를 적고 숫자를 비운다.
class _BalanceCard extends StatelessWidget {
  final BalanceModel? balance;
  final String? error;
  const _BalanceCard({required this.balance, required this.error});

  @override
  Widget build(BuildContext context) {
    final b = balance;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: AppTheme.gradientDecoration(AppTheme.primaryGradient),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('학생회비 장부 잔액',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Text(b == null ? (error == null ? '확인 중' : '-') : Fmt.won(b.balance),
            key: Key(b != null ? 'balance_amount' : (error == null ? 'balance_loading' : 'balance_unknown')),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
              letterSpacing: -1,
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 6),
            Text(error!,
              key: const Key('balance_failed'),
              style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.4),
            ),
          ],
          const SizedBox(height: 16),
          Container(height: 1, color: Colors.white.withOpacity(0.2)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _BalanceItem(label: '총 수입', value: b == null ? '-' : Fmt.won(b.income), isIncome: true)),
              Container(width: 1, height: 36, color: Colors.white.withOpacity(0.2)),
              Expanded(child: _BalanceItem(label: '총 지출', value: b == null ? '-' : Fmt.won(b.expense), isIncome: false)),
            ],
          ),
        ],
      ),
    );
  }
}

class _BalanceItem extends StatelessWidget {
  final String label, value;
  final bool isIncome;
  const _BalanceItem({required this.label, required this.value, required this.isIncome});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(isIncome ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
              size: 12,
              color: isIncome ? const Color(0xFF67E8F9) : const Color(0xFFFCA5A5),
            ),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(color: Colors.white60, fontSize: 11)),
          ],
        ),
        const SizedBox(height: 4),
        Text(value,
          style: TextStyle(
            color: isIncome ? const Color(0xFF67E8F9) : const Color(0xFFFCA5A5),
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      ],
    );
  }
}

class _HardwareBanner extends StatelessWidget {
  final BuildContext context;
  const _HardwareBanner({required this.context});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const HardwareTestScreen()),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.divider),
          boxShadow: AppTheme.softShadow,
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF8B5CF6), Color(0xFF6C63FF)],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.fingerprint_rounded, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('카메라 & 생체인증 테스트',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.textMain),
                  ),
                  SizedBox(height: 2),
                  // [개발 참고: image_picker · local_auth 실기기 검증]
                  Text('영수증 촬영 및 생체인증 실기기 검증',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.primaryLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppTheme.primary),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuData {
  final String title, subtitle, badge;
  final IconData icon;
  final LinearGradient gradient;

  /// 이동할 화면. null 이면 아직 만들지 않은 화면이다 (「준비 중」).
  final Widget? target;
  const _MenuData({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.badge,
    required this.gradient,
    this.target,
  });

  bool get isDimmed => target == null;
}

class _MenuCard extends StatelessWidget {
  final _MenuData data;
  final VoidCallback onTap;
  const _MenuCard({required this.data, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: data.isDimmed ? 0.65 : 1.0,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: AppTheme.softShadow,
            border: data.isDimmed ? Border.all(color: Colors.grey.withOpacity(0.3)) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: data.gradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(data.icon, color: Colors.white, size: 22),
              ),
              const Spacer(),
              Text(data.title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textMain,
                ),
              ),
              const SizedBox(height: 3),
              Text(data.subtitle,
                style: const TextStyle(fontSize: 11, color: AppTheme.textSub, height: 1.3),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: data.isDimmed
                      ? Colors.grey.withOpacity(0.15)
                      : data.gradient.colors.first.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(data.badge,
                  style: TextStyle(
                    fontSize: 10,
                    color: data.isDimmed ? Colors.grey[700] : data.gradient.colors.first,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
