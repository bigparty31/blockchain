import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/models/draft_entry.dart';
import 'package:student_council_app/services/auth_service.dart';
import 'package:student_council_app/services/entry_registration_service.dart';

import 'support/session.dart';

/// 영수증 OCR 판독 — 앱이 `POST /ocr/receipt` 를 부르는 쪽 (PRD §6). 판정은 서버가 한다 (backend/tests/test_ocr_api.py).
void main() {
  final jpeg = [0xFF, 0xD8, 0xFF, 0xE0, ...utf8.encode('receipt jpeg')];
  final png = [0x89, 0x50, 0x4E, 0x47, ...utf8.encode('receipt png')];
  final pdf = utf8.encode('%PDF-1.7 receipt');

  final requests = <http.Request>[];
  late http.Response Function() onOcr;

  http.Response json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  setUp(() async {
    await signInAs(UserRole.TREASURER, userId: 2);
    requests.clear();
    onOcr = () => json({
          'ocr_status': 'MISMATCH',
          'ocr_amount': 30000,
          'input_amount': 35000,
          'duplicate_of': null,
          'ocr_approval_no': 'G63213610',
          'ocr_paid_at': 1794038754,
        });
    EntryRegistrationService.client = MockClient((req) async {
      requests.add(req);
      return onOcr();
    });
  });

  tearDown(() async {
    EntryRegistrationService.client = http.Client();
    await signOutForTest();
  });

  test('원본 바이트를 base64 로, 형식·입력 금액과 함께 보내고 판독값을 읽는다', () async {
    final r = await EntryRegistrationService().readReceipt(jpeg, amount: 35000);

    final req = requests.single;
    expect(req.url.path, '/ocr/receipt');
    expect(req.headers['Authorization'], startsWith('Bearer '), reason: '총무 전용 API');
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    expect(base64Decode(body['image_base64'] as String), jpeg, reason: '재인코딩하지 않는다');
    expect(body['format'], 'jpg');
    expect(body['amount'], 35000);

    expect(r, const OcrReading(status: OcrStatus.MISMATCH, amount: 30000, approvalNo: 'G63213610', paidAt: 1794038754));
    expect(r!.needsConfirm, isTrue);
  });

  test('PNG 는 png 로 보내고, PDF·WebP 는 서버가 판독하지 않아 부르지 않는다', () async {
    await EntryRegistrationService().readReceipt(png, amount: 1000);
    expect((jsonDecode(requests.single.body) as Map)['format'], 'png');

    expect(await EntryRegistrationService().readReceipt(pdf, amount: 1000), isNull);
    expect(requests, hasLength(1));
  });

  test('서버 오류·응답 모양이 다르면 null — 등록을 막지 않는다', () async {
    onOcr = () => json({'detail': 'down'}, 503);
    expect(await EntryRegistrationService().readReceipt(jpeg, amount: 35000), isNull);
    onOcr = () => json({'detail': 'Not Found'}, 404); // OCR 라우터가 없는 옛 서버
    expect(await EntryRegistrationService().readReceipt(jpeg, amount: 35000), isNull);
    onOcr = () => json({'result': 'ok'});
    expect(await EntryRegistrationService().readReceipt(jpeg, amount: 35000), isNull);
  });

  test('로그인이 끝났으면(401) 알린다 — 판독 없이 등록을 이어가지 않는다', () async {
    onOcr = () => json({'detail': 'expired'}, 401);
    await expectLater(
      EntryRegistrationService().readReceipt(jpeg, amount: 35000),
      throwsA(isA<EntryDecisionException>().having((e) => e.failure, 'failure', EntryDecisionFailure.unauthorized)),
    );
    expect(AuthService().session, isNull);
  });

  test('초안 본문에는 ocr_* 만 싣고 중복 대상 id 는 보내지 않는다 (서버가 다시 찾는다)', () {
    const dup = OcrReading(status: OcrStatus.DUPLICATE, amount: 35000, approvalNo: '39007018', paidAt: 1, duplicateOf: 7);
    expect(dup.toCreateJson(), {
      'ocr_status': 'DUPLICATE',
      'ocr_amount': 35000,
      'ocr_approval_no': '39007018',
      'ocr_paid_at': 1,
    });
    const unreadable = OcrReading(status: OcrStatus.UNREADABLE);
    expect(unreadable.toCreateJson(), {'ocr_status': 'UNREADABLE'});
    expect(unreadable.needsConfirm, isFalse, reason: '판독 불가는 묻지 않는다 — 승인 화면에서 경고된다');
  });

  test('초안 목록의 OCR 값을 읽어 이어서 제출할 초안에 넘긴다', () {
    final d = DraftEntry.fromJson({
      'id': 9,
      'term_id': 1,
      'kind': 'EXPENSE',
      'amount': 35000,
      'counterparty': '한결문구',
      'purpose': '명찰',
      'occurred_at': 1789225200,
      'receipt_hash': '0x${'AB' * 32}',
      'ocr_status': 'MATCH',
      'ocr_amount': 35000,
      'ocr_approval_no': '39007018',
      'ocr_paid_at': 1789052400,
      'status': null,
    });
    expect(d.toEntryDraft().ocr,
        const OcrReading(status: OcrStatus.MATCH, amount: 35000, approvalNo: '39007018', paidAt: 1789052400));
    expect(
      DraftEntry.fromJson({
        'id': 9, 'term_id': 1, 'kind': 'EXPENSE', 'amount': 1, 'occurred_at': 0, 'status': null, //
      }).ocr,
      isNull,
    );
  });
}
