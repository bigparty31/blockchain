import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/entry_merge.dart';
import '../../core/entry_verifier.dart';
import '../../core/enums.dart';
import '../../core/format.dart';
import '../../services/auth_service.dart';
import '../../services/student_api_service.dart';
import 'entry_detail_screen.dart';
import 'widgets/student_badges.dart';

/// 수입·지출 목록 (S2) — 정정 이력을 병합해 보여준다 (S9)
///
/// 검증(S4)은 목록을 띄운 뒤 **뒤따라 채운다.** 온체인 조회와 영수증 내려받기가
/// 끝나야 세 단계가 완성되므로, 그 전까지는 「검증 중」으로 두고 끝난 것부터
/// 배지를 갱신한다. 다 끝나기 전에 초록을 보여주면 확인하지 못한 것을
/// 확인했다고 말하는 셈이 된다.
class EntryListScreen extends StatefulWidget {
  /// 미확인 뱃지(S12)를 눌러 들어왔을 때, **그 뱃지가 세고 있던 기준 id**.
  /// 이 id 보다 큰 항목이 「새로 올라온 것」이다. 뱃지 없이 들어왔으면 null.
  ///
  /// 호출자가 넘겨야 하는 이유 — 목록을 여는 순간 [StudentApiService.markEntriesSeen]
  /// 이 기준을 최신 id 로 덮어쓴다. 여기서 직접 읽으면 **이미 덮어쓴 뒤라 항상
  /// 0건**이 된다. 그래서 덮어쓰기 전의 값을 대시보드에서 들고 온다.
  final int? unseenAfterEntryId;

  const EntryListScreen({super.key, this.unseenAfterEntryId});

  @override
  State<EntryListScreen> createState() => _EntryListScreenState();
}

enum _Filter { all, income, expense, flagged, unseen }

class _EntryListScreenState extends State<EntryListScreen> {
  final _api = StudentApiService();

  bool _loading = true;
  List<EntryChain> _chains = [];
  final Map<int, VerificationReport> _reports = {};
  late _Filter _filter =
      widget.unseenAfterEntryId == null ? _Filter.all : _Filter.unseen;

  /// 「미확인」 칩을 띄울지. **뱃지를 눌러 들어왔을 때만 띄운다.**
  /// 상시 노출하면 목록을 한 번 연 뒤로는 영원히 0건인 탭이 남는다 —
  /// 미확인은 「목록을 열면 사라지는」 상태라서 탭으로 둘 성질이 아니다.
  bool get _showUnseenChip => widget.unseenAfterEntryId != null;

  List<_Filter> get _filters => [
        for (final f in _Filter.values)
          if (f != _Filter.unseen || _showUnseenChip) f,
      ];

