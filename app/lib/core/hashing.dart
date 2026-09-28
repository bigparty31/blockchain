import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// 해시 계산 — `docs/HASHING.md` 규칙 v1 의 Dart 구현
///
/// **정본은 `docs/HASHING.md` 이고 테스트 값은 `docs/hashing_vectors.json` 이다.**
/// 이 파일을 고치기 전에 그 문서를 먼저 볼 것. 두 문서는 `.github/CODEOWNERS`
/// 대상이라 규칙 변경에는 손종인 승인이 필요하다.
///
/// 한 바이트만 달라도 학생 화면의 검증 배지가 전부 빨강으로 뜬다.
///
/// ---
/// **학생 앱에서 [canonical] 을 호출하지 말 것.**
/// 텍스트는 백엔드가 저장 시점에 한 번만 다듬고 그 값이 정본이다 (§1.1).
/// API 가 내려준 값을 앱이 다시 다듬으면 오히려 값이 갈린다.
/// [canonical] 과 [canonicalText] 는 총무·감사 앱이 **서명용 해시를 직접 만들 때**
/// 쓰라고 둔 것이다.
class Hashing {
  Hashing._();

  /// 필드 구분자 — U+001F (Unit Separator). **파이프(`|`)가 아니다.**
  ///
  /// 목적란은 자유 입력이라 총무가 `|` 를 칠 수 있고, 그러면 서로 다른 거래가
  /// 같은 해시를 낸다. `상호="한결문구", 목적="명찰|필기구"` 와
  /// `상호="한결문구|명찰", 목적="필기구"` 가 파이프 방식에서는 preimage 가
  /// 완전히 같아진다. U+001F 는 키보드로 칠 수 없어 이 충돌이 구조적으로 없다.
  static const String unitSeparator = '\u001F';

  /// 규칙 버전. 규칙이 바뀌면 이미 확정된 항목의 배지가 전부 깨지므로,
  /// 버전을 올리기 전에 `HASHING.md` §7 을 먼저 정리해야 한다.
  static const int ruleVersion = 1;

  // ── §1 meta_hash ───────────────────────────────────────────

  /// `meta_hash = SHA256( amount ␟ counterparty ␟ purpose ␟ occurred_at ␟ receipt_hash )`
  ///
  /// [counterparty] 와 [purpose] 는 **이미 정본인 값**을 넘겨야 한다.
  /// 학생 앱은 API 응답을 그대로 넘긴다 (§1.1).
  ///
  /// [receiptHash] 가 null 이면 빈 문자열로 들어가며, **구분자는 그대로 둔다** —
  /// preimage 가 `␟` 로 끝난다.
  static String metaHash({
    required int amount,
    required String counterparty,
    required String purpose,
    required int occurredAt,
    String? receiptHash,
  }) {
    final pre = [
      '$amount',
      counterparty,
      purpose,
      '$occurredAt',
      receiptHash ?? '',
    ].join(unitSeparator);
    return '0x${sha256.convert(utf8.encode(pre))}';
  }

  /// 해시 대상 문자열. 디버깅과 벡터 대조용 — preimage 를 눈으로 볼 때 쓴다.
  static String metaPreimage({
    required int amount,
    required String counterparty,
    required String purpose,
    required int occurredAt,
    String? receiptHash,
  }) {
    return [
      '$amount',
      counterparty,
      purpose,
      '$occurredAt',
      receiptHash ?? '',
    ].join(unitSeparator);
  }

  // ── §3 텍스트 해시 ─────────────────────────────────────────

  /// 사유·이의 본문 등 한 필드짜리 텍스트의 해시.
  ///
  /// 인자는 [canonicalText] 를 거친 정본 값이어야 한다.
  /// 값이 없으면 **빈 문자열을 해시하지 말고** `bytes32(0)` 을 쓴다 (§3).
  static String textHash(String text) =>
      '0x${sha256.convert(utf8.encode(text))}';

  // ── §4 파일 해시 ───────────────────────────────────────────

  /// 파일은 **바이트 그대로** 해시한다. 정규화·트림을 하지 않는다.
  ///
  /// 영수증을 내려받아 이 값을 다시 계산하면, `receipt_hash` 가 실제로
  /// 그 파일의 것인지 확인할 수 있다. 이 단계를 빠뜨리면 영수증만
  /// 바꿔치기한 위조를 못 잡는다 (§2 절차 3번).
  static String fileHash(List<int> bytes) => '0x${sha256.convert(bytes)}';

