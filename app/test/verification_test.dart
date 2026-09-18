import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/entry_merge.dart';
import 'package:student_council_app/core/entry_verifier.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
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
    const wallets = {2: registrant, 3: approver};

    EntryModel soundEntry() => _entry(
          id: 2,
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
        walletByUserId: wallets,
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

    test('등록자 주소가 다르면 tampered', () {
      final e = soundEntry();
      final r = EntryVerifier.verify(
        e,
        onChain: chainOf(e),
        receiptBytes: receiptBytes,
        // user #2 의 실제 지갑이 체인에 찍힌 주소와 다르다.
        walletByUserId: const {
          2: '0x000000000000000000000000000000000000dEaD',
          3: approver,
        },
      );
      expect(r.status, VerificationStatus.tampered);
      expect(r.mismatches.map((m) => m.label), contains('등록자'));
    });

    test('주소 대소문자 표기가 달라도 같은 주소로 본다', () {
      final e = soundEntry();
      final r = EntryVerifier.verify(
        e,
        onChain: chainOf(e),
        receiptBytes: receiptBytes,
        walletByUserId: {
          2: registrant.toLowerCase(),
          3: approver.toUpperCase(),
        },
      );
      expect(r.status, VerificationStatus.verified);
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
        walletByUserId: wallets,
      );

      expect(r.hashState, CheckState.passed, reason: '해시는 멀쩡해야 한다');
      expect(r.status, VerificationStatus.tampered);
      expect(r.mismatches.map((m) => m.label), contains('예산 항목'));
    });

    test('수입·지출을 뒤바꿔도 해시는 통과하지만 필드 대조가 잡는다', () {
      final e = soundEntry();
      final swapped = OnChainEntry(
        hash: e.metaHash,
        amount: e.amount,
        kind: EntryKind.INCOME, // 체인은 수입이라고 말한다
        status: e.status,
        occurredAt: e.occurredAt,
        budgetId: e.budgetId ?? 0,
        correctsId: 0,
        registrant: '0x71C7656EC7ab88b098defB751B7401B5f6d8976F',
        approver: '0x2546BcD3c84621e976D8185a91A922aE77ECEc30',
      );

      final r = EntryVerifier.verify(e,
          onChain: swapped, receiptBytes: receiptBytes, walletByUserId: wallets);
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
        walletByUserId: wallets,
      );

      expect(r.hashState, CheckState.passed, reason: '해시는 멀쩡해야 한다');
      expect(r.receipt.state, CheckState.failed);
      expect(r.status, VerificationStatus.tampered);
    });

    test('체인 값이 없으면 초록을 주지 않는다 — partial', () {
      final e = soundEntry();
      final r = EntryVerifier.verify(e,
          onChain: null, receiptBytes: receiptBytes, walletByUserId: wallets);
      expect(r.status, VerificationStatus.partial);
      expect(r.chainDataAvailable, isFalse);
      expect(r.pendingReasons, isNotEmpty);
    });

    test('영수증을 못 받아도 초록을 주지 않는다 — partial', () {
      final e = soundEntry();
      final r = EntryVerifier.verify(e,
          onChain: chainOf(e), receiptBytes: null, walletByUserId: wallets);
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
        walletByUserId: wallets,
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
          onChain: chainOf(income), walletByUserId: wallets);
      expect(
        r.fieldChecks.firstWhere((f) => f.label == '예산 항목').state,
        CheckState.passed,
      );
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
        budgetId: 2,
        correctsId: 0,
        registrant: '0x71C7656EC7ab88b098defB751B7401B5f6d8976F',
        // 체인에는 반려자 주소가 있는데 DB 에는 없다.
        approver: '0x2546BcD3c84621e976D8185a91A922aE77ECEc30',
      );

      final r = EntryVerifier.verify(rejected,
          onChain: chain, walletByUserId: wallets);
      expect(
        r.fieldChecks.firstWhere((f) => f.label == '승인자').state,
        CheckState.notApplicable,
      );
      expect(r.status, isNot(VerificationStatus.tampered));
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
  EntryStatus status = EntryStatus.CONFIRMED,
  int? correctsEntryId,
  CorrectionReason? correctionReason,
  int? approvedBy,
  String? metaHashOverride,
}) {
  return EntryModel(
    id: id,
    termId: 1,
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
