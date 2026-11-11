import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// 영수증 원본 바이트를 고른다. 고르지 않으면 null. 등록 화면이 받고, 테스트는 가짜를 넣는다.
typedef ReceiptPicker = Future<List<int>?> Function(BuildContext context);

bool _starts(List<int> bytes, List<int> sig, [int offset = 0]) {
  if (bytes.length < offset + sig.length) return false;
  for (var i = 0; i < sig.length; i++) {
    if (bytes[offset + i] != sig[i]) return false;
  }
  return true;
}

/// HEIC·HEIF — `ftyp` 상자의 브랜드로 알아본다. 서버는 `.heic` 를 받지 않는다 (서버 #66 `ALLOWED_EXTENSIONS`).
bool _isHeic(List<int> bytes) {
  if (!_starts(bytes, 'ftyp'.codeUnits, 4) || bytes.length < 12) return false;
  final brand = String.fromCharCodes(bytes.sublist(8, 12));
  return const {'heic', 'heix', 'heim', 'heis', 'hevc', 'hevx', 'mif1', 'msf1'}.contains(brand);
}

/// 고른 영수증을 서버가 받을 수 없으면 그 안내 문구, 올릴 수 있으면 null. 고르는 자리에서 막아
/// 「영수증이 없어 지출을 못 올린다」로 끝나지 않게 한다.
String? receiptFormatProblem(List<int> bytes) =>
    _isHeic(bytes) ? '이 사진 형식(HEIC)은 서버가 받지 않아요. JPEG·PNG·WebP·PDF 로 다시 골라 주세요.' : null;

/// 업로드 파일 이름 — 내용의 앞 바이트로 형식을 알아내 확장자를 붙인다. 서버는 확장자를 그대로 쓰고
/// (`/receipts/{해시}.{확장자}`), 내려줄 때 그 확장자로 형식을 정한다. 서버에는 기본 확장자가 없고
/// 허용 목록(`.jpg`·`.jpeg`·`.png`·`.webp`·`.pdf`)에 없으면 400 으로 거부한다.
///
/// HEIC·HEIF 는 이름을 만들지 않고 던진다 — 고르는 자리에서 [receiptFormatProblem] 으로 걸러야 한다.
String receiptFilename(List<int> bytes) {
  if (_isHeic(bytes)) throw ArgumentError.value('HEIC', 'bytes', receiptFormatProblem(bytes));
  if (_starts(bytes, [0x89, 0x50, 0x4E, 0x47])) return 'receipt.png';
  if (_starts(bytes, [0x25, 0x50, 0x44, 0x46])) return 'receipt.pdf'; // %PDF
  if (_starts(bytes, [0x52, 0x49, 0x46, 0x46]) && _starts(bytes, [0x57, 0x45, 0x42, 0x50], 8)) return 'receipt.webp';
  return 'receipt.jpg'; // JPEG(FF D8) 와 그 밖 — 모르는 형식은 서버가 알아서 거부한다
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
