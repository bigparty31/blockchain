import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/enums.dart';
import '../../core/format.dart';
import '../../core/hashing.dart';
import '../../models/entry_model.dart';
import '../../services/entry_registration_service.dart';

/// 영수증 원본을 불러와 기록된 해시와 맞춰 본 결과.
enum ReceiptCheck {
  /// 받은 파일의 SHA-256 이 등록 때 기록된 `receipt_hash` 와 같다 — 올릴 때의 그 파일이다.
  matched,

  /// 받은 파일의 해시가 기록과 다르다 — 올린 뒤 바뀌었거나 다른 파일이다. **이 파일은 보여 주지 않는다.**
  mismatched,

  /// 파일을 받지 못했다 (서버 오류, 옛 서버에 `GET /receipts` 가 없음, 파일 없음).
  unavailable,
}

class ReceiptVerdict {
  final ReceiptCheck check;

  /// 받은 파일. [ReceiptCheck.matched] 일 때만 있다 — 해시가 다른 파일을 화면에 올리지 않는다.
  final Uint8List? bytes;

  /// 앱이 받은 파일로 다시 계산한 해시. 못 받았으면 null.
  final String? computedHash;

  const ReceiptVerdict(this.check, {this.bytes, this.computedHash});
}

/// [entry] 의 영수증 원본을 서버에서 받아 **앱이 직접** SHA-256 을 계산해 기록과 맞춰 본다.
/// 서버가 「일치」라고 알려 주는 것을 믿지 않는다 — 같은 바이트로 같은 해시가 나오는지가 증거다.
///
/// 영수증이 없는 건(수입 등)은 부르지 않는다 — [EntryModel.receiptHash]·[EntryModel.receiptPath] 가 있을 때만.
Future<ReceiptVerdict> verifyReceipt(EntryRegistrar registrar, EntryModel entry) async {
  final recorded = entry.receiptHash;
  final path = entry.receiptPath;
  if (recorded == null || path == null) return const ReceiptVerdict(ReceiptCheck.unavailable);
  final bytes = await registrar.downloadReceipt(path);
  if (bytes == null) return const ReceiptVerdict(ReceiptCheck.unavailable);
  final computed = Hashing.fileHash(bytes);
  if (!Hashing.hashEquals(computed, recorded)) {
    return ReceiptVerdict(ReceiptCheck.mismatched, computedHash: computed);
  }
  return ReceiptVerdict(ReceiptCheck.matched, bytes: Uint8List.fromList(bytes), computedHash: computed);
}

/// 승인 화면의 「영수증」 — 서버 건이면 원본 이미지를 받아 해시를 대조해 보여 주고, 목업 건은 자리표시만 보인다.
class ReceiptViewDialog extends StatefulWidget {
  /// 승인 카드 재료 ([approvalItemFromEntry]). 서버 건은 `'entry'` 에 [EntryModel] 이 있다.
  final Map<String, dynamic> item;

  /// 원본을 받아 오는 입구. 테스트에서 가짜를 넣는다.
  final EntryRegistrar registrar;

  const ReceiptViewDialog({super.key, required this.item, required this.registrar});

  @override
  State<ReceiptViewDialog> createState() => _ReceiptViewDialogState();
}

class _ReceiptViewDialogState extends State<ReceiptViewDialog> {
  ReceiptVerdict? _verdict;
  bool _loading = false;

  EntryModel? get _entry => widget.item['entry'] is EntryModel ? widget.item['entry'] as EntryModel : null;

  /// 받아 볼 영수증이 있는가 — 해시와 경로가 모두 있을 때. 영수증 없는 수입 건은 없다.
  bool get _hasReceipt => _entry?.receiptHash != null && _entry?.receiptPath != null;

