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
import 'auth_service.dart';

/// 이의 제기가 서버에 닿지 못했을 때.
///
/// 실패를 조용히 삼키면 접수되지 않은 이의가 「접수되었습니다」로 뜬다.
class ObjectionFailed implements Exception {
  const ObjectionFailed();
  @override
  String toString() => 'ObjectionFailed';
}

/// 실서버를 보고 있는데 그 조회를 읽지 못했다.
///
/// **[SessionExpired] 와 다른 사건이다.** 세션은 멀쩡하고 그 요청만 실패한
/// 것이므로 로그아웃시킬 이유가 없다. 그렇다고 예시 데이터로 메울 자리도
/// 아니다 — 실제 장부 옆에 예시 숫자가 섞이면 어느 쪽이 진짜인지 알 수 없다.
/// 화면은 이것을 받아 「조회 실패」를 말한다 (스토리보드 2 ⑥).
class LedgerUnavailable implements Exception {
  const LedgerUnavailable();
  @override
  String toString() => 'LedgerUnavailable';
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

  /// HTTP 클라이언트. **테스트에서 갈아끼운다.**
  ///
  /// 패키지 함수 `http.get` 을 직접 부르면 테스트가 **실제 네트워크를 탄다.**
  /// 그러면 결과가 「그 머신에 서버가 떠 있는지」에 따라 달라진다 —
  /// `demo_verification_test` 가 그래서 깨졌다. 서버가 켜져 있으면
  /// `/entries` 가 200 을 주면서 [usingDemoData] 가 꺼지고, 온체인 조회는 404 라
  /// 배지가 전부 `partial` 로 바뀐다. 백엔드를 돌리는 사람 누구에게나 깨지고,
  /// 켜지거나 죽는 중일 때는 연결이 대기해 테스트 한도(30초)를 넘긴다.
  ///
  /// 주입으로 바꾸면 테스트가 응답을 직접 정할 수 있어서, 네트워크 없이
  /// **404 분류나 빈 장부 같은 경로까지** 못박을 수 있다
  /// (`package:http/testing.dart` 의 `MockClient`).
  static http.Client client = http.Client();

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
    // 세션이 바뀐 뒤에 돌아온 응답은 **싱글턴 깃발을 건드리지 않는다**
    // ([_staleSession]). 목록 자체는 부른 화면에 돌려준다 — 그 화면은 이미
    // 닫히는 중이고, 돌려주지 않으면 여기서 던질 곳도 없다.
    final generation = AuthService().sessionGeneration;
    final json = await _getJson(ApiConfig.entries);
    final stale = _staleSession(generation);

