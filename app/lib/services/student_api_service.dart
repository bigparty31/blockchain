import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../core/api_config.dart';
import '../core/enums.dart';
import '../core/hashing.dart';
import '../models/balance_model.dart';
import '../models/budget_model.dart';
import '../models/entry_model.dart';
import '../models/membership_model.dart';
import '../models/objection_model.dart';
import '../models/onchain_entry_model.dart';
import '../models/snapshot_model.dart';

/// 학생 화면 전용 API 서비스 (`screens/student/`)
///
/// 총무·감사 화면이 쓰는 `ApiService` 와 분리해 둔 이유:
///   1. 학생 화면에만 필요한 엔드포인트(이의·SBT·스냅샷·온체인 조회)가 아직 없다
///   2. 같은 파일을 두 담당자가 동시에 고치면 병합 충돌이 난다
///
/// 서버가 안 떠 있으면 데모 데이터로 폴백한다. 데모 데이터의 `meta_hash` 와
/// `receipt_hash` 는 [Hashing] 으로 실제 계산해 넣으므로 검증 배지가 진짜로
/// 동작한다 — 손으로 적은 가짜 해시를 넣으면 전부 빨강으로 떠서 화면을 볼 수 없다.
class StudentApiService {
  static final StudentApiService _instance = StudentApiService._internal();
  factory StudentApiService() => _instance;
  StudentApiService._internal();

  static const _storage = FlutterSecureStorage();
  static const _lastSeenKey = 'student_last_seen_entry_id';
  static const _timeout = Duration(seconds: 3);

  /// 마지막 원장 조회가 서버에서 온 것인지, 예시 데이터로 폴백한 것인지.
  ///
  /// **화면에 반드시 표시해야 한다.** 이 앱의 존재 이유가 「학생이 직접 검증한다」인데
  /// 보고 있는 것이 실제 원장인지 개발용 예시인지 구분이 안 되면 검증에 의미가 없다.
  /// 시연 도중 서버가 꺼져도 화면이 멀쩡해 보여 아무도 알아채지 못한다.
  bool get usingDemoData => _usingDemoData;
  bool _usingDemoData = true;

  /// 서버에 `POST /objections` 가 없을 때 제기한 이의를 담아 두는 곳.
  ///
  /// 엔드포인트가 생기면 이 목록은 통째로 지운다. **항목(`entries`)에는 이런
  /// 폴백을 두지 않는다** — `POST /entries` 는 이미 서버에 있어서, 여기에도
  /// 사본을 두면 「어느 쪽이 진짜 데이터냐」가 갈린다.
  final List<ObjectionModel> _pendingObjections = [];

  // ── 원장 ────────────────────────────────────────────────────

  /// GET /balance — 서버가 계산한 합계.
  ///
  /// 화면에 그대로 쓰지 않는다. 장부 잔액은 항목에서 직접 계산하고(PRD §7.4),
  /// 이 값은 서버 계산과 어긋나는지 볼 때만 참고한다.
  Future<BalanceModel?> fetchBalance() async {
    final json = await _getJson(ApiConfig.balance);
    return json is Map<String, dynamic> ? BalanceModel.fromJson(json) : null;
  }

