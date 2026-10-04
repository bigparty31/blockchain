import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/entry_merge.dart';
import 'package:student_council_app/core/entry_verifier.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/core/term_info.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/models/onchain_entry_model.dart';

/// 정정 병합(S9)과 3단계 검증(S4)의 동작을 고정한다.
void main() {
  final d0908 = Hashing.kstMidnightOf(2026, 9, 8);
  final d0910 = Hashing.kstMidnightOf(2026, 9, 10);

  group('정정 병합 — 정정 항목의 금액은 증감분이다', () {
    final original = _entry(
      id: 4,
      amount: 50000,
      counterparty: '대학마트',
      purpose: '체육대회 간식 구매',
      occurredAt: d0910,
      budgetId: 1,
    );
    final correction = _entry(
      id: 5,
      amount: -20000,
      counterparty: '대학마트',
      purpose: '입력 오류 정정',
      occurredAt: d0910,
      budgetId: 1,
      correctsEntryId: 4,
      correctionReason: CorrectionReason.INPUT_ERROR,
    );

    test('원본과 정정이 한 체인으로 묶인다', () {
      final chains = EntryMerge.fold([original, correction]);
      expect(chains, hasLength(1));
      expect(chains.single.original.id, 4);
      expect(chains.single.corrections.map((c) => c.id), [5]);
    });

    test('최종 금액은 원본 + 증감분이다', () {
      final chain = EntryMerge.fold([original, correction]).single;
      expect(chain.finalAmount, 30000);
      expect(chain.supersededAmount, 50000);
      expect(chain.latestReason, CorrectionReason.INPUT_ERROR);
    });

    test('합계는 확정 항목을 그냥 다 더하면 된다 — 이중 계상되지 않는다', () {
      final entries = [original, correction];
      expect(EntryMerge.totalExpense(entries), 30000);
      expect(EntryMerge.ledgerBalance(entries), -30000);
    });

    test('대기 중인 정정은 금액에 반영하지 않는다', () {
      final pending = _entry(
        id: 6,
        amount: -5000,
        counterparty: '대학마트',
        purpose: '추가 정정',
        occurredAt: d0910,
        budgetId: 1,
        correctsEntryId: 5,
        correctionReason: CorrectionReason.RECEIPT_RECHECK,
        status: EntryStatus.PENDING,
      );

      final chain = EntryMerge.fold([original, correction, pending]).single;
      // 승인 전 금액이 학생 화면 합계에 섞이면 안 된다.
      expect(chain.finalAmount, 30000);
      expect(EntryMerge.totalExpense([original, correction, pending]), 30000);
    });

    test('정정의 정정도 한 체인으로 이어진다', () {
      final second = _entry(
        id: 6,
        amount: -5000,
        counterparty: '대학마트',
        purpose: '재정정',
        occurredAt: d0910,
        budgetId: 1,
        correctsEntryId: 5,
        correctionReason: CorrectionReason.RECEIPT_RECHECK,
      );

      final chain = EntryMerge.fold([original, correction, second]).single;
      expect(chain.corrections.map((c) => c.id), [5, 6]);
      expect(chain.finalAmount, 25000);
    });

    test('원본이 목록에 없는 고아 정정도 사라지지 않는다', () {
      final chains = EntryMerge.fold([correction]);
      expect(chains, hasLength(1));
      expect(chains.single.original.id, 5);
    });
  });

  group('3단계 검증', () {
    final receiptBytes = utf8.encode('receipt-bytes');
    final receiptHash = Hashing.fileHash(receiptBytes);

    const registrant = '0x71C7656EC7ab88b098defB751B7401B5f6d8976F';
    const approver = '0x2546BcD3c84621e976D8185a91A922aE77ECEc30';
    // `GET /users/wallets` 와 같은 모양 — **주소(소문자) → user id** 다.
    // 반대 방향이면 키를 교체한 사람의 옛 주소가 응답에서 사라져, 그 주소로
    // 등록한 과거 항목이 전부 「등록자 불일치 = 변조 감지」로 뒤집힌다.
    final wallets = {
      registrant.toLowerCase(): 2,
      approver.toLowerCase(): 3,
    };

    EntryModel soundEntry({int? termCode = TermInfo.currentTermCode}) => _entry(
          id: 2,
          termCode: termCode,
          amount: 35000,
          counterparty: '한결문구',
          purpose: '신입생 환영회 명찰 및 필기구 구매',
          occurredAt: d0908,
          budgetId: 2,
          receiptHash: receiptHash,
          approvedBy: 3,
        );

    OnChainEntry chainOf(EntryModel e, {int? budgetId}) => OnChainEntry(
          hash: e.metaHash,
          amount: e.amount,
          kind: e.kind,
          status: e.status,
          occurredAt: e.occurredAt,
          term: e.termCode,
          budgetId: budgetId ?? e.budgetId ?? 0,
          correctsId: e.correctsEntryId ?? 0,
          registrant: '0x71C7656EC7ab88b098defB751B7401B5f6d8976F',
          approver: '0x2546BcD3c84621e976D8185a91A922aE77ECEc30',
        );

    test('세 단계를 다 통과하면 verified', () {
      final e = soundEntry();
      final r = EntryVerifier.verify(
        e,
        onChain: chainOf(e),
        receiptBytes: receiptBytes,
        userIdByAddress: wallets,
      );
      expect(r.status, VerificationStatus.verified);
      expect(r.hashState, CheckState.passed);
      expect(r.receipt.state, CheckState.passed);
      expect(r.mismatches, isEmpty);
    });

    test('지갑 매핑이 없으면 등록자를 대조하지 못해 partial 에 머문다', () {
      // 「누가 등록하고 누가 승인했는가」는 해시로 덮이지 않으므로
      // 매핑이 없으면 확인했다고 말할 수 없다.
      final e = soundEntry();
      final r = EntryVerifier.verify(
        e,
        onChain: chainOf(e),
        receiptBytes: receiptBytes,
      );
      expect(r.status, VerificationStatus.partial);
      expect(
        r.fieldChecks.firstWhere((f) => f.label == '등록자').state,
        CheckState.unavailable,
      );
    });

    test('체인 주소의 주인이 다른 사람이면 tampered', () {
      final e = soundEntry();
      final r = EntryVerifier.verify(
        e,
        onChain: chainOf(e),
        receiptBytes: receiptBytes,
        // 체인에 찍힌 등록자 주소가 감사(user #3)의 것인데 DB 는 총무(#2)가
        // 등록했다고 말한다. 등록자 ≠ 승인자 보장이 걸린 자리다.
        userIdByAddress: {
          registrant.toLowerCase(): 3,
          approver.toLowerCase(): 3,
        },
      );
      expect(r.status, VerificationStatus.tampered);
      expect(r.mismatches.map((m) => m.label), contains('등록자'));
    });

    test('체인 주소가 체크섬 표기여도 소문자 매핑에서 찾는다', () {
      // 체인은 EIP-55 체크섬 주소(대소문자 섞임)를 돌려주고 API 는 소문자 키를
      // 내려준다 (`CHAIN_CLIENT.md`). 맞춰 보지 않으면 전부 「모름」이 된다.
      final e = soundEntry();
      final r = EntryVerifier.verify(
        e,
        onChain: chainOf(e),
        receiptBytes: receiptBytes,
        userIdByAddress: wallets,
      );
      expect(r.status, VerificationStatus.verified);
      expect(
        r.fieldChecks.firstWhere((f) => f.label == '등록자').state,
        CheckState.passed,
      );
    });

    test('키 교체 전 주소는 「모름」이지 불일치가 아니다', () {
      // 매핑에 없는 주소를 불일치로 판정하면, 키를 교체한 임원이 과거에
      // 등록·승인한 항목이 전부 학생 화면에서 빨간 「변조 감지」로 뜬다.
      // 옛 주소가 매핑에 실리는 것은 rotateKey 릴레이가 붙은 뒤다.
      final e = soundEntry();
      final r = EntryVerifier.verify(
        e,
        onChain: chainOf(e),
        receiptBytes: receiptBytes,
        // 등록자의 주소만 매핑에서 빠져 있다.
        userIdByAddress: {approver.toLowerCase(): 3},
      );

      expect(r.status, VerificationStatus.partial);
      expect(r.mismatches, isEmpty, reason: '모르는 것은 불일치가 아니다');
      final check = r.fieldChecks.firstWhere((f) => f.label == '등록자');
      expect(check.state, CheckState.unavailable);
      expect(r.pendingReasons.any((s) => s.contains('등록자')), isTrue,
          reason: '왜 초록이 아닌지 화면에 말해줄 수 있어야 한다');
    });

    test('금액이 바뀌면 해시가 어긋나 tampered', () {
      final e = soundEntry();
      // 온체인 해시는 그대로인데 표시 금액만 바뀐 상황
      final tampered = _entry(
        id: e.id,
        amount: 45000,
        counterparty: e.counterparty,
        purpose: e.purpose,
        occurredAt: e.occurredAt,
        budgetId: e.budgetId,
        receiptHash: e.receiptHash,
        approvedBy: 3,
        metaHashOverride: e.metaHash,
      );

      final r = EntryVerifier.verify(
        tampered,
        onChain: chainOf(e),
        receiptBytes: receiptBytes,
      );
      expect(r.status, VerificationStatus.tampered);
      expect(r.hashState, CheckState.failed);
    });

    test('예산 항목만 바꿔치기하면 해시는 통과하지만 필드 대조가 잡는다', () {
      // HASHING.md §2 의 핵심 — budget_id 는 meta_hash 에 들어가지 않는다.
      final e = soundEntry();
      final r = EntryVerifier.verify(
        e,
        onChain: chainOf(e, budgetId: 7), // 체인에는 7, API 는 2
        receiptBytes: receiptBytes,
        userIdByAddress: wallets,
      );

      expect(r.hashState, CheckState.passed, reason: '해시는 멀쩡해야 한다');
      expect(r.status, VerificationStatus.tampered);
      expect(r.mismatches.map((m) => m.label), contains('예산 항목'));
    });

    group('학기 (Entry.term) — 해시가 덮지 않아 따로 대조한다', () {
      test('학기가 어긋나면 해시가 통과해도 변조 감지다', () {
        final e = soundEntry();
        final other = OnChainEntry(
          hash: e.metaHash,
          amount: e.amount,
          kind: e.kind,
          status: e.status,
          occurredAt: e.occurredAt,
          term: 20261, // 체인은 지난 학기라고 말한다
          budgetId: e.budgetId ?? 0,
          correctsId: 0,
          registrant: registrant,
          approver: approver,
        );

        final r = EntryVerifier.verify(e,
            onChain: other, receiptBytes: receiptBytes, userIdByAddress: wallets);

        expect(r.hashState, CheckState.passed,
            reason: 'term 은 meta_hash 에 들어가지 않아 해시로는 안 잡힌다');
        expect(r.status, VerificationStatus.tampered);
        expect(r.mismatches.map((f) => f.label), contains('학기'));
      });

      test('학기를 대조하지 못하면 초록을 주지 않는다', () {
        // `EntryResponse` 에 아직 term_code 가 없는 지금 상태.
        final e = soundEntry(termCode: null);
        final r = EntryVerifier.verify(e,
            onChain: chainOf(e),
            receiptBytes: receiptBytes,
            userIdByAddress: wallets);

        expect(r.status, VerificationStatus.partial,
            reason: '확인 못 한 것을 「완전 검증」으로 보여주면 안 된다');
      });

      test('DB 의 term_id 가 아니라 term_code 와 대조한다', () {
        // term_id 는 1, 학기 코드는 20262 다. 체인 값(20262)과 맞아야 한다 —
        // term_id 를 보고 비교하면 1 != 20262 로 멀쩡한 항목이 전부 어긋난다.
        final e = soundEntry();
        expect(e.termId, 1);
        expect(e.termCode, 20262);

        final r = EntryVerifier.verify(e,
            onChain: chainOf(e),
            receiptBytes: receiptBytes,
            userIdByAddress: wallets);

        expect(r.status, VerificationStatus.verified);
      });
    });

    test('수입·지출을 뒤바꿔도 해시는 통과하지만 필드 대조가 잡는다', () {
      final e = soundEntry();
      final swapped = OnChainEntry(
        hash: e.metaHash,
        amount: e.amount,
        kind: EntryKind.INCOME, // 체인은 수입이라고 말한다
        status: e.status,
        occurredAt: e.occurredAt,
        term: e.termCode,
        budgetId: e.budgetId ?? 0,
        correctsId: 0,
        registrant: '0x71C7656EC7ab88b098defB751B7401B5f6d8976F',
        approver: '0x2546BcD3c84621e976D8185a91A922aE77ECEc30',
      );

      final r = EntryVerifier.verify(e,
          onChain: swapped, receiptBytes: receiptBytes, userIdByAddress: wallets);
      expect(r.hashState, CheckState.passed);
      expect(r.status, VerificationStatus.tampered);
      expect(r.mismatches.map((m) => m.label), contains('수입·지출 구분'));
    });

    test('영수증 파일만 바뀌면 3단계가 잡는다', () {
      final e = soundEntry();
      final r = EntryVerifier.verify(
        e,
        onChain: chainOf(e),
        receiptBytes: utf8.encode('different-bytes'),
        userIdByAddress: wallets,
      );

      expect(r.hashState, CheckState.passed, reason: '해시는 멀쩡해야 한다');
      expect(r.receipt.state, CheckState.failed);
      expect(r.status, VerificationStatus.tampered);
    });

    test('체인 값이 없으면 초록을 주지 않는다 — partial', () {
      final e = soundEntry();
      final r = EntryVerifier.verify(e,
          onChain: null, receiptBytes: receiptBytes, userIdByAddress: wallets);
      expect(r.status, VerificationStatus.partial);
      expect(r.chainDataAvailable, isFalse);
      expect(r.pendingReasons, isNotEmpty);
    });

    test('영수증을 못 받아도 초록을 주지 않는다 — partial', () {
      final e = soundEntry();
      final r = EntryVerifier.verify(e,
          onChain: chainOf(e), receiptBytes: null, userIdByAddress: wallets);
      expect(r.receipt.state, CheckState.unavailable);
      expect(r.status, VerificationStatus.partial);
    });

    test('영수증이 없는 수입 항목은 3단계를 건너뛴다', () {
      final income = _entry(
        id: 1,
        kind: EntryKind.INCOME,
        amount: 5000000,
        counterparty: '컴퓨터공학과 학생회비 일괄 납부',
        purpose: '2026-2학기 학과 학생회비 수납',
        occurredAt: Hashing.kstMidnightOf(2026, 9, 6),
        approvedBy: 3,
      );
      final r = EntryVerifier.verify(
        income,
        onChain: chainOf(income),
        receiptBytes: null,
        userIdByAddress: wallets,
      );
      expect(r.receipt.state, CheckState.notApplicable);
      expect(r.status, VerificationStatus.verified);
    });

    test('NULL budget_id 는 체인의 0 과 같게 본다', () {
      // §2.1 을 빼먹으면 모든 수입 항목이 위조로 판정된다.
      final income = _entry(
        id: 1,
        kind: EntryKind.INCOME,
        amount: 5000000,
        counterparty: '학생회비',
        purpose: '수납',
        occurredAt: Hashing.kstMidnightOf(2026, 9, 6),
        approvedBy: 3,
      );
      expect(income.budgetId, isNull);

      final r = EntryVerifier.verify(income,
          onChain: chainOf(income), userIdByAddress: wallets);
      expect(
        r.fieldChecks.firstWhere((f) => f.label == '예산 항목').state,
        CheckState.passed,
      );
    });

    group('체인에 해시가 아직 없을 때 — 「변조」로 몰지 않는다', () {
      // 채굴 전이라 해시가 안 올라간 것뿐인 정상 항목을 빨강으로 띄우면,
      // 학생은 멀쩡한 기록을 조작된 것으로 읽는다. 「모름」이어야 한다.
      OnChainEntry chainWithoutHash(EntryModel e) => OnChainEntry(
            hash: null,
            amount: e.amount,
            kind: e.kind,
            status: e.status,
            occurredAt: e.occurredAt,
            term: e.termCode,
            budgetId: e.budgetId ?? 0,
            correctsId: 0,
            registrant: registrant,
            approver: approver,
          );

      test('체인 해시가 없으면 불일치가 아니라 대조하지 못한 것이다', () {
        final e = soundEntry();
        final r = EntryVerifier.verify(
          e,
          onChain: chainWithoutHash(e),
          receiptBytes: receiptBytes,
          userIdByAddress: wallets,
        );

        expect(r.status, isNot(VerificationStatus.tampered));
        expect(r.hashState, isNot(CheckState.failed));
        expect(r.onChainHash, isNull);
        expect(r.mismatches, isEmpty);
      });

      test('서버 해시로 대신 맞춰보지 않는다 — 「검증 불가」다', () {
        // 서버 값끼리 맞춰 통과시켜 봐야 확인한 것이 없다.
        // 체인 해시가 없다는 것은 대조할 기록이 없다는 뜻이다.
        final e = soundEntry();
        final r = EntryVerifier.verify(
          e,
          onChain: chainWithoutHash(e),
          receiptBytes: receiptBytes,
          userIdByAddress: wallets,
        );

        expect(r.hashState, CheckState.unavailable);
        expect(r.status, VerificationStatus.unavailable);
        expect(r.comparedAgainst, isNull, reason: '무엇과도 대조하지 않았다');
        expect(r.pendingReasons, isNotEmpty);
      });

      test('서버가 hash: null 을 줘도 빈 문자열로 뭉개지 않는다', () {
        // 빈 문자열은 「값 없음」과 다르게 취급돼 그대로 비교에 들어간다.
        final onChain = OnChainEntry.fromJson(const {
          'hash': null,
          'amount': 35000,
          'kind': 'EXPENSE',
          'status': 'CONFIRMED',
        });
        expect(onChain.hash, isNull);
        expect(onChain.hasHash, isFalse);
      });

      test('API 응답 그대로 — 해시만 없는 정상 항목은 변조가 아니다', () {
        // 신고된 경로 그대로. `hash: null` 이 빈 문자열로 뭉개지면 여기서
        // 「재계산한 값 ≠ ''」 가 되어 멀쩡한 대기 항목이 빨강으로 뜬다.
        final e = soundEntry();
        final onChain = OnChainEntry.fromJson({
          'hash': null,
          'amount': e.amount,
          'kind': e.kind.code,
          'status': e.status.code,
          'occurred_at': e.occurredAt,
          'budget_id': e.budgetId,
          'corrects_id': 0,
          'registrant': registrant,
          'approver': approver,
        });

        final r = EntryVerifier.verify(
          e,
          onChain: onChain,
          receiptBytes: receiptBytes,
          userIdByAddress: wallets,
        );

        expect(r.status, VerificationStatus.unavailable,
            reason: '「변조 감지」가 아니라 「검증 불가」다');
        expect(r.mismatches, isEmpty);
      });

      test('bytes32(0) 은 기록이 아니라 「아직 없음」이다', () {
        // 컨트랙트는 없는 값을 0 으로 돌려준다.
        final onChain = OnChainEntry.fromJson({
          'hash': '0x${'0' * 64}',
          'amount': 35000,
        });
        expect(onChain.hash, isNull);
      });

      test('0 으로 채워진 struct 는 체인 기록으로 치지 않는다', () {
        // `getEntry(id)` 는 없는 id 에도 빈 struct 를 돌려준다. 그것을 진짜
        // 기록으로 믿고 대조하면 `금액 35,000 ↔ 0` 이 어긋나 변조로 판정된다.
        final e = soundEntry();
        final empty = OnChainEntry.fromJson(const {});

        expect(empty.hasRecord, isFalse);

        final r = EntryVerifier.verify(
          e,
          onChain: empty,
          receiptBytes: receiptBytes,
          userIdByAddress: wallets,
        );
        expect(r.status, isNot(VerificationStatus.tampered));
        expect(r.chainDataAvailable, isFalse);
        expect(r.mismatches, isEmpty);
      });
    });

    group('응답에 필드가 없을 때 — 지어낸 값과 대조하지 않는다', () {
      // `/verify` 응답 모양은 아직 확정 전이다 (김경윤 구현 10/9). 어떤 필드가
      // 빠질지 모르는데 없는 값을 그럴듯한 기본값으로 메우면, 빠진 필드를 가진
      // **모든 항목이 학생 화면에서 빨간 「변조 감지」로 뜬다.** 모름이어야 한다.

      /// `getEntry(id)` 를 그대로 담은 정상 응답.
      Map<String, dynamic> chainJson(EntryModel e) => {
            'hash': e.metaHash,
            'amount': e.amount,
            'kind': e.kind.code,
            'status': e.status.code,
            'occurred_at': e.occurredAt,
            'term': e.termCode,
            'budget_id': e.budgetId ?? 0,
            'corrects_id': e.correctsEntryId ?? 0,
            'registrant': registrant,
            'approver': approver,
          };

      final income = _entry(
        id: 1,
        kind: EntryKind.INCOME,
        amount: 5000000,
        counterparty: '컴퓨터공학과 학생회비 일괄 납부',
        purpose: '2026-2학기 학과 학생회비 수납',
        occurredAt: Hashing.kstMidnightOf(2026, 9, 6),
        approvedBy: 3,
      );

      test('정상 응답은 그대로 초록이다 — 기준점', () {
        final r = EntryVerifier.verify(
          income,
          onChain: OnChainEntry.fromJson(chainJson(income)),
          userIdByAddress: wallets,
        );
        expect(r.status, VerificationStatus.verified);
      });

      test('kind 가 빠지면 수입 항목이 「변조 감지」로 뒤집히지 않는다', () {
        // 신고된 경로 그대로 — `kind ?? 'EXPENSE'` 면 수입 항목이 지어낸 지출과
        // 대조돼 INCOME ≠ EXPENSE 로 어긋난다.
        final json = chainJson(income)..remove('kind');
        final onChain = OnChainEntry.fromJson(json);
        expect(onChain.kind, isNull, reason: '없는 것은 EXPENSE 가 아니다');

        final r = EntryVerifier.verify(
          income,
          onChain: onChain,
          userIdByAddress: wallets,
        );

        expect(r.status, VerificationStatus.partial);
        expect(r.mismatches, isEmpty);
        expect(
          r.fieldChecks.firstWhere((f) => f.label == '수입·지출 구분').state,
          CheckState.unavailable,
        );
      });

      test('모르는 kind 코드도 지출로 떨어뜨리지 않는다', () {
        final onChain = OnChainEntry.fromJson(
          chainJson(income)..['kind'] = 'TRANSFER',
        );
        expect(onChain.kind, isNull,
            reason: '모르는 코드를 EXPENSE 로 읽으면 「확인했다」가 거짓이 된다');
      });

      test('budget_id 가 빠지면 「모름」, 실려 온 0 은 그대로 대조한다', () {
        // 0 과 null 을 합치면 §2.1(NULL ↔ 0)이 깨져 수입 항목이 전부 어긋난다.
        final missing = OnChainEntry.fromJson(
          chainJson(income)..remove('budget_id'),
        );
        expect(missing.budgetId, isNull);
        expect(
          EntryVerifier.verify(income,
                  onChain: missing, userIdByAddress: wallets)
              .fieldChecks
              .firstWhere((f) => f.label == '예산 항목')
              .state,
          CheckState.unavailable,
        );

        final zero = OnChainEntry.fromJson(chainJson(income));
        expect(zero.budgetId, 0);
        expect(
          EntryVerifier.verify(income, onChain: zero, userIdByAddress: wallets)
              .fieldChecks
              .firstWhere((f) => f.label == '예산 항목')
              .state,
          CheckState.passed,
          reason: '체인의 0 은 DB 의 budget_id = NULL 과 같다',
        );
      });

      test('registrant 가 빠지면 「한쪽만 값이 있다」가 아니라 「모름」이다', () {
        // `?? address(0)` 으로 메우면 「체인에는 등록자가 없는데 DB 에는 있다」가
        // 되어 불일치로 판정된다.
        final onChain = OnChainEntry.fromJson(
          chainJson(income)..remove('registrant'),
        );
        expect(onChain.registrant, isNull);

        final r = EntryVerifier.verify(
          income,
          onChain: onChain,
          userIdByAddress: wallets,
        );

        expect(r.mismatches, isEmpty);
        expect(
          r.fieldChecks.firstWhere((f) => f.label == '등록자').state,
          CheckState.unavailable,
        );
      });

      test('amount 가 빠져도 0 과 대조하지 않는다', () {
        final onChain = OnChainEntry.fromJson(
          chainJson(income)..remove('amount'),
        );
        expect(onChain.amount, isNull);

        final r = EntryVerifier.verify(
          income,
          onChain: onChain,
          userIdByAddress: wallets,
        );

        expect(r.mismatches, isEmpty);
        expect(
          r.fieldChecks.firstWhere((f) => f.label == '금액').state,
          CheckState.unavailable,
        );
      });

      test('승인자가 address(0) 이면 미처리와 맞아떨어진다', () {
        // 「응답에 없음」과 「실려 온 address(0)」은 다르다. 후자는 DB 의
        // approved_by = NULL 과 대조해 통과해야 한다 (§2.1).
        final pending = _entry(
          id: 9,
          amount: 12000,
          counterparty: '한결문구',
          purpose: '대기 중인 지출',
          occurredAt: d0908,
          budgetId: 2,
          status: EntryStatus.PENDING,
        );
        final onChain = OnChainEntry.fromJson(
          chainJson(pending)..['approver'] = OnChainEntry.zeroAddress,
        );

        final r = EntryVerifier.verify(
          pending,
          onChain: onChain,
          userIdByAddress: wallets,
        );

        expect(
          r.fieldChecks.firstWhere((f) => f.label == '승인자').state,
          CheckState.passed,
        );
        expect(r.mismatches, isEmpty);
      });
    });

    test('반려 항목은 승인자를 비교하지 않는다', () {
      // rejected_by 컬럼이 없어 그냥 비교하면 반려 건이 전부 위조가 된다.
      final rejected = _entry(
        id: 8,
        amount: 10000,
        counterparty: '문구점',
        purpose: '반려된 지출',
        occurredAt: d0908,
        budgetId: 2,
        status: EntryStatus.REJECTED,
      );
      final chain = OnChainEntry(
        hash: rejected.metaHash,
        amount: rejected.amount,
        kind: rejected.kind,
        status: rejected.status,
        occurredAt: rejected.occurredAt,
        term: rejected.termCode,
        budgetId: 2,
        correctsId: 0,
        registrant: '0x71C7656EC7ab88b098defB751B7401B5f6d8976F',
        // 체인에는 반려자 주소가 있는데 DB 에는 없다.
        approver: '0x2546BcD3c84621e976D8185a91A922aE77ECEc30',
      );

      final r = EntryVerifier.verify(rejected,
          onChain: chain, userIdByAddress: wallets);
      expect(
        r.fieldChecks.firstWhere((f) => f.label == '승인자').state,
        CheckState.notApplicable,
      );
      expect(r.status, isNot(VerificationStatus.tampered));
    });
  });

  group('정정 항목도 검증 대상이다', () {
    // 정정은 확정된 기록을 고치는 **유일한 통로**다. 원본만 검증하면
    // 정정 내용이 조작돼도 화면상 초록으로 남고, 화면에 크게 뜨는 최종 금액
    // (`원본 + Σ확정정정`)이 검증된 적 없는 숫자가 된다.
    final original = _entry(
      id: 4,
      amount: 50000,
      counterparty: '대학마트',
      purpose: '체육대회 간식 구매',
      occurredAt: d0910,
      budgetId: 1,
    );
    final correction = _entry(
      id: 5,
      amount: -20000,
      counterparty: '대학마트',
      purpose: '입력 오류 정정',
      occurredAt: d0910,
      budgetId: 1,
      correctsEntryId: 4,
      correctionReason: CorrectionReason.INPUT_ERROR,
    );

    test('체인에 원본과 정정이 모두 들어 있다', () {
      final chain = EntryMerge.fold([original, correction]).single;
      expect(chain.allEntries.map((e) => e.id), [4, 5]);
    });

    test('정정 하나가 어긋나면 체인 전체가 변조 감지다', () {
      expect(
        EntryVerifier.chainStatus(const [
          VerificationStatus.verified,
          VerificationStatus.tampered,
        ]),
        VerificationStatus.tampered,
      );
    });

    test('일부만 확인했으면 부분 검증이다 — 「아무것도 모른다」가 아니다', () {
      expect(
        EntryVerifier.chainStatus(const [
          VerificationStatus.verified,
          VerificationStatus.unavailable,
        ]),
        VerificationStatus.partial,
      );
    });

    test('전부 대조할 기록이 없을 때만 검증 불가다', () {
      expect(
        EntryVerifier.chainStatus(const [
          VerificationStatus.unavailable,
          VerificationStatus.unavailable,
        ]),
        VerificationStatus.unavailable,
      );
    });

    test('모두 통과해야 초록이다', () {
      expect(
        EntryVerifier.chainStatus(const [
          VerificationStatus.verified,
          VerificationStatus.verified,
        ]),
        VerificationStatus.verified,
      );
      expect(
        EntryVerifier.chainStatus(const [
          VerificationStatus.verified,
          VerificationStatus.partial,
        ]),
        VerificationStatus.partial,
      );
    });
  });
}

/// 해시를 실제로 계산해 넣은 항목을 만든다.
EntryModel _entry({
  required int id,
  required int amount,
  required String counterparty,
  required String purpose,
  required int occurredAt,
  EntryKind kind = EntryKind.EXPENSE,
  int? budgetId,
  String? receiptHash,
  int? termCode = TermInfo.currentTermCode,
  EntryStatus status = EntryStatus.CONFIRMED,
  int? correctsEntryId,
  CorrectionReason? correctionReason,
  int? approvedBy,
  String? metaHashOverride,
}) {
  return EntryModel(
    id: id,
    termId: 1,
    termCode: termCode,
    kind: kind,
    amount: amount,
    counterparty: counterparty,
    purpose: purpose,
    budgetId: budgetId,
    occurredAt: occurredAt,
    receiptHash: receiptHash,
    metaHash: metaHashOverride ??
        Hashing.metaHash(
          amount: amount,
          counterparty: counterparty,
          purpose: purpose,
          occurredAt: occurredAt,
          receiptHash: receiptHash,
        ),
    status: status,
    createdBy: 2,
    approvedBy: approvedBy,
    correctsEntryId: correctsEntryId,
    correctionReason: correctionReason,
  );
}
