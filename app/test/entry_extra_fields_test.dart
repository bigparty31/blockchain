import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/screens/council/approval_list_screen.dart';
import 'package:student_council_app/screens/council/my_entries_screen.dart';

/// 서버 `EntryResponse` 의 보강 필드 — `duplicate_of`·`block_reason`·`creator_name` (보드 11/3 「응답 필드 보강」).
///
/// 서버가 아직 이 필드를 안 내려주는 동안(옛 서버·머지 전)에도 앱이 깨지지 않아야 하고,
/// **모르는 값을 그럴듯한 값으로 바꿔 보여 주지 않는다** — 차단 사유를 잘못 알려 주면 총무가 엉뚱한 조치를 한다.
void main() {
  Map<String, dynamic> json([Map<String, dynamic> extra = const {}]) => {
        'id': 7,
        'term_id': 1,
        'term_code': 20262,
        'kind': 'EXPENSE',
        'amount': 35000,
        'counterparty': '한결문구',
        'purpose': '신입생 환영회 명찰',
        'budget_id': 1,
        'occurred_at': 1790694000,
        'meta_hash': '0x00',
        'status': 'PENDING',
        'created_by': 2,
        ...extra,
      };

  group('EntryModel.fromJson', () {
    test('필드가 없는 응답(옛 서버)은 전부 null 이다', () {
      final e = EntryModel.fromJson(json());
      expect(e.duplicateOf, isNull);
      expect(e.blockReason, isNull);
      expect(e.creatorName, isNull);
    });

    test('세 필드를 그대로 읽는다', () {
      final e = EntryModel.fromJson(json({
        'duplicate_of': 3,
        'block_reason': 'BUDGET_EXPIRED',
        'creator_name': '김총무',
        'status': 'BLOCKED',
      }));
      expect(e.duplicateOf, 3);
      expect(e.blockReason, BlockReason.BUDGET_EXPIRED);
      expect(e.creatorName, '김총무');
    });

    test('모르는 block_reason 은 잔량 부족 등으로 바꾸지 않고 null 이다', () {
      for (final bad in ['SOMETHING_NEW', '', ' ', 'budget_exceeded', 7, true]) {
        expect(EntryModel.fromJson(json({'block_reason': bad})).blockReason, isNull, reason: '$bad');
      }
    });

    test('duplicate_of 가 정수가 아니면 null 이다', () {
      for (final bad in ['3', 3.5, true, '']) {
        expect(EntryModel.fromJson(json({'duplicate_of': bad})).duplicateOf, isNull, reason: '$bad');
      }
    });

    test('creator_name 은 앞뒤 공백을 걷고, 비었으면 null 이다', () {
      expect(EntryModel.fromJson(json({'creator_name': '  김총무 '})).creatorName, '김총무');
      expect(EntryModel.fromJson(json({'creator_name': '   '})).creatorName, isNull);
      expect(EntryModel.fromJson(json({'creator_name': 12})).creatorName, isNull);
    });
  });

  group('승인 화면', () {
    test('카드 재료에 duplicateOf·creatorName 이 실린다', () {
      final item = approvalItemFromEntry(EntryModel.fromJson(json({
        'ocr_status': 'DUPLICATE',
        'duplicate_of': 3,
        'creator_name': '김총무',
      })));
      expect(item['duplicateOf'], 3);
      expect(item['creatorName'], '김총무');
    });

    test('서버가 이름을 주면 등록자는 이름, 안 주면 번호로 적는다', () {
      final named = approvalItemFromEntry(EntryModel.fromJson(json({'creator_name': '김총무'})));
      final unnamed = approvalItemFromEntry(EntryModel.fromJson(json()));
      expect(registrantLabel(named), '김총무');
      expect(registrantLabel(unnamed), '사용자 #2');
    });

    test('목업 건(서버 원본 없음)은 지금처럼 김총무', () {
      expect(registrantLabel(const {'createdBy': 2}), '김총무');
    });
  });

  group('내 등록 현황 — 차단 건', () {
    MyEntryItem blocked(Map<String, dynamic> extra) =>
        MyEntryItem.fromEntry(EntryModel.fromJson(json({'status': 'BLOCKED', ...extra})), const []);

    test('사유를 알면 사유를 적는다 — 잔량 부족은 증액 안내까지', () {
      final note = blocked({'block_reason': 'BUDGET_EXCEEDED'}).note!;
      expect(note, contains('잔량 부족'));
      expect(note, contains('증액'));
    });

    test('집행 마감이 지난 건에 증액을 권하지 않는다', () {
      final note = blocked({'block_reason': 'BUDGET_EXPIRED'}).note!;
      expect(note, contains('집행 마감 경과'));
      expect(note, isNot(contains('증액')));
    });

    test('존재하지 않는 예산이면 그렇게 적는다', () {
      expect(blocked({'block_reason': 'BUDGET_NOT_FOUND'}).note, contains('존재하지 않는 예산'));
    });

    test('사유를 못 받았으면 지금까지의 일반 안내를 그대로 쓴다', () {
      expect(blocked({}).note, contains('예산 검사에서 차단됐어요'));
    });
  });
}
