import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/entry_verifier.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/models/onchain_entry_model.dart';
import 'package:student_council_app/services/student_api_service.dart';

/// PR #130 리뷰 지적의 회귀 시험 — codex-loop 1·2차 네 건과 리뷰(이승호) 3번.
///
/// 전부 **화면이 멀쩡해 보이는 채로 틀린 것을 말하는** 종류라 눈으로는 안 잡힌다.
void main() {
  const auditor = '0x90f79bf6eb2c4f870365e785982e1f101e93b906';
  const wallets = {auditor: 3};

  group('경고 없는 확정인데 장부에 사유가 있으면 통과시키지 않는다', () {
    /// 체인은 「경고 없이 확정」이라 사유 해시가 `bytes32(0)` 이다. 그런데 DB 에는
    /// `warning_ack_reason` 이 달려 있다. 그 글은 체인에 해시가 없어 재계산할 대상이
    /// 없고 `meta_hash` 에도 안 들어간다 — 통과로 두면 **검증된 적 없는 사유가 상세
    /// 화면에 뜨고**, 나중에 끼워 넣어도 배지는 초록이다.
    EntryModel entryWith(String? reason) => EntryModel(
          id: 7,
          termId: 1,
          termCode: 20262,
          kind: EntryKind.EXPENSE,
          amount: 48000,
          counterparty: '한결문구',
          purpose: '명찰 제작',
          budgetId: 1,
          occurredAt: 1794841200,
          metaHash: '0x${'a' * 64}',
          status: EntryStatus.CONFIRMED,
          createdBy: 2,
          approvedBy: 3,
          warningAckReason: reason,
        );

    OnChainEntry noWarningChain() => OnChainEntry(
          hash: '0x${'a' * 64}',
          amount: 48000,
          kind: EntryKind.EXPENSE,
          status: EntryStatus.CONFIRMED,
          occurredAt: 1794841200,
          term: 20262,
          budgetId: 1,
          correctsId: 0,
          registrant: '0x0000000000000000000000000000000000000001',
          approver: auditor,
          hadWarning: false,
          reasonHash: OnChainEntry.zeroHash,
        );

    CheckState stateOf(String? reason) => EntryVerifier.verify(
          entryWith(reason),
          onChain: noWarningChain(),
          userIdByAddress: wallets,
        ).fieldChecks.firstWhere((f) => f.label == '승인·반려 사유').state;

    test('사유가 달려 있으면 불일치다', () {
      expect(stateOf('나중에 끼워 넣은 사유'), CheckState.failed);
    });

    test('사유가 없으면 그대로 통과다', () {
      expect(stateOf(null), CheckState.passed);
    });

    test('빈 문자열도 사유가 없는 것으로 본다', () {
      expect(stateOf(''), CheckState.passed);
    });
  });

  group('계좌 대조 404 — 업로드 없음만 정상으로 본다', () {
    http.Response notFound(String detail) => http.Response(
          jsonEncode({'detail': detail}),
          404,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );

    Future<bool> notUploadedFor(String detail) async {
      StudentApiService.client = MockClient((req) async {
        if (req.url.path.endsWith('/entries')) {
          return http.Response('[]', 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }
        return notFound(detail);
      });
      await StudentApiService().fetchEntries(); // 실서버 모드로 들어간다
      return (await StudentApiService().fetchLatestSnapshot()).notUploadedYet;
    }

    tearDown(() => StudentApiService.client = http.Client());

    test('업로드가 없다는 404 는 「아직 안 올라옴」이다', () async {
      expect(await notUploadedFor('아직 업로드된 계좌 거래내역이 없습니다.'), isTrue);
    });

    /// 서버는 진행 중인 학기가 없을 때도 404 다. 그것까지 정상이라고 말하면
    /// **설정이 잘못된 상태가 학기 초처럼 보인다.**
    test('학기가 없다는 404 는 고장 쪽으로 둔다', () async {
      expect(await notUploadedFor('진행 중인 학기가 없습니다.'), isFalse);
    });

    test('뜻을 모르는 404 도 고장 쪽이다', () async {
      expect(await notUploadedFor('Not Found'), isFalse);
    });
  });

  group('현재 학기를 서버에서 고른다', () {
    tearDown(() => StudentApiService.client = http.Client());

    String termsJson(List<Map<String, Object>> terms) => jsonEncode(terms);

    void serve(String body) {
      StudentApiService.client = MockClient((req) async => http.Response(
            body,
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));
    }

    test('기간에 드는 학기의 term_code 를 고른다', () async {
      serve(termsJson([
        {
          'id': 1,
          'term_code': 20261,
          'started_at': '2026-03-01T00:00:00Z',
          'ended_at': '2026-08-31T23:59:59Z',
        },
        {
          'id': 2,
          'term_code': 20262,
          'started_at': '2026-09-01T00:00:00Z',
          'ended_at': '2027-02-28T23:59:59Z',
        },
      ]));

      expect(
        await StudentApiService()
            .fetchCurrentTermCode(now: DateTime.utc(2026, 11, 19)),
        20262,
      );
    });

    /// 아래 네 개는 codex-loop 2차 지적 — 앱과 서버의 학기 선택 규칙이 달라서,
    /// **장부 합계와 계좌 차액이 서로 다른 학기를 말하는** 경우들이다.
    /// 기준은 `backend/app/services/membership.py` 의 `current_term` 이다.

    test('학기 사이 공백에서는 다음 학기가 등록돼 있어도 이전 학기다', () async {
      // 서버는 「이미 시작한」 학기만 후보로 둔다. id 가 큰 쪽을 고르면 아직 시작도
      // 안 한 다음 학기가 잡혀서, 계좌 스냅샷(서버 기준)과 합계가 갈린다.
      serve(termsJson([
        {
          'id': 2,
          'term_code': 20262,
          'started_at': '2026-09-01T00:00:00Z',
          'ended_at': '2027-02-28T23:59:59Z',
        },
        {
          'id': 3,
          'term_code': 20271,
          'started_at': '2027-04-01T00:00:00Z',
          'ended_at': '2027-08-31T23:59:59Z',
        },
      ]));

      expect(
        await StudentApiService()
            .fetchCurrentTermCode(now: DateTime.utc(2027, 3, 15)),
        20262,
      );
    });

    test('시간대 없는 시각은 서버처럼 UTC 로 읽는다 — 시작 경계 (#130 Codex 3차)', () async {
      // SQLite 는 시간대를 빼고 내려준다. 서버는 이를 UTC 로 본다.
      // 2027-03-01T00:00 UTC 전인 02-28T18:00Z 는 서버 기준 아직 이전 학기다
      // (KST 로 읽으면 이미 03-01 03:00 이라 다음 학기로 갈린다).
      serve(termsJson([
        {'id': 2, 'term_code': 20262, 'started_at': '2026-09-01T00:00:00', 'ended_at': '2027-02-28T23:59:59'},
        {'id': 3, 'term_code': 20271, 'started_at': '2027-03-01T00:00:00', 'ended_at': '2027-08-31T23:59:59'},
      ]));

      expect(
        await StudentApiService()
            .fetchCurrentTermCode(now: DateTime.utc(2027, 2, 28, 18)),
        20262,
      );
    });

    test('시간대 없는 시각은 서버처럼 UTC 로 읽는다 — 시작 직후', () async {
      serve(termsJson([
        {'id': 2, 'term_code': 20262, 'started_at': '2026-09-01T00:00:00', 'ended_at': '2027-02-28T23:59:59'},
        {'id': 3, 'term_code': 20271, 'started_at': '2027-03-01T00:00:00', 'ended_at': '2027-08-31T23:59:59'},
      ]));

      expect(
        await StudentApiService()
            .fetchCurrentTermCode(now: DateTime.utc(2027, 3, 1, 0, 30)),
        20271,
      );
    });

    test('parseTermTime — 시간대가 있으면 그대로, 없으면 UTC', () {
      expect(StudentApiService.parseTermTime('2027-03-01T00:00:00'), DateTime.utc(2027, 3, 1));
      expect(StudentApiService.parseTermTime('2027-03-01'), DateTime.utc(2027, 3, 1));
      expect(StudentApiService.parseTermTime('2027-03-01T09:00:00+09:00'), DateTime.utc(2027, 3, 1));
      expect(StudentApiService.parseTermTime('2027-03-01T00:00:00Z'), DateTime.utc(2027, 3, 1));
    });

    test('기간이 겹치면 나중에 시작한 학기다', () async {
      // 배열 순서상 첫 번째가 아니라 시작일이 가장 늦은 것을 고른다 (서버의 max 와 같다).
      serve(termsJson([
        {
          'id': 2,
          'term_code': 20262,
          'started_at': '2026-09-01T00:00:00Z',
          'ended_at': '2027-02-28T23:59:59Z',
        },
        {
          'id': 3,
          'term_code': 20271,
          'started_at': '2026-12-01T00:00:00Z',
          'ended_at': '2027-05-31T23:59:59Z',
        },
      ]));

      expect(
        await StudentApiService()
            .fetchCurrentTermCode(now: DateTime.utc(2027, 1, 15)),
        20271,
      );
    });

    test('아직 시작하지 않은 학기뿐이면 null 이다', () async {
      // null 이면 화면이 **거르지 않는다.** 시작도 안 한 학기로 거르면 합계가 통째로 0 이다.
      serve(termsJson([
        {
          'id': 3,
          'term_code': 20271,
          'started_at': '2027-04-01T00:00:00Z',
          'ended_at': '2027-08-31T23:59:59Z',
        },
      ]));

      expect(
        await StudentApiService()
            .fetchCurrentTermCode(now: DateTime.utc(2026, 11, 19)),
        isNull,
      );
    });

    test('시각을 못 읽는 학기뿐이면 null 이다', () async {
      // 서버와 같은 기준으로 고를 수가 없다 — 모르면 거르지 않는 쪽으로 둔다.
      serve(termsJson([
        {'id': 2, 'term_code': 20262, 'started_at': '언제인지 모름', 'ended_at': '모름'},
      ]));

      expect(await StudentApiService().fetchCurrentTermCode(), isNull);
    });

    test('끝난 학기만 있으면 시작일이 가장 늦은 학기다', () async {
      serve(termsJson([
        {
          'id': 1,
          'term_code': 20261,
          'started_at': '2026-03-01T00:00:00Z',
          'ended_at': '2026-08-31T23:59:59Z',
        },
        {
          'id': 2,
          'term_code': 20262,
          'started_at': '2026-09-01T00:00:00Z',
          'ended_at': '2027-02-28T23:59:59Z',
        },
      ]));

      expect(
        await StudentApiService()
            .fetchCurrentTermCode(now: DateTime.utc(2030, 1, 1)),
        20262,
      );
    });

    /// 못 읽으면 null 이고, 화면은 그때 **거르지 않는다.** 모르는 채로 거르면
    /// 멀쩡한 항목이 합계에서 사라진다.
    test('못 읽으면 null 이다', () async {
      StudentApiService.client =
          MockClient((_) async => http.Response('{}', 500));
      expect(await StudentApiService().fetchCurrentTermCode(), isNull);
    });
  });

  /// 리뷰(이승호) 3번 — `had_warning` 이 빠진 응답에서 **경고 무시 확정이 「불일치」로
  /// 보이던** 것. 체인에 0 이 아닌 사유 해시가 남아 있는데도 `had_warning` 만 보고
  /// 「경고 없는 확정」 분기로 가서, 멀쩡한 항목에 빨간 배지가 붙었다.
  group('had_warning 이 없으면 사유 해시로 판단한다', () {
    const reason = '예산 항목이 달라도 행사 전날이라 집행했다';

    EntryModel confirmedWith(String? warningAckReason) => EntryModel(
          id: 11,
          termId: 1,
          termCode: 20262,
          kind: EntryKind.EXPENSE,
          amount: 48000,
          counterparty: '한결문구',
          purpose: '명찰 제작',
          budgetId: 1,
          occurredAt: 1794841200,
          metaHash: '0x${'a' * 64}',
          status: EntryStatus.CONFIRMED,
          createdBy: 2,
          approvedBy: 3,
          warningAckReason: warningAckReason,
        );

    OnChainEntry chainWith({required String? reasonHash}) => OnChainEntry(
          hash: '0x${'a' * 64}',
          amount: 48000,
          kind: EntryKind.EXPENSE,
          status: EntryStatus.CONFIRMED,
          occurredAt: 1794841200,
          term: 20262,
          budgetId: 1,
          correctsId: 0,
          registrant: '0x0000000000000000000000000000000000000001',
          approver: auditor,
          hadWarning: null, // 서버가 이 필드를 빠뜨린 응답
          reasonHash: reasonHash,
        );

    FieldCheck checkOf(EntryModel e, OnChainEntry c) => EntryVerifier.verify(
          e,
          onChain: c,
          userIdByAddress: wallets,
        ).fieldChecks.firstWhere((f) => f.label == '승인·반려 사유');

    test('사유 해시가 0 이 아니고 원문이 맞으면 통과다', () {
      final check = checkOf(
        confirmedWith(reason),
        chainWith(reasonHash: Hashing.textHash(reason)),
      );
      expect(check.state, CheckState.passed);
    });

    test('사유 해시가 0 이 아니고 원문이 다르면 불일치다', () {
      final check = checkOf(
        confirmedWith('나중에 고친 사유'),
        chainWith(reasonHash: Hashing.textHash(reason)),
      );
      expect(check.state, CheckState.failed);
    });

    /// 체인에 사유 해시는 있는데 원문을 못 받았다 — 재계산할 것이 없으니
    /// 불일치가 아니라 「모름」이다.
    test('사유 해시가 0 이 아닌데 원문이 없으면 모름이다', () {
      final check = checkOf(
        confirmedWith(null),
        chainWith(reasonHash: Hashing.textHash(reason)),
      );
      expect(check.state, CheckState.unavailable);
    });

    /// 여기서는 판단이 바뀌지 않는다. 체인이 「사유 없음」(0)이라고 말하는데 장부에
    /// 사유가 있으면, `had_warning` 을 몰라도 검증된 적 없는 글이다.
    test('사유 해시가 0 인데 장부에 사유가 있으면 불일치다', () {
      final check =
          checkOf(confirmedWith(reason), chainWith(reasonHash: OnChainEntry.zeroHash));
      expect(check.state, CheckState.failed);
    });

    test('사유 해시가 0 이고 장부에도 사유가 없으면 통과다', () {
      final check =
          checkOf(confirmedWith(null), chainWith(reasonHash: OnChainEntry.zeroHash));
      expect(check.state, CheckState.passed);
    });

    /// `reason_hash` 자체가 없는 응답은 전과 같다 — 사유가 없는 평범한 확정을
    /// 「부분 검증」으로 떨어뜨리지 않는다.
    test('사유 해시가 아예 없으면 전과 같이 본다', () {
      expect(
        checkOf(confirmedWith(null), chainWith(reasonHash: null)).state,
        CheckState.notApplicable,
      );
      expect(
        checkOf(confirmedWith(reason), chainWith(reasonHash: null)).state,
        CheckState.unavailable,
      );
    });
  });
}