  @override
  void initState() {
    super.initState();
    if (_hasReceipt) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final verdict = await verifyReceipt(widget.registrar, _entry!);
    if (!mounted) return;
    setState(() {
      _verdict = verdict;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: AppTheme.primaryLight, borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.receipt_long_rounded, color: AppTheme.primary, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('영수증 확인 (#${item['id']})',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.textMain),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _body(),
            const SizedBox(height: 16),
            _row(Icons.description_rounded, '증빙 종류', '${item['receiptInfo']}'),
            _row(
              Icons.document_scanner_rounded,
              'OCR 결과',
              // 영수증 없는 수입은 OCR 을 돌리지 않아 null 이다
              (item['ocrStatus'] as OcrStatus?)?.label ?? '판독 안 함',
            ),
            _row(Icons.storefront_rounded, '가맹점', '${item['merchant']} | ${item['amount']}원'),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppTheme.primary),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: const Text('닫기', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  /// 영수증 자리 — 상태별로 다른 것을 보인다. 해시가 다른 파일은 어떤 경우에도 그리지 않는다.
  Widget _body() {
    // 목업 건 — 서버 파일이 없다. 자리표시만 (예전 모양 그대로)
    if (_entry == null) return _placeholder('영수증 이미지 원본', Icons.receipt_long_rounded);
    if (!_hasReceipt) {
      return _placeholder(_entry!.kind == EntryKind.INCOME ? '수입 건 — 영수증 없음' : '영수증이 첨부되지 않았어요', Icons.receipt_long_rounded);
    }
    if (_loading || _verdict == null) {
      return const SizedBox(
        key: Key('receipt_loading'),
        height: 160,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final v = _verdict!;
    switch (v.check) {
      case ReceiptCheck.matched:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                constraints: const BoxConstraints(maxHeight: 320),
                color: AppTheme.bgPage,
                child: Image.memory(
                  v.bytes!,
                  key: const Key('receipt_image'),
                  fit: BoxFit.contain,
                  // 해시는 맞는데 이미지로 열리지 않는 형식 (PDF 등)
                  errorBuilder: (_, __, ___) => _placeholder('미리 볼 수 없는 파일 형식이에요', Icons.insert_drive_file_rounded),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _badge(
              key: const Key('receipt_hash_match'),
              icon: Icons.verified_rounded,
              color: AppTheme.success,
              text: '올릴 때의 해시와 같아요 — 바뀌지 않은 원본이에요',
            ),
          ],
        );
      case ReceiptCheck.mismatched:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _badge(
              key: const Key('receipt_hash_mismatch'),
              icon: Icons.gpp_bad_rounded,
              color: AppTheme.expense,
              text: '서버의 파일이 기록된 해시와 달라요 — 올린 뒤 바뀌었을 수 있어 보여 주지 않아요. 승인하지 말고 총무에게 확인해 주세요.',
            ),
            const SizedBox(height: 8),
            Text('기록 ${Fmt.shortHash(_entry!.receiptHash!)}\n받은 파일 ${Fmt.shortHash(v.computedHash!)}',
              style: const TextStyle(fontSize: 11, height: 1.5, color: AppTheme.textSub),
            ),
          ],
        );
      case ReceiptCheck.unavailable:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _badge(
              key: const Key('receipt_unavailable'),
              icon: Icons.cloud_off_rounded,
              color: AppTheme.pending,
              text: '영수증 파일을 불러오지 못했어요. 원본을 확인하지 못하면 해시가 맞는지도 알 수 없어요.',
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('다시 시도'),
            ),
          ],
        );
    }
  }

  Widget _placeholder(String label, IconData icon) => Container(
        height: 160,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFEDE9FE), Color(0xFFE0F2FE)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              child: Icon(icon, size: 40, color: AppTheme.primary),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(label,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textMain),
              ),
            ),
          ],
        ),
      );

  Widget _badge({required Key key, required IconData icon, required Color color, required String text}) => Container(
        key: key,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: TextStyle(fontSize: 12, height: 1.4, color: color, fontWeight: FontWeight.w600))),
          ],
        ),
      );

  Widget _row(IconData icon, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 15, color: AppTheme.primary),
            const SizedBox(width: 8),
            Text('$label: ', style: const TextStyle(color: AppTheme.textSub, fontSize: 12)),
            Expanded(child: Text(value, style: const TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w600, fontSize: 12))),
          ],
        ),
      );
}
