/// 학기·소속 표시값
///
/// **서버에서 받아야 하는 값인데 받을 곳이 없어서 여기 고정해 둔 것이다.**
/// `EntryResponse` 와 `BudgetResponse` 에 `term_id` 는 있지만 학기 이름을 주는
/// 엔드포인트가 없고, 학과명은 어디에서도 내려오지 않는다.
///
/// 이대로 두면 **다음 학기에 데이터는 바뀌는데 화면은 계속 이 문구를 말한다.**
/// 두 화면(대시보드 헤더, 내 SBT)이 같은 문자열을 각자 들고 있던 것을 한곳으로
/// 모아, 엔드포인트가 생기면 여기만 고치면 되도록 해 두었다.
///
/// 필요한 것: `GET /terms/{id}` 또는 `EntryResponse` 에 학기 이름 필드.
class TermInfo {
  TermInfo._();

  /// 현재 학기 이름. 서버에 학기 API 가 생기면 그 값으로 바꾼다.
  static const String currentTerm = '2026학년도 2학기';

  /// 현재 학기의 **온체인 학기 코드** `YYYYS` (`terms.term_code`, `Entry.term`).
  ///
  /// DB 의 `term_id`(1, 2…)와 다른 값이다. 지금은 데모 데이터를 만들 때만 쓴다 —
  /// 실제 항목의 학기는 `EntryResponse.term_code` 로 받아야 하며, 화면이 이 상수를
  /// 모든 항목에 갖다 붙이면 **지난 학기 항목까지 이번 학기라고 말하게 된다.**
  static const int currentTermCode = 20262;

  /// 소속 학과. 서버가 내려주지 않는다.
  static const String department = '컴퓨터공학과';

  /// 대시보드 헤더용 — `2026학년도 2학기 · 컴퓨터공학과`
  static const String headline = '$currentTerm · $department';
}
