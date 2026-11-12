import 'package:flutter/material.dart';
import '../../core/enums.dart';
import '../../core/app_theme.dart';
import '../../core/format.dart';
import '../../core/hashing.dart';
import '../../models/budget_model.dart';
import '../../models/draft_entry.dart';
import '../../models/entry_model.dart';
import '../../services/api_service.dart';
import '../../services/entry_registration_service.dart';
import 'budget_revision_screen.dart';
import 'input_rules.dart';
import 'receipt_picker.dart';
import 'registration_result.dart';
import 'resubmit.dart';

/// [이승호 담당: app/lib/screens/council/]
/// 1. 지출 등록 화면
class ExpenseCreateScreen extends StatefulWidget {
  /// 초안 저장·서명 제출. 주지 않으면 서버 ([EntryRegistrationService]).
  final EntryRegistrar? registrar;

  /// 영수증 원본 바이트를 고른다. 주지 않으면 카메라·갤러리 ([pickReceiptBytes]).
  final ReceiptPicker? pickReceipt;

  /// 반려·차단된 지출을 고쳐 새로 등록할 때 그 건 ([canResubmit]). 이전 값으로 채워 연다 (PRD §4.3 T4 3단계).
  final EntryModel? resubmitOf;

  /// 저장해 둔 초안을 이어서 제출할 때 그 초안.
  final DraftEntry? resumeDraft;

  const ExpenseCreateScreen({super.key, this.registrar, this.pickReceipt, this.resubmitOf, this.resumeDraft});

  @override
  State<ExpenseCreateScreen> createState() => _ExpenseCreateScreenState();
}

