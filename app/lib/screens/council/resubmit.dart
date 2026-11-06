import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/enums.dart';
import '../../core/hashing.dart';
import '../../models/entry_model.dart';
import '../../services/entry_registration_service.dart';

/// 반려·차단된 건을 고쳐 **새 번호로** 다시 등록한다 (PRD §4.3 T4 3단계, 데모 6 재등록).
///
/// 체인은 같은 `entryId` 재기록을 막아서(`EntryAlreadyExists`) 이전 건을 고치는 방법이 없다. 이전 값으로
/// 입력 화면을 채워 열 뿐이고, 이전 기록은 체인에 그대로 남는다. **대기(`PENDING`) 건은 여기로 오지 않는다** —
/// 고쳐서 다시 올리면 두 건이 함께 대기하다 둘 다 확정될 수 있다. 대기 건은 「수정 요청 → 반려」가 먼저다.
bool canResubmit(EntryModel e) => e.status == EntryStatus.REJECTED || e.status == EntryStatus.BLOCKED;

/// 오늘의 **한국** 날짜 — 사용일 기본값. 기기 시간대가 UTC 면 `DateTime.now()` 의 날짜가 하루 늦다.
DateTime kstToday([DateTime? now]) {
  final d = Hashing.kstDateOf((now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000);
  return DateTime(d.year, d.month, d.day);
}

/// `occurred_at`(KST 자정) → 날짜 고르기 칸의 값. 연·월·일만 쓴다.
DateTime pickerDateOf(int occurredAt) {
  final d = Hashing.kstDateOf(occurredAt);
  return DateTime(d.year, d.month, d.day);
}

/// 이전 건의 영수증 원본을 서버에서 다시 받아 **해시가 기록과 같을 때만** 쓴다.
///
/// 받은 바이트를 앱이 다시 해시해 보고 서명한다 — 서버가 준 해시를 그대로 서명하지 않는다. 받지 못했거나
/// (옛 서버에는 `GET /receipts` 가 없다) 해시가 다르면 null 이고, 화면은 다시 첨부하라고 한다.
/// 같은 파일이 이미 서버에 있으니 다시 올리지 않고 그 경로를 쓴다.
Future<(List<int>, ReceiptUpload)?> restoreReceipt(EntryRegistrar registrar, EntryModel e) async {
  final hash = e.receiptHash;
  final path = e.receiptPath;
  if (hash == null || path == null) return null;
  final bytes = await registrar.downloadReceipt(path);
  if (bytes == null || !Hashing.hashEquals(Hashing.fileHash(bytes), hash)) return null;
  return (bytes, ReceiptUpload(hash.toLowerCase(), path));
}

/// 입력 화면 맨 위 안내 — 무엇을 다시 등록하는지, 왜 새 번호인지.
class ResubmitBanner extends StatelessWidget {
  final EntryModel source;

  /// 이전 영수증을 다시 쓸 수 없었으면 그 안내 (null 이면 문제 없음).
  final String? receiptNote;

  const ResubmitBanner({super.key, required this.source, this.receiptNote});

  @override
  Widget build(BuildContext context) {
    final rejected = source.status == EntryStatus.REJECTED;
    final title = rejected ? '반려된 #${source.id} 을 고쳐 새로 등록해요' : '차단된 #${source.id} 을 다시 등록해요';
    final reason = source.rejectReason;
    return Container(
      key: const Key('resubmit_banner'),
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.pending.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.pending.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.refresh_rounded, color: AppTheme.pending, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppTheme.textMain)),
              ),
            ],
          ),
          if (rejected && reason != null) ...[
            const SizedBox(height: 6),
            Text('반려 사유: $reason', style: const TextStyle(fontSize: 12, height: 1.4, color: AppTheme.textMain)),
          ],
          const SizedBox(height: 6),
          const Text('이전 값으로 채웠어요. 고친 뒤 제출하면 새 번호로 기록되고, 이전 기록은 체인에 그대로 남아요.',
              style: TextStyle(fontSize: 12, height: 1.4, color: AppTheme.textSub)),
          if (receiptNote != null) ...[
            const SizedBox(height: 6),
            Text(receiptNote!,
                key: const Key('resubmit_receipt_note'),
                style: const TextStyle(fontSize: 12, height: 1.4, color: AppTheme.expense)),
          ],
        ],
      ),
    );
  }
}
