/// PRD §8 Objection 모델
///
/// 학생이 확정 지출에 사유를 묻고 학생회가 답변한다.
/// **원장은 고치지 않고 설명만 쌓인다** (PRD §189) —
/// 이의 제기는 금액이나 상태를 바꾸지 않으며, 미답변 사실이 기록으로 남는다.
class ObjectionModel {
  final int id;
  final int entryId;
  final int userId;
  final String content;
  final String? answer;
  final int? answeredBy;
  final ObjectionStatus status;
  final int raisedAt;
  final int? answeredAt;
  final String? txRaise;
  final String? txAnswer;

  ObjectionModel({
    required this.id,
    required this.entryId,
    required this.userId,
    required this.content,
    this.answer,
    this.answeredBy,
    required this.status,
    required this.raisedAt,
    this.answeredAt,
    this.txRaise,
    this.txAnswer,
  });

  factory ObjectionModel.fromJson(Map<String, dynamic> json) {
    return ObjectionModel(
      id: json['id'] ?? 0,
      entryId: json['entry_id'] ?? 0,
      userId: json['user_id'] ?? 0,
      content: json['content'] ?? '',
      answer: json['answer'],
      answeredBy: json['answered_by'],
      status: ObjectionStatus.fromCode(json['status'] ?? 'OPEN'),
      raisedAt: json['raised_at'] ?? 0,
      answeredAt: json['answered_at'],
      txRaise: json['tx_raise'],
      txAnswer: json['tx_answer'],
    );
  }

  Map<String, dynamic> toCreateJson() => {
        'entry_id': entryId,
        'content': content,
      };
}

/// 이의 상태 (PRD §8).
///
/// `docs/enums.md` 에는 없는 값이므로 공통 `core/enums.dart` 에 넣지 않는다 —
/// 그 파일은 `docs/enums.md` 를 1:1로 옮긴 것이며 임의 추가는 금지되어 있다.
enum ObjectionStatus {
  OPEN('OPEN', '답변 대기'),
  ANSWERED('ANSWERED', '답변 완료');

  final String code;
  final String label;
  const ObjectionStatus(this.code, this.label);

  static ObjectionStatus fromCode(String code) {
    return ObjectionStatus.values.firstWhere(
      (e) => e.code == code,
      orElse: () => ObjectionStatus.OPEN,
    );
  }
}
