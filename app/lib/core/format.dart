import 'package:intl/intl.dart';

/// 화면 표기 공통 포맷터.
class Fmt {
  Fmt._();

  static final _won = NumberFormat('#,###');
  static final _date = DateFormat('yyyy.MM.dd');
  static final _dateTime = DateFormat('yyyy.MM.dd HH:mm');

  /// `35000` → `₩ 35,000`, `-20000` → `-₩ 20,000`
  ///
  /// 총무 화면(`screens/council/`)의 표기와 맞춘 것이다. 같은 잔액이 화면마다
  /// 다른 모양으로 보이면 같은 값인지 아닌지부터 헷갈린다.
  ///
  /// 음수는 부호를 `₩` **앞**에 둔다. 뒤에 두면 `₩ -20,000` 처럼 부호가 가운데
  /// 끼어 한눈에 안 들어온다 — 정정 항목 금액이 증감분이라 음수가 실제로 나온다.
  static String won(int amount) => amount < 0
      ? '-₩ ${_won.format(-amount)}'
      : '₩ ${_won.format(amount)}';

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

  /// epoch 초 → `2026.09.08` (**한국 시간**)
  ///
  /// 기기 시간대를 쓰지 않는다. `occurred_at` 은 사용일의 KST 자정이라(HASHING §1.3) 시간대가 UTC 인
  /// 기기(에뮬레이터 기본값, 해외 로밍)에서 기기 시간으로 바꾸면 하루 전 날짜가 보인다.
  static String date(int epochSeconds) => _date.format(_kst(epochSeconds));

  /// epoch 초 → `2026.09.08 18:30` (**한국 시간**)
  static String dateTime(int epochSeconds) => _dateTime.format(_kst(epochSeconds));

  /// epoch 초의 한국 시각. 연·월·일·시·분만 읽는 값이라 UTC 로 표시한 「벽시계」다.
  static DateTime _kst(int epochSeconds) =>
      DateTime.fromMillisecondsSinceEpoch((epochSeconds + 9 * 3600) * 1000, isUtc: true);

  /// 서버가 주는 시각 문자열 → 시점. **시간대가 없으면 한국 시간으로 읽는다.**
  ///
  /// `DateTime.parse` 는 시간대가 없는 값을 기기 시간대로 읽어서, UTC 로 도는 기기(에뮬레이터 기본값)에서는
  /// 학기 경계 같은 값이 9시간 어긋난다. 서버는 한국 시간 기준이다 (`Fmt.date` 와 같은 약속).
  static DateTime parseServerTime(String text) {
    var t = text.trim();
    if (!t.contains('T')) t = '${t}T00:00:00'; // 날짜만 — 그날 0시
    final hasZone = RegExp(r'(Z|[+-]\d{2}(:?\d{2})?)$').hasMatch(t);
    return DateTime.parse(hasZone ? t : '$t+09:00');
  }

  /// 해시를 앞뒤만 남겨 줄인다. `0x8a3f…6b4e`
  static String shortHash(String hash, {int head = 10, int tail = 6}) {
    if (hash.length <= head + tail + 1) return hash;
    return '${hash.substring(0, head)}…${hash.substring(hash.length - tail)}';
  }

  /// `0.023` → `2.3%`
  static String percent(double rate) => '${(rate * 100).toStringAsFixed(1)}%';

  /// 남은 시간. `45초` · `1분 30초` · `15분`
  ///
  /// **초로만 적으면 안 된다.** 로그인 차단은 앱 자체 잠금이 60초지만 서버
  /// 잠금은 분 단위라(백엔드 #89), 그대로 적으면 「900초 후에 다시 시도해
  /// 주세요」가 된다 — 읽는 사람이 암산을 해야 한다.
  static String duration(Duration d) {
    final total = d.inSeconds < 0 ? 0 : d.inSeconds;
    final minutes = total ~/ 60;
    final seconds = total % 60;
    if (minutes == 0) return '$seconds초';
    if (seconds == 0) return '$minutes분';
    return '$minutes분 $seconds초';
  }
}
