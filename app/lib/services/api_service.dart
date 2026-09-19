import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/api_config.dart';
import '../models/balance_model.dart';
import '../models/budget_model.dart';
import '../models/entry_model.dart';
import '../core/enums.dart';

/// 백엔드 FastAPI 서버(backend/app/main.py)와의 통신 서비스
class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  /// 1. GET /balance (장부 잔액 조회)
  Future<BalanceModel> fetchBalance() async {
    try {
      final response = await http.get(Uri.parse(ApiConfig.balance)).timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(utf8.decode(response.bodyBytes));
        return BalanceModel.fromJson(data);
      }
    } catch (_) {}

    // 서버 미구동 시 fallback 더미 (backend/app/routers/balance.py와 동일한 값)
    return BalanceModel(balance: 4965000, income: 5000000, expense: 35000);
  }

  /// 2. GET /budgets (예산 편성 및 잔량 조회)
  Future<List<BudgetModel>> fetchBudgets() async {
    try {
      final response = await http.get(Uri.parse(ApiConfig.budgets)).timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(utf8.decode(response.bodyBytes));
        return data.map((json) => BudgetModel.fromJson(json)).toList();
      }
    } catch (_) {}

    // 서버 미구동 시 fallback 더미 (backend/app/routers/budgets.py 기준)
    return [
      BudgetModel(id: 1, termId: 1, category: '행사비', plannedAmount: 2500000, remainingAmount: 2500000, executionRate: 0.0, version: 1, expiresAt: 1767196799),
      BudgetModel(id: 2, termId: 1, category: '사업비', plannedAmount: 1500000, remainingAmount: 1465000, executionRate: 0.023, version: 1, expiresAt: 1767196799),
      BudgetModel(id: 3, termId: 1, category: '운영비', plannedAmount: 1000000, remainingAmount: 1000000, executionRate: 0.0, version: 1, expiresAt: 1767196799),
    ];
  }

  /// 3. GET /entries (수입·지출 내역 목록 조회)
  Future<List<EntryModel>> fetchEntries() async {
    try {
      final response = await http.get(Uri.parse(ApiConfig.entries)).timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(utf8.decode(response.bodyBytes));
        return data.map((json) => EntryModel.fromJson(json)).toList();
      }
    } catch (_) {}

    // 서버 미구동 시 fallback 더미 (backend/app/routers/entries.py 기준)
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

  /// 4. POST /entries (신규 지출/수입 등록)
  Future<Map<String, dynamic>> createEntry({
    required EntryKind kind,
    required int amount,
    required String counterparty,
    required String purpose,
    int? budgetId,
    required int occurredAt,
    int? correctsEntryId,
    CorrectionReason? correctionReason,
  }) async {
    final payload = {
      'term_id': 1,
      'kind': kind.code,
      'amount': amount,
      'counterparty': counterparty,
      'purpose': purpose,
      if (budgetId != null) 'budget_id': budgetId,
      'occurred_at': occurredAt,
      if (correctsEntryId != null) 'corrects_entry_id': correctsEntryId,
      if (correctionReason != null) 'correction_reason': correctionReason.code,
    };

    try {
      final response = await http.post(
        Uri.parse(ApiConfig.entries),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 201 || response.statusCode == 200) {
        return jsonDecode(utf8.decode(response.bodyBytes));
      }
    } catch (_) {}

    // 서버 미연결 시 로컬 성공 시뮬레이션 반환
    return {
      'id': 99,
      'status': 'PENDING',
      'message': '오프라인 시뮬레이션: 내역이 PENDING 상태로 등록되었습니다.',
    };
  }
}