  /// 필터를 바꿀 때 목록 맨 위로 되돌리기 위한 것 (스토리보드 3 ①).
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 필터를 바꾼다. **스크롤은 맨 위로 되돌린다** — 그대로 두면 짧아진 목록의
  /// 중간에 떨어져서, 바뀐 결과의 첫 줄을 못 보고 「아무것도 없다」고 읽게 된다.
  void _selectFilter(_Filter f) {
    if (_filter == f) return;
    setState(() => _filter = f);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// **무슨 일이 있어도 `_loading` 은 끈다.** 예전에는 조회가 중간에 던지면
  /// 스피너가 영영 안 꺼져서 화면이 멈춘 것처럼 보였다.
  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final entries = await _api.fetchEntries();
      if (!mounted) return;

      setState(() {
        _chains = EntryMerge.fold(entries);
        _reports.clear();
      });

      // 목록을 열어본 시점에 미확인 뱃지(S12)를 지운다.
      if (entries.isNotEmpty) {
        final maxId = entries.map((e) => e.id).reduce((a, b) => a > b ? a : b);
        await _api.markEntriesSeen(maxId);
      }

      _verifyAll();
    } on SessionExpired {
      // 세션이 끊겼다. `AuthService.onUnauthorized` 가 로그인 화면으로 보내므로
      // 여기서는 목록을 비우기만 한다 — **예시 데이터로 메우지 않는다.**
      // 잡지 않으면 `_load` 가 await 되지 않아(`initState`) 처리되지 않은 비동기
      // 예외가 되고, 테스트에서는 그대로 실패로 뜬다.
      if (mounted) {
        setState(() {
          _chains = [];
          _reports.clear();
        });
      }
    } on LedgerUnavailable {
      // 실서버를 보고 있는데 조회가 깨졌다. 빈 목록이 「내역 없음」으로 읽히는
      // 문제는 남지만, 지어낸 내역을 보여주는 것보다 낫다.
      if (mounted) {
        setState(() {
          _chains = [];
          _reports.clear();
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 체인별로 검증을 돌린다. 끝나는 대로 배지를 갱신한다.
  ///
  /// **원본뿐 아니라 정정 항목도 검증한다.** 정정도 저마다 온체인 entry 이고,
  /// 카드에 크게 뜨는 최종 금액이 정정 금액에서 나온다. 원본만 보면 정정 내용이
  /// 나중에 조작돼도 배지가 초록으로 남는다.
  ///
  /// **한 건이 던져도 나머지는 계속 돌린다.** 이 함수는 `_load` 에서 await 되지
  /// 않으므로 예외가 올라가면 조용히 사라지고, 그 뒤 항목의 배지가 전부
  /// 「검증 중」에 남는다 — 화면은 멀쩡해 보이는데 검증만 멈춘 상태다.
  /// 지갑 매핑처럼 전체에 걸리는 조회도 같은 이유로 감싼다. 매핑을 못 받으면
  /// 등록자 대조만 「모름」이 되고, 해시·영수증 대조는 그대로 돌아간다.
  Future<void> _verifyAll() async {
    Map<String, int>? wallets;
    try {
      wallets = await _api.fetchWalletMap();
    } catch (_) {
      wallets = null;
    }

    for (final chain in _chains) {
      for (final entry in chain.allEntries) {
        try {
          final onChain = await _api.fetchOnChainEntry(entry.id);
          final receiptBytes = await _api.fetchReceiptBytes(entry);
          if (!mounted) return;

          setState(() {
            _reports[entry.id] = EntryVerifier.verify(
              entry,
              onChain: onChain,
              receiptBytes: receiptBytes,
              userIdByAddress: wallets,
            );
          });
        } catch (_) {
          // 이 한 건은 「검증 중」에 남지만 나머지는 끝까지 돈다.
          // 결과를 지어내서 채우지는 않는다 — 확인 못 한 것을 확인했다고
          // 말하는 쪽이 멈춰 있는 배지보다 나쁘다.
        }
      }
    }
  }

  /// 체인 전체의 대표 배지. 아직 한 건이라도 안 끝났으면 null 로 두어
  /// 「검증 중」을 유지한다 — 덜 끝난 상태를 결과로 보여주면 안 된다.
  VerificationStatus? _chainStatus(EntryChain chain) {
    final reports = chain.allEntries.map((e) => _reports[e.id]).toList();
    if (reports.any((r) => r == null)) return null;
    return EntryVerifier.chainStatus(reports.map((r) => r!.status));
  }

  List<EntryChain> get _visible {
    switch (_filter) {
      case _Filter.all:
        return _chains;
      case _Filter.income:
        return _chains.where((c) => c.original.kind == EntryKind.INCOME).toList();
      case _Filter.expense:
        return _chains.where((c) => c.original.kind == EntryKind.EXPENSE).toList();
      case _Filter.unseen:
        // 마지막으로 목록을 연 뒤에 새로 생긴 것.
        //
        // **체인 안의 어느 항목이든 새것이면 보인다.** 원본만 보면, 오래된
        // 지출에 정정이 새로 붙은 건이 「새 소식 없음」으로 빠진다 — 금액이
        // 바뀐 것이야말로 학생이 봐야 할 변화다.
        final after = widget.unseenAfterEntryId ?? 0;
        return _chains
            .where((c) => c.allEntries.any((e) => e.id > after))
            .toList();
      case _Filter.flagged:
        // 학생이 눈여겨봐야 할 건 — 검증 실패 또는 경고 승인.
        // 정정 항목이 어긋난 체인도 여기 걸려야 한다. 원본만 보면
        // 정정 쪽 불일치가 「확인 필요」에서 조용히 빠진다.
        return _chains.where((c) {
          final tampered = c.allEntries
              .any((e) => _reports[e.id]?.isTampered ?? false);
          final head = c.original;
          return tampered ||
              OcrWarningBadge.isWarning(head.ocrStatus, head.categoryWarning);
        }).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppTheme.gradientAppBar(title: '수입·지출 내역'),
      body: Column(
        children: [
          if (!_loading && _api.usingDemoData)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: DemoDataBanner(),
            ),
          if (!_loading && _api.skippedEntryCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: SkippedEntriesBanner(count: _api.skippedEntryCount),
            ),
          _buildFilterBar(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: _visible.isEmpty
                        ? _buildEmpty()
                        : ListView.separated(
                            controller: _scroll,
                            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                            itemCount: _visible.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 12),
                            itemBuilder: (context, i) {
                              final chain = _visible[i];
                              return _EntryChainCard(
                                chain: chain,
                                status: _chainStatus(chain),
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => EntryDetailScreen(chain: chain),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    const labels = {
      _Filter.all: '전체',
      _Filter.income: '수입',
      _Filter.expense: '지출',
      _Filter.flagged: '확인 필요',
      _Filter.unseen: '새 항목',
    };

    // **가로로 스크롤되게 둔다.** 맨 `Row` 로 두면 칩이 화면을 넘는데, 넘친
    // 쪽은 릴리스 빌드에서 그냥 잘린다 — 뱃지로 들어왔을 때 선택돼 있는
    // 「새 항목」 칩이 바로 그 끝자리라, 잘리면 「전체」를 한 번 누른 뒤 새 항목만
    // 보는 화면으로 돌아갈 방법이 없어진다(뱃지는 목록을 연 순간 지워진다).
    //
    // 실제로 360dp 기기에서 칩 5개가 넘친다(에뮬레이터 720x1600·density 320 에서
    // 확인). 글자 크기를 키우면 칩 4개만으로도 넘치므로, 폭·글자 크기와 무관하게
    // 닫으려면 개수를 줄이는 것이 아니라 스크롤이 맞다.
    return Container(
      // **폭을 못 박는다.** 스크롤뷰는 가로로 콘텐츠만큼만 차지해서, 지정하지
      // 않으면 흰 배경이 칩 너비에서 끊기고 오른쪽이 페이지 배경으로 비친다.
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: _filters.map((f) {
            final selected = _filter == f;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => _selectFilter(f),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? AppTheme.primary : AppTheme.bgPage,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: selected ? AppTheme.primary : AppTheme.divider,
                    ),
                  ),
                  child: Text(
                    labels[f]!,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                      color: selected ? Colors.white : AppTheme.textSub,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return ListView(
      children: [
        const SizedBox(height: 120),
        Icon(Icons.inbox_rounded, size: 56, color: AppTheme.textSub.withOpacity(0.4)),
        const SizedBox(height: 12),
        Center(
          child: Text(
            _filter == _Filter.unseen
                ? '새로 올라온 항목이 없습니다'
                : '해당하는 내역이 없습니다',
            style: const TextStyle(color: AppTheme.textSub, fontSize: 14),
          ),
        ),
        // 미확인으로 들어왔는데 비어 있으면 빠져나갈 길을 준다. 칩이 위에
        // 있긴 하지만, 빈 화면을 보고 「내역이 없는 앱」으로 읽고 닫는 쪽이 많다.
        if (_filter == _Filter.unseen) ...[
          const SizedBox(height: 14),
          Center(
            child: TextButton(
              onPressed: () => _selectFilter(_Filter.all),
              child: const Text('전체 내역 보기'),
            ),
          ),
        ],
      ],
    );
  }
}

/// 항목 한 건(정정 체인 포함) 카드
class _EntryChainCard extends StatelessWidget {
  final EntryChain chain;

  /// 원본과 정정을 모두 검증한 결과의 대표 상태. 아직 안 끝났으면 null.
  final VerificationStatus? status;
  final VoidCallback onTap;

  const _EntryChainCard({
    required this.chain,
    required this.status,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final head = chain.original;
    final isIncome = head.kind == EntryKind.INCOME;
    final amountColor = isIncome ? AppTheme.income : AppTheme.expense;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: AppTheme.cardDecoration,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    Fmt.date(head.occurredAt),
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
                  ),
                  const Spacer(),
                  EntryStatusBadge(status: chain.displayStatus),
                ],
              ),
              const SizedBox(height: 10),

              // 금액 칸의 **상한**을 알려면 바깥 제약을 읽어야 한다. 금액을 Row 의
              // 유연 자식으로 두면 남는 폭을 절반씩 나눠 가져서, 거래처 이름이
              // 절반에서 일찍 줄바꿈되고 금액도 카드 끝이 아니라 가운데에 붙는다.
              LayoutBuilder(
                builder: (context, rowConstraints) => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          head.counterparty,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textMain,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          head.purpose,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // **금액은 줄이되 자르지 않는다.** 좁은 기기·큰 글자에서는
                  // 금액 열이 남은 폭을 넘는다(320dp·150% 에서 1px). 말줄임으로
                  // 두면 「₩5,000,0…」 처럼 **자릿수가 사라진 금액**이 보이는데,
                  // 장부 화면에서 그것은 틀린 숫자를 보여주는 것과 같다.
                  // [FittedBox] 는 글자를 작게 만들 뿐 자릿수를 지우지 않는다.
                  //
                  // 유연 자식이 아니라 **제 크기대로 두고 상한만** 건다 — 그래야
                  // 금액이 카드 오른쪽 끝에 붙는다.
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: rowConstraints.maxWidth * 0.55,
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          // 정정된 건은 원본 금액에 취소선을 긋고 최종값을 강조한다.
                          // 원본은 이력에 그대로 남고, 합계에는 최종값만 반영된다.
                          if (chain.hasCorrection)
                            Text(
                              Fmt.won(head.amount),
                              style: TextStyle(
                                fontSize: 12,
                                color: AppTheme.textSub.withOpacity(0.8),
                                decoration: TextDecoration.lineThrough,
                              ),
                            ),
                          Text(
                            '${isIncome ? '+' : '-'}${Fmt.won(chain.finalAmount)}',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: amountColor,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                ),
              ),

              const SizedBox(height: 12),

              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (status == null)
                    const VerifyingChip()
                  else
                    VerificationBadge(status: status!, compact: true),
                  if (OcrWarningBadge.isWarning(head.ocrStatus, head.categoryWarning))
                    OcrWarningBadge(
                      ocrStatus: head.ocrStatus,
                      categoryWarning: head.categoryWarning,
                      compact: true,
                    ),
                  if (chain.latestReason != null)
                    CorrectionBadge(reason: chain.latestReason!),
                ],
              ),

              // 정정 이력 한 줄 요약 — `50,000원 → 30,000원 정정 (입력 오류)`
              if (chain.hasCorrection) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.info.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.subdirectory_arrow_right_rounded,
                          size: 14, color: AppTheme.info),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${Fmt.won(head.amount)} → ${Fmt.won(chain.finalAmount)} 정정'
                          '${chain.latestReason != null ? ' (${chain.latestReason!.label})' : ''}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.info,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
