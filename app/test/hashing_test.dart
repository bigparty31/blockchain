import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/hashing.dart';

/// `docs/hashing_vectors.json` 정본 벡터로 해시 구현을 검증한다.
///
/// **문서에서 값을 눈으로 옮겨 적지 않는다.** 파일을 읽어서 대조한다.
/// 값이 어긋나면 학생 화면의 검증 배지가 전부 빨강으로 뜨므로,
/// 이 테스트가 깨진 채로 커밋하면 안 된다.
void main() {
  late Map<String, dynamic> vectors;

  setUpAll(() {
    // `flutter test` 의 작업 디렉터리는 패키지 루트(app/)다.
    final file = File('../docs/hashing_vectors.json');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'docs/hashing_vectors.json 을 찾지 못했다. develop 을 병합했는지 확인할 것',
    );
    vectors = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  });

  test('규칙 버전과 구분자가 정본과 일치한다', () {
    expect(vectors['hash_rule_version'], Hashing.ruleVersion);
    expect(vectors['separator'], Hashing.unitSeparator);
    expect(Hashing.unitSeparator.codeUnitAt(0), 0x1F);
    expect(vectors['encoding'], 'UTF-8');
    expect(vectors['normalization'], 'NFC');
  });

  group('meta_hash — 학생 앱 대상 3건 (canonical 없이)', () {
    // 학생 앱은 API 가 준 정본 값을 그대로 해시한다 (HASHING.md §1.1).
    // canonical() 을 검사하는 두 벡터(nfd·spaces)는 대상이 아니다.
    const studentVectors = [
      'expense_with_receipt',
      'income_without_receipt',
      'correction_negative_amount',
    ];

    for (final name in studentVectors) {
      test(name, () {
        final v = _findVector(vectors['meta_hash'] as List, name);
        final input = v['input'] as Map<String, dynamic>;

        final preimage = Hashing.metaPreimage(
          amount: input['amount'] as int,
          counterparty: input['counterparty'] as String,
          purpose: input['purpose'] as String,
          occurredAt: input['occurred_at'] as int,
          receiptHash: input['receipt_hash'] as String?,
        );

        // preimage 부터 대조한다. 해시만 보면 어디가 틀렸는지 알 수 없다.
        expect(
          _toHex(utf8.encode(preimage)),
          v['preimage_hex'],
          reason: '$name: preimage 가 다르다 (구분자·필드 순서·인코딩 확인)',
        );

        final actual = Hashing.metaHash(
          amount: input['amount'] as int,
          counterparty: input['counterparty'] as String,
          purpose: input['purpose'] as String,
          occurredAt: input['occurred_at'] as int,
          receiptHash: input['receipt_hash'] as String?,
        );
        expect(actual, v['expected'], reason: '$name: meta_hash 불일치');
      });
    }

    test('occurred_at 이 모두 KST 자정이다', () {
      for (final name in studentVectors) {
        final v = _findVector(vectors['meta_hash'] as List, name);
        final ts = (v['input'] as Map)['occurred_at'] as int;
        expect(
          Hashing.isKstMidnight(ts),
          isTrue,
          reason: '$name: $ts 는 KST 자정이 아니다 (ts % 86400 == 54000)',
        );
      }
    });
  });

  group('canonical() — 총무·감사 앱이 서명용으로 쓴다', () {
    // 학생 앱은 호출하지 않지만, 구현이 틀리면 승호 파트에서 해시가 깨진다.
    test('NFD 입력을 NFC 로 정규화한다', () {
      final v = _findVector(vectors['meta_hash'] as List, 'nfd_input_normalizes_to_nfc');
      final input = v['input'] as Map<String, dynamic>;

      final actual = Hashing.metaHash(
        amount: input['amount'] as int,
        counterparty: Hashing.canonical(input['counterparty'] as String),
        purpose: Hashing.canonical(input['purpose'] as String),
        occurredAt: input['occurred_at'] as int,
        receiptHash: input['receipt_hash'] as String?,
      );
      expect(actual, v['expected']);
    });

    test('앞뒤 U+0020 을 제거한다', () {
      final v = _findVector(vectors['meta_hash'] as List, 'leading_trailing_spaces_trimmed');
      final input = v['input'] as Map<String, dynamic>;

      final actual = Hashing.metaHash(
        amount: input['amount'] as int,
        counterparty: Hashing.canonical(input['counterparty'] as String),
        purpose: Hashing.canonical(input['purpose'] as String),
        occurredAt: input['occurred_at'] as int,
        receiptHash: input['receipt_hash'] as String?,
      );
      expect(actual, v['expected']);
    });

    // String.trim() 을 썼다면 여기서 전부 걸린다.
    for (final name in const [
      'bom_must_not_be_trimmed',
      'nbsp_must_not_be_trimmed',
      'ideographic_space_must_not_be_trimmed',
      'tab_must_not_be_trimmed',
    ]) {
      test('$name — U+0020 외에는 지우지 않는다', () {
        final v = _findVector(vectors['negative_cases'] as List, name);
        final output = Hashing.canonical(v['input'] as String);
        expect(
          _toHex(utf8.encode(output)),
          v['expected_output_hex'],
          reason: '$name: String.trim() 을 쓰면 여기서 걸린다',
        );
      });
    }
  });

  test('파이프 구분자였다면 충돌했을 두 항목이 서로 다르다', () {
    final v = _findVector(vectors['negative_cases'] as List, 'pipe_separator_collision');
    final entries = v['entries'] as List;

    final hashes = <String>[];
    for (final e in entries) {
      final input = e['input'] as Map<String, dynamic>;
      final preimage = Hashing.metaPreimage(
        amount: input['amount'] as int,
        counterparty: input['counterparty'] as String,
        purpose: input['purpose'] as String,
        occurredAt: input['occurred_at'] as int,
        receiptHash: input['receipt_hash'] as String?,
      );
      expect(_toHex(utf8.encode(preimage)), e['preimage_hex'], reason: e['name']);

      final hash = Hashing.metaHash(
        amount: input['amount'] as int,
        counterparty: input['counterparty'] as String,
        purpose: input['purpose'] as String,
        occurredAt: input['occurred_at'] as int,
        receiptHash: input['receipt_hash'] as String?,
      );
      expect(hash, e['expected'], reason: e['name']);
      hashes.add(hash);
    }

    expect(hashes[0], isNot(hashes[1]), reason: '두 항목의 해시가 같으면 구분자가 틀린 것이다');
  });

  group('text_hash (§3)', () {
    test('정본 벡터 전건', () {
      for (final v in vectors['text_hash'] as List) {
        final canonical = Hashing.canonicalText(v['input'] as String);
        expect(
          Hashing.textHash(canonical),
          v['expected'],
          reason: '${v['name']}: ${v['description']}',
        );
      }
    });

    test('빈 문자열은 해시하지 않는다는 전제를 기록해 둔다', () {
      // 다듬은 뒤 빈 문자열이면 bytes32(0) 을 넘겨야 한다.
      // text_hash("") 를 올리면 §2.1 의 NULL ↔ bytes32(0) 대조에서 위조로 판정된다.
      expect(Hashing.canonicalText('  \n\t '), '');
      expect(
        Hashing.textHash(''),
        '0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });
  });

  test('file_hash (§4) — 바이트 그대로, 인코딩이 다르면 해시도 다르다', () {
    final list = vectors['file_hash'] as List;
    final byName = <String, String>{};

    for (final v in list) {
      final bytes = _fromHex(v['content_hex'] as String);
      final actual = Hashing.fileHash(bytes);
      expect(actual, v['expected'], reason: '${v['name']}: ${v['description']}');
      byName[v['name'] as String] = actual;
    }

    for (final v in list) {
      final other = v['must_differ_from'] as String?;
      if (other != null) {
        expect(byName[v['name']], isNot(byName[other]));
      }
    }
  });

  group('KST 자정 변환 (§1.3)', () {
    test('문서에 적힌 두 날짜가 그대로 나온다', () {
      expect(Hashing.kstMidnightOf(2026, 9, 8), 1788793200);
      expect(Hashing.kstMidnightOf(2026, 9, 6), 1788620400);
    });

    test('UTC 자정으로 계산하면 전날로 밀린다', () {
      // 1788793200 은 UTC 로는 2026-09-07 15:00 이다.
      final utcView = DateTime.fromMillisecondsSinceEpoch(1788793200 * 1000, isUtc: true);
      expect(utcView.day, 7);
      // KST 로 보면 2026-09-08 00:00 이다.
      expect(Hashing.kstDateOf(1788793200).day, 8);
    });

    test('생성한 값은 모두 검사를 통과한다', () {
      for (var d = 1; d <= 28; d++) {
        expect(Hashing.isKstMidnight(Hashing.kstMidnightOf(2026, 9, d)), isTrue);
      }
    });
  });

  test('hashEquals 는 0x 접두사와 대소문자만 맞춰 본다', () {
    const bare = '24ae73988d927fb39f45eb6024e9ff8ffa19e8501603565bd82710ea8df4b937';
    expect(Hashing.hashEquals('0x$bare', bare), isTrue);
    expect(Hashing.hashEquals('0x$bare', '0X${bare.toUpperCase()}'), isTrue);
    expect(Hashing.hashEquals('0x$bare', '0x${'0' * 64}'), isFalse);
  });
}

Map<String, dynamic> _findVector(List<dynamic> list, String name) {
  final match = list.firstWhere(
    (v) => (v as Map)['name'] == name,
    orElse: () => throw StateError('벡터 $name 을 찾지 못했다'),
  );
  return match as Map<String, dynamic>;
}

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<int> _fromHex(String hex) => [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
