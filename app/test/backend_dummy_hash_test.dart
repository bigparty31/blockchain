import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/hashing.dart';

/// 백엔드 목업 더미 3건의 `meta_hash` 를 앱이 그대로 재현하는지 본다.
///
/// 값의 출처는 `feat/backend-core` 의 `backend/app/routers/entries.py`
/// (`a6bdf90`, 2026-09-18). **아직 develop 에 머지되지 않았다** — 머지되면
/// 이 테스트가 그대로 목업 서버 연동 검증이 된다.
///
/// 여기서 실패하면 앱과 백엔드의 해시 규격이 갈렸다는 뜻이고,
/// 그때는 학생 화면의 검증 배지가 전부 「변조 감지」로 뜬다.
void main() {
  const fixtures = [
    (
      id: 1,
      amount: 35000,
      counterparty: '한결문구',
      purpose: '신입생 환영회 명찰 및 필기구 구매',
      occurredAt: 1788793200,
      receiptHash:
          '0xabc1234567890abcdef1234567890abcdef1234567890abcdef1234567890abc',
      metaHash:
          '0x24ae73988d927fb39f45eb6024e9ff8ffa19e8501603565bd82710ea8df4b937',
    ),
    (
      id: 2,
      amount: 120000,
      counterparty: '청년피자',
      purpose: '개강총회 다과 주문',
      occurredAt: 1788706800,
      receiptHash:
          '0xdef4567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
      metaHash:
          '0x622fc1b357c04032e65bc1855c73aaff6d519464d69bf22b10761f3b26a1b793',
    ),
    // 수입 건 — 영수증이 없다. receipt_hash 자리는 빈 문자열이고
    // 구분자는 그대로 남아 preimage 가 `␟` 로 끝난다 (HASHING.md §1).
    (
      id: 3,
      amount: 5000000,
      counterparty: '컴퓨터공학과 학생회비 일괄 납부',
      purpose: '2026-2학기 학과 학생회비 수납',
      occurredAt: 1788620400,
      receiptHash: null,
      metaHash:
          '0x74c9740556d857575586251e71fa24091ffaece5c01c4f889d7c1224ce7af3a9',
    ),
  ];

  for (final f in fixtures) {
    test('백엔드 더미 #${f.id} 의 meta_hash 를 앱이 그대로 계산한다', () {
      final computed = Hashing.metaHash(
        amount: f.amount,
        counterparty: f.counterparty,
        purpose: f.purpose,
        occurredAt: f.occurredAt,
        receiptHash: f.receiptHash,
      );

      expect(
        Hashing.hashEquals(computed, f.metaHash),
        isTrue,
        reason: '앱 계산값 $computed / 서버값 ${f.metaHash}',
      );
    });

    test('백엔드 더미 #${f.id} 의 occurred_at 은 KST 자정이다', () {
      expect(Hashing.isKstMidnight(f.occurredAt), isTrue);
    });
  }
}
