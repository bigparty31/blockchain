import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/enums.dart';
import '../../services/notification_service.dart';
import 'approval_list_screen.dart';
import 'correction_approval_screen.dart';
import 'my_entries_screen.dart';

/// 알림 종류의 짧은 이름. 모르는 종류는 「알림」 — 오류로 처리하지 않고 본문을 그대로 보여 준다.
String notificationKindLabel(String kind) => switch (kind) {
      'ENTRY_REGISTERED' => '승인 필요',
      'ENTRY_EDIT_REQUESTED' => '수정 요청',
      'ENTRY_CONFIRMED' => '확정',
      'ENTRY_REJECTED' => '반려',
      'ENTRY_CONFIRM_FAILED' => '확정 실패',
      'ENTRY_BLOCKED' => '차단',
      'REVISION_REQUESTED' => '증액 요청',
      'REVISION_PRESIDENT_SIGNED' => '회장 서명 완료',
      'REVISION_APPROVED' => '증액 승인',
      'REVISION_REJECTED' => '증액 반려',
      'RECLASSIFY_PAIR_UNCONFIRMED' => '재분류 진행 중',
      'SIGNATURE_DEADLINE_NEAR' => '서명 시한 임박',
      'ROLE_CHANGE_REQUESTED' => '롤 변경',
      'PRESIDENT_RECOVERY_PROPOSED' => '회장 복구 제안',
      _ => '알림',
    };

/// 알림을 누르면 갈 화면. 갈 곳이 없으면 null (읽음 처리만 한다).
///
/// 「연결」은 `entry_id`·`budget_revision_request_id` 중 값이 있는 쪽이다 (명세). 증액 쪽 화면(회장·감사
/// 서명)은 문승준 파트라 아직 없다.
Widget? notificationDestination(AppNotification n, UserRole role) {
  final approver = role == UserRole.AUDITOR || role == UserRole.PRESIDENT;
  switch (n.kind) {
    case 'ENTRY_REGISTERED':
    case 'ENTRY_EDIT_REQUESTED':
      return approver ? const ApprovalListScreen() : null;
    case 'ENTRY_CONFIRMED':
    case 'ENTRY_REJECTED':
    case 'ENTRY_CONFIRM_FAILED':
    case 'ENTRY_BLOCKED':
      return role == UserRole.TREASURER ? const MyEntriesScreen() : null;
    case 'REVISION_APPROVED':
    case 'REVISION_REJECTED':
      // 증액 결과를 받은 총무가 할 일은 차단 건을 다시 등록하거나 다시 요청하는 것이다 — 그 화면이 내 등록 현황.
      // 회장은 결과 통보만 받고 이어서 할 일이 없다.
      return role == UserRole.TREASURER ? const MyEntriesScreen() : null;
    case 'RECLASSIFY_PAIR_UNCONFIRMED':
      if (approver) return const CorrectionApprovalScreen();
      return role == UserRole.TREASURER ? const MyEntriesScreen() : null;
    default:
      return null;
  }
}

/// 누를 곳([notificationDestination])이 없을 때 알려 줄 말. 알릴 것이 없으면 null.
///
/// 눌렀는데 읽음 처리만 되고 아무 반응이 없으면 알림이 고장 난 것처럼 보인다. 모르는 종류에는 덧붙이지 않는다 —
/// 서버가 준 본문이 그대로 보이기 때문이다.
String? notificationNoDestinationNotice(AppNotification n, UserRole role) {
  if (notificationDestination(n, role) != null) return null;
  if (n.kind.startsWith('REVISION_') || n.kind == 'SIGNATURE_DEADLINE_NEAR') return '예산 개정 화면은 준비 중입니다.';
  // 회장은 차단 알림을 받지만 차단 건을 보여 주는 화면이 없다 — 증액 요청이 오면 서명하는 쪽이다.
  if (n.kind == 'ENTRY_BLOCKED') return '예산 검사에서 차단된 지출이에요. 증액 요청이 오면 서명 화면에서 처리해요. (서명 화면은 준비 중입니다)';
  return null;
}

/// 알린 시각을 「방금 · N분 전 · N시간 전 · N일 전」으로.
String notificationAge(int notifiedAt, {DateTime? now}) {
  final at = DateTime.fromMillisecondsSinceEpoch(notifiedAt * 1000);
  final diff = (now ?? DateTime.now()).difference(at);
  if (diff.inMinutes < 1) return '방금';
  if (diff.inHours < 1) return '${diff.inMinutes}분 전';
  if (diff.inDays < 1) return '${diff.inHours}시간 전';
  return '${diff.inDays}일 전';
}

