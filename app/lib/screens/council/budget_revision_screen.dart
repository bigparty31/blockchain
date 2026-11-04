import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/format.dart';
import '../../models/budget_model.dart';
import '../../services/api_service.dart';
import 'input_rules.dart';

/// [이승호 담당: app/lib/screens/council/]
/// 예산 개정 요청 화면 (스토리보드 11) — 총무가 예산 항목의 증액을 요청한다.
///
/// - 증액만 할 수 있고(금액은 양수), 사유가 비어 있으면 제출할 수 없다.
/// - 차단된 지출에서 넘어오면 [initialCategory] 항목이 골라져 있고, 그 지출이 근거로 붙는다.
/// - 결재는 총무 요청 → 회장 요청 서명 → 감사 승인 서명 순이다. 이 화면은 첫 단계(요청)까지다.
class BudgetRevisionScreen extends StatefulWidget {
  final String? initialCategory;

  /// 근거가 되는 차단 지출 (차단 안내에서 넘어올 때만).
  final String? basisTitle;
  final int? basisAmount;

  const BudgetRevisionScreen({
    super.key,
    this.initialCategory,
    this.basisTitle,
    this.basisAmount,
  });

  @override
  State<BudgetRevisionScreen> createState() => _BudgetRevisionScreenState();
}

class _BudgetRevisionScreenState extends State<BudgetRevisionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _reasonController = TextEditingController();

  List<BudgetModel> _budgets = const [];
  String? _category;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _category = widget.initialCategory;
    _loadBudgets();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  /// 예산 목록을 못 읽었다. 항목을 고를 수 없으니 요청도 보낼 수 없다 — 못 읽었다고 적는다.
  bool _budgetsFailed = false;

  Future<void> _loadBudgets() async {
    final List<BudgetModel> budgets;
    try {
      budgets = await ApiService().fetchBudgets();
    } on ApiUnavailable {
      if (mounted) setState(() => _budgetsFailed = true);
      return;
    }
    if (!mounted) return;
    setState(() {
      _budgetsFailed = false;
      _budgets = budgets;
      _category ??= budgets.isEmpty ? null : budgets.first.category;
      // 차단 지출이 근거면 모자란 만큼을 기본 증액분으로 채워 둔다.
      final short = _shortfall;
      if (short != null && short > 0 && _amountController.text.isEmpty) {
        _amountController.text = '$short';
      }
    });
  }

  BudgetModel? get _selected {
    for (final b in _budgets) {
      if (b.category == _category) return b;
    }
    return null;
  }

  /// 근거 지출이 선택한 항목의 잔량을 넘는 금액.
  int? get _shortfall {
    final basis = widget.basisAmount;
    final b = _selected;
    if (basis == null || b == null) return null;
    return basis - b.remainingAmount;
  }

  Future<void> _submit() async {
    if (_submitting || !_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    final amount = int.parse(_amountController.text);
    // trim() 을 쓰지 않는다 — BOM 처리가 서버(Python)와 달라 사유 해시가 갈린다 (input_rules.dart 머리말).
    // 정본화는 서명용 해시를 만들 때 Hashing.canonicalText 가 한다.
    final reason = _reasonController.text;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(color: AppTheme.info.withOpacity(0.12), shape: BoxShape.circle),
                child: const Icon(Icons.trending_up_rounded, color: AppTheme.info, size: 30),
              ),
              const SizedBox(height: 16),
              const Text('예산 개정 요청 완료!',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textMain),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: AppTheme.bgPage, borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv('예산 항목', _category ?? '-'),
                    _kv('증액분', '+${Fmt.won(amount)}'),
                    _kv('사유', reason),
                    if (widget.basisTitle != null) _kv('근거 지출', widget.basisTitle!),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text('총무 요청 ✓ → 회장 요청 서명 → 감사 승인 서명',
                style: TextStyle(fontSize: 12, color: AppTheme.textSub, height: 1.4),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: GradientButton(
                  onPressed: () => Navigator.pop(ctx),
                  label: '확인',
                  icon: Icons.check_rounded,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _submitting = false);
    Navigator.pop(context);
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: '$k: ', style: const TextStyle(color: AppTheme.textSub, fontSize: 13)),
            TextSpan(text: v, style: const TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w600, fontSize: 13)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final short = _shortfall;
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: const Text('예산 개정 요청', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        flexibleSpace: Container(decoration: const BoxDecoration(gradient: AppTheme.primaryGradient)),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.basisTitle != null) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppTheme.expense.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFFFCDD2)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.block_rounded, color: AppTheme.expense, size: 18),
                          SizedBox(width: 8),
                          Text('근거: 차단된 지출',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppTheme.expense),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text('${widget.basisTitle} · ${Fmt.won(widget.basisAmount ?? 0)}',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textMain),
                      ),
                      if (short != null && short > 0) ...[
                        const SizedBox(height: 4),
                        Text('${_category ?? ''} 잔량이 ${Fmt.won(short)} 모자라요',
                          style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
              const Text('예산 항목', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textMain)),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _budgets.any((b) => b.category == _category) ? _category : null,
                isExpanded: true,
                decoration: _decoration('증액할 항목'),
                items: [
                  for (final b in _budgets)
                    DropdownMenuItem(
                      value: b.category,
                      child: Text('${b.category} · 잔량 ${Fmt.won(b.remainingAmount)}', overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => _category = v),
                validator: (v) => v == null ? '예산 항목을 골라 주세요' : null,
              ),
              if (_budgetsFailed)
                Row(
                  children: [
                    const Expanded(
                      child: Text('예산 목록을 불러오지 못했어요.',
                          key: Key('budgets_failed'), style: TextStyle(fontSize: 12, color: AppTheme.expense)),
                    ),
                    TextButton(onPressed: _loadBudgets, child: const Text('다시 시도')),
                  ],
                ),
              if (selected != null) ...[
                const SizedBox(height: 6),
                Text('편성 ${Fmt.won(selected.plannedAmount)} · 집행률 ${Fmt.percent(selected.executionRate)}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
                ),
              ],
              const SizedBox(height: 20),
              const Text('증액 금액', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textMain)),
              const SizedBox(height: 8),
              TextFormField(
                controller: _amountController,
                keyboardType: TextInputType.number,
                decoration: _decoration('늘릴 금액 (원)'),
                validator: (v) => InputRules.positiveAmount(v, fieldName: '증액 금액'),
              ),
              const SizedBox(height: 20),
              const Text('사유', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textMain)),
              const SizedBox(height: 8),
              TextFormField(
                controller: _reasonController,
                maxLines: 3,
                decoration: _decoration('왜 늘려야 하는지 적어 주세요'),
                validator: (v) => InputRules.requiredReason(v, fieldName: '사유'),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.primaryLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text('결재 순서: 총무 요청 → 회장 요청 서명 → 감사 승인 서명. 두 서명이 모두 있어야 증액돼요.',
                  style: TextStyle(fontSize: 12, height: 1.4, color: AppTheme.textMain),
                ),
              ),
              const SizedBox(height: 24),
              GradientButton(
                onPressed: _submitting ? null : _submit,
                label: '예산 개정 요청하기',
                icon: Icons.send_rounded,
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _decoration(String hint) => InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      );
}
