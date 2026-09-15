import 'package:intl/intl.dart';

/// 화면 표기 공통 포맷터.
class Fmt {
  Fmt._();

  static final _won = NumberFormat('#,###');
  static final _date = DateFormat('yyyy.MM.dd');
  static final _dateTime = DateFormat('yyyy.MM.dd HH:mm');

  /// `35000` → `35,000원`
  static String won(int amount) => '${_won.format(amount)}원';

  /// `35000` → `35,000` (단위를 따로 붙일 때)
  static String plain(int amount) => _won.format(amount);

  /// 큰 금액을 요약해서 보여준다. `2500000` → `250만`
  static String compact(int amount) {
    if (amount.abs() >= 100000000) {
      final v = amount / 100000000;
      return '${_trim(v)}억';
    }
    if (amount.abs() >= 10000) {
      final v = amount / 10000;
      return '${_trim(v)}만';
    }
    return _won.format(amount);
  }

  static String _trim(double v) {
    final s = v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  /// epoch 초 → `2026.09.08`
  static String date(int epochSeconds) =>
      _date.format(DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000));

  /// epoch 초 → `2026.09.08 18:30`
  static String dateTime(int epochSeconds) =>
      _dateTime.format(DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000));

  /// 해시를 앞뒤만 남겨 줄인다. `0x8a3f…6b4e`
  static String shortHash(String hash, {int head = 10, int tail = 6}) {
    if (hash.length <= head + tail + 1) return hash;
    return '${hash.substring(0, head)}…${hash.substring(hash.length - tail)}';
  }

  /// `0.023` → `2.3%`
  static String percent(double rate) => '${(rate * 100).toStringAsFixed(1)}%';
}
