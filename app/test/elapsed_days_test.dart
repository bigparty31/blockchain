import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/elapsed_days.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/screens/council/inquiry_response_screen.dart';
import 'package:student_council_app/screens/student/entry_detail_screen.dart';

/// 「N일 경과」를 **학생 화면과 임원 화면이 같은 규칙으로** 세는지.
///
/// 예전에는 학생은 KST, 임원은 기기 시간대로 세어서 UTC 에뮬레이터·해외 로밍이면 같은 이의에
/// 두 화면이 다른 일수를 보여 줬다. 답변 독촉이 누구 기준인지 알 수 없게 되는 회귀다.
void main() {
  // KST 기준 어느 날 N시 (= 그날 KST 자정 + N시간)
  int kstAt(int y, int m, int d, int hour) =>
      Hashing.kstMidnightOf(y, m, d) + hour * 3600;

  DateTime utcOf(int epochSeconds) =>
      DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true);

  group('kstElapsedDays — 제기 시각(Unix 초)', () {
    test('같은 KST 날짜면 0일', () {
      expect(
        kstElapsedDays(kstAt(2026, 11, 10, 9), now: utcOf(kstAt(2026, 11, 10, 23))),
        0,
      );
    });

    test('자정을 한 번 넘으면 1일 — 9시간밖에 안 지나도', () {
      expect(
        kstElapsedDays(kstAt(2026, 11, 10, 23), now: utcOf(kstAt(2026, 11, 11, 8))),
        1,
      );
    });

    test('기기 시계가 뒤로 가 있어도 음수를 보이지 않는다', () {
      expect(
        kstElapsedDays(kstAt(2026, 11, 10, 12), now: utcOf(kstAt(2026, 11, 8, 12))),
        0,
      );
    });
  });

  group('kstElapsedDaysFromDate — 제기일(날짜 문자열)', () {
    test('사흘 뒤면 3일', () {
      expect(
        kstElapsedDaysFromDate('2026-09-11', now: utcOf(kstAt(2026, 9, 14, 10))),
        3,
      );
    });

    test('같은 날이면 0일', () {
      expect(
        kstElapsedDaysFromDate('2026-09-11', now: utcOf(kstAt(2026, 9, 11, 23))),
        0,
      );
    });

    test('음수는 0', () {
      expect(
        kstElapsedDaysFromDate('2026-09-11', now: utcOf(kstAt(2026, 9, 1, 10))),
        0,
      );
    });

    test('날짜로 읽을 수 없으면 0 — 화면이 깨지지 않는다', () {
      expect(kstElapsedDaysFromDate('날짜 아님'), 0);
      expect(kstElapsedDaysFromDate(''), 0);
    });

    test('기기가 UTC 라도 KST 날짜로 센다', () {
      // KST 9/12 02:00 — UTC 로는 아직 9/11 17:00 이다.
      // 기기 로컬(UTC)로 셌다면 9/11 이라 0일이 나온다.
      expect(
        kstElapsedDaysFromDate('2026-09-11', now: utcOf(kstAt(2026, 9, 12, 2))),
        1,
      );
    });
  });

  group('두 화면이 같은 값을 낸다', () {
    test('같은 이의를 두고 학생·임원 화면의 일수가 일치한다', () {
      // 같은 건: KST 11/10 에 제기. 학생은 Unix 초로, 임원은 날짜 문자열로 받는다.
      final raisedAt = kstAt(2026, 11, 10, 23); // 늦은 밤 제기
      const raisedDate = '2026-11-10';

      for (final probe in [
        kstAt(2026, 11, 10, 23), // 같은 날
        kstAt(2026, 11, 11, 8), // 자정 한 번
        kstAt(2026, 11, 13, 1), // 사흘 뒤
        kstAt(2026, 11, 20, 15), // 열흘 뒤
      ]) {
        final now = utcOf(probe);
        expect(
          objectionElapsedDays(raisedAt, now: now),
          inquiryElapsedDays(raisedDate, now: now),
          reason: '학생과 임원이 같은 이의에 다른 일수를 보여 주면 안 된다 (now=$now)',
        );
      }
    });
  });
}