  /// GET /entries — 수입·지출 목록 (S2)
  Future<List<EntryModel>> fetchEntries() async {
    final json = await _getJson(ApiConfig.entries);
    if (json is List) {
      _usingDemoData = false;
      return json.map((e) => EntryModel.fromJson(e)).toList();
    }
    _usingDemoData = true;
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

  // ── 온체인 조회 (검증 2단계) ───────────────────────────────

  /// `AccountingLedger.getEntry(id)` 결과를 받아온다 (HASHING.md §2).
  ///
  /// 해시가 덮지 않는 `kind`·`budget_id` 등을 대조하려면 이 값이 필요하다.
  /// **아직 이 엔드포인트가 없다** (HASHING.md §8 열린 항목) — 없으면 null 을
  /// 돌려주고, 검증은 「부분 검증」으로 표시된다.
  /// **서버 원장을 보고 있을 때는 폴백하지 않는다.** 데모 온체인 값은 entry id 로
  /// 데모 항목을 찾아 돌려주는데, 서버 항목과는 id 만 같고 내용이 전혀 다르다.
  /// 그대로 비교하면 서버의 2번(청년피자 120,000)을 데모의 2번(한결문구 35,000)과
  /// 맞춰보게 되어 **멀쩡한 항목이 전부 「변조 감지」로 뜬다.**
  /// 모르는 것은 채우지 말고 null 로 두어 「부분 검증」이 되게 한다.
  Future<OnChainEntry?> fetchOnChainEntry(int entryId) async {
    final json = await _getJson('${ApiConfig.baseUrl}/entries/$entryId/onchain');
    if (json is Map<String, dynamic>) return OnChainEntry.fromJson(json);
    return _usingDemoData ? _demoOnChain(entryId) : null;
  }

  /// GET /users/wallets — user id ↔ 지갑 주소 매핑 (검증 2단계)
  ///
  /// 체인의 `registrant`·`approver` 는 지갑 주소이고 DB 의 `created_by`·
  /// `approved_by` 는 user id 라 값 자체가 다르다. 이 매핑이 없으면
  /// **누가 등록하고 누가 승인했는지를 대조할 수 없다** (HASHING.md §2).
  /// 인증 파트(손종인)에 요청해 둔 상태다.
  Future<Map<int, String>?> fetchWalletMap() async {
    final json = await _getJson('${ApiConfig.baseUrl}/users/wallets');
    if (json is Map<String, dynamic>) {
      return json.map((k, v) => MapEntry(int.parse(k), v as String));
    }
    // 서버 원장에는 데모 지갑을 끼워 넣지 않는다 ([fetchOnChainEntry] 참고).
    return _usingDemoData ? _demoWallets : null;
  }

  /// 영수증 원본 바이트를 내려받는다 (검증 3단계, HASHING.md §4).
  ///
  /// **바이트를 그대로** 받아야 한다. 서버·CDN 이 재인코딩하거나 EXIF 회전을
  /// 보정하면 재계산이 깨진다.
  Future<List<int>?> fetchReceiptBytes(EntryModel entry) async {
    final path = entry.receiptPath;
    if (path == null) return null;

    final url = path.startsWith('http') ? path : '${ApiConfig.baseUrl}$path';
    try {
      final res = await http.get(Uri.parse(url)).timeout(_timeout);
      if (res.statusCode == 200) return res.bodyBytes;
    } catch (_) {}

    // 서버 항목의 영수증을 못 받았을 때 데모 바이트를 돌려주면 「영수증이 바뀌었다」는
    // 거짓 판정이 된다. 못 받았으면 못 받은 것으로 둔다 ([fetchOnChainEntry] 참고).
    return _usingDemoData ? _demoReceiptBytes(entry.id) : null;
  }

  // ── 아직 백엔드에 없는 엔드포인트 ──────────────────────────

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

    // 이번 세션에 직접 제기한 것만 돌려준다. 미리 넣어 둔 예시 이의는 두지 않는다 —
    // 쓴 적 없는 질문이 「답변 대기」로 떠 있으면 자기가 올린 것과 구분되지 않는다.
    return entryId == null
        ? List.of(_pendingObjections)
        : _pendingObjections.where((o) => o.entryId == entryId).toList();
  }

  /// POST /objections — 이의 제기 (S8)
  ///
  /// 본문의 정본화·해시는 백엔드가 한다 (HASHING.md §1.1, §3).
  /// 학생 앱은 쓰기 권한이 없어 직접 서명하지 않는다 (PRD §9.2).
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

    // 서버가 없을 때. 만들어서 돌려주기만 하면 화면을 나가는 순간 사라지므로
    // 세션 동안 들고 있는다.
    final nextId = _pendingObjections.isEmpty
        ? 1
        : _pendingObjections.map((o) => o.id).reduce((a, b) => a > b ? a : b) + 1;

