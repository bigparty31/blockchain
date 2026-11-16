import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../models/entry_model.dart';
import 'entry_decision_service.dart';
import 'signed_post.dart';

/// 총무의 **수정 요청** — 승인 대기(`PENDING`) 건을 고치고 싶을 때 (PRD §4.3 T4, 서버 #76).
///
/// 대기 건은 고칠 수 없다. 새로 올리면 두 건이 함께 대기하다 둘 다 확정될 수 있어서다. 수정을 요청하면
/// 승인권자는 그 건을 **확정할 수 없고 반려만 할 수 있다**. 반려되면 「고쳐서 다시 제출」로 새 건을 올린다.
///
/// 서명이 필요 없는 요청이다(본문 없음). 이미 요청한 건에 다시 요청해도 서버는 같은 응답을 준다(멱등).
class EntryRevisionService {
  EntryRevisionService._();

  /// HTTP 클라이언트. 테스트에서 갈아끼운다.
  static http.Client client = http.Client();

  static const timeout = Duration(seconds: 10);

  /// `POST /entries/{id}/request-revision`. 요청 시각이 채워진 항목을 돌려준다.
  ///
  /// 확정이 이미 처리 중이면(409) 고칠 수 없다 — 정정 등록으로 진행하라고 안내한다.
  static Future<EntryModel> requestRevision(int entryId) async {
    final body = await sendAndDecode(
      (authHeaders) =>
          client.post(Uri.parse('${ApiConfig.entries}/$entryId/request-revision'), headers: authHeaders).timeout(timeout),
      what: '수정 요청',
      conflictMessage: '이미 확정 처리 중이라 수정을 요청할 수 없어요. 고치려면 확정된 뒤 정정 등록으로 진행해 주세요.',
    );
    try {
      return EntryModel.fromJson(body);
    } catch (_) {
      // 200 인데 읽을 수 없다 — 요청이 접수됐는지 모른다. 목록을 새로 고쳐 확인하게 한다
      throw const EntryDecisionException(
        EntryDecisionFailure.unknownOutcome,
        '수정 요청 결과를 확인하지 못했어요. 목록을 새로 고쳐 요청됐는지 확인해 주세요.',
      );
    }
  }
}
