import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/api_config.dart';
import '../models/balance_model.dart';
import '../models/budget_model.dart';
import '../models/draft_entry.dart';
import '../models/entry_model.dart';
import '../core/dev_flags.dart';
import '../core/enums.dart';
import '../core/format.dart';
import 'auth_service.dart';

/// 서버에서 읽지 못했다 (연결 실패·200 이 아닌 응답·형식 오류). [what] 은 화면에 쓰는 대상 이름.
class ApiUnavailable implements Exception {
  final String what;
  const ApiUnavailable(this.what);

  String get message => '$what을(를) 불러오지 못했어요. 잠시 후 다시 시도해 주세요.';

  @override
  String toString() => '$runtimeType: $what';
}

/// 401 — 로그인이 끝났다. [AuthService.reportUnauthorized] 가 로그인 화면으로 보낸다.
class ApiUnauthorized extends ApiUnavailable {
  const ApiUnauthorized(super.what);

  @override
  String get message => '로그인이 끝났어요. 다시 로그인해 주세요.';
}

/// 403 — 로그인은 됐지만 이 역할로는 할 수 없다 (예: 총무가 승인 목록을 부름).
class ApiForbidden extends ApiUnavailable {
  const ApiForbidden(super.what);

  @override
  String get message => '이 작업을 할 권한이 없어요.';
}

