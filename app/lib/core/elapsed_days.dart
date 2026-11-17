/// 「제기 후 N일 경과」의 **단일 구현** (PRD §4.5).
///
/// 학생 화면(이의 제기)과 임원 화면(이의 답변)이 같은 건을 두고 각각 날짜를 세던 것을 여기로
/// 모았다. 두 화면이 같은 이의에 다른 일수를 보여 주면, 답변 독촉이 누구 기준인지 알 수 없다.
///
/// **24시간 단위가 아니라 날짜가 바뀐 횟수를 센다.** 어제 23시에 제기한 건이 오늘 아침에도
/// 「0일 경과」로 보이면 미답변 압력이 하루 늦게 걸린다 — 답하지 않은 사실이 쌓이는 것이
/// 이 표시의 목적이다.
///
/// **시간대는 KST 로 고정한다.** 기기 시간대를 쓰면 UTC 인 에뮬레이터나 해외 로밍에서 날짜가
/// 하루 밀린다 (`Fmt.date`·[Hashing.kstDateOf] 와 같은 판단).
library;

import 'hashing.dart';

/// KST 달력 날짜 둘 사이에 날짜가 바뀐 횟수. 음수는 0 으로 막는다.
///
/// 기기 시계가 뒤로 가 있으면 음수가 나온다 — 「-2일 경과」를 보여 주지 않는다.
int _daysBetween(DateTime raisedKst, DateTime nowKst) {
  final days = DateTime.utc(nowKst.year, nowKst.month, nowKst.day)
      .difference(DateTime.utc(raisedKst.year, raisedKst.month, raisedKst.day))
      .inDays;
  return days < 0 ? 0 : days;
}

/// 지금을 KST 벽시계로 읽는다. [now] 는 시각(instant)이지 달력 날짜가 아니다.
DateTime _nowInKst(DateTime? now) =>
    Hashing.kstDateOf((now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000);

/// 제기 시각(Unix 초)부터 오늘까지 **KST 날짜가 바뀐 횟수**.
///
/// 학생 화면이 쓴다 — 서버가 `raised_at` 을 Unix 초로 준다.
int kstElapsedDays(int raisedAtEpochSeconds, {DateTime? now}) => _daysBetween(
      Hashing.kstDateOf(raisedAtEpochSeconds),
      _nowInKst(now),
    );

/// `2026-09-11` 같은 **날짜 문자열**부터 오늘까지 KST 날짜가 바뀐 횟수.
///
/// 임원 화면이 쓴다 — 목업 데이터가 날짜 문자열이다. 날짜 문자열은 이미 달력 날짜라
/// 시간대 변환 없이 연·월·일을 그대로 KST 날짜로 읽는다.
///
/// 날짜로 읽을 수 없으면 0 이다. 목업이 아닌 값이 들어와도 화면이 깨지지 않아야 한다.
int kstElapsedDaysFromDate(String raisedDate, {DateTime? now}) {
  final d = DateTime.tryParse(raisedDate);
  if (d == null) return 0;
  return _daysBetween(DateTime.utc(d.year, d.month, d.day), _nowInKst(now));
}
