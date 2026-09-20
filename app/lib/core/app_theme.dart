import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// 공통 디자인 시스템 - 학생회 앱 (밝고 세련된 학생 친화 테마)
class AppTheme {
  AppTheme._();

  // ── 주요 컬러 팔레트 ──────────────────────────────────────────
  static const Color primary     = Color(0xFF6C63FF); // 보라 (메인)
  static const Color primaryDark = Color(0xFF4F46E5);
  static const Color primaryLight= Color(0xFFEDE9FE);

  static const Color income  = Color(0xFF06B6D4); // 청록 (수입)
  static const Color expense = Color(0xFFF43F5E); // 핑크레드 (지출)
  static const Color pending = Color(0xFFF59E0B); // 앰버 (대기)
  static const Color success = Color(0xFF10B981); // 에메랄드 (승인)
  static const Color info    = Color(0xFF3B82F6); // 블루 (정보)

  static const Color bgPage  = Color(0xFFF5F3FF); // 라벤더 화이트 배경
  static const Color bgCard  = Color(0xFFFFFFFF);
  static const Color textMain= Color(0xFF1E1B4B);
  static const Color textSub = Color(0xFF64748B);
  static const Color divider = Color(0xFFE8E4FF);

  // ── 그라디언트 프리셋 ───────────────────────────────────────
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [Color(0xFF6C63FF), Color(0xFF9B59D6)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient incomeGradient = LinearGradient(
    colors: [Color(0xFF06B6D4), Color(0xFF0EA5E9)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient headerGradient = LinearGradient(
    colors: [Color(0xFF6C63FF), Color(0xFFA78BFA), Color(0xFF06B6D4)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // ── 공통 카드 박스섀도우 ───────────────────────────────────
  static List<BoxShadow> get cardShadow => [
    BoxShadow(
      color: const Color(0xFF6C63FF).withOpacity(0.08),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
  ];

  static List<BoxShadow> get softShadow => [
    BoxShadow(
      color: Colors.black.withOpacity(0.06),
      blurRadius: 10,
      offset: const Offset(0, 2),
    ),
  ];

  // ── 공통 카드 데코레이션 ───────────────────────────────────
  static BoxDecoration get cardDecoration => BoxDecoration(
    color: bgCard,
    borderRadius: BorderRadius.circular(20),
    boxShadow: cardShadow,
  );

  static BoxDecoration gradientDecoration(LinearGradient gradient) => BoxDecoration(
    gradient: gradient,
    borderRadius: BorderRadius.circular(20),
    boxShadow: [
      BoxShadow(
        color: gradient.colors.first.withOpacity(0.3),
        blurRadius: 20,
        offset: const Offset(0, 8),
      ),
    ],
  );

  // ── 공통 입력 필드 데코레이션 ─────────────────────────────
  static InputDecoration inputDecoration({
    required String label,
    String? hint,
    IconData? icon,
    Widget? suffix,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: icon != null ? Icon(icon, color: primary, size: 20) : null,
      suffixIcon: suffix,
      labelStyle: const TextStyle(color: textSub, fontSize: 14),
      hintStyle: TextStyle(color: textSub.withOpacity(0.5), fontSize: 13),
      filled: true,
      fillColor: const Color(0xFFFAF9FF),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFFE0DEFF), width: 1.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFFE0DEFF), width: 1.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: expense, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }

  // ── 기본 앱바 ─────────────────────────────────────────────
  static AppBar gradientAppBar({
    required String title,
    List<Widget>? actions,
    Widget? bottom,
    bool showBack = true,
  }) {
    return AppBar(
      title: Text(title,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 17,
          letterSpacing: -0.3,
        ),
      ),
      flexibleSpace: Container(
        decoration: const BoxDecoration(gradient: primaryGradient),
      ),
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: true,
      actions: actions,
      bottom: bottom as PreferredSizeWidget?,
    );
  }

  // ── ThemeData ────────────────────────────────────────────
  static ThemeData get themeData => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: primary,
      primary: primary,
      secondary: income,
      surface: bgCard,
    ),
    useMaterial3: true,
    scaffoldBackgroundColor: bgPage,
    textTheme: GoogleFonts.nunitoTextTheme().copyWith(
      bodyLarge: GoogleFonts.nunito(color: textMain),
      bodyMedium: GoogleFonts.nunito(color: textMain),
      titleLarge: GoogleFonts.nunito(fontWeight: FontWeight.bold, color: textMain),
    ),
    appBarTheme: const AppBarTheme(centerTitle: true, elevation: 0),
    cardTheme: CardThemeData(
      color: bgCard,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: primaryLight,
      labelStyle: const TextStyle(color: primaryDark, fontWeight: FontWeight.w600, fontSize: 12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
  );
}

/// 색상 뱃지 위젯
class StatusBadge extends StatelessWidget {
  final String label;
  final Color color;
  final Color? bgColor;
  const StatusBadge({super.key, required this.label, required this.color, this.bgColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor ?? color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12),
      ),
    );
  }
}

/// 그라디언트 버튼
class GradientButton extends StatelessWidget {
  final VoidCallback onPressed;
  final String label;
  final IconData? icon;
  final LinearGradient gradient;

  const GradientButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.gradient = AppTheme.primaryGradient,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: gradient.colors.first.withOpacity(0.35),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                ],
                Text(label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
