import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import 'auth_service.dart';

/// 알림 한 건 (`docs/NOTIFICATION_API.md` 초안 — 손종인).
class AppNotification {
  final int id;

  /// 서버의 `kind`. 앱이 모르는 값이어도 그대로 둔다 — [body] 를 표시하면 된다.
  final String kind;
  final int? entryId;
  final int? budgetRevisionRequestId;

  /// 서버가 만든 문구. 앱은 그대로 표시한다.
  final String body;
  final int createdAt;

  /// 마지막으로 알린 시각 (재알림 때 갱신된다). 정렬·표시 기준.
  final int notifiedAt;
  final int? readAt;

  /// 재알림 횟수. 0 이면 처음 알림이다.
  final int remindCount;

  const AppNotification({
    required this.id,
    required this.kind,
    required this.body,
    required this.createdAt,
    required this.notifiedAt,
    this.entryId,
    this.budgetRevisionRequestId,
    this.readAt,
    this.remindCount = 0,
  });

  bool get isRead => readAt != null;

  AppNotification copyWith({int? readAt}) => AppNotification(
        id: id,
        kind: kind,
        body: body,
        createdAt: createdAt,
        notifiedAt: notifiedAt,
        entryId: entryId,
        budgetRevisionRequestId: budgetRevisionRequestId,
        readAt: readAt ?? this.readAt,
        remindCount: remindCount,
      );

  /// 필수 칸이 없으면 던진다 — 호출한 쪽이 그 한 건만 건너뛴다.
  factory AppNotification.fromJson(Map<String, dynamic> json) => AppNotification(
        id: json['id'] as int,
        kind: json['kind'] as String,
        body: json['body'] as String,
        createdAt: json['created_at'] as int,
        notifiedAt: (json['notified_at'] ?? json['created_at']) as int,
        entryId: json['entry_id'] as int?,
        budgetRevisionRequestId: json['budget_revision_request_id'] as int?,
        readAt: json['read_at'] as int?,
        remindCount: (json['remind_count'] as int?) ?? 0,
      );
}

/// 알림 API (PRD v0.14 §4.8 1단계 — 폴링). 서버 구현은 11/7~8 예정이라 명세 초안대로 먼저 붙인다.
///
/// **못 읽으면 null 이다.** 더미로 메우지 않고, 0·빈 목록으로 내리지도 않는다 — 못 읽은 것을
/// 「새 알림 없음」으로 적으면 처리할 건이 있는데도 임원이 할 일이 없다고 읽는다 (PRD §7.3).
class NotificationService {
  NotificationService._();

  /// HTTP 클라이언트. 테스트에서 갈아끼운다.
  static http.Client client = http.Client();
  static const timeout = Duration(seconds: 5);

  /// 화면을 열어 둔 동안 다시 읽는 간격 — 화면 동기화(§4.9)와 같은 15초.
  static const pollInterval = Duration(seconds: 15);

  static Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('${ApiConfig.baseUrl}$path').replace(queryParameters: query);

  /// 401 이면 세션이 끝난 것이다 — 로그인 화면으로 보낸다 (`AuthService.reportUnauthorized`).
  static Future<http.Response?> _send(Future<http.Response> Function() request) async {
    final http.Response res;
    try {
      res = await request().timeout(timeout);
    } catch (_) {
      return null;
    }
    if (res.statusCode == 401) {
      await AuthService().reportUnauthorized();
      return null;
    }
    return res;
  }

  /// 목록 — 안 읽은 것 먼저, 그 안에서 최근 알린 순 (서버가 정렬한다). 못 읽으면 null.
  static Future<List<AppNotification>?> list({bool unreadOnly = false, int limit = 50}) async {
    final res = await _send(() => client.get(
          _uri('/notifications', {'unread_only': '$unreadOnly', 'limit': '$limit'}),
          headers: AuthService().authHeaders,
        ));
    if (res == null || res.statusCode != 200) return null;
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      return null;
    }
    if (body is! List) return null;
    final items = <AppNotification>[];
    for (final raw in body) {
      // 모양이 어긋난 한 건 때문에 목록 전체를 잃지 않는다.
      try {
        items.add(AppNotification.fromJson(raw as Map<String, dynamic>));
      } catch (_) {}
    }
    return items;
  }

  /// 안 읽은 수 — 뱃지 폴링용. 못 읽으면 null.
  static Future<int?> unreadCount() async {
    final res = await _send(() => client.get(_uri('/notifications/unread-count'), headers: AuthService().authHeaders));
    if (res == null || res.statusCode != 200) return null;
    try {
      final count = (jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>)['count'];
      return count is int && count >= 0 ? count : null;
    } catch (_) {
      return null;
    }
  }

  /// 읽음 처리. 성공하면 서버의 `read_at`, 실패하면 null.
  /// 이미 읽은 알림도 200 이고, 없는 알림·남의 알림은 404 다.
  static Future<int?> markRead(int id) async {
    final res = await _send(() => client.post(_uri('/notifications/$id/read'), headers: AuthService().authHeaders));
    if (res == null || res.statusCode != 200) return null;
    try {
      return (jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>)['read_at'] as int;
    } catch (_) {
      return null;
    }
  }
}
