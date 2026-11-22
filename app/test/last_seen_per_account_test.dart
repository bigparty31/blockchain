import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/services/student_api_service.dart';

import 'support/session.dart';

/// 미확인 뱃지의 「마지막으로 본 내역 id」는 **계정별**이다. 로그아웃 때 지우면 같은 학생이 다시 로그인해도
/// 전체 내역이 새 항목으로 뜬다 (실기기에서 14 가 다시 떴다).
const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  final store = <String, String>{};

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    store.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      final key = call.arguments['key'] as String?;
      switch (call.method) {
        case 'read':
          return store[key];
        case 'write':
          store[key!] = call.arguments['value'] as String;
          return null;
        case 'delete':
          store.remove(key);
          return null;
        case 'readAll':
          return Map<String, String>.of(store);
        case 'containsKey':
          return store.containsKey(key);
        default:
          return null;
      }
    });
  });

  tearDown(() async {
    await signOutForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
  });

  test('같은 학생이 로그아웃했다가 다시 로그인해도 본 위치가 이어진다', () async {
    final api = StudentApiService();
    await signInAs(UserRole.STUDENT, userId: 1);
    await api.markEntriesSeen(14);
    expect(await api.lastSeenEntryId(), 14);

    await api.resetSessionState(); // 로그아웃 때 main.dart 가 부르는 것
    await signOutForTest();
    await signInAs(UserRole.STUDENT, userId: 1);

    expect(await api.lastSeenEntryId(), 14, reason: '지워지면 전체 내역이 새 항목으로 다시 뜬다');
  });

  test('다른 학생에게는 앞사람의 본 위치가 넘어가지 않는다', () async {
    final api = StudentApiService();
    await signInAs(UserRole.STUDENT, userId: 1);
    await api.markEntriesSeen(14);
    await api.resetSessionState();
    await signOutForTest();

    await signInAs(UserRole.STUDENT, userId: 3);
    expect(await api.lastSeenEntryId(), 0, reason: '다른 계정의 기준을 읽으면 안 된다');
    await api.markEntriesSeen(5);

    await api.resetSessionState();
    await signOutForTest();
    await signInAs(UserRole.STUDENT, userId: 1);
    expect(await api.lastSeenEntryId(), 14, reason: '뒷사람이 써도 앞사람의 것은 그대로');
  });

  test('로그인한 학번을 모르면 읽지도 쓰지도 않는다', () async {
    final api = StudentApiService();
    await signOutForTest();
    await api.markEntriesSeen(14);
    expect(store, isEmpty, reason: '누구의 것인지 모르는 값을 저장하면 다음 사람에게 넘어간다');
    expect(await api.lastSeenEntryId(), 0);
  });

  test('예전 기기 공용 키는 로그아웃 때 정리한다', () async {
    store['student_last_seen_entry_id'] = '99';
    await StudentApiService().resetSessionState();
    expect(store.containsKey('student_last_seen_entry_id'), isFalse);
  });
}
