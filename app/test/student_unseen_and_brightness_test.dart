import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/app_theme.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/screens/student/entry_list_screen.dart';
import 'package:student_council_app/screens/student/my_sbt_screen.dart';
import 'package:student_council_app/screens/student/student_home_screen.dart';
import 'package:student_council_app/services/student_api_service.dart';

/// 스토리보드 2 ⑤(미확인 뱃지 → 새 항목만)와 6 ②(QR 을 누르면 화면 밝기)를
/// 못박는다. 둘 다 **화면이 멀쩡해 보이는 채로 뚫리는** 종류다.
///
/// 미확인 쪽이 특히 그렇다. 전체 목록을 열어도 화면은 정상이고, 잃는 것은
/// 「어느 것이 새 건지」뿐이다. 그런데 목록을 여는 순간 뱃지가 지워지므로
/// **다시 찾을 방법이 없어진다** — 지출 확정을 학생에게 알리는 S12 의 경로가
/// 거기서 끊긴다.
void main() {
  tearDown(() => StudentApiService.client = http.Client());

  group('정정 사유 OTHER (docs/enums.md)', () {
    test('OTHER 를 OTHER 로 읽는다', () {
      expect(CorrectionReason.fromCode('OTHER'), CorrectionReason.OTHER);
      expect(CorrectionReason.OTHER.label, '기타');
    });

    test('REFUND 라벨은 「반환」이다', () {
      expect(CorrectionReason.REFUND.label, '반환');
    });

    /// **이 테스트가 잡는 회귀** — `OTHER` 가 enum 에 없으면 `fromCode` 의
    /// `orElse` 가 `INPUT_ERROR` 로 떨어뜨린다. 비어 보이는 것이 아니라
    /// **틀린 사유가 화면에 뜬다.** 「기타(상세 사유는 purpose)」로 정정된
    /// 건이 「입력 오류」로 보이는 것이라 학생이 읽는 내용 자체가 달라진다.
    test('아는 코드는 INPUT_ERROR 로 뭉개지지 않는다', () {
      for (final r in CorrectionReason.values) {
        expect(CorrectionReason.fromCode(r.code), r,
            reason: '${r.code} 가 ${CorrectionReason.fromCode(r.code).code} 로 읽혔다');
      }
    });
  });

  group('미확인 뱃지 → 「새 항목」 필터 (스토리보드 2 ⑤)', () {
    setUp(_mockSecureStorage);
    tearDown(_clearSecureStorageMock);

    testWidgets('기준 id 보다 큰 항목만 보인다', (tester) async {
      StudentApiService.client = _ledger();

      // id 2 까지 확인했다 → 3 번만 새 항목이다.
      await _pumpList(tester, unseenAfterEntryId: 2);

      expect(find.textContaining('새로 들어온 지출'), findsOneWidget);
      expect(find.textContaining('지난달 간식비'), findsNothing,
          reason: '이미 확인한 항목은 「새 항목」에 없어야 한다');
    });

    testWidgets('「새 항목」 칩이 선택된 채로 열린다', (tester) async {
      StudentApiService.client = _ledger();

      await _pumpList(tester, unseenAfterEntryId: 2);

      expect(find.text('새 항목'), findsOneWidget);
    });

    testWidgets('뱃지 없이 들어오면 전체가 보이고 「새 항목」 칩도 없다', (tester) async {
      StudentApiService.client = _ledger();

      await _pumpList(tester, unseenAfterEntryId: null);

      expect(find.textContaining('지난달 간식비'), findsOneWidget);
      expect(find.textContaining('새로 들어온 지출'), findsOneWidget);

      // 목록을 한 번 열면 미확인은 영원히 0 건이다. 상시 탭으로 두면
      // 눌러도 아무것도 없는 칸이 남는다.
      expect(find.text('새 항목'), findsNothing);
    });

    testWidgets('비어 있으면 「전체 내역 보기」로 빠져나갈 수 있다', (tester) async {
      StudentApiService.client = _ledger();

      // 이미 전부 확인한 상태로 들어온 경우.
      await _pumpList(tester, unseenAfterEntryId: 99);

      expect(find.text('새로 올라온 항목이 없습니다'), findsOneWidget);
      expect(find.text('해당하는 내역이 없습니다'), findsNothing,
          reason: '「새 항목이 없다」와 「내역이 없다」는 다른 말이다');

      await tester.tap(find.text('전체 내역 보기'));
      await _settle(tester);

      expect(find.textContaining('지난달 간식비'), findsOneWidget);
    });

    /// 오래된 지출에 **정정이 새로 붙은** 건. 원본 id 만 보면 「새 소식 없음」
    /// 으로 빠지는데, 금액이 바뀐 것이야말로 학생이 봐야 할 변화다.
    testWidgets('정정이 새로 붙은 오래된 건도 새 항목에 걸린다', (tester) async {
      StudentApiService.client = _ledgerWithLateCorrection();

      await _pumpList(tester, unseenAfterEntryId: 2);

      expect(find.textContaining('지난달 간식비'), findsOneWidget,
          reason: '원본은 오래됐지만 정정(id 5)이 새로 붙었다');
    });
  });

  group('대시보드가 넘기는 기준 id', () {
    tearDown(_clearSecureStorageMock);

    /// **가장 중요한 회귀.** 목록을 여는 순간 `markEntriesSeen` 이 저장된 기준을
    /// 최신 id 로 덮어쓴다. 목록 화면이 기준을 직접 읽으면 **이미 덮어쓴 뒤라
    /// 언제나 0 건**이 되어, 필터가 있으나 마나가 된다. 그래서 덮어쓰기 전의
    /// 값을 대시보드가 들고 와서 넘겨야 한다.
    testWidgets('덮어쓰기 전의 값을 넘긴다', (tester) async {
      final writes = <String>[];
      _mockSecureStorage(read: '2', onWrite: writes.add);
      StudentApiService.client = _ledger();

      await _pumpWidget(tester, const StudentHomeScreen());

      // 뱃지가 떠 있다 (id 3 > 2).
      await _tapEntriesTile(tester);

      // 목록이 열리면서 기준이 3 으로 덮어써졌는데도…
      expect(writes, contains('3'),
          reason: '목록을 열면 읽음 처리가 돌아야 한다 (전제 확인)');

      // …필터는 옛 기준(2)으로 돈다.
      expect(find.textContaining('새로 들어온 지출'), findsOneWidget);
      expect(find.textContaining('지난달 간식비'), findsNothing,
          reason: '덮어쓴 값(3)을 기준으로 삼았으면 여기도 0 건이 된다');
    });

    testWidgets('미확인이 0 건이면 전체로 연다', (tester) async {
      _mockSecureStorage(read: '3'); // 이미 전부 확인
      StudentApiService.client = _ledger();

      await _pumpWidget(tester, const StudentHomeScreen());
      await _tapEntriesTile(tester);

      expect(find.text('새 항목'), findsNothing,
          reason: '새 것이 없는데 「새 항목」으로 열면 빈 화면부터 보게 된다');
      expect(find.textContaining('지난달 간식비'), findsOneWidget);
    });
  });

  group('QR 밝기 (스토리보드 6 ②)', () {
    late List<MethodCall> calls;

    setUp(() {
      _mockSecureStorage();
      calls = _mockBrightness();
    });
    tearDown(() {
      _clearSecureStorageMock();
      _clearBrightnessMock();
    });

    testWidgets('누르면 밝기를 올리고 안내 문구가 바뀐다', (tester) async {
      StudentApiService.client = _membership();

      await _pumpWidget(tester, const MySbtScreen());

      expect(find.text('QR을 누르면 화면이 밝아집니다'), findsOneWidget,
          reason: '안 적어 두면 누를 수 있다는 것을 아무도 모른다');

      await tester.tap(find.byKey(qrBrightnessToggleKey));
      await _settle(tester);

      expect(calls.map((c) => c.method), contains('setApplicationScreenBrightness'));
      expect(find.textContaining('밝기를 올렸습니다'), findsOneWidget);
    });

    testWidgets('다시 누르면 되돌린다', (tester) async {
      StudentApiService.client = _membership();
      await _pumpWidget(tester, const MySbtScreen());

      await tester.tap(find.byKey(qrBrightnessToggleKey));
      await _settle(tester);
      calls.clear();

      await tester.tap(find.byKey(qrBrightnessToggleKey));
      await _settle(tester);

      expect(calls.map((c) => c.method),
          contains('resetApplicationScreenBrightness'));
      expect(find.text('QR을 누르면 화면이 밝아집니다'), findsOneWidget);
    });

    /// 화면을 나갈 때 되돌리지 않으면 **다른 화면까지 최대 밝기로 남는다.**
    testWidgets('화면을 나가면 되돌린다', (tester) async {
      StudentApiService.client = _membership();
      await _pumpWidget(tester, const MySbtScreen());

      await tester.tap(find.byKey(qrBrightnessToggleKey));
      await _settle(tester);
      calls.clear();

      // 화면을 치운다 → dispose
      await _pumpWidget(tester, const SizedBox.shrink());

      expect(calls.map((c) => c.method),
          contains('resetApplicationScreenBrightness'));
    });

    /// 밝기는 **부가 기능**이다. 플랫폼 채널이 없거나 기기가 거부해도
    /// QR 은 멀쩡히 떠야 한다 — 입장에 쓰는 화면이다.
    testWidgets('밝기 조절이 실패해도 QR 은 그대로 뜬다', (tester) async {
      _clearBrightnessMock(); // MissingPluginException 이 나는 상태
      StudentApiService.client = _membership();

      await _pumpWidget(tester, const MySbtScreen());
      await tester.tap(find.byKey(qrBrightnessToggleKey));
      await _settle(tester);

      expect(tester.takeException(), isNull);
      expect(find.byKey(qrBrightnessToggleKey), findsOneWidget);
    });
  });
}

