/// 입력 검사 — `docs/HASHING.md` §1.1(한 줄 텍스트)·§3(여러 줄 텍스트) 입력 거부 규칙
///
/// 서버는 아래 입력을 400 으로 거부한다. 앱이 먼저 막아 두면 서명까지 간 뒤
/// `HASH_MISMATCH` 로 되돌아오는 일이 없다.
///
/// 여기서는 **검사만** 한다. 서명용 해시를 만들 때의 정본화(NFC 등)는
/// `core/hashing.dart` 의 `Hashing.canonical` / `canonicalText` 를 쓴다 (feat/app-student).
/// `String.trim()` 은 쓰지 않는다 — BOM 처리가 Python 과 달라 해시가 갈린다.
class InputRules {
  InputRules._();

  /// 눈에 보이지 않으면서 해시를 바꾸는 문자 (§1.1). 한 줄·여러 줄 모두 거부.
  static const Set<int> _invisible = {
    0x00A0, // NBSP
    0x200B, // ZWSP
    0x3000, // 전각 공백
    0xFEFF, // BOM
  };

  /// `meta_hash` 에 들어가는 한 줄 텍스트 (`counterparty`, `purpose`). §1.1 · §5
  ///
  /// - 제어문자 U+0000~U+001F 전면 금지 (탭 포함 — 구분자 U+001F 충돌 차단)
  /// - 보이지 않는 공백류 금지
  /// - 앞뒤 U+0020 을 뺀 뒤 빈 문자열이면 거부
  ///
  /// 오류 메시지를 돌려주고, 통과하면 null. `TextFormField.validator` 에 그대로 쓴다.
  static String? singleLine(String? value, {required String fieldName}) {
    final v = value ?? '';
    if (_edgeTrim(v, const {0x20}).isEmpty)
      return '$fieldName${_eulReul(fieldName)} 입력해 주세요';
    for (final r in v.runes) {
      if (r <= 0x1F) return '$fieldName에 탭·줄바꿈 등 제어문자는 쓸 수 없어요';
      if (_invisible.contains(r)) return '$fieldName에 보이지 않는 공백 문자는 쓸 수 없어요';
    }
    return null;
  }

  /// 여러 줄 텍스트 — 반려 사유·경고 무시 승인 사유·이의 답변. §3
  ///
  /// 처리 순서를 지킨다. 순서가 바뀌면 멀쩡한 입력이 거부된다.
  ///   1. CRLF · CR → LF
  ///   2. 제어문자 검사 (탭·LF 외 거부)
  ///   3. 앞뒤 U+0020 · U+0009 · U+000A 제거
  ///   4. NFC 정규화 — 서명용 해시를 만들 때 `Hashing.canonicalText` 가 한다
  ///
  /// 사유가 필수인 자리(반려·경고 무시 승인)에서 3번 뒤 빈 문자열이면 서버가 400 이므로
  /// 여기서 거부한다. `text_hash("")` 를 올리면 `bytes32(0)` 과 달라 위조로 판정된다.
  static String? requiredReason(String? value, {String fieldName = '사유'}) {
    var v = (value ?? '').replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    for (final r in v.runes) {
      if (r <= 0x1F && r != 0x09 && r != 0x0A) {
        return '$fieldName에 쓸 수 없는 제어문자가 있어요';
      }
      if (_invisible.contains(r)) return '$fieldName에 보이지 않는 공백 문자는 쓸 수 없어요';
    }
    v = _edgeTrim(v, const {0x20, 0x09, 0x0A});
    if (v.isEmpty) return '$fieldName${_eulReul(fieldName)} 입력해 주세요';
    return null;
  }

  /// 금액 — 양의 정수 (0 금지). 정정 음수는 정정 화면에서 따로 다룬다. §5
  static String? positiveAmount(String? value, {required String fieldName}) {
    final v = value ?? '';
    if (v.isEmpty) return '$fieldName${_eulReul(fieldName)} 입력해 주세요';
    // 천단위 쉼표·부호·소수점은 meta_hash preimage 를 바꾸므로 받지 않는다.
    if (!RegExp(r'^[0-9]+$').hasMatch(v)) return '숫자만 입력해 주세요 (쉼표·소수점 불가)';
    final n = int.tryParse(v);
    if (n == null || n <= 0) return '0보다 큰 금액을 입력해 주세요';
    return null;
  }

  /// 받침 유무에 맞는 목적격 조사 (사유 → 를, 금액 → 을).
  static String _eulReul(String word) {
    if (word.isEmpty) return '을(를)';
    final c = word.runes.last;
    if (c < 0xAC00 || c > 0xD7A3) return '을(를)';
    return (c - 0xAC00) % 28 == 0 ? '를' : '을';
  }

  /// `trim()` 대신 지울 문자를 명시한다.
  static String _edgeTrim(String s, Set<int> edge) {
    final runes = s.runes.toList();
    var start = 0;
    var end = runes.length;
    while (start < end && edge.contains(runes[start])) {
      start++;
    }
    while (end > start && edge.contains(runes[end - 1])) {
      end--;
    }
    return String.fromCharCodes(runes.sublist(start, end));
  }
}
