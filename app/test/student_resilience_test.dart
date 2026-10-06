import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/models/membership_model.dart';
import 'package:student_council_app/screens/student/entry_detail_screen.dart';
import 'package:student_council_app/services/student_api_service.dart';

MembershipModel _membership({int? burnedAt}) => MembershipModel(
      id: 1,
      userId: 3,
      termId: 1,
      tokenId: 128,
      commitHash: '0x7d3a9f1c',
      mintedAt: 1788620400,
      burnedAt: burnedAt,
      qrPayload: 'SCA:2026-2:U000003',
    );

/// 서버가 이상한 값을 주거나 아예 대답하지 않을 때, 학생 화면이
/// **조용히 잘못 말하거나 멈추지 않는지** 확인한다.
///
/// 둘 다 눈으로는 안 보이는 회귀다. 화면은 멀쩡히 그려지는데
/// 버튼 하나가 잠겨 있거나, 스피너가 영영 안 꺼진다.
void main() {
  group('이의 제기는 납부가 확인된 경우에만 열린다 (fail-closed)', () {
    // **의도적으로 fail-closed 다.** 이의는 학생회에 답변 의무를 만들고 미답변
    // 카운트로 남는다. 확인되지 않은 사람이 그걸 만들 수 있으면 카운트를 믿을 수
    // 없게 된다. 대가로 조회가 안 되는 동안 납부한 학생도 막히므로, 화면은
    // 「확인할 수 없습니다 + 다시 시도」를 같이 띄운다 (`_ObjectionGate`).

    test('보유가 확인되면 열린다', () {
      final held = MembershipResult.ok(_membership());

      expect(held.held, isTrue);
      expect(canObject(isConfirmed: true, membership: held), isTrue);
      expect(objectionBlock(isConfirmed: true, membership: held),
          ObjectionBlock.none);
    });

    test('조회에 실패하면 막는다 — 다만 「미보유」라고 말하지는 않는다', () {
      const failed = MembershipResult.failed();

      expect(failed.held, isFalse, reason: '실패를 보유로 치지는 않는다');
      expect(canObject(isConfirmed: true, membership: failed), isFalse);
      expect(
        objectionBlock(isConfirmed: true, membership: failed),
        ObjectionBlock.membershipUnknown,
        reason: '조회 실패를 미보유 문구로 안내하면 납부한 학생에게 거짓을 말한다',
      );
    });

    test('아직 확인 중(null)이면 막는다', () {
      expect(canObject(isConfirmed: true, membership: null), isFalse);
      expect(objectionBlock(isConfirmed: true, membership: null),
          ObjectionBlock.membershipUnknown,
          reason: '확인 전은 미보유가 아니라 모름이다');
    });

    test('서버가 「발급받은 적 없음」이라고 분명히 답하면 막는다', () {
      const none = MembershipResult.ok(null);

      // 「분명히 답한」 것은 **`200` + 본문 `null`** 이다 (backend_requests.md §1-4).
      // `404` 는 이쪽으로 오지 않는다 — 경로가 아직 없어서 FastAPI 의 「경로 없음」
      // 404 와 「미보유」 404 가 앱에서 구분되지 않기 때문이다.
      expect(none.failed, isFalse, reason: '200 + null 은 조회 실패가 아니다');
      expect(canObject(isConfirmed: true, membership: none), isFalse);
      expect(objectionBlock(isConfirmed: true, membership: none),
          ObjectionBlock.noMembership,
          reason: '이쪽만 「납부 확인이 필요합니다」로 안내할 수 있다');
    });

    test('회수(burn)된 멤버십은 보유가 아니다', () {
      final burned = MembershipResult.ok(_membership(burnedAt: 1789052400));

      expect(canObject(isConfirmed: true, membership: burned), isFalse);
      expect(objectionBlock(isConfirmed: true, membership: burned),
          ObjectionBlock.noMembership);
    });

    test('확정되지 않은 항목은 SBT 가 있어도 막는다', () {
      final held = MembershipResult.ok(_membership());

      expect(canObject(isConfirmed: false, membership: held), isFalse);
      expect(
        objectionBlock(isConfirmed: false, membership: held),
        ObjectionBlock.notConfirmed,
        reason: '확정 여부를 먼저 본다 — SBT 문구를 띄울 상황이 아니다',
      );
    });
  });

  group('/memberships/me 의 404 는 미보유가 아니라 조회 실패다', () {
    // 리뷰 피드백 1번. 이 경로가 백엔드에 아직 없어서 FastAPI 의 「경로 없음」
    // 404 가 내려오는데, 그것을 미보유로 읽으면 **모든 학생에게 「납부 확인이
    // 필요합니다」가 뜬다.** 두 404 는 앱에서 구분할 수 없으므로 미보유는
    // `200` + 본문으로만 판정한다 (backend_requests.md §1-4).

    final api = StudentApiService();

    tearDown(() => StudentApiService.client = http.Client());

    void respond(int status, String body) {
      StudentApiService.client =
          MockClient((_) async => http.Response(body, status));
    }

    test('404 는 조회 실패(= 모름)다 — 미보유로 단정하지 않는다', () async {
      respond(404, '{"detail":"Not Found"}');
      // 실서버에서 실제로 내려오는 본문이다. 경로가 없을 때 FastAPI 의 기본 404.
      final r = await api.fetchMyMembership();

      expect(r.failed, isTrue, reason: '미보유로 읽으면 전원에게 미납 안내가 뜬다');
      expect(r.held, isFalse, reason: '모름을 보유로 치지도 않는다');
    });

    test('5xx 도 조회 실패다', () async {
      respond(500, 'boom');
      expect((await api.fetchMyMembership()).failed, isTrue);
    });

    test('200 + null 은 미보유다 — 404 와 다르게 다룬다', () async {
      respond(200, 'null');
      final r = await api.fetchMyMembership();

      expect(r.failed, isFalse, reason: '서버가 분명히 대답했다');
      expect(r.held, isFalse);
      expect(r.membership, isNull);
    });

    test('404 에 데모 멤버십을 끼워 넣지 않는다', () async {
      // 서버가 대답한 것을 데모로 메우면, 실서버의 404 에 **가짜 SBT 와 QR 이
      // 진짜처럼 뜬다.** 데모 폴백은 서버에 닿지도 못했을 때만이다.
      respond(404, '{"detail":"Not Found"}');
      final r = await api.fetchMyMembership();

      expect(r.membership, isNull, reason: '행사 입장 QR 이라 더 위험하다');
    });
  });

  group('미보유를 「보유」로 읽지 않는다 (/memberships/me 응답 모양)', () {
    // 뚫리면 **미납 학생에게 「납부 확인됨」 배지와 QR 이 뜨고 이의 버튼이 열린다.**
    // 미보유 응답 모양이 아직 합의 전이라(backend_requests.md §1-4) 어느 모양이
    // 와도 보유로 넘어가지 않아야 한다.

    Map<String, dynamic> real() => {
          'id': 1,
          'user_id': 3,
          'term_id': 1,
          'token_id': 128,
          'commit_hash': '0x7d3a9f1c',
          'minted_at': 1788620400,
          'qr_payload': 'SCA:2026-2:U000003',
        };

    test('벗은 null 은 미보유다', () {
      final r = StudentApiService.parseMembership(null);
      expect(r.failed, isFalse, reason: '서버가 대답했으므로 조회 실패가 아니다');
      expect(r.held, isFalse);
      expect(r.membership, isNull);
    });

    test('래퍼 {"membership": null} 도 미보유다', () {
      final r = StudentApiService.parseMembership({'membership': null});
      expect(r.held, isFalse,
          reason: '{ 로 시작한다는 이유로 보유가 되면 미납자에게 QR 이 뜬다');
      expect(r.membership, isNull);
    });

    test('{"data": null} 도 미보유다', () {
      expect(StudentApiService.parseMembership({'data': null}).held, isFalse);
    });

    test('빈 객체 {} 는 미보유다 — 기본값으로 멤버십을 지어내지 않는다', () {
      final r = StudentApiService.parseMembership(<String, dynamic>{});
      expect(r.held, isFalse,
          reason: 'burned_at 이 없다고 「회수 안 됨」으로 읽으면 안 된다');
    });

    test('id 가 0 이면 미보유다 — 0 은 「없음」으로 예약된 값이다', () {
      final r = StudentApiService.parseMembership(real()..['id'] = 0);
      expect(r.held, isFalse);
    });

    test('멀쩡한 응답은 보유로 읽는다', () {
      final r = StudentApiService.parseMembership(real());
      expect(r.held, isTrue);
      expect(r.membership!.tokenId, 128);
      expect(r.membership!.hasQr, isTrue);
    });

    test('래퍼에 담긴 멀쩡한 멤버십도 읽는다', () {
      final r = StudentApiService.parseMembership({'membership': real()});
      expect(r.held, isTrue, reason: '래퍼로 정해지면 그쪽도 읽혀야 한다');
      expect(r.membership!.tokenId, 128);
    });

    test('회수(burn)된 멤버십은 보유가 아니다', () {
      final r =
          StudentApiService.parseMembership(real()..['burned_at'] = 1789052400);
      expect(r.held, isFalse);
    });

    test('qr_payload 가 비면 보유이지만 QR 은 그리지 않는다', () {
      final r = StudentApiService.parseMembership(real()..['qr_payload'] = '');
      expect(r.held, isTrue, reason: '납부는 확인됐다');
      expect(r.membership!.hasQr, isFalse,
          reason: '찍히지 않는 QR 을 「납부 확인됨」과 함께 띄우면 안 된다');
    });

    test('뜻 모를 본문은 미보유가 아니라 「모름」이다', () {
      expect(StudentApiService.parseMembership('ok').failed, isTrue);
      expect(StudentApiService.parseMembership(7).failed, isTrue);
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
