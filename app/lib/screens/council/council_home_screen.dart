import 'package:flutter/material.dart';
import '../../core/enums.dart';
import '../../core/app_theme.dart';
import 'expense_create_screen.dart';
import 'income_create_screen.dart';
import 'approval_list_screen.dart';
import 'correction_screen.dart';
import 'inquiry_response_screen.dart';
import 'hardware_test_screen.dart';

/// [이승호 담당: app/lib/screens/council/]
/// 총무·감사·회장 역할별 맞춤 메인 대시보드 화면
class CouncilHomeScreen extends StatelessWidget {
  final UserRole role;
  const CouncilHomeScreen({super.key, this.role = UserRole.TREASURER});

  // [개발 참고: API 및 패키지 연동]
  // 1. 지출 등록: image_picker (영수증 촬영/OCR) · POST /entries
  // 2. 수입 등록: POST /entries
  // 3. 승인 대기 목록: local_auth (생체인증 서명) · PUT /entries/:id/approve
  // 4. 장부 정정 신청: enums.md (정정 사유) · POST /corrections
  // 5. 학생 이의 답변: GET /inquiries · POST /inquiries/:id/answer

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
        return '총무 · 회계 전용 (장부 집행 및 수납 관리)';
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
        return '총무·회계 모드';
    }
  }

  bool get _isApprover => role == UserRole.AUDITOR || role == UserRole.PRESIDENT;

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
                  _BalanceCard(),
                  const SizedBox(height: 16),

                  // 2. 역할별 핵심 업무 최상단 강조 영역
                  if (_isApprover) ...[
                    // 감사/회장: 승인 대기 목록 VIP 하이라이트 배너
                    _ApprovalHighlightBanner(
                      roleName: role == UserRole.AUDITOR ? '감사' : '학생회장',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ApprovalListScreen()),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ] else ...[
                    // 총무/회계: 지출 & 수입 등록 퀵 액션 배너
                    _TreasurerQuickActions(context: context),
                    const SizedBox(height: 20),
                  ],

                  // 3. 하드웨어 테스트 배너
                  _HardwareBanner(context: context),
                  const SizedBox(height: 24),

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
                        _isApprover ? '결재 권한 활성화' : '집행 권한 활성화',
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

  Widget _buildMenuGrid(BuildContext context) {
    final menus = [
      _MenuData(
        title: '지출 등록',
        subtitle: '영수증 촬영·첨부 및 지출 신청',
        icon: Icons.receipt_long_rounded,
        badge: _isApprover ? '총무 전용 🔒' : '영수증 첨부',
        isLocked: _isApprover,
        gradient: const LinearGradient(colors: [Color(0xFF6C63FF), Color(0xFF9B59D6)]),
        target: const ExpenseCreateScreen(),
      ),
      _MenuData(
        title: '수입 등록',
        subtitle: '학생회비·학교지원금 수납 내역',
        icon: Icons.savings_rounded,
        badge: _isApprover ? '총무 전용 🔒' : '장부 기록',
        isLocked: _isApprover,
        gradient: const LinearGradient(colors: [Color(0xFF06B6D4), Color(0xFF0EA5E9)]),
        target: const IncomeCreateScreen(),
      ),
      _MenuData(
        title: '승인 대기 목록',
        subtitle: '생체인증 전자서명으로 최종 승인',
        icon: Icons.fingerprint_rounded,
        badge: _isApprover ? '⭐ 핵심 결재' : '진행 현황',
        isLocked: false,
        gradient: const LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFFEC4899)]),
        target: const ApprovalListScreen(),
      ),
      _MenuData(
        title: '장부 정정 신청',
        subtitle: '오기입·환불·재분류 정정 요청',
        icon: Icons.edit_note_rounded,
        badge: _isApprover ? '정정 검토' : '정정 요청',
        isLocked: false,
        gradient: const LinearGradient(colors: [Color(0xFFF59E0B), Color(0xFFEF4444)]),
        target: const CorrectionScreen(),
      ),
      _MenuData(
        title: '학생 이의 답변',
        subtitle: '지출 이의 확인 및 소명 작성',
        icon: Icons.question_answer_rounded,
        badge: _isApprover ? '소명 열람' : '소명 작성',
        isLocked: false,
        gradient: const LinearGradient(colors: [Color(0xFF10B981), Color(0xFF06B6D4)]),
        target: const InquiryResponseScreen(),
      ),
    ];

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
          number: index + 1,
          onTap: () {
            if (m.isLocked) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Row(
                    children: [
                      const Icon(Icons.lock_rounded, color: Colors.white, size: 18),
                      const SizedBox(width: 8),
                      Text('${m.title}은(는) 총무(TREASURER) 전용 권한입니다.'),
                    ],
                  ),
                  backgroundColor: AppTheme.textMain,
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  duration: const Duration(seconds: 2),
                ),
              );
            } else {
              Navigator.push(
                context,
                PageRouteBuilder(
                  pageBuilder: (_, a, __) => m.target,
                  transitionsBuilder: (_, a, __, child) =>
                    FadeTransition(opacity: a, child: child),
                  transitionDuration: const Duration(milliseconds: 300),
                ),
              );
            }
          },
        );
      },
    );
  }
}

