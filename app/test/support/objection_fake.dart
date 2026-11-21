import 'dart:async';

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

  /// 목록을 읽은 횟수 (처음 열 때 포함).
  int listCalls = 0;

  /// 주면 풀릴 때까지 답변을 붙잡아 둔다 — 서명·기록 중의 화면을 본다.
  Completer<void>? gate;

  /// true 면 [answerError] 를 던지기 **전에** 서버에는 답변이 기록된 것으로 한다 —
  /// 시간 초과인데 실제로는 체인에 들어간 경우.
  bool recordBeforeError = false;

  /// [answerError] 를 던지기 직전에 부른다 — 실제 서비스가 401 에서 하는 전역 로그인 이동(`reportUnauthorized` →
  /// `onUnauthorized`)을 시험이 흉내 낼 때 쓴다.
  void Function()? beforeAnswerError;

  FakeObjectionApi(this.items);

  @override
  Future<List<ObjectionModel>> list() async {
    listCalls++;
    if (listError != null) throw listError!;
    return List.of(items);
  }

  ObjectionModel _answered(ObjectionModel o, String answer) => ObjectionModel(
        id: o.id,
        entryId: o.entryId,
        userId: o.userId,
        content: o.content,
        answer: answer,
        answeredBy: 3,
        status: ObjectionStatus.ANSWERED,
        raisedAt: o.raisedAt,
        answeredAt: o.raisedAt + 60,
      );

  @override
  Future<ObjectionModel> answer(ObjectionModel objection, String answer) async {
    if (gate != null) await gate!.future;
    if (answerError != null) {
      beforeAnswerError?.call();
      if (recordBeforeError) {
        final i = items.indexWhere((x) => x.id == objection.id);
        if (i >= 0) items[i] = _answered(objection, answer);
      }
      throw answerError!;
    }
    answered.add(answer);
    return _answered(objection, answer);
  }
}
