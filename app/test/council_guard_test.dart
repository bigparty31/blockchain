import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_council_app/core/enums.dart';
import 'package:student_council_app/screens/council/approval_list_screen.dart';
import 'package:student_council_app/screens/council/correction_approval_screen.dart';
import 'package:student_council_app/screens/council/income_create_screen.dart';
import 'package:student_council_app/services/api_service.dart';
import 'package:student_council_app/services/auth_service.dart';

/// 승인 화면의 역할 가드와 본인 등록 건 차단, 수입 영수증 첨부(선택).
void main() {
  setUp(() {
    AuthService.store = MemoryTokenStore();
    AuthService.lockStore = MemoryLoginLockStore();
    AuthService().resetAttempts();
    // 목업 목록(items)으로 가드를 본다. 서버 목록 경로는 council_decision_test.dart
    ApiService.useDemoData = true;
  });

  tearDown(() async {
    await AuthService().logout();
    AuthService.client = http.Client();
  });

  /// 가짜 서버로 로그인해 [AuthService.session] 을 채운다 (`logout_test.dart` 와 같은 방식).
  Future<void> loginAs(UserRole role, int userId) async {
    http.Response json(Object body) => http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
    AuthService.client = MockClient((req) async {
      if (req.url.path == '/auth/login') {
        return json({'access_token': 'token-$userId', 'token_type': 'bearer', 'role': role.code, 'name': '임원'});
      }
      if (req.url.path == '/auth/me') {
        return json({'id': userId, 'student_no': '2024000$userId', 'name': '임원', 'role': role.code});
      }
      return http.Response('{}', 404);
    });
    await AuthService().login('2024000$userId', 'userPassword123!');
  }

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(411, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: home));
    await tester.pumpAndSettle();
  }

  group('승인 화면 역할 가드', () {
    for (final role in [UserRole.TREASURER, UserRole.STUDENT, null]) {
      testWidgets('${role?.code ?? '로그인 안 함'} 는 열 수 없다', (tester) async {
        await pump(tester, ApprovalListScreen(role: role, items: buildApprovalMockItems()));
        expect(find.text('이 작업을 할 권한이 없습니다.'), findsOneWidget);
        expect(find.text('승인 서명'), findsNothing);
      });
    }

    for (final role in [UserRole.AUDITOR, UserRole.PRESIDENT]) {
      testWidgets('${role.code} 는 연다', (tester) async {
        await pump(tester, ApprovalListScreen(role: role, items: buildApprovalMockItems()));
        expect(find.text('이 작업을 할 권한이 없습니다.'), findsNothing);
        expect(find.text('승인 서명'), findsWidgets);
      });
    }

    testWidgets('인자를 주지 않으면 로그인한 세션의 역할을 쓴다', (tester) async {
      await loginAs(UserRole.TREASURER, 2);
      await pump(tester, ApprovalListScreen(items: buildApprovalMockItems()));
      expect(find.text('이 작업을 할 권한이 없습니다.'), findsOneWidget);

      await loginAs(UserRole.AUDITOR, 5);
      await pump(tester, ApprovalListScreen(items: buildApprovalMockItems()));
      expect(find.text('승인 서명'), findsWidgets);
    });

    testWidgets('로그인했으면 인자로 받은 역할보다 세션 역할을 믿는다 — 인자로 권한을 주장할 수 없다', (tester) async {
      await loginAs(UserRole.TREASURER, 2);
      await pump(tester, ApprovalListScreen(role: UserRole.AUDITOR, items: buildApprovalMockItems()));
      expect(find.text('이 작업을 할 권한이 없습니다.'), findsOneWidget);

      await pump(tester, const CorrectionApprovalScreen(role: UserRole.PRESIDENT));
      expect(find.text('이 작업을 할 권한이 없습니다.'), findsOneWidget);
    });

    testWidgets('인자를 주지 않으면 로그인한 사람의 id 로 본인 등록 건을 막는다', (tester) async {
      // 목업 #9 「학교 지원금」은 3번 사용자가 등록했다.
      await loginAs(UserRole.AUDITOR, 3);
      await pump(tester, ApprovalListScreen(items: buildApprovalMockItems()));
      await tester.dragUntilVisible(find.text('등록자와 승인자가 같아 처리할 수 없어요'), find.byType(ListView).first, const Offset(0, -200));
      expect(find.text('등록자와 승인자가 같아 처리할 수 없어요'), findsOneWidget);
    });
  });

  group('본인 등록 건', () {
    test('등록자와 같은 사용자만 해당한다', () {
      expect(isOwnEntry({'createdBy': 3}, 3), isTrue);
      expect(isOwnEntry({'createdBy': 3}, 5), isFalse);
      expect(isOwnEntry({'createdBy': 3}, null), isFalse);
      expect(isOwnEntry({'id': 1}, 3), isFalse);
    });

    testWidgets('내가 등록한 건은 승인·반려 버튼이 회색이고 눌러도 아무 일도 없다', (tester) async {
      await pump(tester, ApprovalListScreen(role: UserRole.AUDITOR, currentUserId: 3, items: buildApprovalMockItems()));
      await tester.dragUntilVisible(find.text('등록자와 승인자가 같아 처리할 수 없어요'), find.byType(ListView).first, const Offset(0, -200));
      expect(find.text('등록자와 승인자가 같아 처리할 수 없어요'), findsOneWidget);
      // 마지막 「승인 서명」 글자가 내 건의 회색 칸이다 — 눌러도 서명 다이얼로그가 뜨지 않는다
      await tester.tap(find.text('승인 서명').last, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('집행 최종 승인'), findsNothing);
    });

    testWidgets('다른 감사에게는 같은 건이 정상으로 보이고 서명할 수 있다', (tester) async {
      await pump(tester, ApprovalListScreen(role: UserRole.AUDITOR, currentUserId: 5, items: buildApprovalMockItems()));
      expect(find.text('등록자와 승인자가 같아 처리할 수 없어요'), findsNothing);
      await tester.dragUntilVisible(find.text('학교 지원금'), find.byType(ListView).first, const Offset(0, -200));
      await tester.tap(find.text('승인 서명').last);
      await tester.pumpAndSettle();
      expect(find.text('집행 최종 승인'), findsOneWidget);
    });
  });

  group('수입 영수증 첨부 (선택)', () {
    testWidgets('첨부하지 않아도 제출되고, 첨부하면 결과에 표시된다', (tester) async {
      await pump(tester, const IncomeCreateScreen());
      expect(find.text('영수증 첨부 (선택)'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextFormField, '상세 출처 / 내용 *'), '학생회비 수납');
      await tester.enterText(find.widgetWithText(TextFormField, '입금 금액(원) *'), '1000000');
      await tester.ensureVisible(find.text('제출하기'));
      await tester.tap(find.text('제출하기'));
      await tester.pumpAndSettle();
      expect(find.text('수입 제출 완료!'), findsOneWidget);
      expect(find.textContaining('영수증: 없음'), findsOneWidget);
    });

    testWidgets('탭하면 첨부되고 다시 탭하면 해제된다', (tester) async {
      await pump(tester, const IncomeCreateScreen());
      await tester.ensureVisible(find.text('영수증 첨부 (선택)'));
      await tester.tap(find.text('영수증 첨부 (선택)'));
      await tester.pump();
      expect(find.text('영수증 첨부 완료 (탭하여 해제)'), findsOneWidget);
      await tester.tap(find.text('영수증 첨부 완료 (탭하여 해제)'));
      await tester.pump();
      expect(find.text('영수증 첨부 (선택)'), findsOneWidget);
    });
  });
}