// ── 감사/회장 전용 승인 대기 VIP 배너 ──────────────────────────
class _ApprovalHighlightBanner extends StatelessWidget {
  final String roleName;
  final VoidCallback onTap;
  const _ApprovalHighlightBanner({required this.roleName, required this.onTap});

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
                  child: Row(
                    children: [
                      const Icon(Icons.star_rounded, size: 14, color: Colors.white),
                      const SizedBox(width: 4),
                      Text('$roleName 최우선 결재 업무', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('대기 3건', style: TextStyle(color: Color(0xFF8B5CF6), fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              '3. 승인 대기 목록 (생체 서명)',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 4),
            Text(
              '총무가 등록한 지출·정정 건을 검토하고 지문/Face ID로 최종 승인합니다.',
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
                  Text('지금 결재 검토하기', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
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

// ── 총무/회계 전용 지출 & 수입 등록 퀵 액션 배너 ─────────────────
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
                        Text('1. 지출 등록', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
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
                        Text('2. 수입 등록', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
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

class _BalanceCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: AppTheme.gradientDecoration(AppTheme.primaryGradient),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('학생회비 장부 잔액',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              // [개발 참고: GET /balance 연동]
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.sync_rounded, size: 12, color: Colors.white),
                    SizedBox(width: 4),
                    Text('실시간 연동', style: TextStyle(color: Colors.white, fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('₩ 4,965,000',
            style: TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
              letterSpacing: -1,
            ),
          ),
          const SizedBox(height: 16),
          Container(height: 1, color: Colors.white.withOpacity(0.2)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _BalanceItem(label: '총 수입', value: '₩ 5,000,000', isIncome: true)),
              Container(width: 1, height: 36, color: Colors.white.withOpacity(0.2)),
              Expanded(child: _BalanceItem(label: '총 지출', value: '₩ 35,000', isIncome: false)),
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
  final bool isLocked;
  final LinearGradient gradient;
  final Widget target;
  const _MenuData({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.badge,
    required this.isLocked,
    required this.gradient,
    required this.target,
  });
}

class _MenuCard extends StatelessWidget {
  final _MenuData data;
  final int number;
  final VoidCallback onTap;
  const _MenuCard({required this.data, required this.number, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: data.isLocked ? 0.65 : 1.0,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: AppTheme.softShadow,
            border: data.isLocked ? Border.all(color: Colors.grey.withOpacity(0.3)) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
                  Text('$number',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: Colors.grey.withOpacity(0.15),
                      height: 1,
                    ),
                  ),
                ],
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
                  color: data.isLocked
                      ? Colors.grey.withOpacity(0.15)
                      : data.gradient.colors.first.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(data.badge,
                  style: TextStyle(
                    fontSize: 10,
                    color: data.isLocked ? Colors.grey[700] : data.gradient.colors.first,
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
