import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/entry_verifier.dart';
import 'package:student_council_app/models/entry_model.dart';
import 'package:student_council_app/services/student_api_service.dart';

/// 데모 데이터의 배지 결과를 **서비스 경로 그대로** 고정한다.
///
/// 지갑 매핑·온체인 응답·영수증을 각각 다른 곳에서 만들기 때문에, 한쪽 모양만
/// 바뀌면 **멀쩡한 데모 7건이 전부 「변조 감지」로 뒤집힌다.** 실제로 컨트랙트
/// 병합 때 임원 주소가 바뀌면서 그럴 뻔했고, 매핑 방향을 주소 → user id 로
/// 뒤집을 때도 같은 사고가 가능하다. 모델·검증기 단위 테스트로는 안 잡히는
/// 종류라(각각은 멀쩡하다) 여기서 끝에서 끝까지 본다.
///
/// 중간발표 시연이 이 데이터로 돌아가므로 결과가 바뀌면 바로 드러나야 한다.
void main() {
  test('데모 7건 — 정상 4건은 초록, 일부러 조작한 3건만 빨강', () async {
    final api = StudentApiService();

    // 서버가 없으면 데모로 떨어진다. `_usingDemoData` 가 켜져야 아래 폴백들이
    // 같은 데모 세계를 보므로 이 호출이 먼저여야 한다.
    final entries = await api.fetchEntries();
    expect(entries, isNotEmpty);

    final wallets = await api.fetchWalletMap();
    expect(wallets, isNotNull, reason: '데모 지갑 매핑이 없으면 등록자가 「모름」이 된다');

    final statuses = <int, VerificationStatus>{};
    for (final EntryModel e in entries) {
      final chain = await api.fetchOnChainEntry(e.id);
      final bytes = await api.fetchReceiptBytes(e);
      statuses[e.id] = EntryVerifier.verify(
        e,
        onChain: chain,
        receiptBytes: bytes,
        userIdByAddress: wallets,
      ).status;
    }

    // #3 영수증 바꿔치기 · #6 금액 변조 · #7 예산 항목 옮기기 — 일부러 만든 건이다.
    const tamperedIds = {3, 6, 7};

    for (final entry in statuses.entries) {
      expect(
        entry.value,
        tamperedIds.contains(entry.key)
            ? VerificationStatus.tampered
            : VerificationStatus.verified,
        reason: '데모 #${entry.key} 의 배지가 바뀌었다',
      );
    }
  });

  test('등록자 대조가 실제로 돌아간다 — 「모름」으로 비어 있지 않다', () async {
    // 매핑 방향이 어긋나면 모든 등록자 검사가 조용히 「모름」이 되고, 배지는
    // partial 이라 빨강이 아니어서 눈에 잘 안 띈다. 그래서 따로 못 박는다.
    final api = StudentApiService();
    final entries = await api.fetchEntries();
    final wallets = await api.fetchWalletMap();

    final e = entries.firstWhere((x) => x.id == 2);
    final report = EntryVerifier.verify(
      e,
      onChain: await api.fetchOnChainEntry(e.id),
      receiptBytes: await api.fetchReceiptBytes(e),
      userIdByAddress: wallets,
    );

    for (final label in ['등록자', '승인자']) {
      expect(
        report.fieldChecks.firstWhere((f) => f.label == label).state,
        CheckState.passed,
        reason: '$label 를 주소 → user id 매핑으로 대조하지 못했다',
      );
    }
  });
}
