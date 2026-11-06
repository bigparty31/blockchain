import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// 영수증 원본 바이트를 고른다. 고르지 않으면 null. 등록 화면이 받고, 테스트는 가짜를 넣는다.
typedef ReceiptPicker = Future<List<int>?> Function(BuildContext context);

/// 업로드 파일 이름 — 내용의 앞 바이트로 형식을 알아내 확장자를 붙인다. 서버는 확장자를 그대로 쓰고
/// (`/receipts/{해시}.{확장자}`), 내려줄 때 그 확장자로 형식을 정한다.
String receiptFilename(List<int> bytes) {
  bool starts(List<int> sig, [int offset = 0]) {
    if (bytes.length < offset + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (bytes[offset + i] != sig[i]) return false;
    }
    return true;
  }

  if (starts([0x89, 0x50, 0x4E, 0x47])) return 'receipt.png';
  if (starts([0x25, 0x50, 0x44, 0x46])) return 'receipt.pdf'; // %PDF
  if (starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x45, 0x42, 0x50], 8)) return 'receipt.webp';
  if (starts([0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69], 4)) return 'receipt.heic'; // ftyphei(c)
  return 'receipt.jpg'; // JPEG(FF D8) 와 그 밖 — 서버 기본값과 같다
}

/// 기본 선택기 — 카메라 촬영 또는 갤러리.
///
/// `imageQuality`·`maxWidth` 를 주지 않는다. 주면 다시 인코딩돼 바이트가 바뀌고, 영수증 해시(`receipt_hash`)가
/// 원본 파일과 달라진다 — 서버도 재인코딩·EXIF 회전을 금지한다 (보드 kky-rcp, HASHING §4).
Future<List<int>?> pickReceiptBytes(BuildContext context) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.camera_alt_rounded),
            title: const Text('카메라로 촬영'),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_rounded),
            title: const Text('갤러리에서 선택'),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ],
      ),
    ),
  );
  if (source == null) return null;
  final file = await ImagePicker().pickImage(source: source);
  return file == null ? null : await file.readAsBytes();
}
