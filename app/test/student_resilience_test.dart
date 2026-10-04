import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/screens/student/entry_detail_screen.dart';
import 'package:student_council_app/services/student_api_service.dart';

/// 서버가 이상한 값을 주거나 아예 대답하지 않을 때, 학생 화면이
/// **조용히 잘못 말하거나 멈추지 않는지** 확인한다.
///
/// 둘 다 눈으로는 안 보이는 회귀다. 화면은 멀쩡히 그려지는데
/// 버튼 하나가 잠겨 있거나, 스피너가 영영 안 꺼진다.
void main() {
  group('SBT 조회 실패는 「미보유」가 아니라 「모름」이다', () {
    test('조회에 실패하면 이의 제기를 막지 않는다', () {
      const failed = MembershipResult.failed();

      expect(failed.held, isFalse, reason: '실패를 보유로 치지는 않는다');
      expect(
        canObject(isConfirmed: true, membership: failed),
        isTrue,
        reason: '서버 장애 때 납부한 학생이 이의를 제기하지 못하면 안 된다',
      );
    });

    test('아직 확인 중(null)이어도 막지 않는다', () {
      expect(canObject(isConfirmed: true, membership: null), isTrue);
    });

    test('서버가 「발급받은 적 없음」이라고 분명히 답하면 막는다', () {
      const none = MembershipResult.ok(null);

      expect(none.failed, isFalse, reason: '404 는 조회 실패가 아니다');
      expect(
        canObject(isConfirmed: true, membership: none),
        isFalse,
        reason: '서버가 대답한 미보유는 막아야 한다',
      );
    });

    test('확정되지 않은 항목은 SBT 가 있어도 막는다', () {
      expect(
        canObject(isConfirmed: false, membership: const MembershipResult.failed()),
        isFalse,
      );
    });
  });

  group('모르는 status 하나가 목록 전체를 막지 않는다', () {
    late StudentApiService api;

    setUp(() => api = StudentApiService());

    Map<String, dynamic> entryJson(int id, String status) => {
          'id': id,
          'term_id': 1,
          'kind': 'EXPENSE',
          'amount': 10000,
          'counterparty': '한결문구',
          'purpose': '물품 구매',
          'occurred_at': 1757862000,
          'status': status,
        };

    test('docs/enums.md 에 없는 status 는 건너뛰고 나머지를 돌려준다', () {
      final parsed = api.parseEntries([
        entryJson(1, 'CONFIRMED'),
        entryJson(2, 'SETTLED'), // enums.md 에 없는 값
        entryJson(3, 'PENDING'),
      ]);

      expect(parsed.map((e) => e.id), [1, 3],
          reason: '한 건이 깨져도 나머지는 보여야 한다');
      expect(api.skippedEntryCount, 1);
    });

    test('건너뛴 건은 PENDING 으로 메우지 않는다', () {
      final parsed = api.parseEntries([entryJson(2, 'SETTLED')]);

      expect(parsed, isEmpty,
          reason: '모르는 상태를 「승인대기」라고 잘못 말하면 안 된다');
      expect(parsed.any((e) => e.status == EntryStatus.PENDING), isFalse);
    });

    test('초안(status IS NULL)은 정상 제외라 건너뛴 건수에 세지 않는다', () {
      final draft = entryJson(9, 'PENDING')..['status'] = null;

      final parsed = api.parseEntries([entryJson(1, 'CONFIRMED'), draft]);

      expect(parsed.map((e) => e.id), [1]);
      expect(api.skippedEntryCount, 0,
          reason: '초안 제외는 오류가 아니라 규칙이다');
    });

    test('멀쩡한 응답이면 건너뛴 건수가 0 이다', () {
      api.parseEntries([entryJson(1, 'CONFIRMED'), entryJson(2, 'REJECTED')]);

      expect(api.skippedEntryCount, 0);
    });

    test('건너뛴 건수는 조회할 때마다 다시 센다', () {
      api.parseEntries([entryJson(2, 'SETTLED')]);
      expect(api.skippedEntryCount, 1);

      api.parseEntries([entryJson(1, 'CONFIRMED')]);
      expect(api.skippedEntryCount, 0, reason: '이전 조회 결과가 남으면 안 된다');
    });
  });
}
