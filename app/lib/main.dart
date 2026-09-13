import 'package:flutter/material.dart';
import 'core/enums.dart';
import 'core/app_theme.dart';
import 'screens/student/student_home_screen.dart';
import 'screens/council/council_home_screen.dart';

void main() {
  runApp(const StudentCouncilApp());
}

class StudentCouncilApp extends StatelessWidget {
  const StudentCouncilApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '학생회 회계 투명성 시스템',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeData,
      home: const RoleLoginScreen(),
    );
  }
}

/// [로그인 화면]
/// - ID/PW 기반 로그인 인터페이스
/// - 하드코딩 계정 매핑:
///   - block1 / 1234 : 총무·회계 (UserRole.TREASURER)
///   - block2 / 1234 : 감사 (UserRole.AUDITOR)
///   - block3 / 1234 : 학생 (UserRole.STUDENT)
///   - block4 / 1234 : 학생회장 (UserRole.PRESIDENT)
class RoleLoginScreen extends StatefulWidget {
  const RoleLoginScreen({super.key});

  @override
  State<RoleLoginScreen> createState() => _RoleLoginScreenState();
}

class _RoleLoginScreenState extends State<RoleLoginScreen>
    with SingleTickerProviderStateMixin {
  final _idController = TextEditingController(text: 'block1');
  final _pwController = TextEditingController(text: '1234');
  bool _obscurePw = true;
  String? _errorMessage;

  late AnimationController _animController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  // 테스트 계정 목록
  final List<Map<String, dynamic>> _quickAccounts = [
    {'id': 'block1', 'name': '총무/회계', 'role': UserRole.TREASURER, 'color': AppTheme.primary, 'icon': Icons.account_balance_wallet_rounded},
    {'id': 'block2', 'name': '감사', 'role': UserRole.AUDITOR, 'color': AppTheme.pending, 'icon': Icons.fact_check_rounded},
    {'id': 'block4', 'name': '학생회장', 'role': UserRole.PRESIDENT, 'color': AppTheme.expense, 'icon': Icons.star_rounded},
    {'id': 'block3', 'name': '학생', 'role': UserRole.STUDENT, 'color': AppTheme.income, 'icon': Icons.school_rounded},
  ];

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnim = CurvedAnimation(parent: _animController, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero)
        .animate(CurvedAnimation(parent: _animController, curve: Curves.easeOut));
    _animController.forward();
  }

  @override
  void dispose() {
    _idController.dispose();
    _pwController.dispose();
    _animController.dispose();
    super.dispose();
  }

  // 현재 입력된 ID에 해당하는 역할 감지
  UserRole? _detectRole(String id) {
    final cleanId = id.trim().toLowerCase();
    switch (cleanId) {
      case 'block1':
        return UserRole.TREASURER;
      case 'block2':
        return UserRole.AUDITOR;
      case 'block3':
        return UserRole.STUDENT;
      case 'block4':
        return UserRole.PRESIDENT;
      default:
        return null;
    }
  }

  void _applyQuickAccount(Map<String, dynamic> acc) {
    setState(() {
      _idController.text = acc['id'] as String;
      _pwController.text = '1234';
      _errorMessage = null;
    });
  }

  void _handleLogin() {
    final id = _idController.text.trim();
    final pw = _pwController.text.trim();

    if (id.isEmpty) {
      setState(() => _errorMessage = '아이디를 입력해 주세요');
      return;
    }

    final role = _detectRole(id);
    if (role == null) {
      setState(() => _errorMessage = '등록되지 않은 계정입니다.\n(block1, block2, block3, block4 사용 가능)');
      return;
    }

    setState(() => _errorMessage = null);

    Widget targetScreen;
    if (role == UserRole.STUDENT) {
      targetScreen = const StudentHomeScreen();
    } else {
      targetScreen = CouncilHomeScreen(role: role);
    }

    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, a, __) => targetScreen,
        transitionsBuilder: (_, a, __, child) => FadeTransition(
          opacity: a,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.05, 0),
              end: Offset.zero,
            ).animate(a),
            child: child,
          ),
        ),
        transitionDuration: const Duration(milliseconds: 350),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentRole = _detectRole(_idController.text);
    final activeAcc = _quickAccounts.firstWhere(
      (a) => a['role'] == currentRole,
      orElse: () => _quickAccounts.first,
    );

    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      body: Stack(
        children: [
          // 상단 그라디언트 배경
          Positioned(
            top: 0, left: 0, right: 0,
            height: 300,
            child: Container(
              decoration: const BoxDecoration(
                gradient: AppTheme.headerGradient,
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(40)),
              ),
            ),
          ),

          SafeArea(
            child: FadeTransition(
              opacity: _fadeAnim,
              child: SlideTransition(
                position: _slideAnim,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      const SizedBox(height: 36),

                      // 헤더 타이틀
                      const Text(
                        '학생회 회계 관리',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '블록체인 기반 투명성 & 무결성 검증 시스템',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white.withOpacity(0.85),
                        ),
                      ),
                      const SizedBox(height: 28),

                      // 메인 로그인 카드
                      Container(
                        padding: const EdgeInsets.all(26),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.primary.withOpacity(0.15),
                              blurRadius: 30,
                              offset: const Offset(0, 12),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 역할 뱃지 & 안내
                            Center(
                              child: Column(
                                children: [
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 300),
                                    width: 64,
                                    height: 64,
                                    decoration: BoxDecoration(
                                      color: (activeAcc['color'] as Color).withOpacity(0.12),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      activeAcc['icon'] as IconData,
                                      size: 32,
                                      color: activeAcc['color'] as Color,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    currentRole != null ? '${currentRole.label} 로그인' : '통합 로그인',
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: AppTheme.textMain,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    currentRole != null
                                        ? '${activeAcc['name']} 권한으로 접속합니다'
                                        : '아이디와 비밀번호를 입력해 주세요',
                                    style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 24),

                            // 아이디 입력
                            const Text('아이디 (ID)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppTheme.textMain)),
                            const SizedBox(height: 6),
                            TextFormField(
                              controller: _idController,
                              onChanged: (_) => setState(() => _errorMessage = null),
                              decoration: AppTheme.inputDecoration(
                                label: '',
                                hint: '예: block1, block2, block3, block4',
                                icon: Icons.person_rounded,
                              ),
                            ),
                            const SizedBox(height: 14),

                            // 비밀번호 입력
                            const Text('비밀번호 (Password)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppTheme.textMain)),
                            const SizedBox(height: 6),
                            TextFormField(
                              controller: _pwController,
                              obscureText: _obscurePw,
                              decoration: InputDecoration(
                                hintText: '비밀번호 입력',
                                hintStyle: const TextStyle(color: AppTheme.textSub, fontSize: 14),
                                prefixIcon: const Icon(Icons.lock_rounded, color: AppTheme.primary, size: 20),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscurePw ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                                    color: AppTheme.textSub,
                                    size: 20,
                                  ),
                                  onPressed: () => setState(() => _obscurePw = !_obscurePw),
                                ),
                                filled: true,
                                fillColor: AppTheme.bgPage,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: const BorderSide(color: AppTheme.divider),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: const BorderSide(color: AppTheme.divider),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: const BorderSide(color: AppTheme.primary, width: 2),
                                ),
                              ),
                            ),

                            // 에러 메시지
                            if (_errorMessage != null) ...[
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: Colors.red.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.error_outline_rounded, color: Colors.red, size: 16),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        _errorMessage!,
                                        style: const TextStyle(color: Colors.red, fontSize: 12),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],

                            const SizedBox(height: 22),

                            // 로그인 버튼
                            SizedBox(
                              width: double.infinity,
                              child: GradientButton(
                                onPressed: _handleLogin,
                                label: currentRole != null ? '${currentRole.label} 화면으로 접속' : '로그인',
                                icon: Icons.arrow_forward_rounded,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // 빠른 테스트 계정 선택기
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: AppTheme.softShadow,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.touch_app_rounded, size: 16, color: AppTheme.primary),
                                SizedBox(width: 6),
                                Text(
                                  '테스트 계정 빠른 선택',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppTheme.textMain),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: _quickAccounts.map((acc) {
                                final isSelected = _idController.text.trim().toLowerCase() == acc['id'];
                                return GestureDetector(
                                  onTap: () => _applyQuickAccount(acc),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: isSelected ? (acc['color'] as Color).withOpacity(0.15) : AppTheme.bgPage,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isSelected ? (acc['color'] as Color) : AppTheme.divider,
                                        width: isSelected ? 1.5 : 1,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(acc['icon'] as IconData, size: 14, color: isSelected ? acc['color'] as Color : AppTheme.textSub),
                                        const SizedBox(width: 6),
                                        Text(
                                          '${acc['id']} (${acc['name']})',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                            color: isSelected ? acc['color'] as Color : AppTheme.textMain,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