  // ── §1.1 정본화 — 학생 앱은 호출하지 않는다 ────────────────

  /// `meta_hash` 에 들어가는 한 줄 텍스트의 정본화 (§1.1).
  ///
  /// **제거하는 것은 앞뒤의 U+0020 뿐이다.**
  /// `String.trim()` 을 쓰면 안 된다 — Dart 의 `trim()` 은 U+FEFF(BOM)를 지우는데
  /// Python 의 `strip()` 은 남긴다. 양쪽이 갈리면 해시가 깨진다.
  /// NBSP·전각공백·탭도 남겨야 한다 (`hashing_vectors.json` 의 `canonical_identity` 벡터).
  static String canonical(String s) {
    var t = s;
    while (t.startsWith(' ')) {
      t = t.substring(1);
    }
    while (t.endsWith(' ')) {
      t = t.substring(0, t.length - 1);
    }
    return unorm.nfc(t);
  }

  /// 여러 줄 텍스트의 정본화 (§3).
  ///
  /// 처리 순서를 지킬 것. 제어문자 검사를 개행 변환보다 먼저 하면
  /// CR 이 먼저 걸려 멀쩡한 여러 줄 입력이 전부 거부된다.
  ///   1. CRLF·CR → LF
  ///   2. 제어문자 검사 (백엔드 담당)
  ///   3. 앞뒤 trim (U+0020 · U+0009 · U+000A)
  ///   4. NFC 정규화
  static String canonicalText(String s) {
    var t = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    bool edge(String c) => c == ' ' || c == '\t' || c == '\n';
    while (t.isNotEmpty && edge(t[0])) {
      t = t.substring(1);
    }
    while (t.isNotEmpty && edge(t[t.length - 1])) {
      t = t.substring(0, t.length - 1);
    }
    return unorm.nfc(t);
  }

  // ── 비교 보조 ──────────────────────────────────────────────

  /// 두 해시가 같은 값인지 본다.
  ///
  /// `0x` 접두사 유무와 대소문자는 **표기 차이일 뿐 변조가 아니므로** 맞춰서 본다.
  /// 규칙상 양쪽 모두 `0x` + 소문자로 와야 하지만, 한쪽이 표기를 어겼다고
  /// 「변조 감지」를 띄우면 오탐이 된다.
  ///
  /// 여기서도 `String.trim()` 은 쓰지 않는다 — 해시 문자열에 공백이 붙어 있다면
  /// 그것 자체가 규격 위반이므로 조용히 지워서 통과시키면 안 된다.
  static bool hashEquals(String a, String b) => _bare(a) == _bare(b);

  static String _bare(String hash) {
    final lower = hash.toLowerCase();
    return lower.startsWith('0x') ? lower.substring(2) : lower;
  }

  // ── §1.3 occurred_at ──────────────────────────────────────

  /// KST 자정을 나타내는 Unix 초인지 검사한다.
  ///
  /// 백엔드는 `ts % 86400 == 54000` 이 아니면 400 으로 거부한다.
  /// UTC 자정으로 계산하면 9시간이 어긋나 **전날로 밀린다.**
  static bool isKstMidnight(int epochSeconds) =>
      epochSeconds % 86400 == _kstMidnightRemainder;

  /// KST(UTC+9) 자정의 86400 나머지. `24:00 - 09:00 = 15:00 = 54000초`
  static const int _kstMidnightRemainder = 54000;

  /// 사용일(연·월·일)을 KST 자정 Unix 초로 바꾼다.
  ///
  /// 시·분·초는 버린다. 같은 날이면 언제 등록하든 같은 값이 나와야 한다.
  static int kstMidnightOf(int year, int month, int day) {
    final utc = DateTime.utc(year, month, day);
    // KST 자정은 같은 날 UTC 00:00 보다 9시간 이르다.
    return utc.millisecondsSinceEpoch ~/ 1000 - 9 * 3600;
  }

  /// KST 자정 Unix 초를 사람이 읽는 날짜로 되돌린다.
  static DateTime kstDateOf(int epochSeconds) =>
      DateTime.fromMillisecondsSinceEpoch(
        (epochSeconds + 9 * 3600) * 1000,
        isUtc: true,
      );
}