    final created = ObjectionModel(
      id: nextId,
      entryId: entryId,
      userId: 3,
      content: content,
      status: ObjectionStatus.OPEN,
      raisedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    _pendingObjections.add(created);
    return created;
  }

  /// GET /memberships/me — 본인 SBT 보유 여부와 QR 페이로드 (S5)
  Future<MembershipModel?> fetchMyMembership() async {
    final json = await _getJson('${ApiConfig.baseUrl}/memberships/me');
    if (json is Map<String, dynamic>) return MembershipModel.fromJson(json);
    return _demoMembership();
  }

  // ── 미확인 항목 뱃지 카운트 (S12) ──────────────────────────

  Future<int> lastSeenEntryId() async {
    try {
      final raw = await _storage.read(key: _lastSeenKey);
      return int.tryParse(raw ?? '') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> markEntriesSeen(int maxEntryId) async {
    try {
      await _storage.write(key: _lastSeenKey, value: maxEntryId.toString());
    } catch (_) {
      // 저장 실패는 조용히 넘긴다 — 뱃지가 안 지워질 뿐 기능에 지장 없다.
    }
  }

  // ── 내부 ────────────────────────────────────────────────────

  Future<dynamic> _getJson(String url) async {
    try {
      final res = await http.get(Uri.parse(url)).timeout(_timeout);
      if (res.statusCode == 200) {
        return jsonDecode(utf8.decode(res.bodyBytes));
      }
    } catch (_) {}
    return null;
  }

  // ══ 데모 데이터 ════════════════════════════════════════════
  // 서버 미구동 시 화면 확인용.
  //
  // `occurred_at` 은 모두 **KST 자정** 이다 (HASHING.md §1.3).
  // `ts % 86400 == 54000` 을 만족하지 않으면 백엔드가 400 으로 거부한다.

  static final int _d0906 = Hashing.kstMidnightOf(2026, 9, 6);
  static final int _d0908 = Hashing.kstMidnightOf(2026, 9, 8);
  static final int _d0909 = Hashing.kstMidnightOf(2026, 9, 9);
  static final int _d0910 = Hashing.kstMidnightOf(2026, 9, 10);
  static final int _d0911 = Hashing.kstMidnightOf(2026, 9, 11);
  static final int _d0912 = Hashing.kstMidnightOf(2026, 9, 12);

  /// 데모용 지갑 매핑. user #2 총무, #3 감사, #4 회장.
  static const Map<int, String> _demoWallets = {
    2: '0x71C7656EC7ab88b098defB751B7401B5f6d8976F',
    3: '0x2546BcD3c84621e976D8185a91A922aE77ECEc30',
    4: '0xbDA5747bFD65F08deb54cb465eB87D40e51B197E',
  };

  /// 항목별 데모 영수증 바이트. 실제 이미지 대신 구분 가능한 더미를 쓴다.
  static List<int> _demoReceiptBytes(int entryId) =>
      utf8.encode('demo-receipt-$entryId');

  /// 바이트에서 실제로 계산한 영수증 해시 — 검증 3단계가 통과한다.
  static String _receiptHashOf(int entryId) =>
      Hashing.fileHash(_demoReceiptBytes(entryId));

  /// 해시가 올바른 항목을 만든다 — 검증 1단계가 통과한다.
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
      metaHash: Hashing.metaHash(
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
      // #1 확정 수입 — 영수증 없음 (receipt_hash NULL → preimage 가 구분자로 끝난다)
      _sound(
        id: 1,
        kind: EntryKind.INCOME,
        amount: 5000000,
        counterparty: '컴퓨터공학과 학생회비 일괄 납부',
        purpose: '2026-2학기 학과 학생회비 수납',
        occurredAt: _d0906,
        txPending: '0x8a3f1c9e2b7d4a6f0c5e8b1d3f7a9c2e4b6d8f0a',
        txConfirm: '0x1d5b8e3a7c2f9d4b6e0a8c3f5b7d9e1a4c6f8b2d',
      ),

      // #2 확정 지출 · OCR 일치 — 세 단계 모두 통과하는 정상 건
      _sound(
        id: 2,
        kind: EntryKind.EXPENSE,
        amount: 35000,
        counterparty: '한결문구',
        purpose: '신입생 환영회 명찰 및 필기구 구매',
        occurredAt: _d0908,
        budgetId: 2,
        receiptPath: '/receipts/sample_02.jpg',
        receiptHash: _receiptHashOf(2),
        ocrStatus: OcrStatus.MATCH,
        ocrAmount: 35000,
        ocrApprovalNo: '12345678',
        txPending: '0x2e7b9d1a5c3f8e0b6d4a2c9f7b5e3d1a8c0f6b4e',
        txConfirm: '0x9c4a2f7e5b3d1a8c6f0e4b2d9a7c5f3e1b8d6a0c',
      ),

      // #3 승인 대기 — 영수증 바이트가 기록된 해시와 다르다.
      //    승인 전에 원본이 바뀌는 것을 탐지하려고 Pending 을 먼저 기록한다.
      //    검증 3단계가 없으면 이걸 못 잡는다.
      _sound(
        id: 3,
        kind: EntryKind.EXPENSE,
        amount: 120000,
        counterparty: '청년피자',
        purpose: '개강총회 다과 주문',
        occurredAt: _d0909,
        budgetId: 1,
        receiptPath: '/receipts/sample_03.jpg',
        // 등록 시점의 영수증 해시. 지금 내려오는 파일과 다르다.
        receiptHash: Hashing.fileHash(utf8.encode('demo-receipt-3-original')),
        ocrStatus: OcrStatus.MATCH,
        ocrAmount: 120000,
        ocrApprovalNo: '87654321',
        status: EntryStatus.PENDING,
        txPending: '0x5f8d3b1e9a7c2f4d6b0e8a3c5f7d9b1e3a5c7f9d',
      ),

      // #4 OCR 불일치인데 사유 입력 후 승인된 건 — S7 뱃지 대상
      _sound(
        id: 4,
        kind: EntryKind.EXPENSE,
        amount: 50000,
        counterparty: '대학마트',
        purpose: '체육대회 간식 구매',
        occurredAt: _d0910,
        budgetId: 1,
        receiptPath: '/receipts/sample_04.jpg',
        receiptHash: _receiptHashOf(4),
        ocrStatus: OcrStatus.MISMATCH,
        ocrAmount: 30000,
        ocrApprovalNo: '24681357',
        warningAckReason: 'OCR 금액 불일치, 영수증 원본 확인함',
        txPending: '0x3a6c8e0b2d4f6a8c0e2b4d6f8a0c2e4b6d8f0a2c',
        txConfirm: '0x7b1d3f5a9c7e1b3d5f7a9c1e3b5d7f9a1c3e5b7d',
      ),

      // #5 위 #4 를 정정 — **금액은 새 총액이 아니라 증감분이다.**
      //    50,000 → 30,000 이므로 -20,000. HASHING.md 샘플 3 과 같은 형태다.
      _sound(
        id: 5,
        kind: EntryKind.EXPENSE,
        amount: -20000,
        counterparty: '대학마트',
        purpose: '입력 오류 정정',
        occurredAt: _d0910,
        budgetId: 1,
        correctsEntryId: 4,
        correctionReason: CorrectionReason.INPUT_ERROR,
        txPending: '0x0c2e4b6d8f0a2c4e6b8d0f2a4c6e8b0d2f4a6c8e',
        txConfirm: '0x6d8f0a2c4e6b8d0f2a4c6e8b0d2f4a6c8e0b2d4f',
      ),

      // #6 등록 이후 금액이 바뀐 건 — 검증 1단계(해시)가 잡는다.
      //    meta_hash 는 80,000원 기준으로 기록됐는데 현재 금액은 45,000원이다.
      EntryModel(
        id: 6,
        termId: 1,
        kind: EntryKind.EXPENSE,
        amount: 45000,
        counterparty: '한빛인쇄',
        purpose: '학과 홍보 포스터 인쇄',
        budgetId: 3,
        occurredAt: _d0911,
        receiptPath: '/receipts/sample_06.jpg',
        receiptHash: _receiptHashOf(6),
        metaHash: Hashing.metaHash(
          amount: 80000,
          counterparty: '한빛인쇄',
          purpose: '학과 홍보 포스터 인쇄',
          occurredAt: _d0911,
          receiptHash: _receiptHashOf(6),
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

      // #7 예산 항목만 바꿔치기한 건 — **해시는 멀쩡하다.**
      //    budget_id 는 meta_hash 에 들어가지 않아서, 1단계만 하면 초록으로 뜬다.
      //    2단계(getEntry 필드 대조)가 있어야 잡힌다 (HASHING.md §2 실측).
      _sound(
        id: 7,
        kind: EntryKind.EXPENSE,
        amount: 28000,
        counterparty: '우리분식',
        purpose: '학생회 간부 회의 다과',
        occurredAt: _d0912,
        budgetId: 3, // 체인에는 1(행사비)로 올라가 있다
        receiptPath: '/receipts/sample_07.jpg',
        receiptHash: _receiptHashOf(7),
        ocrStatus: OcrStatus.MATCH,
        ocrAmount: 28000,
        ocrApprovalNo: '99887766',
        txPending: '0x2c4e6b8d0f2a4c6e8b0d2f4a6c8e0b2d4f6a8c0e',
        txConfirm: '0xa2c4e6b8d0f2a4c6e8b0d2f4a6c8e0b2d4f6a8c0',
      ),
    ];
  }

  /// 데모용 온체인 값. 대부분 API 값과 일치하고, #7 만 예산 항목이 다르다.
  OnChainEntry? _demoOnChain(int entryId) {
    final entry = _demoEntries().where((e) => e.id == entryId);
    if (entry.isEmpty) return null;
    final e = entry.first;

    return OnChainEntry(
      hash: e.metaHash,
      amount: e.amount,
      kind: e.kind,
      status: e.status,
      occurredAt: e.occurredAt,
      // #7 은 체인에 행사비(1)로 올라가 있는데 API 는 운영비(3)라고 말한다.
      budgetId: entryId == 7 ? 1 : (e.budgetId ?? 0),
      correctsId: e.correctsEntryId ?? 0,
      registrant: '0x71C7656EC7ab88b098defB751B7401B5f6d8976F',
      approver: e.approvedBy == null
          ? OnChainEntry.zeroAddress
          : '0x2546BcD3c84621e976D8185a91A922aE77ECEc30',
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
        expiresAt: Hashing.kstMidnightOf(2027, 1, 1),
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
        expiresAt: Hashing.kstMidnightOf(2027, 1, 1),
      ),
      BudgetModel(
        id: 3,
        termId: 1,
        category: '운영비',
        plannedAmount: 1000000,
        remainingAmount: 927000,
        executionRate: 0.073,
        version: 1,
        expiresAt: Hashing.kstMidnightOf(2027, 1, 1),
      ),
    ];
  }

  SnapshotModel _demoSnapshot() {
    // 확정 지출 합계 = 35,000 + 50,000 - 20,000 + 45,000 + 28,000 = 138,000
    // 장부 잔액 = 5,000,000 - 138,000 = 4,862,000
    // 계좌에는 원장에 없는 28,000원 지출이 하나 더 빠져 있다.
    return SnapshotModel(
      id: 1,
      termId: 1,
      bankBalance: 4834000,
      snapshotAt: _d0912,
      txHash: '0xa1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0',
      unrecorded: [
        UnrecordedTransaction(
          amount: 28000,
          counterparty: '카페베네 후문점',
          occurredAt: _d0912,
        ),
      ],
    );
  }

  MembershipModel _demoMembership() {
    return MembershipModel(
      id: 1,
      userId: 3,
      termId: 1,
      tokenId: 128,
      commitHash: '0x7d3a9f1c5e8b2d4a6c0f8e3b5d7a9c1f3e5b7d9a',
      mintedAt: _d0906,
      qrPayload: 'SCA:2026-2:U000003',
    );
  }
}
