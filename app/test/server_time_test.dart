import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/format.dart';
import 'package:student_council_app/services/api_service.dart';

void main() {
  group('Fmt.parseServerTime — 서버가 주는 시각을 기기 시간대와 무관하게 읽는다 (#111 리뷰)', () {
    test('시간대가 없는 값은 한국 시간이다', () {
      expect(Fmt.parseServerTime('2026-03-01T00:00:00').isAtSameMomentAs(DateTime.utc(2026, 2, 28, 15)), isTrue);
    });

    test('날짜만 있는 값은 그날 한국 시간 0시다', () {
      expect(Fmt.parseServerTime('2026-03-01').isAtSameMomentAs(DateTime.utc(2026, 2, 28, 15)), isTrue);
    });

    test('Z·오프셋이 있으면 그 시각을 따른다', () {
      expect(Fmt.parseServerTime('2026-03-01T00:00:00Z').isAtSameMomentAs(DateTime.utc(2026, 3, 1)), isTrue);
      expect(Fmt.parseServerTime('2026-03-01T09:00:00+09:00').isAtSameMomentAs(DateTime.utc(2026, 3, 1)), isTrue);
      expect(Fmt.parseServerTime('2026-03-01T00:00:00.5').isAtSameMomentAs(DateTime.utc(2026, 2, 28, 15, 0, 0, 500)), isTrue);
    });
  });

  test('fetchCurrentTermId — 시간대 없는 학기 경계도 한국 시간으로 비교한다', () async {
    ApiService.useDemoData = false;
    addTearDown(() => ApiService.useDemoData = true);
    ApiService.client = MockClient((req) async => http.Response(
        '[{"id":1,"started_at":"2026-01-01T00:00:00","ended_at":"2026-02-28T23:59:59"},'
        '{"id":2,"started_at":"2026-03-01T00:00:00","ended_at":"2026-08-31T23:59:59"}]',
        200,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    // 한국 시간 3월 1일 00:30 — 기기가 UTC 라도 학기 2
    final id = await ApiService().fetchCurrentTermId(now: DateTime.utc(2026, 2, 28, 15, 30));
    expect(id, 2);
  });
}
