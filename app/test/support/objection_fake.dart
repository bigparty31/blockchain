import 'package:student_council_app/models/objection_model.dart';
import 'package:student_council_app/services/objection_answer_service.dart';

/// 목업 시절 시험이 쓰던 이의 두 건(답변 대기 #101, 답변 완료 #102)을 모델로 — 서버 연동 뒤에도 화면 시험이 같은 장면을 본다.
List<ObjectionModel> sampleObjections() {
  final now = DateTime.now().toUtc();
  return [
    ObjectionModel(
      id: 101,
      entryId: 1,
      userId: 1,
      content: '한결문구 신입생 환영회 물품 35,000원 건 세부 품목 내역서가 누락되어 있습니다.',
      status: ObjectionStatus.OPEN,
      raisedAt: now.subtract(const Duration(days: 3)).millisecondsSinceEpoch ~/ 1000,
    ),
    ObjectionModel(
      id: 102,
      entryId: 2,
      userId: 1,
      content: '청년피자 다과 주문 건 참석자 명단 증빙이 첨부되어 있나요?',
      answer: '네, 개강총회 당일 출석 서명부 스캔본을 증빙에 추가 업로드 완료하였습니다.',
      answeredBy: 3,
      status: ObjectionStatus.ANSWERED,
      raisedAt: DateTime.utc(2026, 9, 12).millisecondsSinceEpoch ~/ 1000,
      answeredAt: DateTime.utc(2026, 9, 13).millisecondsSinceEpoch ~/ 1000,
    ),
  ];
}

/// 화면 시험용 가짜 서버. 답변하면 그 건을 답변 완료로 바꿔 돌려준다.
class FakeObjectionApi implements ObjectionAnswerApi {
  final List<ObjectionModel> items;
  final answered = <String>[];
  Object? listError;
  Object? answerError;

  FakeObjectionApi(this.items);

  @override
  Future<List<ObjectionModel>> list() async {
    if (listError != null) throw listError!;
    return List.of(items);
  }

  @override
  Future<ObjectionModel> answer(ObjectionModel objection, String answer) async {
    if (answerError != null) throw answerError!;
    answered.add(answer);
    return ObjectionModel(
      id: objection.id,
      entryId: objection.entryId,
      userId: objection.userId,
      content: objection.content,
      answer: answer,
      answeredBy: 3,
      status: ObjectionStatus.ANSWERED,
      raisedAt: objection.raisedAt,
      answeredAt: objection.raisedAt + 60,
    );
  }
}
