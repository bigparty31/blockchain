import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// 영수증 원본 바이트를 고른다. 고르지 않으면 null. 등록 화면이 받고, 테스트는 가짜를 넣는다.
typedef ReceiptPicker = Future<List<int>?> Function(BuildContext context);

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