class _ExpenseCreateScreenState extends State<ExpenseCreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _amountController = TextEditingController();
  final _merchantController = TextEditingController();
  final _memoController = TextEditingController();

  String _selectedBudgetCategory = '행사비';
  DateTime _selectedDate = kstToday();
  bool _submitting = false;

  /// 이전·저장해 둔 영수증을 서버에서 받는 중. 받기 전에 제출하면 영수증 없이 올라가 해시가 비고, 뒤늦게 온 영수증은 붙지 못한다.
  bool _restoringReceipt = false;

  bool get _receiptPending => _restoringReceipt && _receiptHash == null;

  /// 영수증 원본 바이트의 SHA-256. 지출은 제출에 필수다 (초안은 없어도 저장된다).
  String? _receiptHash;
  bool get _hasReceiptImage => _receiptHash != null;

  /// 고른 영수증 원본 바이트와, 서버에 올린 결과. 같은 사진은 한 번만 올린다 — 사진을 바꾸면 비운다.
  List<int>? _receiptBytes;
  ReceiptUpload? _upload;

  late final EntryRegistrar _registrar = widget.registrar ?? EntryRegistrationService();

  /// 저장한 초안 번호와 그때의 입력. 입력이 그대로면 다시 제출할 때 같은 번호를 쓴다 (서명 시한 안 재제출, API §2.3).
  int? _draftId;
  EntryDraft? _savedDraft;

  /// 서버 예산 (`GET /budgets`). 지출의 예산 id·학기는 고른 항목의 것을 쓴다.
  List<BudgetModel> _budgets = const [];

  final List<String> _budgetCategories = ['행사비', '사업비', '운영비'];

  /// 예산 항목별 잔량 (`GET /budgets`). 고르기 전에 남은 예산을 보여 준다 (스토리보드 7 ③).
  Map<String, int> _remaining = const {};

  /// 마지막 제출이 차단(`BLOCKED`)된 건의 번호 — 예산 개정 요청의 근거로 붙인다 (`blocked_entry_id`).
  int? _blockedId;

  /// 다시 등록할 때 이전 영수증을 쓰지 못한 이유.
  String? _receiptNote;

  @override
  void initState() {
    super.initState();
    final source = widget.resubmitOf;
    if (source != null) _prefill(source);
    final draft = widget.resumeDraft;
    if (draft != null) _prefillDraft(draft);
    _loadBudgets();
  }

  /// 이전 건의 값으로 채운다. 예산은 목록을 읽은 뒤 id 로 항목을 고른다. 메모는 장부에 없어서 비워 둔다.
  void _prefill(EntryModel e) {
    _titleController.text = e.purpose;
    _merchantController.text = e.counterparty;
    _amountController.text = '${e.amount}';
    _selectedDate = pickerDateOf(e.occurredAt);
    if (e.status == EntryStatus.BLOCKED) _blockedId = e.id;
    if (e.receiptHash == null) return;
    _restoringReceipt = true;
    restoreReceipt(_registrar, e).then((restored) {
      _restoringReceipt = false;
      if (!mounted || _receiptHash != null) return; // 그새 다른 사진을 골랐으면 그대로 둔다
      setState(() {
        if (restored == null) {
          _receiptNote = '이전 영수증을 불러오지 못했어요. 영수증을 다시 첨부해 주세요.';
          return;
        }
        _receiptBytes = restored.$1;
        _receiptHash = restored.$2.hash;
        _upload = restored.$2;
      });
    });
  }

  /// 저장해 둔 초안의 값으로 채운다. 그 번호와 저장 내용을 들고 있어서, 고치지 않고 제출하면 새 초안을 만들지 않는다.
  void _prefillDraft(DraftEntry d) {
    _titleController.text = d.purpose;
    _merchantController.text = d.counterparty;
    _amountController.text = '${d.amount}';
    _selectedDate = pickerDateOf(d.occurredAt);
    _draftId = d.id;
    _savedDraft = d.toEntryDraft();
    if (d.receiptHash == null) return;
    _restoringReceipt = true;
    restoreReceiptFile(_registrar, d.receiptHash, d.receiptPath).then((restored) {
      _restoringReceipt = false;
      if (!mounted || _receiptHash != null) return; // 그새 다른 사진을 골랐으면 그대로 둔다
      setState(() {
        if (restored == null) {
          _receiptNote = '저장해 둔 영수증을 불러오지 못했어요. 영수증을 다시 첨부해 주세요.';
          return;
        }
        _receiptBytes = restored.$1;
        _receiptHash = restored.$2.hash;
        _upload = restored.$2;
      });
    });
  }

  /// 예산 잔량을 못 읽은 이유. 잔량 없이 항목만 보이고, 이유를 적는다.
  String? _budgetsError;

  Future<void> _loadBudgets() async {
    try {
      final budgets = await ApiService().fetchBudgets();
      if (!mounted) return;
      setState(() {
        _budgetsError = null;
        _budgets = budgets;
        _remaining = {for (final b in budgets) b.category: b.remainingAmount};
        // 다시 등록이면 이전 건의 예산 항목을 고른다
        final budgetId = widget.resubmitOf?.budgetId ?? widget.resumeDraft?.budgetId;
        for (final b in budgets) {
          if (b.id == budgetId && _budgetCategories.contains(b.category)) _selectedBudgetCategory = b.category;
        }
      });
    } on ApiUnavailable catch (e) {
      if (mounted) setState(() => _budgetsError = e.message);
    }
  }

  String _budgetLabel(String category) {
    final left = _remaining[category];
    return left == null ? category : '$category · 잔량 ${Fmt.won(left)}';
  }

  @override
  void dispose() {
    _titleController.dispose();
    _amountController.dispose();
    _merchantController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2026, 1, 1),
      lastDate: DateTime(2026, 12, 31),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(primary: AppTheme.primary),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  /// 영수증을 고른다 — 원본 바이트를 그대로 해시한다 (HASHING §4). 원본 업로드는 서버 API 가 생기면 붙인다 (보드 kky-rcp).
  Future<void> _attachReceipt() async {
    // 제출 중에는 바꾸지 못한다 — 올리던 사진의 경로가 다른 사진의 해시와 섞이지 않게 (#71 리뷰)
    if (_submitting) {
      _snack('제출 중에는 영수증을 바꿀 수 없어요.');
      return;
    }
    final bytes = await (widget.pickReceipt ?? pickReceiptBytes)(context);
    if (bytes == null || !mounted || _submitting) return;
    final problem = receiptFormatProblem(bytes);
    if (problem != null) {
      _snack(problem);
      return;
    }
    setState(() {
      _receiptBytes = bytes;
      _receiptHash = Hashing.fileHash(bytes);
      _upload = null;
      _receiptNote = null;
    });
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  BudgetModel? _budgetFor(String category) {
    for (final b in _budgets) {
      if (b.category == category) return b;
    }
    return null;
  }

  /// 입력으로 초안을 만든다. 만들 수 없으면 이유를 알리고 null.
  EntryDraft? _buildDraft({required bool forSubmit, String? receiptPath}) {
    final budget = _budgetFor(_selectedBudgetCategory);
    if (budget == null) {
      _snack(_budgetsError != null
          ? '예산 목록을 불러오지 못해 예산 항목을 확인할 수 없어요. 잠시 후 다시 시도해 주세요.'
          : '「$_selectedBudgetCategory」 예산을 찾지 못했어요. 예산 목록을 확인해 주세요.');
      return null;
    }
    if (forSubmit && _receiptHash == null) {
      _snack('지출은 영수증을 첨부해야 제출할 수 있어요.');
      return null;
    }
    return EntryDraft(
      kind: EntryKind.EXPENSE,
      termId: budget.termId, // 지출의 학기는 예산의 학기 — 다르면 체인이 TermMismatch
      amount: int.parse(_amountController.text),
      counterparty: _merchantController.text,
      purpose: _titleController.text,
      budgetId: budget.id,
      occurredAt: _occurredAt,
      receiptHash: _receiptHash,
      receiptPath: receiptPath,
    );
  }

  /// 영수증 원본을 아직 안 올렸으면 올리고 서버 경로를 돌려준다 — 초안보다 먼저 (#66: 파일 없는 해시는 400).
  Future<String?> _ensureUploaded() async {
    final bytes = _receiptBytes;
    if (bytes == null) return null;
    _upload ??= await _registrar.uploadReceipt(bytes, filename: receiptFilename(bytes));
    return _upload!.path;
  }

  /// 같은 입력으로 이미 저장한 초안이 있으면 그 번호를, 없으면 새로 저장한 번호를.
  Future<int> _ensureDraft(EntryDraft draft) async {
    if (_draftId != null && _savedDraft == draft) return _draftId!;
    final id = await _registrar.saveDraft(draft);
    _draftId = id;
    _savedDraft = draft;
    return id;
  }

  /// 사용일 → `occurred_at`. **KST 자정** Unix 초 (HASHING §1.3).
  /// 기기 로컬 시간대를 쓰지 않고 선택한 연·월·일만 쓴다.
  int get _occurredAt => Hashing.kstMidnightOf(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
      );

  /// ① 초안 저장 — 서버에만 저장한다. 체인 검사(BLOCKED)도 서명도 하지 않는다.
  Future<void> _saveDraft() async {
    if (_submitting) return;
    if (_receiptPending) {
      _snack('이전 영수증을 불러오는 중이에요. 잠시 후 다시 눌러 주세요.');
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    // 입력은 여기서 한 번만 읽는다 — 업로드·저장을 기다리는 사이 바꿔도(금액을 비워도) 보낸 값과 안내가 같다 (#71 리뷰)
    final base = _buildDraft(forSubmit: false); // 예산 확인 — 올리기 전에 막는다
    if (base == null) return;
    final category = _selectedBudgetCategory;
    setState(() => _submitting = true);
    final EntryDraft draft;
    try {
      draft = base.withReceiptPath(await _ensureUploaded());
      await _ensureDraft(draft);
    } on EntryDecisionException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _snack(e.message);
      return;
    } catch (_) {
      // 예상 못 한 실패도 「제출 중」에 갇히지 않게 푼다 — 서버에는 이미 기록됐을 수 있어 확인을 권한다
      if (!mounted) return;
      setState(() => _submitting = false);
      _snack('등록을 마치지 못했어요. 내 등록 현황에서 확인한 뒤 다시 시도해 주세요.');
      return;
    }
    if (!mounted) return;
    setState(() => _submitting = false);
    await _showResult(const RegistrationResult.draft(), draft, category);
  }

  /// ② 제출 — 기기 키로 서명해 체인에 올린다. 결과는 `PENDING` 또는 `BLOCKED`.
  /// 실패하면 초안 번호를 들고 있다가 다시 제출할 때 쓴다.
  Future<void> _submitExpense() async {
    if (_submitting) return;
    if (_receiptPending) {
      _snack('이전 영수증을 불러오는 중이에요. 잠시 후 다시 눌러 주세요.');
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    final base = _buildDraft(forSubmit: true); // 예산·영수증 확인 — 올리기 전에 막는다. 입력은 여기서 한 번만 읽는다
    if (base == null) return;
    final category = _selectedBudgetCategory;
    setState(() => _submitting = true);

    final RegistrationResult result;
    final EntryDraft draft;
    try {
      draft = base.withReceiptPath(await _ensureUploaded());
      final id = await _ensureDraft(draft);
      final outcome = await _registrar.submit(id, draft);
      result = outcome.status == EntryStatus.BLOCKED
          ? RegistrationResult.blocked(outcome.blockReason!)
          : const RegistrationResult.pending();
      _blockedId = outcome.status == EntryStatus.BLOCKED ? id : null;
      _draftId = null; // 체인에 올라갔다 — 다음 제출은 새 초안이다
      _savedDraft = null;
    } on EntryDecisionException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _snack(e.message);
      return;
    } catch (_) {
      // 예상 못 한 실패도 「제출 중」에 갇히지 않게 푼다 — 서버에는 이미 기록됐을 수 있어 확인을 권한다
      if (!mounted) return;
      setState(() => _submitting = false);
      _snack('등록을 마치지 못했어요. 내 등록 현황에서 확인한 뒤 다시 시도해 주세요.');
      return;
    }
    if (!mounted) return;
    setState(() => _submitting = false);
    await _showResult(result, draft, category);
  }

  /// 결과 안내 — **입력칸이 아니라 보낸 초안**으로 만든다. 응답을 기다리는 사이 입력을 바꿔도(금액을 비워도)
  /// 서버에 기록된 값을 보이고, 비운 금액을 다시 읽다 예외가 나지 않는다.
  Future<void> _showResult(RegistrationResult result, EntryDraft draft, String category) async {
    final done = await showRegistrationResultDialog(
      context,
      kindLabel: '지출',
      rows: [
        ('목적', draft.purpose),
        ('사용처', draft.counterparty),
        ('금액', '${draft.amount}원'),
        ('예산 항목', category),
      ],
      result: result,
      occurredAtNote: '전송값 occurred_at: ${draft.occurredAt} (사용일 KST 00:00)',
      onBudgetRevision: () => _openBudgetRevision(draft, category),
    );
    if (done && mounted) Navigator.pop(context);
  }

  /// 차단 안내 → 예산 개정 요청. 차단된 지출(보낸 초안)이 근거로 붙고 예산 항목이 골라져 넘어간다.
  void _openBudgetRevision(EntryDraft draft, String category) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BudgetRevisionScreen(
          initialCategory: category,
          basisTitle: draft.purpose,
          basisAmount: draft.amount,
          blockedEntryId: _blockedId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: const Text('지출 등록', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
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
              if (widget.resubmitOf != null) ResubmitBanner(source: widget.resubmitOf!, receiptNote: _receiptNote),
              if (widget.resumeDraft != null) DraftBanner(draftId: widget.resumeDraft!.id, receiptNote: _receiptNote),
              // 영수증 첨부 영역
              GestureDetector(
                onTap: _attachReceipt,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  // 고정 height 대신 최소 높이 — 큰 글자에서 내용이 커져도 세로로 넘치지 않는다
                  constraints: const BoxConstraints(minHeight: 160),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _hasReceiptImage ? AppTheme.primary : AppTheme.divider,
                      width: _hasReceiptImage ? 2 : 1.5,
                    ),
                    boxShadow: AppTheme.softShadow,
                  ),
                  child: _hasReceiptImage
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: const BoxDecoration(
                                color: AppTheme.primaryLight,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.check_rounded, color: AppTheme.primary, size: 28),
                            ),
                            const SizedBox(height: 10),
                            const Text('영수증 첨부 완료',
                              style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.primary, fontSize: 15),
                            ),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(colors: [AppTheme.primary, Color(0xFF9B59D6)]),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                '원본 해시 ${Fmt.shortHash(_receiptHash!)}',
                                style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text('탭하여 다른 사진으로 변경',
                              style: TextStyle(fontSize: 11, color: AppTheme.textSub.withOpacity(0.7)),
                            ),
                          ],
                        )
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: AppTheme.primaryLight,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: const Icon(Icons.camera_alt_rounded, color: AppTheme.primary, size: 26),
                            ),
                            const SizedBox(height: 10),
                            const Text('영수증 촬영 또는 사진 첨부',
                              style: TextStyle(fontSize: 14, color: AppTheme.textMain, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                            // 원본 사진 바이트의 해시가 meta_hash 에 들어간다 (HASHING §4)
                            const Text('제출하려면 영수증이 필요해요 · 원본 해시가 함께 기록돼요',
                              style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 20),

              _SectionLabel(label: '지출 정보'),
              const SizedBox(height: 12),

              TextFormField(
                controller: _titleController,
                decoration: AppTheme.inputDecoration(
                  label: '목적 *',
                  hint: '예: 신입생 오리엔테이션 다과 구매',
                  icon: Icons.description_rounded,
                ),
                validator: (v) => InputRules.singleLine(v, fieldName: '목적'),
              ),
              const SizedBox(height: 14),

              TextFormField(
                controller: _merchantController,
                decoration: AppTheme.inputDecoration(
                  label: '사용처(상호명) *',
                  hint: '예: 한결문구점',
                  icon: Icons.storefront_rounded,
                ),
                validator: (v) => InputRules.singleLine(v, fieldName: '사용처'),
              ),
              const SizedBox(height: 14),

              TextFormField(
                controller: _amountController,
                keyboardType: TextInputType.number,
                decoration: AppTheme.inputDecoration(
                  label: '지출 금액(원) *',
                  hint: '예: 35000',
                  icon: Icons.monetization_on_rounded,
                ),
                validator: (v) => InputRules.positiveAmount(v, fieldName: '금액'),
              ),
              const SizedBox(height: 14),

              // 예산 항목 (잔량 표시)
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFFAF9FF),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.divider, width: 1.5),
                ),
                child: DropdownButtonFormField<String>(
                  value: _selectedBudgetCategory,
                  isExpanded: true,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded, color: AppTheme.primary),
                  decoration: InputDecoration(
                    labelText: '예산 항목 *',
                    labelStyle: const TextStyle(color: AppTheme.textSub, fontSize: 14),
                    border: InputBorder.none,
                    prefixIcon: const Icon(Icons.category_rounded, color: AppTheme.primary, size: 20),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                  items: _budgetCategories
                      .map((c) => DropdownMenuItem(value: c, child: Text(_budgetLabel(c), overflow: TextOverflow.ellipsis)))
                      .toList(),
                  onChanged: (val) => setState(() => _selectedBudgetCategory = val!),
                ),
              ),
              if (_budgetsError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Text(_budgetsError!,
                      key: const Key('budgets_failed'), style: const TextStyle(fontSize: 12, color: AppTheme.expense)),
                ),
              const SizedBox(height: 14),

              // 날짜 선택
              GestureDetector(
                onTap: _pickDate,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFAF9FF),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppTheme.divider, width: 1.5),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.calendar_today_rounded, color: AppTheme.primary, size: 20),
                      const SizedBox(width: 12),
                      // Expanded: 좁은 화면·큰 글자에서 날짜가 넘치지 않고 줄바꿈된다 (Spacer 대신)
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('지출 일자 *',
                              style: TextStyle(color: AppTheme.textSub, fontSize: 12),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${_selectedDate.year}년 ${_selectedDate.month}월 ${_selectedDate.day}일',
                              style: const TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w600, fontSize: 15),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.edit_calendar_rounded, color: AppTheme.textSub, size: 18),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              TextFormField(
                controller: _memoController,
                maxLines: 2,
                decoration: AppTheme.inputDecoration(
                  label: '지출 메모 (선택)',
                  hint: '행사 참석 인원 등 세부 내역 기재',
                  icon: Icons.notes_rounded,
                ),
              ),
              const SizedBox(height: 28),

              // 스토리보드 7: ⑦ 초안 저장 → ⑧ 제출 순서
              OutlinedButton.icon(
                onPressed: _submitting ? null : _saveDraft,
                icon: const Icon(Icons.save_outlined),
                label: const Text('초안으로 저장'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primary,
                  minimumSize: const Size.fromHeight(48),
                  side: const BorderSide(color: AppTheme.primary),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 10),
              GradientButton(
                onPressed: _submitExpense,
                label: _submitting ? '제출 중...' : '제출하기',
                icon: Icons.upload_rounded,
              ),
              const SizedBox(height: 8),
              const Center(
                child: Text('초안 저장은 체인에 올리지 않아요. 제출하면 감사/회장 승인 대기(PENDING)로 기록됩니다',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(width: 3, height: 16, decoration: BoxDecoration(
          gradient: AppTheme.primaryGradient,
          borderRadius: BorderRadius.circular(2),
        )),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textMain)),
      ],
    );
  }
}