// ── 응답 ────────────────────────────────────────────────────────

/// id 1·2 는 오래된 건, id 3 이 새 건.
MockClient _ledger() => MockClient((req) async {
      if (req.url.path.endsWith('/entries')) {
        return http.Response(_entriesJson, 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return http.Response('[]', 200);
    });

/// 오래된 원본(id 1)에 새 정정(id 5)이 붙은 장부.
MockClient _ledgerWithLateCorrection() => MockClient((req) async {
      if (req.url.path.endsWith('/entries')) {
        return http.Response(_entriesWithCorrectionJson, 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return http.Response('[]', 200);
    });

MockClient _membership() => MockClient((req) async {
      if (req.url.path.endsWith('/memberships/me')) {
        return http.Response(_membershipJson, 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return http.Response('[]', 200);
    });

const _entriesJson = '''
[
  {"id":1,"term_id":1,"kind":"EXPENSE","amount":30000,"counterparty":"편의점",
   "purpose":"지난달 간식비","occurred_at":1762000000,"status":"CONFIRMED"},
  {"id":2,"term_id":1,"kind":"INCOME","amount":500000,"counterparty":"학과",
   "purpose":"지난달 지원금","occurred_at":1762000000,"status":"CONFIRMED"},
  {"id":3,"term_id":1,"kind":"EXPENSE","amount":12000,"counterparty":"문구점",
   "purpose":"새로 들어온 지출","occurred_at":1762600000,"status":"CONFIRMED"}
]
''';

const _entriesWithCorrectionJson = '''
[
  {"id":1,"term_id":1,"kind":"EXPENSE","amount":30000,"counterparty":"편의점",
   "purpose":"지난달 간식비","occurred_at":1762000000,"status":"CONFIRMED"},
  {"id":2,"term_id":1,"kind":"INCOME","amount":500000,"counterparty":"학과",
   "purpose":"지난달 지원금","occurred_at":1762000000,"status":"CONFIRMED"},
  {"id":5,"term_id":1,"kind":"EXPENSE","amount":-5000,"counterparty":"편의점",
   "purpose":"금액 정정","occurred_at":1762600000,"status":"CONFIRMED",
   "corrects_entry_id":1,"correction_reason":"INPUT_ERROR"}
]
''';

const _membershipJson = '''
{"id":1,"user_id":1,"term_id":1,"token_id":7,"commit_hash":"0xabc",
 "minted_at":1762000000,"qr_payload":"STU-2024001"}
''';

// ── 띄우기 ──────────────────────────────────────────────────────

/// 대시보드의 「수입·지출 내역」 타일을 누른다.
///
/// `find.text` 를 바로 누르면 안 된다 — 타일이 접힌 화면 아래에 있으면
/// 좌표가 화면 밖이라 탭이 **빗나가고도 테스트는 통과한다**(경고만 뜬다).
/// 보이는 데까지 스크롤한 뒤 누르고, 누를 대상도 `InkWell` 로 집는다.
Future<void> _tapEntriesTile(WidgetTester tester) async {
  final tile = find.ancestor(
    of: find.text('수입·지출 내역'),
    matching: find.byType(InkWell),
  );
  await tester.ensureVisible(tile.first);
  await tester.pump();
  await tester.tap(tile.first);
  await _settle(tester);
}

Future<void> _pumpList(WidgetTester tester, {int? unseenAfterEntryId}) =>
    _pumpWidget(tester, EntryListScreen(unseenAfterEntryId: unseenAfterEntryId));

Future<void> _pumpWidget(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(theme: AppTheme.themeData, home: child));
  await _settle(tester);
}

/// `_timeout` 타이머가 남아 있어 `pumpAndSettle` 은 쓰지 않는다
/// (`student_unavailable_states_test.dart` 의 같은 이유).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

// ── 플랫폼 채널 가짜 ─────────────────────────────────────────────

const _secureStorageChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const _brightnessChannel = MethodChannel('github.com/aaassseee/screen_brightness');

void _mockSecureStorage({String? read, void Function(String)? onWrite}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureStorageChannel, (call) async {
    switch (call.method) {
      case 'read':
        return read;
      case 'readAll':
        return <String, String>{};
      case 'containsKey':
        return read != null;
      case 'write':
        onWrite?.call(call.arguments['value'] as String);
        return null;
      default:
        return null;
    }
  });
}

void _clearSecureStorageMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureStorageChannel, null);
}

/// 밝기 채널이 받은 호출을 기록한다. 실제로 올라갔는지는 기기에서만 알 수
/// 있지만, **호출이 나갔는지와 되돌렸는지**는 여기서 못박을 수 있다.
List<MethodCall> _mockBrightness() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_brightnessChannel, (call) async {
    calls.add(call);
    return null;
  });
  return calls;
}

void _clearBrightnessMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_brightnessChannel, null);
}
