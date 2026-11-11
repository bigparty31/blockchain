import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/enums.dart';
import '../core/format.dart';
import '../core/role_home.dart';
import '../services/auth_service.dart';

/// 화면 1 — 로그인 (작성지침 「1. 로그인」, 스토리보드 p1·p2)
///
/// 로그인 키는 **학번**이다. 전에는 `block1`~`block4` 를 앱이 역할로 매핑하고
/// 비밀번호는 읽지도 않았는데, 그러면 ⑴ 서버 계정과 맞지 않고 ⑵ 입력한 아이디로
/// **역할이 드러나며** ⑶ 비밀번호가 사실상 없다. 역할은 서버가 판정한 값만 쓴다.
///
/// `main.dart` 가 아니라 여기 둔 이유 — `main.dart` 는 팀 공용 파일이라
/// 화면 코드가 들어 있으면 로그인 화면을 고칠 때마다 공용 파일이 바뀐다
/// (`router.dart` 의 같은 판단).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  final _studentNoController = TextEditingController();
  final _pwController = TextEditingController();
  final _auth = AuthService();

  bool _obscurePw = true;
  bool _busy = false;

  /// 차단 중 남은 시간을 1초마다 다시 그리기 위한 타이머.
  Timer? _lockTicker;

  late AnimationController _animController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  /// 개발용 테스트 계정 (docs/API.md 「인증」 4). 비밀번호는 모두 같다.
  ///
  /// **발표 빌드에서는 보이지 않는다** ([kDebugMode], 작성지침 화면 1
  /// 「화면 전체 규칙」). 지우지 않는 이유는 아직 역할별 첫 화면이 없어
  /// 다른 역할 화면을 열 방법이 이것뿐이기 때문이다.
  static const _testPassword = 'userPassword123!';
  static const _testAccounts = [
    ('20240001', '학생', AppTheme.income, Icons.school_rounded),
    ('20240002', '총무/회계', AppTheme.primary, Icons.account_balance_wallet_rounded),
    ('20240003', '감사', AppTheme.pending, Icons.fact_check_rounded),
    ('20240004', '학생회장', AppTheme.expense, Icons.star_rounded),
  ];

  @override
  void initState() {
    super.initState();
    // 버튼 활성(①②가 둘 다 입력됐는지)이 입력에 따라 바뀐다.
    _studentNoController.addListener(_onInputChanged);
    _pwController.addListener(_onInputChanged);

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnim = CurvedAnimation(parent: _animController, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero)
        .animate(CurvedAnimation(parent: _animController, curve: Curves.easeOut));
    _animController.forward();

    // 기기에 남은 잠금을 읽어 **화면을 열자마자** 남은 시간을 보여준다.
    // 이것이 없으면 잠긴 상태인데 입력이 열려 보이고, 눌러 본 뒤에야 막힌다.
    _auth.loadLock().then((_) {
      if (!mounted) return;
      setState(() {});
      if (_lockLeft != null) _startLockTicker();
    });

    if (_lockLeft != null) _startLockTicker();

    // 기기에 토큰이 남은 사실을 **여기서도 알린다.**
    //
    // 세션 만료는 `main.dart` 가 로그인 화면으로 밀어내면서 스낵바로 말해 주지만,
    // **앱을 켤 때의 복원 실패는 그 경로를 지나지 않는다** — `SessionGate` 가
    // 조용히 로그인 화면을 세울 뿐이다. 그쪽에서 토큰 삭제까지 실패하면
    // ([AuthService.restore] 의 `_Unauthorized` 분기) 깃발만 서고 아무도 말하지
    // 않아, 공용 기기에 남의 토큰이 남은 것을 사용자가 모른다.
    //
    // 프레임이 끝난 뒤에 띄운다 — `initState` 에는 `ScaffoldMessenger` 가 아직 없다.
    // `consume` 이라 만료 경로에서 두 번 뜨지는 않는다.
    if (_auth.tokenClearFailed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_auth.consumeTokenClearFailed()) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '이 기기에서 이전 로그인 정보를 지우지 못했습니다 — '
              '공용 기기라면 앱 데이터를 삭제해 주세요.',
            ),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 6),
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    _lockTicker?.cancel();
    _studentNoController.dispose();
    _pwController.dispose();
    _animController.dispose();
    super.dispose();
  }

  void _onInputChanged() {
    if (mounted) setState(() {});
  }

  /// **입력된 학번에 걸린** 잠금만 본다.
  ///
  /// 서버 잠금(`429`)은 학번 단위라, 기기 전체로 보면 A 가 잠긴 기기에서
  /// B 가 로그인하지 못한다 ([AuthService.lockRemainingFor]).
  Duration? get _lockLeft => _auth.lockRemainingFor(_studentNoController.text.trim());

  bool get _canSubmit =>
      !_busy &&
      _lockLeft == null &&
      _studentNoController.text.trim().isNotEmpty &&
      _pwController.text.isNotEmpty;

  void _startLockTicker() {
    _lockTicker?.cancel();
    _lockTicker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      if (_lockLeft == null) t.cancel();
      setState(() {});
    });
  }

  Future<void> _handleLogin() async {
    // 중복 호출 차단 — 버튼을 두 번 누르거나 엔터와 탭이 겹쳐도 한 번만 보낸다.
    if (_busy || !_canSubmit) return;
    setState(() => _busy = true);

    Object? failure;
    try {
      final session = await _auth.login(
        _studentNoController.text.trim(),
        _pwController.text,
      );
      if (!mounted) return;

      // **저장이 안 된 로그인은 그렇다고 말한다** ([AuthService.sessionNotPersisted]).
      // 사용자는 「로그인 상태가 유지된다」고 알고 있어서, 다음에 앱을 켰을 때
      // 로그인 화면이 뜨면 앱이 멋대로 로그아웃시킨 것으로 보인다. 위험하지는
      // 않다 — 기기에 남은 토큰이 없다는 뜻이기도 하다.
      //
      // 홈으로 넘어간 뒤에도 남는다: `MaterialApp.scaffoldMessengerKey` 가
      // 앱 전체의 messenger 라 화면 교체에 딸려 사라지지 않는다.
      if (_auth.sessionNotPersisted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('이 기기에 로그인 상태를 저장하지 못했습니다 — 앱을 다시 켜면 다시 로그인해야 합니다.'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 6),
          ),
        );
      }

      _goHome(session.role);
      return;
    } catch (e) {
      failure = e;
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    if (!mounted) return;

    // **로딩을 끝낸 뒤에 알린다.** 팝업을 띄운 채로 `_busy` 를 두면 뒤에 있는
    // 버튼이 「로그인 중」으로 남고 ①② 가 잠긴 상태가 되어, 확인을 눌러 닫기
    // 전에는 비밀번호를 다시 칠 수 없다 (작성지침 ④ 「성공: 로그인 화면」).
    if (failure is LoginFailure) {
      // ② 만 비운다. 학번은 남겨 다시 치지 않게 한다.
      _pwController.clear();
      if (failure.locked) _startLockTicker();
      await _showFailureDialog(locked: failure.locked);
      return;
    }
    if (failure is LoginLocked) {
      _startLockTicker();
      await _showFailureDialog(
        locked: true,
        remaining: failure.remaining,
        byServer: failure.byServer,
      );
      return;
    }

    // 학번·비밀번호는 맞았는데 **기기 보관소를 믿을 수 없어** 로그인을 확정하지
    // 않은 경우다 ([SessionStoreUnsafe]). 「연결 실패」로 뭉개면 사용자는 다시
    // 눌러 보다 끝나고, 왜 안 되는지 알 방법이 없다. 비밀번호도 비우지 않는다 —
    // 틀린 게 아니다.
    if (failure is SessionStoreUnsafe) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '이 기기에 로그인 정보를 저장할 수 없어 로그인을 중단했습니다. '
            '이전 사용자의 정보가 남아 있어 앱 데이터를 삭제한 뒤 다시 시도해 주세요.',
          ),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 8),
        ),
      );
      return;
    }

    // [LoginUnavailable] 과 예상 못 한 예외. 팝업이 아니라 토스트이고 ①② 는
    // 그대로 둔다 (작성지침 ③ 실패 (3)) — 비밀번호가 틀렸다는 근거가 없다.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('연결에 실패했습니다. 잠시 후 다시 시도해 주세요.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 실패 팝업 ④. 바깥을 눌러도 닫힌다.
  /// [byServer] 면 **서버가 건 잠금**이다 (`429`). 이때 「비밀번호를 5회
  /// 틀렸습니다」라고 말하면 안 된다 — 서버 잠금은 학번 단위라 남이 내 학번으로
  /// 틀려도 걸리고, 그 사람은 자기 비밀번호를 의심하게 된다.
  Future<void> _showFailureDialog({
    required bool locked,
    Duration? remaining,
    bool byServer = false,
  }) {
    final left = remaining ?? _lockLeft ?? AuthService.lockDuration;
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: Icon(
          locked ? Icons.lock_clock_rounded : Icons.error_outline_rounded,
          color: locked ? AppTheme.expense : Colors.red,
          size: 36,
        ),
        title: Text(locked ? '로그인이 일시 차단되었습니다' : '로그인할 수 없습니다'),
        content: Text(
          locked
              ? byServer
                  ? '로그인 시도가 많아 서버가 이 학번을 잠시 잠갔습니다.\n'
                      '${Fmt.duration(left)} 후에 다시 시도해 주세요.'
                  : '비밀번호를 ${AuthService.maxAttempts}회 연속 틀렸습니다.\n'
                      '${Fmt.duration(left)} 후에 다시 시도해 주세요.'
              // 학번이 없는 것인지 비밀번호가 틀린 것인지 구분하지 않는다.
              // 구분하면 학번만 넣어보며 등록된 사람을 알아낼 수 있다.
              : '학번 또는 비밀번호가 올바르지 않습니다.',
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  void _goHome(UserRole role) {
    final target = homeScreenFor(role); // 역할 분기표는 core/role_home.dart 한 군데에 있다

    // push 가 아니라 pushReplacement — 홈에서 뒤로 가면 로그인으로 돌아오면 안 된다.
    // 로그아웃하지 않고 로그인 화면에 닿는 경로를 만들면 세션과 화면이 어긋난다.
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, a, __) => target,
        transitionsBuilder: (_, a, __, child) => FadeTransition(
          opacity: a,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0.05, 0), end: Offset.zero).animate(a),
            child: child,
          ),
        ),
        transitionDuration: const Duration(milliseconds: 350),
      ),
    );
  }

  void _applyTestAccount(String studentNo) {
    _studentNoController.text = studentNo;
    _pwController.text = _testPassword;
  }

  @override
  Widget build(BuildContext context) {
    final lockLeft = _lockLeft;

    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      body: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
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
                        style: TextStyle(fontSize: 14, color: Colors.white.withOpacity(0.85)),
                      ),
                      const SizedBox(height: 28),
                      _loginCard(lockLeft),
                      const SizedBox(height: 24),
                      if (kDebugMode) _testAccountCard(),
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

  Widget _loginCard(Duration? lockLeft) {
    return Container(
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
          // 역할 뱃지는 두지 않는다 — 로그인 전에는 역할을 모른다.
          // 학번으로 역할을 추측해 보여주면 그 자체가 계정 정보 노출이다.
          Center(
            child: Column(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.lock_person_rounded, size: 32, color: AppTheme.primary),
                ),
                const SizedBox(height: 12),
                const Text(
                  '통합 로그인',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textMain,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '학번과 비밀번호를 입력해 주세요',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ① 학번 입력란
          const Text(
            '학번',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppTheme.textMain),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('login_student_no'),
            controller: _studentNoController,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username],
            // 형식 검사를 하지 않는다 — 올바른 학번인지는 서버가 판정한다 (작성지침 ①).
            decoration: AppTheme.inputDecoration(
              label: '',
              hint: '예: 20240001',
              icon: Icons.badge_rounded,
            ),
          ),
          const SizedBox(height: 14),

          // ② 비밀번호 입력란
          const Text(
            '비밀번호',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppTheme.textMain),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('login_password'),
            controller: _pwController,
            enabled: !_busy,
            obscureText: _obscurePw,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => _canSubmit ? _handleLogin() : null,
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

          // 차단 중 안내. 실패 사유는 팝업이 말하므로 여기엔 두지 않는다.
          if (lockLeft != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.expense.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.expense.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.lock_clock_rounded, color: AppTheme.expense, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _auth.lockByServer
                          ? '서버가 이 학번의 로그인을 잠시 막았습니다. '
                              '${Fmt.duration(lockLeft)} 후 다시 시도해 주세요.'
                          : '연속 실패로 차단되었습니다. '
                              '${Fmt.duration(lockLeft)} 후 다시 시도해 주세요.',
                      style: const TextStyle(color: AppTheme.expense, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 22),

          // ③ 로그인 버튼
          SizedBox(
            width: double.infinity,
            child: _busy
                ? const _LoadingButton()
                : GradientButton(
                    key: const Key('login_submit'),
                    // 회색일 때는 눌러도 아무 일도 없다 — 왜 안 되는지 말해 줄 것이
                    // 없는 상태다(입력이 비었거나 차단 중이고, 둘 다 화면에 보인다).
                    onPressed: _canSubmit ? _handleLogin : null,
                    enabled: _canSubmit,
                    label: '로그인',
                    icon: Icons.arrow_forward_rounded,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _testAccountCard() {
    return Container(
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
              Icon(Icons.construction_rounded, size: 16, color: AppTheme.primary),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  '개발용 · 발표 빌드에서 제거',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: AppTheme.textMain,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _testAccounts.map((acc) {
              final (studentNo, name, color, icon) = acc;
              final isSelected = _studentNoController.text.trim() == studentNo;
              return GestureDetector(
                onTap: _busy ? null : () => _applyTestAccount(studentNo),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: isSelected ? color.withOpacity(0.15) : AppTheme.bgPage,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected ? color : AppTheme.divider,
                      width: isSelected ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 14, color: isSelected ? color : AppTheme.textSub),
                      const SizedBox(width: 6),
                      Text(
                        '$studentNo ($name)',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected ? color : AppTheme.textMain,
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
    );
  }
}

/// 로그인 중 버튼. 누를 수 없고 진행 중임을 보인다 (작성지침 ③ 누르면).
class _LoadingButton extends StatelessWidget {
  const _LoadingButton();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: AppTheme.primaryGradient,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
          ),
          SizedBox(width: 10),
          Text(
            '로그인 중…',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
          ),
        ],
      ),
    );
  }
}
