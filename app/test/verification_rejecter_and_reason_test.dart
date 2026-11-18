import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/entry_verifier.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/core/hashing.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/models/onchain_entry_model.dart';

/// #51 — 반려자와 승인·반려 사유를 학생 검증에 넣는다.
///
/// 컨트랙트의 `approver` 는 확정자와 반려자를 겸하는데 DB 는 둘을 나눠 담는다.
/// 상태에 따라 대조 상대가 갈리지 않으면 **멀쩡한 반려 항목이 전부 위조로 뜬다.**
/// 사유는 체인에 해시만 남으므로, 원문을 나중에 고쳐도 해시는 못 고친다는 점을 쓴다.
void main() {
  const treasurer = '0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc'; // user 2
  const auditor = '0x90f79bf6eb2c4f870365e785982e1f101e93b906'; // user 3
  const wallets = {treasurer: 2, auditor: 3};

  EntryModel entry({
    required EntryStatus status,
    int? approvedBy,
    int? rejectedBy,
    String? rejectReason,
    String? warningAckReason,
  }) =>
      EntryModel(
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
        status: status,
        createdBy: 2,
        approvedBy: approvedBy,
        rejectedBy: rejectedBy,
        rejectReason: rejectReason,
        warningAckReason: warningAckReason,
      );

  OnChainEntry onChain({
    required EntryStatus status,
    String? approver,
    bool? hadWarning,
    String? reasonHash,
  }) =>
      OnChainEntry(
        hash: '0x${'a' * 64}',
        amount: 48000,
        kind: EntryKind.EXPENSE,
        status: status,
        occurredAt: 1794841200,
        term: 20262,
        budgetId: 1,
        correctsId: 0,
        registrant: treasurer,
        approver: approver,
        hadWarning: hadWarning,
        reasonHash: reasonHash,
      );

  FieldCheck checkOf(EntryModel e, OnChainEntry c, String label) {
    final report =
        EntryVerifier.verify(e, onChain: c, userIdByAddress: wallets);
    return report.fieldChecks.firstWhere((f) => f.label == label);
  }

  group('반려자 대조', () {
    test('반려 건은 체인 approver 를 rejected_by 와 맞춘다', () {
      final check = checkOf(
        entry(status: EntryStatus.REJECTED, rejectedBy: 3, rejectReason: '영수증 불명확'),
        onChain(
          status: EntryStatus.REJECTED,
          approver: auditor,
          reasonHash: Hashing.textHash('영수증 불명확'),
        ),
        '반려자',
      );
      expect(check.state, CheckState.passed);
    });

    test('반려자가 다르면 잡아낸다', () {
      final check = checkOf(
        entry(status: EntryStatus.REJECTED, rejectedBy: 2, rejectReason: '영수증 불명확'),
        onChain(
          status: EntryStatus.REJECTED,
          approver: auditor, // user 3 인데 DB 는 2 라고 한다
          reasonHash: Hashing.textHash('영수증 불명확'),
        ),
        '반려자',
      );
      expect(check.state, CheckState.failed);
    });

    test('확정 건은 approved_by 와 맞춘다', () {
      final check = checkOf(
        entry(status: EntryStatus.CONFIRMED, approvedBy: 3),
        onChain(
          status: EntryStatus.CONFIRMED,
          approver: auditor,
          hadWarning: false,
          reasonHash: OnChainEntry.zeroHash,
        ),
        '승인자',
      );
      expect(check.state, CheckState.passed);
    });
  });

  group('사유 해시 대조', () {
    test('경고 무시 확정 — warning_ack_reason 으로 재계산해 맞춘다', () {
      const reason = '행사 성격상 다른 항목이 맞다고 판단';
      final check = checkOf(
        entry(
          status: EntryStatus.CONFIRMED,
          approvedBy: 3,
          warningAckReason: reason,
        ),
        onChain(
          status: EntryStatus.CONFIRMED,
          approver: auditor,
          hadWarning: true,
          reasonHash: Hashing.textHash(reason),
        ),
        '승인·반려 사유',
      );
      expect(check.state, CheckState.passed);
    });

    test('원문이 바뀌면 해시가 어긋난다 — 사후 수정 탐지', () {
      final check = checkOf(
        entry(
          status: EntryStatus.CONFIRMED,
          approvedBy: 3,
          warningAckReason: '나중에 고친 사유',
        ),
        onChain(
          status: EntryStatus.CONFIRMED,
          approver: auditor,
          hadWarning: true,
          reasonHash: Hashing.textHash('원래 사유'),
        ),
        '승인·반려 사유',
      );
      expect(check.state, CheckState.failed);
    });

    test('경고 없는 확정은 bytes32(0) 이어야 한다', () {
      final check = checkOf(
        entry(status: EntryStatus.CONFIRMED, approvedBy: 3),
        onChain(
          status: EntryStatus.CONFIRMED,
          approver: auditor,
          hadWarning: false,
          reasonHash: OnChainEntry.zeroHash,
        ),
        '승인·반려 사유',
      );
      expect(check.state, CheckState.passed);
    });

    test('경고가 없다는데 체인에 사유 해시가 있으면 어긋난다', () {
      final check = checkOf(
        entry(status: EntryStatus.CONFIRMED, approvedBy: 3),
        onChain(
          status: EntryStatus.CONFIRMED,
          approver: auditor,
          hadWarning: false,
          reasonHash: Hashing.textHash('있으면 안 되는 사유'),
        ),
        '승인·반려 사유',
      );
      expect(check.state, CheckState.failed);
    });

    test('reason_hash 가 없고 사유도 없으면 「해당 없음」이다 — 멀쩡한 항목을 강등하지 않는다', () {
      // 서버가 아직 안 내려주는 필드다. 여기서 「모름」을 남기면 사유가 애초에 없는
      // 평범한 확정 항목까지 전부 「부분 검증」으로 떨어진다.
      final check = checkOf(
        entry(status: EntryStatus.CONFIRMED, approvedBy: 3),
        onChain(status: EntryStatus.CONFIRMED, approver: auditor),
        '승인·반려 사유',
      );
      expect(check.state, CheckState.notApplicable);
    });

    test('reason_hash 가 없는데 학생에게 사유가 보이면 「모름」이다', () {
      // 보이는 글을 대조하지 못한 것은 실제로 모르는 것이다. 통과로 만들면 안 된다.
      final check = checkOf(
        entry(
          status: EntryStatus.CONFIRMED,
          approvedBy: 3,
          warningAckReason: '영수증 원본 확인함',
        ),
        onChain(status: EntryStatus.CONFIRMED, approver: auditor),
        '승인·반려 사유',
      );
      expect(check.state, CheckState.unavailable);
    });

    test('체인에 해시는 있는데 원문을 못 받았으면 「모름」이다', () {
      final check = checkOf(
        entry(status: EntryStatus.REJECTED, rejectedBy: 3),
        onChain(
          status: EntryStatus.REJECTED,
          approver: auditor,
          reasonHash: Hashing.textHash('사유'),
        ),
        '승인·반려 사유',
      );
      expect(check.state, CheckState.unavailable);
    });

    test('받은 원문을 다시 다듬지 않는다 — 서버가 정본이 아닌 값을 주면 드러나야 한다', () {
      // 백엔드가 저장 시점에 다듬은 값이 정본이다(HASHING.md §1.1). 앱이 또 다듬으면
      // 서버가 끝에 공백이 붙은 값을 내려보내도 조용히 교정되어 통과해 버린다.
      const canonical = '영수증 불명확';
      final check = checkOf(
        entry(
          status: EntryStatus.REJECTED,
          rejectedBy: 3,
          rejectReason: '$canonical  ', // 서버가 정본이 아닌 값을 줬다
        ),
        onChain(
          status: EntryStatus.REJECTED,
          approver: auditor,
          reasonHash: Hashing.textHash(canonical),
        ),
        '승인·반려 사유',
      );
      expect(check.state, CheckState.failed);
    });
  });
}
