import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import 'signed_post.dart';

export 'signed_post.dart' show EntryDecisionException, EntryDecisionFailure;

/// 총무의 예산 증액 요청 (T9, PRD §4.1 개정 1단계). 서명은 없다 — 회장·감사가 다음 단계에서 서명한다.
class IncreaseRequestDraft {
  final int termId;
  final String category;
  final int budgetId;

  /// **증액분**이다. 바뀐 뒤 총액이 아니다 (`IncreaseRequest.amount`, API §3).
  final int amount;

  /// 사유 원문. 서버가 정본화해(`canonical_text`) 저장하고, 회장·감사가 그 해시에 서명한다.
  final String reason;

  /// 근거가 된 차단 지출 — 결산의 「초과 집행 이후 개정」 지표가 이 연결로 센다.
  final int? blockedEntryId;

  const IncreaseRequestDraft({
    required this.termId,
    required this.category,
    required this.budgetId,
    required this.amount,
    required this.reason,
    this.blockedEntryId,
  });

  /// `POST /budget-revisions` 본문.
  Map<String, Object> toJson() => {
        'term_id': termId,
        'category': category,
        'budget_id': budgetId,
        'requested_amount': amount,
        'reason': reason,
        if (blockedEntryId != null) 'blocked_entry_id': blockedEntryId!,
      };
}

/// 증액 요청 화면이 쓰는 입구. 테스트는 가짜를 넣는다.
abstract class BudgetRevisionRequester {
  /// 요청을 등록하고 요청 번호를 돌려준다. 실패하면 [EntryDecisionException].
  Future<int> requestIncrease(IncreaseRequestDraft draft);
}

/// `POST /budget-revisions` (총무 전용). 결과는 `PENDING` — 회장 서명을 기다린다.
class BudgetRevisionService implements BudgetRevisionRequester {
  /// HTTP 클라이언트. 테스트에서 갈아끼운다.
  static http.Client client = http.Client();

  /// 서버가 등록 전에 체인에서 예산을 읽는다(`get_budget`). 넉넉히 둔다.
  static const timeout = Duration(seconds: 15);

  @override
  Future<int> requestIncrease(IncreaseRequestDraft draft) async {
    final body = await postSigned(
      client,
      '${ApiConfig.baseUrl}/budget-revisions',
      draft.toJson(),
      what: '증액 요청',
      timeout: timeout,
    );
    final id = body['id'];
    if (id is! int) {
      throw const EntryDecisionException(
        EntryDecisionFailure.unknownOutcome,
        '요청 번호를 받지 못했어요. 요청이 등록됐는지 알림함에서 확인해 주세요.',
      );
    }
    return id;
  }
}
