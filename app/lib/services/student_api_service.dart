import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../core/api_config.dart';
import '../core/enums.dart';
import '../core/meta_hash.dart';
import '../models/balance_model.dart';
import '../models/budget_model.dart';
import '../models/entry_model.dart';
import '../models/membership_model.dart';
import '../models/objection_model.dart';
import '../models/snapshot_model.dart';

/// 학생 화면 전용 API 서비스 (`screens/student/`)
///
/// 총무·감사 화면이 쓰는 `ApiService` 와 분리해 둔 이유:
///   1. 학생 화면에만 필요한 엔드포인트(이의·SBT·스냅샷)가 백엔드에 아직 없다
///   2. 같은 파일을 두 담당자가 동시에 고치면 병합 충돌이 난다
///
/// 서버가 안 떠 있으면 데모 데이터로 폴백한다. 데모 데이터의 `meta_hash` 는
/// [MetaHash] 로 실제 계산해 넣으므로 검증 배지(S4)가 실제로 동작한다 —
/// 손으로 적은 가짜 해시를 넣으면 전부 빨강으로 떠서 화면을 확인할 수 없다.
class StudentApiService {
  static final StudentApiService _instance = StudentApiService._internal();
  factory StudentApiService() => _instance;
  StudentApiService._internal();

  static const _storage = FlutterSecureStorage();
  static const _lastSeenKey = 'student_last_seen_entry_id';

  static const _timeout = Duration(seconds: 3);

  // ── 원장 ────────────────────────────────────────────────────

  /// GET /balance — 장부 잔액·총수입·총지출 (S1)
  Future<BalanceModel> fetchBalance() async {
    final json = await _getJson(ApiConfig.balance);
    if (json is Map<String, dynamic>) return BalanceModel.fromJson(json);
    return _demoBalance();
  }

  /// GET /entries — 수입·지출 목록 (S2)
  Future<List<EntryModel>> fetchEntries() async {
    final json = await _getJson(ApiConfig.entries);
    if (json is List) {
      return json.map((e) => EntryModel.fromJson(e)).toList();
    }
    return _demoEntries();
  }

  /// GET /budgets — 예산 항목별 잔량·집행률·개정 이력 (S6)
  Future<List<BudgetModel>> fetchBudgets() async {
    final json = await _getJson(ApiConfig.budgets);
    if (json is List) {
      return json.map((e) => BudgetModel.fromJson(e)).toList();
    }
    return _demoBudgets();
  }

  // ── 아직 백엔드에 없는 엔드포인트 ──────────────────────────
  // 손종인(인증·릴레이)·김경윤(회계 API)과 규격 합의 후 연결한다.

  /// GET /snapshots/latest — 통장 잔액 스냅샷과 미등록 건 (S11)
  Future<SnapshotModel> fetchLatestSnapshot() async {
    final json = await _getJson('${ApiConfig.baseUrl}/snapshots/latest');
    if (json is Map<String, dynamic>) return SnapshotModel.fromJson(json);
    return _demoSnapshot();
  }

  /// GET /objections?entry_id= — 이의 목록 (S8)
  Future<List<ObjectionModel>> fetchObjections({int? entryId}) async {
    final url = entryId == null
        ? '${ApiConfig.baseUrl}/objections'
        : '${ApiConfig.baseUrl}/objections?entry_id=$entryId';
    final json = await _getJson(url);
    if (json is List) {
      return json.map((e) => ObjectionModel.fromJson(e)).toList();
    }
    final all = _demoObjections();
    return entryId == null ? all : all.where((o) => o.entryId == entryId).toList();
  }

  /// POST /objections — 이의 제기 (S8)
  ///
  /// 원장은 바뀌지 않는다. 설명만 쌓이고, 미답변 사실이 기록으로 남는다.
  Future<ObjectionModel> raiseObjection({
    required int entryId,
    required String content,
  }) async {
    try {
      final res = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/objections'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'entry_id': entryId, 'content': content}),
          )
          .timeout(_timeout);
      if (res.statusCode == 200 || res.statusCode == 201) {
        return ObjectionModel.fromJson(jsonDecode(utf8.decode(res.bodyBytes)));
      }
    } catch (_) {}

