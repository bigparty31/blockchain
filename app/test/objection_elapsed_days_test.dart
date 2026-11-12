import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/screens/student/entry_detail_screen.dart';

/// 「제기 후 N일 경과」가 **한국 날짜 기준**으로 세어지는지 (스토리보드 5 ⑤).
///
/// 24시간 단위로 세면 어제 늦게 제기한 건이 오늘도 「0일」로 남아 미답변 압력이
/// 하루 늦게 걸린다. 기기 시간대로 세면 UTC 에뮬레이터에서 날짜가 하루 밀린다.
void main() {
  // KST 기준 어느 날 09:00 (= 그날 자정 + 9시간)
  int kstAt(int y, int m, int d, int hour) =>
      Hashing.kstMidnightOf(y, m, d) + hour * 3600;

  DateTime utcOf(int epochSeconds) =>
      DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true);

  test('같은 날이면 0일', () {
    final raised = kstAt(2026, 11, 10, 9);
    final now = utcOf(kstAt(2026, 11, 10, 23));
    expect(objectionElapsedDays(raised, now: now), 0);
  });

  test('자정을 한 번 넘으면 1일 — 23시 제기 → 다음 날 아침', () {
    final raised = kstAt(2026, 11, 10, 23);
    final now = utcOf(kstAt(2026, 11, 11, 8)); // 9시간밖에 안 지났지만 날짜는 바뀌었다
    expect(objectionElapsedDays(raised, now: now), 1);
  });

  test('사흘 뒤면 3일', () {
    final raised = kstAt(2026, 11, 10, 12);
    final now = utcOf(kstAt(2026, 11, 13, 1));
    expect(objectionElapsedDays(raised, now: now), 3);
  });

  test('기기 시계가 뒤로 가 있어도 음수를 보이지 않는다', () {
    final raised = kstAt(2026, 11, 10, 12);
    final now = utcOf(kstAt(2026, 11, 8, 12));
    expect(objectionElapsedDays(raised, now: now), 0);
  });

  test('기기가 UTC 라도 KST 날짜로 센다', () {
    // KST 11/11 02:00 에 제기 = UTC 로는 아직 11/10 17:00 이다.
    final raised = kstAt(2026, 11, 11, 2);
    // KST 11/11 10:00 — 같은 KST 날짜라 0일이어야 한다.
    // 기기 로컬(UTC)로 날짜를 셌다면 11/10 → 11/11 로 1일이 나온다.
    final now = utcOf(kstAt(2026, 11, 11, 10));
    expect(objectionElapsedDays(raised, now: now), 0);
  });
}