    if (json is List) {
      final entries = stale ? parseEntriesOnly(json) : parseEntries(json);
      if (!stale) _usingDemoData = false;
      return entries;
    }
    if (!stale) {
      _usingDemoData = true;
      _skippedEntryCount = 0;
    }
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
    final (entries, skipped) = _parse(json);
    _skippedEntryCount = skipped;
    return entries;
  }

  /// [parseEntries] 와 같지만 [skippedEntryCount] 를 **갱신하지 않는다.**
  ///
  /// 지난 세션의 응답을 변환할 때 쓴다 — 그 건수를 써 두면 다음 사용자의 화면이
  /// 「n 건을 읽지 못했습니다」를 자기 조회 결과로 읽는다 ([_staleSession]).
  List<EntryModel> parseEntriesOnly(List<dynamic> json) => _parse(json).$1;

  (List<EntryModel>, int) _parse(List<dynamic> json) {
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
    return (entries, skipped);
  }

  /// GET /budgets — 예산 항목별 잔량·집행률·개정 이력 (S6)
  ///
  /// **실서버를 보고 있으면 폴백하지 않는다** ([fetchLatestSnapshot] 과 같은 이유).
  /// 실제 장부 옆에 예시 예산이 뜨면 집행률·잔량이 전부 거짓인데 배너는 없다.
  /// 못 읽었으면 던져서 화면이 「조회 실패」를 말하게 한다 (스토리보드 2 ⑥).
  Future<List<BudgetModel>> fetchBudgets() async {
    final json = await _getJson(ApiConfig.budgets);
    if (json is List) {
      return json.map((e) => BudgetModel.fromJson(e)).toList();
    }
    if (!_usingDemoData) throw const LedgerUnavailable();
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

  /// GET /entries/{id} — 단건 상세.
  ///
  /// **목록(`GET /entries`)에 없는 값이 여기에만 있다.** 지금은 `block_number` 가 그렇다 —
  /// 서버가 트랜잭션 영수증을 읽어 채우는데(backend `entries.py` `_fetch_entry_chain_detail`),
  /// 항목마다 RPC 왕복이라 목록에서는 하지 않는다. 목록 응답에서는 `null` 이다
  /// (2026-11-12 실연동에서 확인: 목록 `null` / 상세 `11`).
  ///
  /// 못 읽으면 null 이다. **예시 데이터로 메우지 않는다** — 상세 화면은 이미 목록에서 받은
  /// 값을 그리고 있고, 여기서 데모 값을 섞으면 실제 항목에 가짜 블록 번호가 붙는다.
  Future<EntryModel?> fetchEntry(int entryId) async {
    final json = await _getJson('${ApiConfig.entries}/$entryId');
    if (json is Map<String, dynamic>) return EntryModel.fromJson(json);
    return null;
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
  /// **우리 서버가 아니면 토큰을 붙이지 않는다.** `receipt_path` 는 절대 URL 일
  /// 수 있고(S3·CDN) 백엔드에는 출처 제한이 없다 — 그대로 보내면 **남의 서버가
  /// 학생 JWT 를 받아 간다.** presigned URL 은 `Authorization` 헤더가 붙었다는
  /// 이유만으로 요청을 거부하기도 해서, 붙이는 쪽이 더 잘 동작하는 것도 아니다.
  ///
  /// 같은 이유로 **남의 서버 401 을 세션 만료로 보지 않는다.** 외부 저장소의
  /// 거부 한 번으로 멀쩡한 로그인이 끊기면, 학생은 영수증을 열었다가 로그아웃된다.
  Future<List<int>?> fetchReceiptBytes(EntryModel entry) async {
    final path = entry.receiptPath;
    if (path == null) return null;

    final url = path.startsWith('http') ? path : '${ApiConfig.baseUrl}$path';
    final ours = ApiConfig.isOwnOrigin(url);
    final auth = _auth;

    final http.Response res;
    try {
      res = await client
          .get(
            Uri.parse(url),
            headers: ours ? auth.headers : const <String, String>{},
          )
          .timeout(_timeout);
    } catch (_) {
      // 서버 항목의 영수증을 못 받았을 때 데모 바이트를 돌려주면 「영수증이 바뀌었다」는
      // 거짓 판정이 된다. 못 받았으면 못 받은 것으로 둔다 ([fetchOnChainEntry] 참고).
      return _usingDemoData ? _demoReceiptBytes(entry.id) : null;
    }

    if (res.statusCode == 200) return res.bodyBytes;
    if (ours) await _checkUnauthorized(res.statusCode, token: auth.token);

    return _usingDemoData ? _demoReceiptBytes(entry.id) : null;
  }

  // ── 아직 백엔드에 없는 엔드포인트 ──────────────────────────

  /// GET /snapshots/latest — 통장 잔액 스냅샷과 미등록 건 (S11)
  ///
  /// 대조 기능 자체는 서버에 `GET /bank/snapshots` · `/bank/snapshots/{id}` 로 있지만
  /// **학생은 그쪽을 쓸 수 없다** — 둘 다 `council_only` 라 학생 토큰은 403 이고,
  /// `bank` 라우터가 `STUDENT_QUERY_ROUTERS` 에 없어 학생 서버에는 경로가 생기지 않는다
  /// (2026-11-12 실연동에서 확인, `docs/backend_requests.md` §1-5). 경로를 바꾸면 안 되는 이유다.
  ///
  /// **실서버를 보고 있으면 폴백하지 않는다.** 이 엔드포인트는 백엔드에 아직
  /// 없어서 실모드에서 404 가 확정인데, 그때 예시 스냅샷을 돌려주면 **실제
  /// 장부와 가짜 통장 잔액·미등록 거래가 한 화면에 섞인다.** [usingDemoData] 는
  /// `fetchEntries` 가 성공해서 false 이므로 데모 배너도 뜨지 않아, 학생은 그
  /// 혼합을 알아챌 방법이 없다 ([fetchOnChainEntry]·[fetchMyMembership] 의 같은 판단).
  Future<SnapshotModel?> fetchLatestSnapshot() async {
    final json = await _getJson('${ApiConfig.baseUrl}/snapshots/latest');
    if (json is Map<String, dynamic>) return SnapshotModel.fromJson(json);
    return _usingDemoData ? _demoSnapshot() : null;
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
  /// Throws [ObjectionFailed], [SessionExpired].
  Future<ObjectionModel> raiseObjection({
    required int entryId,
    required String content,
  }) async {
    final auth = _auth;

    http.Response? res;
    try {
      res = await client
          .post(
            Uri.parse('${ApiConfig.baseUrl}/objections'),
            headers: {'Content-Type': 'application/json', ...auth.headers},
            body: jsonEncode({'entry_id': entryId, 'content': content}),
          )
          .timeout(_timeout);
    } catch (_) {
      res = null; // 서버에 닿지 못했다
    }

    if (res != null) {
      // 401 은 여기서 던진다 — 아래 폴백으로 내려가면 세션이 끊긴 것을
      // 「서버 무응답」으로 말하게 된다.
      await _checkUnauthorized(res.statusCode, token: auth.token);

      if (res.statusCode == 200 || res.statusCode == 201) {
        try {
          return ObjectionModel.fromJson(jsonDecode(utf8.decode(res.bodyBytes)));
        } catch (_) {
          // 접수는 됐는데 응답을 못 읽었다. 폴백으로 내려가지 않는다 —
          // 로컬 사본을 만들면 같은 이의가 두 번 접수된 것처럼 보인다.
          throw const ObjectionFailed();
        }
      }
    }

    // **보낸 세션이 아직 그 세션인지 먼저 본다.** 로그아웃·세션 만료가 이
    // 응답보다 먼저 도착하면 [resetSessionState] 가 목록을 비우고 데모 깃발을
    // 다시 켜 두는데, 그 상태에서 아래 폴백으로 내려가면 **지난 사용자가 쓴
    // 이의가 목록에 들어간다.** 다음 사람의 조회가 실패하면(그때 폴백이
    // `_pendingObjections` 를 돌려준다) 남의 이의 내용이 자기 것으로 보인다.
    //
    // 세션이 바뀌었으면 폴백도 성공도 아니다 — 받을 화면 자체가 없다.
    if (_staleSession(auth.generation)) throw const ObjectionFailed();

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
  /// 못 읽었으면 「모름」을 돌려준다. **데모 값은 서버에 닿지도 못했을 때만** 끼워
  /// 넣는다 ([fetchOnChainEntry] 참고) — 서버가 404 로 대답한 것은 데모로 메울
  /// 자리가 아니다.
  ///
  /// **미보유는 `200` + 본문 `null` 이다** (backend_requests.md §1-4).
  /// `404` 는 미보유로 읽지 않는다 — 이 경로가 서버에 아직 없어서, FastAPI 가
  /// 「경로 없음」으로 내는 404 와 「발급받은 적 없음」을 뜻하는 404 가 앱에서
  /// 구분되지 않는다. 404 를 미보유로 다루면 **엔드포인트가 생기기 전까지 모든
  /// 학생에게 「학생회비 납부 확인이 필요합니다」가 뜨고 이의 제기 버튼이 잠긴다.**
  /// 못 읽은 것은 「모름」으로 두는 쪽이 안전하다 ([canObject] 의 같은 판단).
  Future<MembershipResult> fetchMyMembership() async {
    final auth = _auth;
    try {
      final res = await client
          .get(Uri.parse('${ApiConfig.baseUrl}/memberships/me'), headers: auth.headers)
          .timeout(_timeout);
      if (res.statusCode == 200) {
        return parseMembership(jsonDecode(utf8.decode(res.bodyBytes)));
      }
      // 401 도 「모름」이다 — 미보유가 아니다. 세션이 끊긴 것뿐이라, 미납으로 읽으면
      // 납부한 학생에게 「납부 확인이 필요합니다」가 뜬다.
      //
      // **여기서는 던지지 않는다.** 이 화면에 필요한 답은 이미 「모름」으로
      // 정해져 있고(아래 `MembershipResult.failed`), 던지면 호출자가 그 답을
      // 받지 못해 배지가 「조회 중」에 멈춘다. 세션 정리는 보고만으로 충분하다 —
      // `onUnauthorized` 가 로그인 화면으로 보낸다.
      if (res.statusCode == 401) {
        await AuthService().reportUnauthorized(token: auth.token);
      }

      // 서버가 **대답은 했는데** 읽을 수 없는 경우다 (404 · 5xx · 모양이 다른 200).
      // **여기서 데모 값을 끼워 넣지 않는다.** `_usingDemoData` 는 초기값이 true 이고
      // `fetchEntries` 가 성공할 때만 false 가 되므로, 장부 조회 없이 이 화면으로
      // 바로 들어오면(`AppRoutes.studentSbt`) 실서버의 404 에 **가짜 데모 SBT 와 QR 이
      // 진짜처럼 뜬다.** 행사 입장에 쓰는 QR 이라 더 그렇다.
      return const MembershipResult.failed();
    } catch (_) {}

    // 여기는 서버에 **닿지도 못한** 경우다 — 그게 데모 모드의 뜻이다.
    return _usingDemoData
        ? MembershipResult.ok(_demoMembership())
        : const MembershipResult.failed();
  }

  /// `GET /memberships/me` 의 **`200` 응답 본문**을 판정한다.
  ///
  /// **미보유를 「보유」로 읽지 않는 것이 이 함수의 일이다.** 미납 학생에게
  /// 「납부 확인됨」 배지와 QR 이 뜨고 이의 제기 버튼이 열리면, 게이팅이 있다는
  /// 사실 자체가 무의미해진다.
  ///
  /// 미보유의 모양이 아직 합의 전이라(`backend_requests.md` §1-4) **세 가지를 모두
  /// 미보유로 받는다** — 벗은 `null`, 래퍼 `{"membership": null}`, 빈 객체 `{}`.
  /// 래퍼는 나중에 옆에 필드를 붙이기 좋아서 백엔드가 흔히 고르는 방식이라
  /// 가능성이 낮지 않고, 그대로 두면 `{` 로 시작한다는 이유로 보유 쪽 분기에
  /// 떨어진다. 지갑 매핑을 두 형식 다 읽게 해 둔 것과 같은 이유로, 어느 쪽으로
  /// 정해져도 깨지지 않게 한다.
  ///
  /// 마지막 방어선은 [MembershipModel.isValid] 다 — 모르는 모양이 와도 `id` 가
  /// 실려 있지 않으면 보유로 판정되지 않는다.
  static MembershipResult parseMembership(dynamic body) {
    final unwrapped = _unwrapMembership(body);

    // 서버가 분명히 「발급받은 적 없음」이라고 대답한 경우.
    if (unwrapped == null) return const MembershipResult.ok(null);

    if (unwrapped is Map<String, dynamic>) {
      final m = MembershipModel.fromJson(unwrapped);
      // 모양은 객체인데 멤버십이 아니다(`{}` 등) — 미보유로 다룬다.
      return MembershipResult.ok(m.isValid ? m : null);
    }

    // 숫자·문자열 같은 뜻 모를 본문. 읽은 것이 아니므로 「모름」이다.
    return const MembershipResult.failed();
  }

  /// 래퍼 한 겹을 벗긴다. 감싸여 있지 않으면 그대로 돌려준다.
  ///
  /// 멤버십 필드에는 `membership`·`data` 라는 이름이 없어서 충돌하지 않는다.
  static dynamic _unwrapMembership(dynamic body) {
    if (body is! Map<String, dynamic>) return body;
    for (final key in const ['membership', 'data']) {
      if (body.containsKey(key)) return body[key];
    }
    return body;
  }

  // ── 미확인 항목 뱃지 카운트 (S12) ──────────────────────────

  Future<int> lastSeenEntryId() async {
    await _sessionReset; // 지난 사용자의 기준을 읽지 않는다 ([_sessionReset])
    try {
      final raw = await _storage.read(key: _lastSeenKey);
      return int.tryParse(raw ?? '') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> markEntriesSeen(int maxEntryId) async {
    await _sessionReset; // 지난 사용자의 삭제가 이 값을 지우지 않게 ([_sessionReset])
    try {
      await _storage.write(key: _lastSeenKey, value: maxEntryId.toString());
    } catch (_) {
      // 저장 실패는 조용히 넘긴다 — 뱃지가 안 지워질 뿐 기능에 지장 없다.
    }
  }

  // ── 내부 ────────────────────────────────────────────────────

  /// Throws [SessionExpired] — `401`. **그 밖의 실패는 null 이다.**
  ///
  /// 401 만 예외인 이유: 못 읽은 것을 null 로 돌려주면 호출자가 예시 데이터로
  /// 폴백하는데, 세션 만료는 폴백할 자리가 아니다 ([SessionExpired] 설명).
  /// try 블록 **밖에서** 판정하는 것도 그래서다 — 안에서 던지면 바로 아래
  /// `catch (_)` 가 삼켜 다시 null 이 된다.
  Future<dynamic> _getJson(String url) async {
    final auth = _auth;

    final http.Response res;
    try {
      res = await client.get(Uri.parse(url), headers: auth.headers).timeout(_timeout);
    } catch (_) {
      return null; // 서버에 닿지 못했다 — 데모 모드의 뜻이다
    }

    if (res.statusCode == 401) {
      await AuthService().reportUnauthorized(token: auth.token);
      throw const SessionExpired();
    }
    if (res.statusCode != 200) return null;

    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      return null;
    }
  }

  /// 로그인한 세션의 인증 헤더와 **그때 쓴 토큰**.
  ///
  /// 조회 API 는 지금 토큰 없이도 되지만(docs/API.md 「인증」 3), 붙여 두면
  /// 서버가 인증을 요구하도록 바뀔 때 앱이 조용히 빈 화면이 되지 않는다.
  ///
  /// 토큰까지 들고 다니는 이유는 [AuthService.authSnapshot] 설명에 있다 —
  /// 401 을 보고할 때 「그 요청이 쓴 토큰」이어야 늦게 온 응답이 새 세션을
  /// 지우지 않는다.
  ({Map<String, String> headers, String? token, int generation}) get _auth =>
      AuthService().authSnapshot;

  /// 이 요청을 보낸 세션이 **이미 다른 세션으로 바뀌었는지**.
  ///
  /// 이 클래스는 싱글턴이라 로그아웃·세션 만료를 넘어 살아 있고, 그때
  /// [resetSessionState] 가 세션에 묶인 상태를 비운다. 그런데 **그 전에 나간
  /// 요청은 비운 뒤에 돌아온다** — 돌아와서 싱글턴에 뭔가 쓰면 비운 것이
  /// 되살아나고, 그것을 다음 사용자가 본다.
  ///
  /// 토큰 비교로는 모자라다: 로그아웃하면 토큰이 null 이라 비교할 대상이 없다
  /// ([AuthService.sessionGeneration]).
  bool _staleSession(int generation) => generation != AuthService().sessionGeneration;

  /// 우리 서버가 준 `401` 인가. 남의 서버 401 은 세션과 무관하다.
  ///
  /// Throws [SessionExpired] — 우리 서버의 401 인 경우.
  Future<void> _checkUnauthorized(int statusCode, {required String? token}) async {
    if (statusCode != 401) return;
    await AuthService().reportUnauthorized(token: token);
    throw const SessionExpired();
  }

  /// 로그아웃·세션 만료 때 **세션에 묶인 상태를 비운다** (`main.dart` 가 연결).
  ///
  /// 이 클래스는 싱글턴이라 로그아웃해도 살아 있다. 비우지 않으면 같은 기기의
  /// 다음 사람에게 **이전 사용자가 제기한 이의 목록**이 보이고, 미확인 뱃지가
  /// 이전 사용자의 「마지막으로 본 항목」을 기준으로 계산된다. 데모 깃발도
  /// 되돌려 두어야 다음 사용자의 첫 조회가 실패했을 때 예시 데이터를 실제
  /// 원장으로 읽지 않는다.
  /// 진행 중인 [resetSessionState] 의 보관소 삭제. 없으면 null 이다.
  ///
  /// `main.dart` 는 `onSessionCleared` 가 `void` 라 **이것을 기다리지 않는다.**
  /// 메모리 상태는 아래에서 `await` 전에 비우므로 문제가 없지만, 뱃지 기준
  /// 삭제는 비동기라 **다음 사용자의 읽기·쓰기와 겹칠 수 있다** — 지난 사용자의
  /// 「마지막으로 본 항목」을 다음 사람이 읽거나, 그 삭제가 다음 사람이 방금 쓴
  /// 값을 지운다. 여기에 들고 있다가 그 두 곳에서 기다린다.
  Future<void>? _sessionReset;

  Future<void> resetSessionState() {
    // **`await` 전에 비운다.** `onSessionCleared` 는 세션이 비워지는 순간
    // 동기로 불리므로, 여기까지는 다음 사용자의 요청이 끼어들 틈이 없다.
    _pendingObjections.clear();
    _usingDemoData = true;
    _skippedEntryCount = 0;
    final reset = _clearLastSeen();
    _sessionReset = reset;
    reset.whenComplete(() {
      // 그 사이 또 로그아웃했으면 그쪽 삭제가 진행 중이다 — 그것을 덮지 않는다.
      if (_sessionReset == reset) _sessionReset = null;
    });
    return reset;
  }

  Future<void> _clearLastSeen() async {
    try {
      await _storage.delete(key: _lastSeenKey);
    } catch (_) {
      // 뱃지 기준이 남을 뿐이다. 로그아웃 자체를 막을 이유는 아니다.
    }
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

  /// 데모 항목 7건. **한 번만 만들어 재사용한다.**
  ///
  /// [_demoOnChain] 이 항목 하나를 찾을 때마다 이것을 다시 부르는데, 각 항목은
  /// `Hashing.metaHash`(SHA-256 + NFC 정규화)를 계산한다. 그래서 항목 7개를
  /// 검증하면 metaHash 를 **49번** 계산했다. 값이 고정이라(모든 `occurredAt` 이
  /// 상수 KST 자정) 캐시해도 결과가 같다.
  ///
  /// 리스트를 공유해도 안전하다 — [EntryModel] 은 전 필드가 final 이고,
  /// `EntryMerge.fold` 는 `where().toList()` 로 복사한 뒤 정렬한다.
  static List<EntryModel>? _demoEntriesCache;

  List<EntryModel> _demoEntries() => _demoEntriesCache ??= _buildDemoEntries();

  List<EntryModel> _buildDemoEntries() {
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
