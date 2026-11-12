import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/enums.dart';
import '../../core/hashing.dart';
import '../../models/entry_model.dart';
import '../../services/api_service.dart';
import '../../services/entry_registration_service.dart';
import 'input_rules.dart';
import 'receipt_picker.dart';
import 'registration_result.dart';
import 'resubmit.dart';

/// [이승호 담당: app/lib/screens/council/]
/// 2. 수입 등록 화면
class IncomeCreateScreen extends StatefulWidget {
  /// 초안 저장·서명 제출. 주지 않으면 서버 ([EntryRegistrationService]).
  final EntryRegistrar? registrar;

  /// 영수증 원본 바이트를 고른다. 주지 않으면 카메라·갤러리 ([pickReceiptBytes]).
  final ReceiptPicker? pickReceipt;

  /// 반려된 수입을 고쳐 새로 등록할 때 그 건 ([canResubmit]). 이전 값으로 채워 연다 (PRD §4.3 T4 3단계).
  final EntryModel? resubmitOf;

  const IncomeCreateScreen({super.key, this.registrar, this.pickReceipt, this.resubmitOf});

  @override
  State<IncomeCreateScreen> createState() => _IncomeCreateScreenState();
}

class _IncomeCreateScreenState extends State<IncomeCreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _sourceController = TextEditingController();
  final _amountController = TextEditingController();
  final _memoController = TextEditingController();

  DateTime _selectedDate = kstToday();
  String _incomeType = '학생회비 수납';

  /// 영수증(입금 확인서 등) 원본 바이트의 해시. 수입은 영수증이 선택이다 (지출은 필수).
  String? _receiptHash;
  bool get _hasReceipt => _receiptHash != null;

  /// 고른 영수증 원본 바이트와, 서버에 올린 결과. 같은 사진은 한 번만 올린다.
  List<int>? _receiptBytes;
  ReceiptUpload? _upload;

  bool _submitting = false;

  late final EntryRegistrar _registrar = widget.registrar ?? EntryRegistrationService();

  /// 저장한 초안 번호와 그때의 입력 — 제출이 실패하면 다시 제출할 때 같은 번호를 쓴다 (API §2.3).
  int? _draftId;
  EntryDraft? _savedDraft;

  /// 지금 학기 (`GET /terms`). 수입은 예산이 없어 학기를 따로 읽는다.
  int? _termId;
  String? _termError;

  /// 다시 등록할 때 이전 영수증을 쓰지 못한 이유.
  String? _receiptNote;

  @override
  void initState() {
    super.initState();
    final source = widget.resubmitOf;
    if (source == null) {
      _loadTerm();
    } else {
      _prefill(source);
    }
  }

  /// 이전 건의 값으로 채운다. 학기는 이전 건의 학기 그대로, 분류는 이전 수입 사유 그대로 둔다
  /// (목록에 없는 사유면 「기타」 칸이 골라진 채 이전 문구가 기록된다). 메모는 장부에 없어서 비워 둔다.
  void _prefill(EntryModel e) {
    _termId = e.termId;
    _sourceController.text = e.counterparty;
    _amountController.text = '${e.amount}';
    _incomeType = e.purpose;
    _selectedDate = pickerDateOf(e.occurredAt);
    if (e.receiptHash == null) return;
    restoreReceipt(_registrar, e).then((restored) {
      if (!mounted || _receiptHash != null) return;
      setState(() {
        if (restored == null) {
          _receiptNote = '이전 영수증을 불러오지 못했어요. 필요하면 다시 첨부해 주세요.';
          return;
        }
        _receiptBytes = restored.$1;
        _receiptHash = restored.$2.hash;
        _upload = restored.$2;
      });
    });
  }

  Future<void> _loadTerm() async {
    try {
      final id = await ApiService().fetchCurrentTermId();
      if (mounted) setState(() => _termId = id);
    } on ApiUnavailable catch (e) {
      if (mounted) setState(() => _termError = e.message);
    }
  }

  /// 첨부돼 있으면 해제, 아니면 고른다 — 원본 바이트를 그대로 해시한다 (HASHING §4).
  Future<void> _toggleReceipt() async {
    // 제출 중에는 바꾸지 못한다 — 올리던 사진의 경로가 다른 사진의 해시와 섞이지 않게 (#71 리뷰)
    if (_submitting) {
      _snack('제출 중에는 영수증을 바꿀 수 없어요.');
      return;
    }
    if (_hasReceipt) {
      setState(() {
        _receiptHash = null;
        _receiptBytes = null;
        _upload = null;
      });
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

  final List<Map<String, dynamic>> _incomeTypeInfos = [
    {'label': '학생회비 수납', 'icon': Icons.people_rounded, 'color': const Color(0xFF06B6D4)},
    {'label': '단과대/학교 지원금', 'icon': Icons.account_balance_rounded, 'color': const Color(0xFF3B82F6)},
    {'label': '동문회 찬조금', 'icon': Icons.handshake_rounded, 'color': const Color(0xFF8B5CF6)},
    {'label': '행사 부스 수익금', 'icon': Icons.storefront_rounded, 'color': const Color(0xFF10B981)},
    {'label': '기타', 'icon': Icons.more_horiz_rounded, 'color': const Color(0xFF64748B)},
  ];

  @override
  void dispose() {
    _sourceController.dispose();
    _amountController.dispose();
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
          colorScheme: const ColorScheme.light(primary: AppTheme.income),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  /// 사용일 → `occurred_at`. **KST 자정** Unix 초 (HASHING §1.3).
  /// 기기 로컬 시간대를 쓰지 않고 선택한 연·월·일만 쓴다.
  int get _occurredAt => Hashing.kstMidnightOf(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
      );

  /// 초안 저장 → 기기 서명 → 제출. 수입은 예산 검사 대상이 아니라 결과는 `PENDING` 이다.
  Future<void> _submitIncome() async {
    if (_submitting || !_formKey.currentState!.validate()) return;
    final termId = _termId;
    if (termId == null) {
      _snack(_termError != null ? '$_termError 제출하지 않았어요.' : '학기 정보를 불러오는 중이에요. 잠시 후 다시 시도해 주세요.');
      return;
    }
    // 입력은 여기서 한 번만 읽는다 — 업로드·저장·제출을 기다리는 사이 바꿔도(금액을 비워도) 보낸 값과 안내가 같다.
    // 출처(납부자)는 거래처, 분류는 수입 사유로 기록한다. 메모는 장부에 올리지 않는다
    final base = EntryDraft(
      kind: EntryKind.INCOME,
      termId: termId,
      amount: int.parse(_amountController.text),
      counterparty: _sourceController.text,
      purpose: _incomeType,
      occurredAt: _occurredAt,
      receiptHash: _receiptHash,
    );
    final bytes = _receiptBytes;
    final shownType = _incomeType;
    final shownDate =
        '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';
    setState(() => _submitting = true);
    final RegistrationResult result;
    final EntryDraft draft;
    try {
      // 영수증을 붙였으면 원본을 먼저 올린다 — 같은 사진은 한 번만 (#66: 파일 없는 해시는 400)
      if (bytes != null) _upload ??= await _registrar.uploadReceipt(bytes, filename: receiptFilename(bytes));
      draft = base.withReceiptPath(_upload?.path);
      if (_draftId == null || _savedDraft != draft) {
        _draftId = await _registrar.saveDraft(draft);
        _savedDraft = draft;
      }
      final outcome = await _registrar.submit(_draftId!, draft);
      result = outcome.status == EntryStatus.BLOCKED
          ? RegistrationResult.blocked(outcome.blockReason!)
          : const RegistrationResult.pending();
      _draftId = null;
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

    final done = await showRegistrationResultDialog(
      context,
      kindLabel: '수입',
      rows: [
        ('분류', shownType),
        ('출처', draft.counterparty),
        ('금액', '${draft.amount}원'),
        ('일자', shownDate),
        ('영수증', draft.receiptHash != null ? '첨부' : '없음'),
      ],
      result: result,
      occurredAtNote: '전송값 occurred_at: ${draft.occurredAt} (사용일 KST 00:00)',
      gradient: AppTheme.incomeGradient,
    );
    if (done && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final currentInfo = _incomeTypeInfos.firstWhere(
      (e) => e['label'] == _incomeType,
      orElse: () => _incomeTypeInfos.last,
    );

    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: const Text('수입 등록', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        flexibleSpace: Container(decoration: const BoxDecoration(gradient: AppTheme.incomeGradient)),
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
              // 수입 유형 선택 카드 (가로 스크롤)
              SizedBox(
                height: 94,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _incomeTypeInfos.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final info = _incomeTypeInfos[index];
                    final isSelected = _incomeType == info['label'];
                    return GestureDetector(
                      onTap: () => setState(() => _incomeType = info['label'] as String),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 100,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                        decoration: BoxDecoration(
                          color: isSelected ? (info['color'] as Color).withOpacity(0.12) : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isSelected ? info['color'] as Color : AppTheme.divider,
                            width: isSelected ? 2 : 1.5,
                          ),
                          boxShadow: isSelected ? [] : AppTheme.softShadow,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(info['icon'] as IconData,
                              color: isSelected ? info['color'] as Color : AppTheme.textSub,
                              size: 24,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              (info['label'] as String).replaceAll('/', '\n'),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                color: isSelected ? info['color'] as Color : AppTheme.textSub,
                                height: 1.2,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 20),

              // 선택된 수입 유형 표시 배너
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [(currentInfo['color'] as Color).withOpacity(0.15), (currentInfo['color'] as Color).withOpacity(0.05)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: (currentInfo['color'] as Color).withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: (currentInfo['color'] as Color).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(currentInfo['icon'] as IconData, color: currentInfo['color'] as Color, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('선택된 수입 유형', style: TextStyle(color: AppTheme.textSub, fontSize: 11)),
                        Text(_incomeType,
                          style: TextStyle(color: currentInfo['color'] as Color, fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              TextFormField(
                controller: _sourceController,
                decoration: AppTheme.inputDecoration(
                  label: '상세 출처 / 내용 *',
                  hint: '예: 2026학년도 2학기 학생회비 일괄 수납',
                  icon: Icons.edit_note_rounded,
                ),
                validator: (v) => InputRules.singleLine(v, fieldName: '수입 상세 내용'),
              ),
              const SizedBox(height: 14),

              TextFormField(
                controller: _amountController,
                keyboardType: TextInputType.number,
                decoration: AppTheme.inputDecoration(
                  label: '입금 금액(원) *',
                  hint: '예: 5000000',
                  icon: Icons.monetization_on_rounded,
                ),
                validator: (v) => InputRules.positiveAmount(v, fieldName: '입금 금액'),
              ),
              const SizedBox(height: 14),

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
                      Icon(Icons.calendar_today_rounded, color: currentInfo['color'] as Color, size: 20),
                      const SizedBox(width: 12),
                      // Expanded: 좁은 화면·큰 글자에서 날짜가 넘치지 않고 줄바꿈된다 (Spacer 대신)
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('입금 확인 일자 *', style: TextStyle(color: AppTheme.textSub, fontSize: 12)),
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

              // 영수증 첨부 (선택)
              GestureDetector(
                onTap: _toggleReceipt,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: _hasReceipt ? AppTheme.income.withOpacity(0.08) : const Color(0xFFFAF9FF),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _hasReceipt ? AppTheme.income : AppTheme.divider, width: 1.5),
                  ),
                  child: Row(
                    children: [
                      Icon(_hasReceipt ? Icons.check_circle_rounded : Icons.attach_file_rounded,
                        color: _hasReceipt ? AppTheme.income : AppTheme.textSub, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _hasReceipt ? '영수증 첨부 완료 (탭하여 해제)' : '영수증 첨부 (선택)',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: _hasReceipt ? FontWeight.bold : FontWeight.normal,
                            color: _hasReceipt ? AppTheme.income : AppTheme.textSub,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              TextFormField(
                controller: _memoController,
                maxLines: 3,
                decoration: AppTheme.inputDecoration(
                  label: '통장 입금 메모 및 확인 정보',
                  hint: '예: 신한은행 학생회 계좌 거래내역 확인 완료',
                  icon: Icons.notes_rounded,
                ),
              ),
              const SizedBox(height: 28),

              GradientButton(
                onPressed: _submitIncome,
                label: _submitting ? '제출 중...' : '제출하기',
                icon: Icons.add_circle_rounded,
                gradient: AppTheme.incomeGradient,
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
