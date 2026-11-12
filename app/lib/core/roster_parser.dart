import 'dart:convert';

/// 납부자 명단을 읽은 결과.
class Roster {
  /// 학번 (파일 순서, 중복 제거).
  final List<String> studentNos;

  /// 같은 학번이 두 번 이상 나온 횟수 (첫 번째만 남겼다).
  final int duplicates;

  /// 학번을 찾지 못한 줄 수 (빈 줄·제목 줄 제외).
  final int unreadLines;

  const Roster({required this.studentNos, required this.duplicates, required this.unreadLines});
}

/// 납부자 명단 파일(CSV·TXT) 또는 붙여넣은 글에서 학번만 뽑는다 (PRD A3 「납부자 명단 파일 업로드」).
///
/// - 제목 줄에 `학번` 칸이 있으면 **그 칸만** 읽는다. 납부일(20261102 같은 8자리 숫자)이 다른 칸에 있어도 학번으로 오인하지 않는다.
/// - 제목 줄이 없으면(학번만 한 줄씩, 또는 붙여넣기) 줄마다 **첫 번째 숫자 칸**을 학번으로 본다.
/// - 학번은 6~12자리 숫자. 엑셀이 붙이는 따옴표·`="…"`·앞뒤 공백은 벗긴다.
///
/// 인코딩: 학번은 숫자라 UTF-8 이든 CP949(한글 엑셀 CSV)든 같은 바이트다. 한글 제목은 CP949 면 깨지는데,
/// 그때는 제목 줄을 못 찾아 「줄마다 첫 숫자 칸」 방식으로 읽는다.
class RosterParser {
  RosterParser._();

  static final _studentNo = RegExp(r'^\d{6,12}$');

  static Roster parseBytes(List<int> bytes) => parseText(utf8.decode(bytes, allowMalformed: true));

  static Roster parseText(String text) {
    final lines = const LineSplitter()
        .convert(text.replaceFirst('﻿', ''))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    int? column;
    var start = 0;
    if (lines.isNotEmpty) {
      final header = _cells(lines.first);
      final i = header.indexWhere((c) => c == '학번' || c.toLowerCase() == 'student_no');
      if (i >= 0) {
        column = i;
        start = 1;
      }
    }

    final seen = <String>{};
    final out = <String>[];
    var duplicates = 0;
    var unread = 0;
    for (final line in lines.skip(start)) {
      final cells = _cells(line);
      final String? no;
      if (column != null) {
        no = column < cells.length && _studentNo.hasMatch(cells[column]) ? cells[column] : null;
      } else {
        no = cells.cast<String?>().firstWhere((c) => _studentNo.hasMatch(c!), orElse: () => null);
      }
      if (no == null) {
        unread++;
      } else if (!seen.add(no)) {
        duplicates++;
      } else {
        out.add(no);
      }
    }
    return Roster(studentNos: out, duplicates: duplicates, unreadLines: unread);
  }

  /// 쉼표·탭·세미콜론으로 나누고, 엑셀 표기(`"…"`, `="…"`)를 벗긴다. 학번에 쉼표가 들어갈 일은 없어 따옴표 안 쉼표는 다루지 않는다.
  static List<String> _cells(String line) => line.split(RegExp(r'[,\t;]')).map((c) {
        var v = c.trim();
        if (v.startsWith('=')) v = v.substring(1);
        if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) v = v.substring(1, v.length - 1);
        return v.trim();
      }).toList();
}
