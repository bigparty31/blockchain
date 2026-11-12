import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/services/entry_registration_service.dart';

/// 화면 테스트용 등록기 — 서버·체인 없이 결과만 정한다. 받은 초안을 기록한다.
///
/// 기본 판정은 예산 잔량 초과면 `BLOCKED`(BUDGET_EXCEEDED), 아니면 `PENDING` 이다. 잔량은 ApiService 의
/// 시연용 예산(행사비 #1 2,470,000 · 사업비 #2 1,465,000 · 운영비 #3 1,000,000)과 같다.
class FakeRegistrar implements EntryRegistrar {
  final Map<int, int> remaining;
  FakeRegistrar({Map<int, int>? remaining}) : remaining = remaining ?? {1: 2470000, 2: 1465000, 3: 1000000};

  final List<EntryDraft> drafts = [];
  final List<(int, EntryDraft)> submits = [];

  /// 다음 제출을 이 예외로 실패시킨다 (한 번만).
  EntryDecisionException? failNextSubmit;

  int _nextId = 100;

  @override
  Future<int> saveDraft(EntryDraft draft) async {
    drafts.add(draft);
    return _nextId++;
  }

  @override
  Future<SubmitOutcome> submit(int id, EntryDraft draft) async {
    submits.add((id, draft));
    final fail = failNextSubmit;
    if (fail != null) {
      failNextSubmit = null;
      throw fail;
    }
    final left = draft.budgetId == null ? null : remaining[draft.budgetId];
    if (left != null && draft.amount > left) return const SubmitOutcome(EntryStatus.BLOCKED, BlockReason.BUDGET_EXCEEDED);
    return const SubmitOutcome(EntryStatus.PENDING, null);
  }
}

/// 테스트용 영수증 — 고정 바이트. 해시는 `Hashing.fileHash(fakeReceiptBytes)`.
final fakeReceiptBytes = utf8.encode('fake receipt jpeg bytes');
Future<List<int>?> fakeReceipt(BuildContext _) async => fakeReceiptBytes;
