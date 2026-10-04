import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../core/api_config.dart';
import '../core/enums.dart';
import '../core/hashing.dart';
import '../core/term_info.dart';
import '../models/balance_model.dart';
import '../models/budget_model.dart';
import '../models/entry_model.dart';
import '../models/membership_model.dart';
import '../models/objection_model.dart';
import '../models/onchain_entry_model.dart';
import '../models/snapshot_model.dart';

/// 이의 제기가 서버에 닿지 못했을 때.
///
/// 실패를 조용히 삼키면 접수되지 않은 이의가 「접수되었습니다」로 뜬다.
class ObjectionFailed implements Exception {
  const ObjectionFailed();
  @override
  String toString() => 'ObjectionFailed';
}

/// SBT 조회 결과 — **미보유와 조회 실패를 구분한다** (스토리보드 6 ②·③).
///
/// 둘을 뭉개면 조회가 안 됐을 뿐인데 SBT 를 가진 학생에게 「없다」고 말하게 되고,
/// 그 학생은 이의 제기 버튼까지 회색으로 막힌다.
class MembershipResult {
  /// 조회 자체가 안 된 경우. 이때 [membership] 은 「없음」이 아니라 「모름」이다.
  final bool failed;

  /// 조회된 멤버십. 발급받은 적이 없으면 null.
  final MembershipModel? membership;

  const MembershipResult.ok(this.membership) : failed = false;
  const MembershipResult.failed()
      : failed = true,
        membership = null;

