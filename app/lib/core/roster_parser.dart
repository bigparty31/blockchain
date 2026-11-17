import 'dart:convert';

/// 명단에서 학번을 **확실히** 고를 수 없을 때. 짐작해서 다른 학생을 대상으로 넣지 않고 멈춘다.
class RosterFormatException implements Exception {
  final String message;
  const RosterFormatException(this.message);

  @override
  String toString() => 'RosterFormatException: $message';
}

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
/// **짐작하지 않는다** (#102 리뷰): 학번 칸을 잘못 고르면 다른 학생에게 회원권이 발행된다.
/// - UTF-8 이 아닌 파일(한글 엑셀의 기본 CSV 는 CP949)은 읽지 않는다. 제목 「학번」이 깨져 칸을 못 찾고,
///   그러면 `이름,납부일,학번` 의 납부일(20261102)을 학번으로 집게 된다. Dart 에는 CP949 디코더가 없어 다시 저장을 안내한다.
/// - 제목 줄이 없는데 한 줄에 학번 모양 숫자가 둘 이상이면 어느 것이 학번인지 모르므로 멈춘다.
class RosterParser {
  RosterParser._();

  static final _studentNo = RegExp(r'^\d{6,12}$');

  static Roster parseBytes(List<int> bytes) {
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw const RosterFormatException(
        'UTF-8 로 저장된 파일이 아니에요 (한글 엑셀 기본 CSV 로 보여요). 엑셀에서 「CSV UTF-8(쉼표로 분리)」로 다시 저장해 주세요.',
      );
    }
    return parseText(text);
  }

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
        final candidates = cells.where(_studentNo.hasMatch).toList();
        if (candidates.length > 1) {
          throw RosterFormatException(
            '한 줄에 학번처럼 보이는 숫자가 ${candidates.length}개 있어요 (「$line」). '
            '어느 것이 학번인지 알 수 없어 읽지 않았어요. 제목 줄에 「학번」 칸을 넣어 주세요.',
          );
        }
        no = candidates.isEmpty ? null : candidates.single;
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