/// 백엔드 FastAPI 서버(backend/app/main.py)와의 통신 서비스
///
/// **조회가 실패하면 [ApiUnavailable] 을 던진다. 더미 값으로 덮지 않는다** (PRD v0.14 §7.3).
/// 덮으면 서버가 죽어도 더미 건이 화면에 보이고, 임원이 그 건에 서명하게 된다.
/// 시연용 더미는 개발 빌드(`DEV_TOOLS`)에서만 켠다 — [useDemoData].
class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  /// 조회 실패 시 시연용 더미를 쓸지. 기본은 개발 빌드(`DEV_TOOLS`)에서만 켜진다.
  /// 목업 화면 테스트처럼 더미가 필요한 곳은 직접 켠다.
  static bool useDemoData = kDevTools;

  /// 더미를 쓸 수 없으면 던진다.
  static void _demoOrThrow(String what) {
    if (!useDemoData) throw ApiUnavailable(what);
  }

  /// HTTP 클라이언트. **테스트에서 갈아끼운다.**
  ///
  /// 패키지 함수 `http.get` 을 직접 부르면 테스트가 실제 네트워크를 타고, 결과가
  /// 「그 머신에 서버가 떠 있는지」에 따라 달라진다 (`student_api_service.dart`
  /// 의 `client` 주석에 같은 사고가 적혀 있다).
  static http.Client client = http.Client();

  static const _timeout = Duration(seconds: 3);

  /// GET + 로그인 토큰 ([AuthService.authSnapshot]).
  ///
  /// 401·403 은 「서버가 없다」와 다르다 — **더미로 메우지 않고** 바로 던진다.
  /// - 401: 세션이 끝났다. [AuthService.reportUnauthorized] 가 세션을 비우고 로그인 화면으로 보낸다.
  ///   **보내기 직전의 토큰**을 함께 넘긴다 — 늦게 돌아온 401 이 그 사이 다시 로그인해 만든 새 세션을 지우지 않게.
  /// - 403: 이 역할로는 볼 수 없다. 화면이 「권한이 없어요」를 띄운다.
  static Future<http.Response> _get(String url, String what) async {
    final auth = AuthService().authSnapshot; // 응답이 돌아온 뒤가 아니라 보내기 직전에 잡는다
    final res = await client.get(Uri.parse(url), headers: auth.headers).timeout(_timeout);
    if (res.statusCode == 401) {
      await AuthService().reportUnauthorized(token: auth.token);
      throw ApiUnauthorized(what);
    }
    if (res.statusCode == 403) throw ApiForbidden(what);
    return res;
  }

  /// 1. GET /balance (장부 잔액 조회)
  Future<BalanceModel> fetchBalance() async {
    try {
      final response = await _get(ApiConfig.balance, '장부 잔액');
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(utf8.decode(response.bodyBytes));
        return BalanceModel.fromJson(data);
      }
    } on ApiUnavailable {
      rethrow;
    } catch (_) {}

    // 서버 미구동 시 fallback 더미 (backend/app/routers/balance.py와 동일한 값) — 개발 빌드에서만
    _demoOrThrow('장부 잔액');
    return BalanceModel(balance: 4965000, income: 5000000, expense: 35000);
  }

  /// 2. GET /budgets (예산 편성 및 잔량 조회)
  Future<List<BudgetModel>> fetchBudgets() async {
    try {
      final response = await _get(ApiConfig.budgets, '예산 목록');
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(utf8.decode(response.bodyBytes));
        return data.map((json) => BudgetModel.fromJson(json)).toList();
      }
    } on ApiUnavailable {
      rethrow;
    } catch (_) {}

    // 서버 미구동 시 fallback 더미 (backend/app/routers/budgets.py 기준) — 개발 빌드에서만
    _demoOrThrow('예산 목록');
    return [
      BudgetModel(
        id: 1,
        termId: 1,
        category: '행사비',
        plannedAmount: 2500000,
        remainingAmount: 2470000,
        executionRate: 0.012,
        version: 2,
        expiresAt: 1797260399,
        revisionReason: '참가인원 증가',
      ),
      BudgetModel(id: 2, termId: 1, category: '사업비', plannedAmount: 1500000, remainingAmount: 1465000, executionRate: 0.023, version: 1, expiresAt: 1797260399),
      BudgetModel(id: 3, termId: 1, category: '운영비', plannedAmount: 1000000, remainingAmount: 1000000, executionRate: 0.0, version: 1, expiresAt: 1797260399),
    ];
  }

  /// GET /budget-revisions?status_filter=PENDING — 회장 서명을 기다리는 예산 증액 요청 건수 (학생회 임원 전용).
  ///
  /// **시연용 더미가 없다.** 못 읽거나 모르면 null 이다 — 0 건으로 내리지도, 있는 것처럼 꾸미지도 않는다.
  /// 401 이면 [_get] 이 이미 로그인 화면으로 보냈다. 한 건이 이상해도 건수 전체를 잃지 않게 목록 길이만 센다.
  Future<int?> fetchRevisionSignWaitingCount() async {
    try {
      final response = await _get('${ApiConfig.baseUrl}/budget-revisions?status_filter=PENDING', '증액 요청 건수');
      if (response.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      return data is List ? data.length : null;
    } catch (_) {
      return null;
    }
  }

  /// GET /entries/drafts — 내가 저장해 둔 초안 (총무만, 서버 #76).
  ///
  /// **못 읽으면 [ApiUnavailable] 이다. 더미로 메우지 않는다** — 없는 초안을 보여 주면 이어서 제출할 수 없는 건을
  /// 누르게 된다. 읽을 수 없는 항목(status 가 있거나 모양이 다른 것)은 그 한 건만 건너뛴다.
  Future<List<DraftEntry>> fetchDrafts() async {
    final response = await _get('${ApiConfig.entries}/drafts', '초안 목록').catchError((Object e) {
      if (e is ApiUnavailable) throw e;
      throw const ApiUnavailable('초안 목록');
    });
    if (response.statusCode != 200) throw const ApiUnavailable('초안 목록');
    final Object? data;
    try {
      data = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw const ApiUnavailable('초안 목록');
    }
    if (data is! List) throw const ApiUnavailable('초안 목록');
    final out = <DraftEntry>[];
    for (final item in data) {
      if (item is! Map<String, dynamic>) continue;
      try {
        out.add(DraftEntry.fromJson(item));
      } catch (_) {}
    }
    return out;
  }

  /// 3. GET /entries (수입·지출 내역 목록 조회)
  Future<List<EntryModel>> fetchEntries() async {
    try {
      final response = await _get(ApiConfig.entries, '내역');
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(utf8.decode(response.bodyBytes));
        return data.map((json) => EntryModel.fromJson(json)).toList();
      }
    } on ApiUnavailable {
      rethrow;
    } catch (_) {}

    // 서버 미구동 시 fallback 더미 (backend/app/routers/entries.py 기준) — 개발 빌드에서만
    _demoOrThrow('내역');
    return [
      EntryModel(
        id: 1,
        termId: 1,
        kind: EntryKind.EXPENSE,
        amount: 35000,
        counterparty: '한결문구',
        purpose: '신입생 환영회 명찰 및 필기구 구매',
        budgetId: 2,
        occurredAt: 1788793200, // 2026-09-08 00:00 KST (% 86400 == 54000)
        receiptPath: '/receipts/sample_01.jpg',
        receiptHash: '0xabc1234567890abcdef1234567890abcdef1234567890abcdef1234567890abc',
        metaHash: '0x24ae73988d927fb39f45eb6024e9ff8ffa19e8501603565bd82710ea8df4b937',
        ocrAmount: 35000,
        ocrApprovalNo: '12345678',
        ocrStatus: OcrStatus.MATCH,
        status: EntryStatus.CONFIRMED,
        createdBy: 2,
      ),
      EntryModel(
        id: 2,
        termId: 1,
        kind: EntryKind.EXPENSE,
        amount: 120000,
        counterparty: '청년피자',
        purpose: '개강총회 다과 주문',
        budgetId: 1,
        occurredAt: 1788706800, // 2026-09-07 00:00 KST
        receiptPath: '/receipts/sample_02.jpg',
        receiptHash: '0xdef4567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
        metaHash: '0x622fc1b357c04032e65bc1855c73aaff6d519464d69bf22b10761f3b26a1b793',
        ocrAmount: 120000,
        ocrApprovalNo: '87654321',
        ocrStatus: OcrStatus.MATCH,
        status: EntryStatus.PENDING,
        createdBy: 2,
      ),
      EntryModel(
        id: 3,
        termId: 1,
        kind: EntryKind.INCOME,
        amount: 5000000,
        counterparty: '컴퓨터공학과 학생회비 일괄 납부',
        purpose: '2026-2학기 학과 학생회비 수납',
        occurredAt: 1788620400, // 2026-09-06 00:00 KST
        metaHash: '0x74c9740556d857575586251e71fa24091ffaece5c01c4f889d7c1224ce7af3a9',
        status: EntryStatus.CONFIRMED,
        createdBy: 2,
      ),
    ];
  }

  /// 지금 학기의 DB id (`GET /terms`) — 시작·종료 사이인 학기, 없으면 가장 최근(id 가 큰) 학기.
  /// 수입 등록이 쓴다 (지출은 고른 예산의 학기를 쓴다 — 다르면 체인이 `TermMismatch`).
  Future<int> fetchCurrentTermId({DateTime? now}) async {
    try {
      final response = await _get('${ApiConfig.baseUrl}/terms', '학기');
      if (response.statusCode == 200) {
        final terms = (jsonDecode(utf8.decode(response.bodyBytes)) as List).cast<Map<String, dynamic>>();
        if (terms.isNotEmpty) {
          final t = now ?? DateTime.now();
          for (final term in terms) {
            final start = Fmt.parseServerTime(term['started_at'] as String);
            final end = Fmt.parseServerTime(term['ended_at'] as String);
            if (!t.isBefore(start) && !t.isAfter(end)) return term['id'] as int;
          }
          return terms.map((e) => e['id'] as int).reduce((a, b) => a > b ? a : b);
        }
      }
    } on ApiUnavailable {
      rethrow;
    } catch (_) {}

    // 서버 미구동 시 fallback — 시연용 예산·내역과 같은 학기 1. 개발 빌드에서만
    _demoOrThrow('학기');
    return 1;
  }

  /// 4. 승인 대기(`PENDING`) 건수. 총무·감사 홈의 배지가 쓴다.
  ///
  /// **못 읽으면 null 이다. 더미로 메우지 않는다.**
  /// [fetchEntries] 는 서버가 없으면 더미를 돌려주는데, 그 더미에는 `PENDING` 이
  /// 한 건 들어 있다. 그것을 세면 서버가 꺼져 있을 때 「대기 1건」이 뜬다 —
  /// 고치려던 `'대기 3건'` 하드코딩과 같은 종류의 **지어낸 숫자**다.
  ///
  /// 0 과 null 도 구분해야 한다. 못 읽은 것을 0 으로 내리면 감사 화면에
  /// 「대기 없음」이 떠서, 승인을 기다리는 지출이 있는데도 할 일이 없다고 읽는다
  /// (학생 쪽 `_loadFailed`·`MembershipResult.failed` 와 같은 판단).
  ///
  /// `docs/enums.md` 에 없는 status 를 만나면 [EntryStatus.fromCode] 가 던진다.
  /// 그 한 건 때문에 건수 전체를 잃지 않도록 항목 단위로 건너뛴다.
  Future<int?> fetchPendingCount() async {
    try {
      // 401·403 도 null(모름)이다. 401 이면 _get 이 이미 로그인 화면으로 보냈다.
      final response = await _get(ApiConfig.entries, '승인 대기 건수');
      if (response.statusCode != 200) return null;

      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! List) return null;

      var pending = 0;
      for (final e in data) {
        // 초안(status IS NULL)은 아직 체인에 올라가지 않아 승인 대상이 아니다.
        if (e is! Map || e['status'] == null) continue;
        try {
          if (EntryStatus.fromCode(e['status'] as String) == EntryStatus.PENDING) pending++;
        } catch (_) {}
      }
      return pending;
    } catch (_) {
      return null;
    }
  }
}
