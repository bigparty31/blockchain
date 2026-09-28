import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/entry_merge.dart';
import '../../core/entry_verifier.dart';
import '../../core/enums.dart';
import '../../core/format.dart';
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
  const EntryListScreen({super.key});

  @override
  State<EntryListScreen> createState() => _EntryListScreenState();
}

enum _Filter { all, income, expense, flagged }

class _EntryListScreenState extends State<EntryListScreen> {
  final _api = StudentApiService();

  bool _loading = true;
  List<EntryChain> _chains = [];
  final Map<int, VerificationReport> _reports = {};
  _Filter _filter = _Filter.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final entries = await _api.fetchEntries();
    if (!mounted) return;

    setState(() {
      _chains = EntryMerge.fold(entries);
      _reports.clear();
      _loading = false;
    });

    // 목록을 열어본 시점에 미확인 뱃지(S12)를 지운다.
    if (entries.isNotEmpty) {
      final maxId = entries.map((e) => e.id).reduce((a, b) => a > b ? a : b);
      await _api.markEntriesSeen(maxId);
    }

    _verifyAll();
  }

  /// 체인별로 검증을 돌린다. 끝나는 대로 배지를 갱신한다.
  ///
  /// **원본뿐 아니라 정정 항목도 검증한다.** 정정도 저마다 온체인 entry 이고,
  /// 카드에 크게 뜨는 최종 금액이 정정 금액에서 나온다. 원본만 보면 정정 내용이
  /// 나중에 조작돼도 배지가 초록으로 남는다.
  Future<void> _verifyAll() async {
    final wallets = await _api.fetchWalletMap();

    for (final chain in _chains) {
      for (final entry in chain.allEntries) {
        final onChain = await _api.fetchOnChainEntry(entry.id);
        final receiptBytes = await _api.fetchReceiptBytes(entry);
        if (!mounted) return;

        setState(() {
          _reports[entry.id] = EntryVerifier.verify(
            entry,
            onChain: onChain,
            receiptBytes: receiptBytes,
            walletByUserId: wallets,
          );
        });
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
          _buildFilterBar(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: _visible.isEmpty
                        ? _buildEmpty()
                        : ListView.separated(
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
    };

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Row(
        children: _Filter.values.map((f) {
          final selected = _filter == f;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => setState(() => _filter = f),
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
    );
  }

  Widget _buildEmpty() {
    return ListView(
      children: [
        const SizedBox(height: 120),
        Icon(Icons.inbox_rounded, size: 56, color: AppTheme.textSub.withOpacity(0.4)),
        const SizedBox(height: 12),
        const Center(
          child: Text(
            '해당하는 내역이 없습니다',
            style: TextStyle(color: AppTheme.textSub, fontSize: 14),
          ),
        ),
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

              Row(
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
                  Column(
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
                ],
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
