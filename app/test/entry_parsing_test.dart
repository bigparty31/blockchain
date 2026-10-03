import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/models/onchain_entry_model.dart';

/// `status ?? PENDING` 을 걷어낸 자리를 지킨다 (3주차 계획 — 장정아 ①).
///
/// 없는 값을 `PENDING` 으로 메우면 **둘 다 거짓말이 된다.**
/// - API 쪽: 체인에 안 올라간 초안이 학생 목록에 「승인대기」로 섞인다
/// - 온체인 쪽: 지어낸 `PENDING` 과 대조해 확정 항목이 「상태 불일치」로 뜬다
///
/// 둘 다 화면은 멀쩡해 보이고 값만 틀리는 종류라 테스트로 못 박아 둔다.
void main() {
  Map<String, dynamic> entryJson({Object? status = 'CONFIRMED'}) => {
        'id': 2,
        'term_id': 1,
        'kind': 'EXPENSE',
        'amount': 35000,
        'counterparty': '한결문구',
        'purpose': '신입생 환영회 명찰 및 필기구 구매',
        'occurred_at': 1788793200,
        'meta_hash': 'd8e7c7ae0471a319b0c7546f',
        'status': status,
        'created_by': 2,
      };

  group('EntryModel.fromJson — 초안을 PENDING 으로 둔갑시키지 않는다', () {
    test('status 가 없으면 던진다', () {
      expect(
        () => EntryModel.fromJson(entryJson(status: null)),
        throwsA(isA<FormatException>()),
        reason: '초안(status IS NULL)은 학생 앱에 내려오면 안 되는 값이다',
      );
    });

    test('status 가 있으면 그대로 읽는다', () {
      expect(EntryModel.fromJson(entryJson()).status, EntryStatus.CONFIRMED);
    });

    test('모르는 코드는 PENDING 으로 떨어뜨리지 않고 던진다', () {
      expect(
        () => EntryModel.fromJson(entryJson(status: 'SETTLED')),
        throwsA(isA<ArgumentError>()),
        reason: '백엔드가 상태를 늘렸을 때 조용히 「승인대기」라고 말하면 안 된다',
      );
    });
  });

  group('OnChainEntry.fromJson', () {
    test('status 가 없으면 PENDING 이 아니라 「모름」이다', () {
      final c = OnChainEntry.fromJson({'amount': 35000});
      expect(c.status, isNull,
          reason: '지어낸 PENDING 과 대조하면 확정 항목이 어긋난다');
    });

    test('term 은 학기 코드 그대로 읽는다', () {
      final c = OnChainEntry.fromJson({'amount': 35000, 'term': 20262});
      expect(c.term, 20262);
    });

    test('term 이 없으면 null 이다', () {
      expect(OnChainEntry.fromJson({'amount': 35000}).term, isNull);
    });
  });

  test('term_code 와 term_id 는 다른 값이다', () {
    final e = EntryModel.fromJson({
      ...entryJson(),
      'term_id': 1,
      'term_code': 20262,
    });

    expect(e.termId, 1);
    expect(e.termCode, 20262);
    expect(e.termId, isNot(e.termCode),
        reason: '이 둘을 바꿔 쓰면 모든 항목이 변조 판정된다');
  });
}