/// [이승호 담당: app/lib/screens/council/]
/// 임원 알림함 (PRD v0.14 §4.8 1단계 — 알림함·뱃지·폴링, A16).
///
/// - 열려 있는 동안 15초마다 다시 읽고, 앱으로 돌아올 때도 다시 읽는다 (§4.9 화면 동기화).
/// - **못 읽은 것과 빈 것을 구분한다.** 조회 실패를 「새 알림이 없어요」로 적지 않는다.
/// - 누르면 읽음 처리하고 관련 화면으로 간다. 읽음은 처리가 아니다 — 처리하지 않으면 재알림이 온다.
class NotificationInboxScreen extends StatefulWidget {
  final UserRole role;
  const NotificationInboxScreen({super.key, required this.role});

  @override
  State<NotificationInboxScreen> createState() => _NotificationInboxScreenState();
}

class _NotificationInboxScreenState extends State<NotificationInboxScreen> with WidgetsBindingObserver {
  List<AppNotification>? _items;
  bool _loading = true;

  /// 마지막 조회가 실패했다. 예전 목록이 있으면 그대로 두고 위에 알린다.
  bool _failed = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _poll = Timer.periodic(NotificationService.pollInterval, (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load(silent: true);
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    final items = await NotificationService.list();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failed = items == null;
      if (items != null) _items = items;
    });
  }

  Future<void> _open(AppNotification n) async {
    if (!n.isRead) {
      final readAt = await NotificationService.markRead(n.id);
      if (!mounted) return;
      if (readAt != null) {
        setState(() => _items = [for (final i in _items ?? <AppNotification>[]) i.id == n.id ? i.copyWith(readAt: readAt) : i]);
      } else {
        // 404(이미 정리된 알림)이거나 연결 실패다. 목록을 다시 받아 실제 상태를 보여 준다.
        unawaited(_load(silent: true));
      }
    }
    if (!mounted) return;
    final destination = notificationDestination(n, widget.role);
    if (destination != null) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => destination));
      if (mounted) await _load(silent: true);
    } else {
      final notice = notificationNoDestinationNotice(n, widget.role);
      if (notice != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(notice), behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: const Text('알림', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        foregroundColor: Colors.white,
        flexibleSpace: Container(decoration: const BoxDecoration(gradient: AppTheme.primaryGradient)),
        actions: [
          IconButton(
            key: const Key('notification_refresh'),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '새로고침',
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    final items = _items;
    if (items == null) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return _Message(
        icon: Icons.cloud_off_rounded,
        text: '알림을 불러오지 못했어요.',
        action: TextButton(onPressed: _load, child: const Text('다시 시도')),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_failed)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('최신 알림을 불러오지 못했어요. 아래는 마지막으로 받은 목록이에요.',
                  style: TextStyle(fontSize: 12, color: AppTheme.expense)),
            ),
          if (items.isEmpty)
            const _Message(icon: Icons.notifications_none_rounded, text: '새 알림이 없어요.')
          else
            for (final n in items) _NotificationTile(item: n, onTap: () => _open(n)),
        ],
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final AppNotification item;
  final VoidCallback onTap;
  const _NotificationTile({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final unread = !item.isRead;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: unread ? Colors.white : AppTheme.bgPage,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: Key('notification_${item.id}'),
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: unread ? AppTheme.primary.withOpacity(0.35) : AppTheme.divider),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 5, right: 10),
                  child: Icon(Icons.circle, size: 8, color: unread ? AppTheme.primary : Colors.transparent),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(notificationKindLabel(item.kind),
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.primary)),
                          if (item.remindCount > 0)
                            Text('재알림 ${item.remindCount}회',
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.expense)),
                          Text(notificationAge(item.notifiedAt),
                              style: const TextStyle(fontSize: 11, color: AppTheme.textSub)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(item.body,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.4,
                            color: AppTheme.textMain,
                            fontWeight: unread ? FontWeight.w600 : FontWeight.normal,
                          )),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  const _Message({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: AppTheme.textSub),
          const SizedBox(height: 10),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textSub)),
          if (action != null) ...[const SizedBox(height: 8), action!],
        ],
      ),
    );
  }
}
