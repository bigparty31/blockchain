/// 행사·입장 (A12) — docs/API.md 「행사·입장」.

/// 행사 하나 (`GET /events` 의 항목, `POST /events` 응답).
class EventInfo {
  final int id;
  final int termId;
  final String name;

  /// 행사 시각. 서버는 `Z`·`+09:00` 어느 쪽으로든 줄 수 있어 시각으로 파싱해 둔다 (API.md 1번).
  final DateTime heldAt;

  const EventInfo({required this.id, required this.termId, required this.name, required this.heldAt});

  factory EventInfo.fromJson(Map<String, dynamic> json) => EventInfo(
        id: json['id'] as int,
        termId: json['term_id'] as int,
        name: json['name'] as String,
        heldAt: DateTime.parse(json['held_at'] as String),
      );
}

/// 입장 판정 (`POST /events/{id}/check-in` 의 `result`). 다섯 가지 모두 200 으로 온다.
enum CheckInResult {
  /// 이번 학기 회원권 보유 → 입장. 기록을 남겼다
  admitted('ADMITTED'),

  /// 이 행사에 이미 입장함. 처음 입장한 시각이 함께 온다
  alreadyCheckedIn('ALREADY_CHECKED_IN'),

  /// 이번 학기 회원권 없음 (미납·환불 회수·다른 학기 회원권만)
  notMember('NOT_MEMBER'),

  /// QR 의 ID 가 없는 사용자이거나 학생이 아님
  unknownStudent('UNKNOWN_STUDENT'),

  /// 회원권 확인 자체를 못 함 (체인 연결 실패·3초 초과). **거부가 아니다** — 「미납」으로 안내하지 않고 다시 찍게 한다
  unverifiable('UNVERIFIABLE');

  final String code;
  const CheckInResult(this.code);

  static CheckInResult fromCode(String code) =>
      values.firstWhere((r) => r.code == code, orElse: () => throw FormatException('모르는 입장 판정: $code'));
}

/// 입장 판정 응답.
class CheckInOutcome {
  final CheckInResult result;
  final int eventId;
  final int? userId;

  /// 현장 본인 확인용 — QR 의 ID 는 추측할 수 있어서(U000001 → U000002) 학생증과 이름을 맞춰 본다.
  final String? studentNo;
  final String? name;

  /// 입장 시각. [CheckInResult.alreadyCheckedIn] 이면 **처음** 입장한 시각.
  final DateTime? checkedInAt;

  const CheckInOutcome({
    required this.result,
    required this.eventId,
    this.userId,
    this.studentNo,
    this.name,
    this.checkedInAt,
  });

  factory CheckInOutcome.fromJson(Map<String, dynamic> json) {
    final at = json['checked_in_at'];
    return CheckInOutcome(
      result: CheckInResult.fromCode(json['result'] as String),
      eventId: json['event_id'] as int,
      userId: json['user_id'] as int?,
      studentNo: json['student_no'] as String?,
      name: json['name'] as String?,
      checkedInAt: at is String ? DateTime.parse(at) : null,
    );
  }
}

/// 학생 회원권 QR 모양인가 — `SCA:<학기>:U<학생 ID 1~12자리>` (서버 `parse_qr` 와 같은 규칙).
///
/// 서버에 보내기 전에 거른다. 행사장에는 영수증·주차 QR 등 다른 QR 이 많아서, 모양이 다르면 요청하지 않고 바로 알린다.
/// 앞뒤 공백·줄바꿈은 서버처럼 무시한다.
bool isStudentQr(String payload) => RegExp(r'^SCA:[^:\s]+:U\d{1,12}$').hasMatch(payload.trim());