  /// 유효한 SBT 를 들고 있는지. 조회 실패는 보유로 치지 않는다.
  bool get held => !failed && membership != null && membership!.isValid;
}

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

  /// 마지막 [fetchEntries] 에서 파싱에 실패해 목록에서 빠진 항목 수.
  ///
  /// **0 이 아니면 화면에 반드시 알린다.** 조용히 빼면 학생은 「내역이 원래
  /// 이게 다」로 오해한다. 반대로 한 건 깨졌다고 목록 전체를 비우면 멀쩡한
  /// 나머지까지 못 본다.
  ///
  /// 초안(`status IS NULL`)은 정상 제외라 여기 세지 않는다.
  int get skippedEntryCount => _skippedEntryCount;
  int _skippedEntryCount = 0;

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
  ///
  /// **초안은 걸러낸다.** 총무가 저장만 하고 체인에 올리지 않은 건은 `status` 가
  /// 없는 상태로 내려오는데(스토리보드 3 「화면 전체 규칙」), [EntryModel.fromJson]
  /// 이 그것을 `PENDING` 으로 채워 넣어서 그냥 두면 **학생 목록에 「승인대기」로
  /// 섞여 보인다.** 아직 아무 데도 올라가지 않아 검증할 대상조차 없는 건이다.
  Future<List<EntryModel>> fetchEntries() async {
    final json = await _getJson(ApiConfig.entries);
    if (json is List) {
      _usingDemoData = false;
      return parseEntries(json);
    }
    _usingDemoData = true;
    _skippedEntryCount = 0;
    return _demoEntries();
  }

  /// `GET /entries` 응답을 모델로 바꾼다. [skippedEntryCount] 를 갱신한다.
  ///
  /// **한 항목이 깨져도 나머지는 보여준다.** [EntryStatus.fromCode] 는
  /// `docs/enums.md` 에 없는 값을 만나면 던지는데(도메인 규칙 1 — 조용히
  /// 넘어가는 대신 드러낸다), 목록 전체를 한 번에 변환하면 그 한 건 때문에
  /// 화면이 통째로 멈춘다. 그래서 항목 단위로 받아 건너뛴다.
  ///
  /// **모르는 값을 `PENDING` 으로 메우지는 않는다.** 메우면 학생 화면이
  /// 모르는 상태를 「승인대기」라고 잘못 말하게 된다.
  ///
  /// `fromJson` 이 아니라 여기서 걸러야 하는 이유는 [EntryModel.fromJson] 이
  /// 실패를 던져서 알리는 계약이기 때문이다. 판단은 호출자 몫이다.
  List<EntryModel> parseEntries(List<dynamic> json) {
    final entries = <EntryModel>[];
    var skipped = 0;
    for (final e in json) {
      // 초안(status IS NULL)은 학생 앱에서 정상 제외 — 실패로 세지 않는다.
      if (e is Map && e['status'] == null) continue;
      try {
        entries.add(EntryModel.fromJson(e));
      } catch (_) {
        skipped++;
      }
    }
    _skippedEntryCount = skipped;
    return entries;
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

  /// GET /users/wallets — **지갑 주소 → user id** 매핑 (검증 2단계)
  ///
  /// 체인의 `registrant`·`approver` 는 지갑 주소이고 DB 의 `created_by`·
  /// `approved_by` 는 user id 라 값 자체가 다르다. 이 매핑이 없으면
  /// **누가 등록하고 누가 승인했는지를 대조할 수 없다** (HASHING.md §2).
  Future<Map<String, int>?> fetchWalletMap() async {
    final json = await _getJson('${ApiConfig.baseUrl}/users/wallets');
    if (json is Map<String, dynamic>) {
      final parsed = parseWalletMap(json);
      if (parsed != null) return parsed;
    }
    // 서버 원장에는 데모 지갑을 끼워 넣지 않는다 ([fetchOnChainEntry] 참고).
    return _usingDemoData ? _demoUserIdByAddress : null;
  }

  /// `GET /users/wallets` 응답을 **주소(소문자) → user id** 로 모은다.
  ///
  /// **두 형식을 모두 받는다.** 인증 파트가 응답을 주소 → id 방향으로 바꾸는 중인데
  /// (PR #20), 앱과 서버의 머지 순서를 맞추지 않아도 되게 양쪽을 다 읽는다.
  /// 한쪽만 먼저 올라가면 파싱이 던져서 **검증이 아예 안 돌고 배지가 「검증 중」에
  /// 멈춘다** — `_verifyAll` 은 await 되지 않아 그 예외가 조용히 사라진다.
  /// #20 이 머지되고 실연동이 끝나면 옛 형식 가지는 지우면 된다.
  ///
  /// 못 읽은 항목은 **버리지 않고 건너뛴다** — 한 사람 때문에 매핑 전체를 잃으면
  /// 나머지 항목의 등록자 대조까지 「모름」이 된다.
  static Map<String, int>? parseWalletMap(Map<String, dynamic> json) {
    final map = <String, int>{};

    json.forEach((key, value) {
      if (key.toLowerCase().startsWith('0x')) {
        // 새 형식 — `{"0x3c44…": 2}`. 한 사람이 주소를 여러 개 가질 수 있다.
        final id = value is int ? value : int.tryParse('$value');
        if (id != null) map[key.toLowerCase()] = id;
      } else {
        // 옛 형식 — `{"2": "0x3C44…"}`. 사용자당 주소 하나뿐이라 키를 교체하면
        // 옛 주소가 응답에서 사라진다. 방향만 뒤집어 같은 모양으로 담는다.
        final id = int.tryParse(key);
        if (id != null && value is String && value.startsWith('0x')) {
          map[value.toLowerCase()] = id;
        }
      }
    });

    // 하나도 못 읽었으면 「매핑 없음」이다. 빈 매핑을 돌려주면 「주소가 매핑에
    // 없다」가 되어 사유 문구가 엉뚱해진다.
    return map.isEmpty ? null : map;
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
  ///
  /// 서버 원장을 보고 있는데 전송이 실패하면 [ObjectionFailed] 를 던진다.
  /// 조용히 로컬 폴백으로 넘어가면 **접수되지도 않은 이의가 「접수되었습니다」로
  /// 뜬다** — 학생은 답변을 기다리지만 학생회에는 아무것도 가 있지 않다
  /// (스토리보드 5 ③ 「실패: 서버 무응답 → 토스트 · 입력 내용은 남겨둔다」).
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

    if (!_usingDemoData) throw const ObjectionFailed();

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
  ///
  /// **조회 실패와 미보유는 다르다** (스토리보드 6 ②·③). 미보유는 서버가
  /// 대답한 결과라 「학생회비 납부 확인이 필요합니다」로 안내하면 되지만, 조회가
  /// 안 된 것은 보유 여부 자체를 모르는 상태다. 못 받았는데 「미보유」라고 하면
  /// SBT 를 가진 학생에게 없다고 말하는 셈이 된다.
  ///
  /// 못 받았으면 null 을 돌려준다 — 다른 조회들과 같은 규칙으로, 데모 데이터는
  /// 데모 모드일 때만 끼워 넣는다 ([fetchOnChainEntry] 참고).
  Future<MembershipResult> fetchMyMembership() async {
    try {
      final res = await http
          .get(Uri.parse('${ApiConfig.baseUrl}/memberships/me'))
          .timeout(_timeout);
      if (res.statusCode == 200) {
        return MembershipResult.ok(
          MembershipModel.fromJson(jsonDecode(utf8.decode(res.bodyBytes))),
        );
      }
      // 404 는 「발급받은 적 없음」이다. 서버가 분명히 대답한 것이므로
      // 조회 실패가 아니라 미보유로 다룬다.
      if (res.statusCode == 404) return const MembershipResult.ok(null);
    } catch (_) {}

    return _usingDemoData
        ? MembershipResult.ok(_demoMembership())
        : const MembershipResult.failed();
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

  /// 데모용 지갑 매핑 — `GET /users/wallets` 가 내려주는 것과 같은 값이다.
  ///
  /// 컨트랙트 병합으로 임원 주소가 정해졌다
  /// (`contracts/deployments/localhost.json` 의 `accounts` 와 일치).
  /// 역할이 아니라 **지갑이 등록된 사용자**가 들어 있어서, 임기가 끝난 사람이
  /// 등록·승인한 과거 항목도 검증된다.
  static const Map<int, String> _demoWallets = {
    2: '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC', // 총무
    3: '0x90F79bf6EB2c4f870365E785982E1f101E93b906', // 감사
    4: '0x70997970C51812dc3A010C7d01b50e0d17dc79C8', // 회장
    5: '0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc', // 감사 2
  };

  /// [fetchWalletMap] 이 돌려주는 모양 — API 와 같은 **주소 → user id** 방향이다.
  ///
  /// `_demoWallets` 에서 만들어 쓴다. 주소를 두 군데 적어 두면 한쪽만 바뀌는 순간
  /// 데모 전체가 「등록자 불일치 = 변조 감지」로 뒤집힌다 ([_demoOnChain] 참고).
  static final Map<String, int> _demoUserIdByAddress = {
    for (final e in _demoWallets.entries) e.value.toLowerCase(): e.key,
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
    int termCode = TermInfo.currentTermCode,
    EntryStatus status = EntryStatus.CONFIRMED,
    int? correctsEntryId,
    CorrectionReason? correctionReason,
    String? txPending,
    String? txConfirm,
  }) {
    return EntryModel(
      id: id,
      termId: 1,
      termCode: termCode,
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
        termCode: TermInfo.currentTermCode,
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
      term: e.termCode,
      // **주소를 여기에 따로 적지 않는다.** 지갑 매핑과 두 군데에 적어 두면
      // 한쪽만 바뀌는 순간 데모 전체가 「등록자 불일치 = 변조 감지」로 뒤집힌다.
      // 실제로 컨트랙트 병합 때 주소가 바뀌면서 그럴 뻔했다.
      registrant: _demoWallets[e.createdBy] ?? OnChainEntry.zeroAddress,
      approver: e.approvedBy == null
          ? OnChainEntry.zeroAddress
          : (_demoWallets[e.approvedBy] ?? OnChainEntry.zeroAddress),
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
