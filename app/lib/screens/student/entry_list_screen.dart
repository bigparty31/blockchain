import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/entry_merge.dart';
import '../../core/enums.dart';
import '../../core/format.dart';
import '../../core/meta_hash.dart';
import '../../services/student_api_service.dart';
import 'entry_detail_screen.dart';
import 'widgets/student_badges.dart';

/// 수입·지출 목록 (S2) — 정정 이력을 병합해 보여준다 (S9)
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
      _loading = false;
    });

    // 목록을 열어본 시점에 미확인 뱃지(S12)를 지운다.
    if (entries.isNotEmpty) {
      final maxId = entries.map((e) => e.id).reduce((a, b) => a > b ? a : b);
      await _api.markEntriesSeen(maxId);
    }
  }

  List<EntryChain> get _visible {
    switch (_filter) {
      case _Filter.all:
        return _chains;
      case _Filter.income:
        return _chains.where((c) => c.latest.kind == EntryKind.INCOME).toList();
      case _Filter.expense:
        return _chains.where((c) => c.latest.kind == EntryKind.EXPENSE).toList();
      case _Filter.flagged:
        // 학생이 눈여겨봐야 할 건 — 검증 실패 또는 경고 승인
        return _chains.where((c) {
          final e = c.latest;
          return MetaHash.verify(e).isTampered ||
              OcrWarningBadge.isWarning(e.ocrStatus, e.categoryWarning);
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
                            itemBuilder: (context, i) => _EntryChainCard(
                              chain: _visible[i],
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => EntryDetailScreen(chain: _visible[i]),
                                ),
                              ),
                            ),
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
  final VoidCallback onTap;

  const _EntryChainCard({required this.chain, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final head = chain.original;
    final latest = chain.latest;
    final verification = MetaHash.verify(latest);
    final isIncome = latest.kind == EntryKind.INCOME;
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
              // 날짜 · 상태
              Row(
                children: [
                  Text(
                    Fmt.date(latest.occurredAt),
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
                  ),
                  const Spacer(),
                  EntryStatusBadge(status: latest.status),
                ],
              ),
              const SizedBox(height: 10),

              // 사용처 · 금액
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          latest.counterparty,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textMain,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          latest.purpose,
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
                        '${isIncome ? '+' : '-'}${Fmt.won(latest.amount)}',
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

              // 뱃지들
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  VerificationBadge(status: verification.status, compact: true),
                  if (OcrWarningBadge.isWarning(latest.ocrStatus, latest.categoryWarning))
                    OcrWarningBadge(
                      ocrStatus: latest.ocrStatus,
                      categoryWarning: latest.categoryWarning,
                      compact: true,
                    ),
                  if (chain.latestReason != null)
                    CorrectionBadge(reason: chain.latestReason!),
                ],
              ),

              // 정정 이력 한 줄 요약 — `50,000원 → 30,000원 정정 (입력오류)`
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
                          '${Fmt.won(head.amount)} → ${Fmt.won(chain.latest.amount)} 정정'
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