    // 오프라인 시뮬레이션 — 제출된 것처럼 보이되 답변은 비어 있다.
    return ObjectionModel(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      entryId: entryId,
      userId: 3,
      content: content,
      status: ObjectionStatus.OPEN,
      raisedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  /// GET /memberships/me — 본인 SBT 보유 여부와 QR 페이로드 (S5)
  Future<MembershipModel?> fetchMyMembership() async {
    final json = await _getJson('${ApiConfig.baseUrl}/memberships/me');
    if (json is Map<String, dynamic>) return MembershipModel.fromJson(json);
    return _demoMembership();
  }

  // ── 미확인 항목 뱃지 카운트 (S12) ──────────────────────────

  /// 마지막으로 확인한 항목 id. 처음이면 0.
  Future<int> lastSeenEntryId() async {
    try {
      final raw = await _storage.read(key: _lastSeenKey);
      return int.tryParse(raw ?? '') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 내역 목록을 열어본 시점에 호출해 뱃지를 지운다.
  Future<void> markEntriesSeen(int maxEntryId) async {
    try {
      await _storage.write(key: _lastSeenKey, value: maxEntryId.toString());
    } catch (_) {
      // 저장 실패는 조용히 넘긴다 — 뱃지가 안 지워질 뿐 기능에 지장 없다.
    }
  }

  // ── 내부 ────────────────────────────────────────────────────

  /// 성공하면 디코딩된 JSON, 실패하면 null 을 돌려준다.
  /// null 이 오면 호출부가 데모 데이터로 폴백한다.
  Future<dynamic> _getJson(String url) async {
    try {
      final res = await http.get(Uri.parse(url)).timeout(_timeout);
      if (res.statusCode == 200) {
        return jsonDecode(utf8.decode(res.bodyBytes));
      }
    } catch (_) {}
    return null;
  }

  // ── 데모 데이터 ────────────────────────────────────────────
  // 서버 미구동 시 화면 확인용. 검증 배지·OCR 경고·정정 병합이
  // 실제로 동작하는 것을 볼 수 있도록 구성했다.

  static const _demoReceiptHash = '9f2c1d4e8a7b5c3f0e6d9a2b4c8e1f7a';

  /// 해시가 올바른 항목 — 검증 통과(초록)로 표시된다.
  static EntryModel _sound({
    required int id,
    required EntryKind kind,
    required int amount,
    required String counterparty,
    required String purpose,
    required int occurredAt,
    int? budgetId,
    String? receiptPath,
    String? receiptHash,
    OcrStatus? ocrStatus,
    int? ocrAmount,
    String? ocrApprovalNo,
    bool categoryWarning = false,
    String? warningAckReason,
    EntryStatus status = EntryStatus.CONFIRMED,
    int? correctsEntryId,
    CorrectionReason? correctionReason,
    String? txPending,
    String? txConfirm,
  }) {
    return EntryModel(
      id: id,
      termId: 1,
      kind: kind,
      amount: amount,
      counterparty: counterparty,
      purpose: purpose,
      budgetId: budgetId,
      occurredAt: occurredAt,
      receiptPath: receiptPath,
      receiptHash: receiptHash,
      metaHash: MetaHash.compute(
        amount: amount,
        counterparty: counterparty,
        purpose: purpose,
        occurredAt: occurredAt,
        receiptHash: receiptHash,
      ),
      ocrAmount: ocrAmount,
      ocrApprovalNo: ocrApprovalNo,
      ocrStatus: ocrStatus,
      categoryWarning: categoryWarning,
      warningAckReason: warningAckReason,
      status: status,
      createdBy: 2,
      approvedBy: status == EntryStatus.CONFIRMED ? 3 : null,
      txPending: txPending,
      txConfirm: txConfirm,
      correctsEntryId: correctsEntryId,
      correctionReason: correctionReason,
    );
  }

  List<EntryModel> _demoEntries() {
    return [
      // 확정 수입 — 영수증 없음(receipt_hash null)
      _sound(
        id: 1,
        kind: EntryKind.INCOME,
        amount: 5000000,
        counterparty: '컴퓨터공학과 학생회',
        purpose: '2026학년도 2학기 학생회비 납부',
        occurredAt: 1757213600,
        txPending: '0x8a3f1c9e2b7d4a6f0c5e8b1d3f7a9c2e4b6d8f0a',
        txConfirm: '0x1d5b8e3a7c2f9d4b6e0a8c3f5b7d9e1a4c6f8b2d',
      ),

      // 확정 지출 · OCR 일치 — 검증 통과
      _sound(
        id: 2,
        kind: EntryKind.EXPENSE,
        amount: 35000,
        counterparty: '한결문구',
        purpose: '신입생 환영회 명찰 및 필기구 구매',
        occurredAt: 1757300000,
        budgetId: 2,
        receiptPath: '/receipts/sample_01.jpg',
        receiptHash: _demoReceiptHash,
        ocrStatus: OcrStatus.MATCH,
        ocrAmount: 35000,
        ocrApprovalNo: '12345678',
        txPending: '0x2e7b9d1a5c3f8e0b6d4a2c9f7b5e3d1a8c0f6b4e',
        txConfirm: '0x9c4a2f7e5b3d1a8c6f0e4b2d9a7c5f3e1b8d6a0c',
      ),

      // 승인 대기 — 총무 등록 직후 Pending 기록만 있는 상태
      _sound(
        id: 3,
        kind: EntryKind.EXPENSE,
        amount: 120000,
        counterparty: '청년피자',
        purpose: '개강총회 다과 주문',
        occurredAt: 1757386400,
        budgetId: 1,
        receiptPath: '/receipts/sample_02.jpg',
        receiptHash: _demoReceiptHash,
        ocrStatus: OcrStatus.MATCH,
        ocrAmount: 120000,
        ocrApprovalNo: '87654321',
        status: EntryStatus.PENDING,
        txPending: '0x5f8d3b1e9a7c2f4d6b0e8a3c5f7d9b1e3a5c7f9d',
      ),

      // OCR 불일치인데 사유 입력 후 승인된 건 — S7 뱃지 대상
      _sound(
        id: 4,
        kind: EntryKind.EXPENSE,
        amount: 50000,
        counterparty: '대학마트',
        purpose: '체육대회 간식 구매',
        occurredAt: 1757472800,
        budgetId: 1,
        receiptPath: '/receipts/sample_03.jpg',
        receiptHash: _demoReceiptHash,
        ocrStatus: OcrStatus.MISMATCH,
        ocrAmount: 30000,
        ocrApprovalNo: '24681357',
        warningAckReason: '영수증 일부 훼손으로 판독 오류. 카드 전표로 금액 확인함',
        txPending: '0x3a6c8e0b2d4f6a8c0e2b4d6f8a0c2e4b6d8f0a2c',
        txConfirm: '0x7b1d3f5a9c7e1b3d5f7a9c1e3b5d7f9a1c3e5b7d',
      ),

      // 위 4번을 정정한 항목 — S9 병합 표시 대상
      _sound(
        id: 5,
        kind: EntryKind.EXPENSE,
        amount: 30000,
        counterparty: '대학마트',
        purpose: '체육대회 간식 구매',
        occurredAt: 1757559200,
        budgetId: 1,
        receiptPath: '/receipts/sample_03.jpg',
        receiptHash: _demoReceiptHash,
        ocrStatus: OcrStatus.MATCH,
        ocrAmount: 30000,
        ocrApprovalNo: '24681357',
        correctsEntryId: 4,
        correctionReason: CorrectionReason.INPUT_ERROR,
        txPending: '0x0c2e4b6d8f0a2c4e6b8d0f2a4c6e8b0d2f4a6c8e',
        txConfirm: '0x6d8f0a2c4e6b8d0f2a4c6e8b0d2f4a6c8e0b2d4f',
      ),

      // 등록 이후 금액이 바뀐 건 — 검증 배지 빨강 시연용.
      // meta_hash 는 80,000원 기준으로 기록됐는데 현재 금액은 45,000원이다.
      EntryModel(
        id: 6,
        termId: 1,
        kind: EntryKind.EXPENSE,
        amount: 45000,
        counterparty: '한빛인쇄',
        purpose: '학과 홍보 포스터 인쇄',
        budgetId: 3,
        occurredAt: 1757645600,
        receiptPath: '/receipts/sample_04.jpg',
        receiptHash: _demoReceiptHash,
        metaHash: MetaHash.compute(
          amount: 80000,
          counterparty: '한빛인쇄',
          purpose: '학과 홍보 포스터 인쇄',
          occurredAt: 1757645600,
          receiptHash: _demoReceiptHash,
        ),
        ocrStatus: OcrStatus.MATCH,
        ocrAmount: 80000,
        ocrApprovalNo: '13572468',
        status: EntryStatus.CONFIRMED,
        createdBy: 2,
        approvedBy: 3,
        txPending: '0x4e6b8d0f2a4c6e8b0d2f4a6c8e0b2d4f6a8c0e2b',
        txConfirm: '0x8f0a2c4e6b8d0f2a4c6e8b0d2f4a6c8e0b2d4f6a',
      ),
    ];
  }

  BalanceModel _demoBalance() {
    // PENDING 은 제외한다 — 대기 건을 미리 반영하면 승인되지 않은 수치가
    // 학생 화면 합계에 섞인다.
    return BalanceModel(
      balance: 5000000 - (35000 + 30000 + 45000),
      income: 5000000,
      expense: 35000 + 30000 + 45000,
    );
  }

  List<BudgetModel> _demoBudgets() {
    return [
      // 개정된 예산 — 200만 → 250만 (v2). S6 개정 이력 표시 대상
      BudgetModel(
        id: 1,
        termId: 1,
        category: '행사비',
        plannedAmount: 2500000,
        remainingAmount: 2470000,
        executionRate: 0.012,
        version: 2,
        expiresAt: 1767196799,
        revisionReason: '참가인원 증가',
      ),
      BudgetModel(
        id: 2,
        termId: 1,
        category: '사업비',
        plannedAmount: 1500000,
        remainingAmount: 1465000,
        executionRate: 0.023,
        version: 1,
        expiresAt: 1767196799,
      ),
      BudgetModel(
        id: 3,
        termId: 1,
        category: '운영비',
        plannedAmount: 1000000,
        remainingAmount: 955000,
        executionRate: 0.045,
        version: 1,
        expiresAt: 1767196799,
      ),
    ];
  }

  SnapshotModel _demoSnapshot() {
    return SnapshotModel(
      id: 1,
      termId: 1,
      // 장부잔액(4,890,000)보다 계좌가 28,000원 적다 → 미등록 지출 의심
      bankBalance: 4862000,
      snapshotAt: 1757732000,
      txHash: '0xa1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0',
      unrecorded: [
        UnrecordedTransaction(
          amount: 28000,
          counterparty: '카페베네 후문점',
          occurredAt: 1757690000,
        ),
      ],
    );
  }

  List<ObjectionModel> _demoObjections() {
    return [
      ObjectionModel(
        id: 1,
        entryId: 2,
        userId: 3,
        content: '신입생 환영회 물품 35,000원 건 세부 품목 내역서가 누락되어 있습니다.',
        status: ObjectionStatus.OPEN,
        raisedAt: 1757400000,
        txRaise: '0xc3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2',
      ),
      ObjectionModel(
        id: 2,
        entryId: 4,
        userId: 3,
        content: 'OCR 판독 금액과 등록 금액이 다른데 승인된 이유가 궁금합니다.',
        answer: '영수증 하단이 훼손되어 판독에 실패했습니다. 카드 전표 사본으로 '
            '실제 결제금액 50,000원을 확인했고, 이후 정정 절차로 30,000원으로 '
            '바로잡았습니다.',
        answeredBy: 4,
        status: ObjectionStatus.ANSWERED,
        raisedAt: 1757500000,
        answeredAt: 1757580000,
        txRaise: '0xe5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4',
        txAnswer: '0xf6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5',
      ),
    ];
  }

  MembershipModel _demoMembership() {
    return MembershipModel(
      id: 1,
      userId: 3,
      termId: 1,
      tokenId: 128,
      commitHash: '0x7d3a9f1c5e8b2d4a6c0f8e3b5d7a9c1f3e5b7d9a',
      mintedAt: 1757126400,
      qrPayload: 'SCA:2026-2:U000003',
    );
  }
}
