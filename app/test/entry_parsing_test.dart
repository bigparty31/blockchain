import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/models/onchain_entry_model.dart';
import 'package:student_council_app/services/student_api_service.dart';

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

    test('모르는 status 는 던지지 않고 「모름」으로 둔다', () {
      // `EntryStatus.fromCode` 를 그대로 부르면 여기서 던진다. 검증 경로에는
      // 그 예외를 받아 줄 자리가 없어서, 던지면 `_verify`·`_verifyAll` 이 중간에
      // 멈추고 그 뒤 항목의 배지가 전부 「검증 중」에 남는다.
      late OnChainEntry c;
      expect(
        () => c = OnChainEntry.fromJson({'amount': 35000, 'status': 'SETTLED'}),
        returnsNormally,
        reason: '검증 루프가 모르는 상태 하나에 멈추면 안 된다',
      );
      expect(c.status, isNull, reason: '모르는 상태는 불일치가 아니라 모름이다');
      expect(c.amount, 35000, reason: '나머지 필드는 그대로 읽혀야 한다');
    });

    test('아는 status 는 그대로 읽는다', () {
      final c = OnChainEntry.fromJson({'amount': 35000, 'status': 'CONFIRMED'});
      expect(c.status, EntryStatus.CONFIRMED);
    });

    test('term 은 학기 코드 그대로 읽는다', () {
      final c = OnChainEntry.fromJson({'amount': 35000, 'term': 20262});
      expect(c.term, 20262);
    });

    test('term 이 없으면 null 이다', () {
      expect(OnChainEntry.fromJson({'amount': 35000}).term, isNull);
    });

    test('응답에 없는 필드는 전부 null 이다 — 지어낸 기본값을 두지 않는다', () {
      // 하나라도 기본값으로 메우면 그 필드를 가진 항목이 「변조 감지」로 뜬다.
      final c = OnChainEntry.fromJson(const {'hash': '0xd8e7c7ae'});
      expect(c.kind, isNull, reason: 'EXPENSE 로 메우면 수입 항목이 어긋난다');
      expect(c.amount, isNull, reason: '0 은 컨트랙트가 금지한 값이다');
      expect(c.budgetId, isNull, reason: '실려 온 0 과 구분해야 한다 (§2.1)');
      expect(c.correctsId, isNull);
      expect(c.occurredAt, isNull);
      expect(c.registrant, isNull, reason: 'address(0) 은 「미처리」라는 다른 뜻이다');
      expect(c.approver, isNull);
      expect(c.status, isNull);
      expect(c.term, isNull);
    });

    test('실려 온 0 · address(0) 은 「없음」이 아니라 「비어 있음」이다', () {
      final c = OnChainEntry.fromJson({
        'amount': 35000,
        'budget_id': 0,
        'corrects_id': 0,
        'approver': OnChainEntry.zeroAddress,
      });
      expect(c.budgetId, 0);
      expect(c.correctsId, 0);
      expect(c.approver, isNotNull);
      expect(c.hasApprover, isFalse, reason: 'address(0) 은 미처리다');
    });
  });

  group('GET /users/wallets 파싱 — 주소 → user id', () {
    // 방향이 중요하다. user id → 주소 하나면 키를 교체한 사람의 옛 주소가
    // 응답에서 사라져, 그 주소로 등록한 과거 항목이 전부 「변조 감지」가 된다.

    test('새 형식을 읽는다 — 키는 주소, 값은 숫자 id', () {
      final map = StudentApiService.parseWalletMap(const {
        '0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc': 2,
        '0x90f79bf6eb2c4f870365e785982e1f101e93b906': 3,
      });
      expect(map, {
        '0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc': 2,
        '0x90f79bf6eb2c4f870365e785982e1f101e93b906': 3,
      });
    });

    test('한 사람이 주소를 여러 개 가져도 다 담는다', () {
      // 키 교체(rotateKey) 후의 모양. 옛 주소로 등록한 과거 항목도 대조된다.
      final map = StudentApiService.parseWalletMap(const {
        '0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc': 2,
        '0x000000000000000000000000000000000000dead': 2,
      });
      expect(map!.values.toSet(), {2});
      expect(map, hasLength(2));
    });

    test('옛 형식(user id → 주소)도 같은 모양으로 뒤집어 읽는다', () {
      // #20 머지 전까지 서버가 내려주는 형식. 머지 순서를 맞추지 않아도
      // 되게 둘 다 받는다 — 한쪽만 올라가면 파싱이 던져서 검증이 아예 안 돈다.
      final map = StudentApiService.parseWalletMap(const {
        '2': '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC',
      });
      expect(map, {'0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc': 2});
    });

    test('주소 키가 체크섬 표기여도 소문자로 담는다', () {
      // 체인에서 읽은 주소(`CHAIN_CLIENT.md` — EIP-55)와 맞춰 보려면 한쪽으로
      // 표기를 모아야 한다. 안 모으면 전부 「매핑에 없는 주소」가 된다.
      final map = StudentApiService.parseWalletMap(const {
        '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC': 2,
      });
      expect(map, {'0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc': 2});
    });

    test('값이 문자열 숫자여도 읽는다', () {
      final map = StudentApiService.parseWalletMap(const {
        '0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc': '2',
      });
      expect(map, {'0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc': 2});
    });

    test('못 읽는 항목 하나 때문에 매핑 전체를 잃지 않는다', () {
      final map = StudentApiService.parseWalletMap(const {
        '0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc': 2,
        '0x90f79bf6eb2c4f870365e785982e1f101e93b906': null,
      });
      expect(map, {'0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc': 2});
    });

    test('하나도 못 읽으면 「매핑 없음」이다', () {
      // 빈 매핑을 돌려주면 「주소가 매핑에 없다」가 되어 사유 문구가 엉뚱해진다.
      expect(StudentApiService.parseWalletMap(const {}), isNull);
      expect(StudentApiService.parseWalletMap(const {'nope': 'nope'}), isNull);
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
