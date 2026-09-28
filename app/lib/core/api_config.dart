import 'dart:io';

class ApiConfig {
  /// 로컬 개발 환경 기본 백엔드 URL
  /// Android 에뮬레이터: 10.0.2.2:8000
  /// iOS 시뮬레이터 / 데스크탑: 127.0.0.1:8000
  /// 실기기: PC의 Wi-Fi 로컬 IP 지정 필요
  static String get baseUrl {
    try {
      if (Platform.isAndroid) {
        return 'http://10.0.2.2:8000';
      } else {
        return 'http://127.0.0.1:8000';
      }
    } catch (_) {
      return 'http://localhost:8000';
    }
  }

  // Endpoints
  static String get entries => '$baseUrl/entries';
  static String get balance => '$baseUrl/balance';
  static String get budgets => '$baseUrl/budgets';
}
