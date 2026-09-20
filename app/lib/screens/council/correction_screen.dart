import 'package:flutter/material.dart';
import '../../core/entry_merge.dart';
import '../../core/enums.dart';
import '../../core/app_theme.dart';
import '../../core/format.dart';
import '../../services/api_service.dart';
import 'input_rules.dart';

/// [이승호 담당: app/lib/screens/council/]
/// 4. 정정 신청 화면
class CorrectionScreen extends StatefulWidget {
  const CorrectionScreen({super.key});

  @override
  State<CorrectionScreen> createState() => _CorrectionScreenState();
}

class _CorrectionScreenState extends State<CorrectionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _entryIdController = TextEditingController();
  final _correctedAmountController = TextEditingController();
  final _detailController = TextEditingController();

  CorrectionReason _selectedReason = CorrectionReason.INPUT_ERROR;
  bool _hasCorrectionReceipt = false;

  /// 조회한 정정 대상(정정 체인). 조회 전이거나 정정할 수 없으면 null.
  EntryChain? _target;

  /// 조회 실패·정정 불가 사유. 화면에 그대로 보여 준다.
  String? _targetError;
  bool _looking = false;

  /// 사용자가 입력한 「수정 후 올바른 금액」. 형식이 틀리면 null.
  int? get _correctedAmount {
    final v = _correctedAmountController.text;
    return InputRules.nonNegativeAmount(v, fieldName: '금액') == null ? int.parse(v) : null;
  }

  /// 정정 항목의 `amount` — **새 총액이 아니라 증감분**이다 (`올바른 금액 − 현재 금액`).
  ///
  /// 컨트랙트는 음수를 정정 항목(`correctsId != 0`)에만 허용하고, 장부 합계는 확정 항목을
  /// 그냥 더해 계산한다 (`EntryMerge`, HASHING 샘플 3: `-20000`). 새 총액을 보내면 원본과
  /// 더해져 금액이 두 배가 된다. 0 은 컨트랙트가 거부한다 (`ZeroAmount`).
  int? get _delta {
    final target = _target;
    final corrected = _correctedAmount;
    if (target == null || corrected == null) return null;
    return corrected - target.finalAmount;
  }

  /// `+₩ 5,000` / `-₩ 20,000`
  String _signed(int amount) => amount > 0 ? '+${Fmt.won(amount)}' : Fmt.won(amount);

  /// 대상 내역을 조회해 정정할 수 있는지 본다. 규칙:
  /// - 확정(`CONFIRMED`)된 항목만 정정할 수 있다 (`CorrectionTargetNotConfirmed`)
  /// - 정정 항목이 아니라 원본 ID 로 신청한다 (정정 체인은 원본에서 시작)
  /// - 승인 대기 중인 정정이 있으면 그 결과를 기다린다 (금액 기준이 흔들리기 때문)
  Future<void> _lookupTarget() async {
    final idError = InputRules.entryId(_entryIdController.text);
    if (idError != null) {
      setState(() {
        _target = null;
        _targetError = idError;
      });
      return;
    }

    setState(() {
      _looking = true;
      _target = null;
      _targetError = null;
    });
    final entries = await ApiService().fetchEntries();
    if (!mounted) return;

    final id = int.parse(_entryIdController.text);
    final chains = EntryMerge.fold(entries);
    EntryChain? found;
    String? error;
    for (final chain in chains) {
      if (chain.original.id == id) {
        found = chain;
        break;
      }
      if (chain.corrections.any((c) => c.id == id)) {
        error = '#$id 는 정정 항목이에요. 원본 #${chain.original.id} 로 신청해 주세요.';
        break;
      }
    }
    error ??= found == null ? '#$id 내역을 찾을 수 없어요.' : null;

    if (found != null) {
      if (!found.isConfirmed) {
        error = '확정(CONFIRMED)된 내역만 정정할 수 있어요. (현재 ${found.original.status.label})';
      } else {
        final pending = found.corrections.where((c) => c.status == EntryStatus.PENDING);
        if (pending.isNotEmpty) {
          error = '승인 대기 중인 정정 #${pending.first.id} 이 있어요. 승인·반려된 뒤에 신청해 주세요.';
        }
      }
    }

    setState(() {
      _looking = false;
      _target = error == null ? found : null;
      _targetError = error;
    });
  }

  @override
  void dispose() {
    _entryIdController.dispose();
    _correctedAmountController.dispose();
    _detailController.dispose();
    super.dispose();
  }

  void _submitCorrection() {
    final valid = _formKey.currentState!.validate();
    if (_target == null) {
      setState(() => _targetError ??= '먼저 [내역 조회] 로 정정할 내역을 확인해 주세요.');
      return;
    }
    if (valid) {
      final target = _target!;
      final delta = _delta!;
      showDialog(
        context: context,
        builder: (ctx) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: AppTheme.pending.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.send_rounded, color: AppTheme.pending, size: 28),
                ),
                const SizedBox(height: 16),
                const Text('정정 신청 접수 완료!',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textMain),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: AppTheme.bgPage, borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _InfoRow(label: '대상 내역', value: '#${target.original.id} ${target.original.counterparty}'),
                      _InfoRow(
                        label: '정정 사유',
                        value: '${_selectedReason.label} (${_selectedReason.code})',
                      ),
                      _InfoRow(
                        label: '금액 변경',
                        value: '${Fmt.won(target.finalAmount)} → ${Fmt.won(_correctedAmount!)}',
                      ),
                      _InfoRow(label: '기록되는 정정 금액', value: _signed(delta)),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Text('감사단 및 회장에게 승인 요청이 전달되었습니다',
                  style: TextStyle(color: AppTheme.textSub, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                const Text('※ 서버 연동 전 목업 결과예요',
                  style: TextStyle(color: AppTheme.textSub, fontSize: 11),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: GradientButton(
                    onPressed: () { Navigator.pop(ctx); Navigator.pop(context); },
                    label: '확인',
                    icon: Icons.check_rounded,
                    gradient: const LinearGradient(
                      colors: [Color(0xFFF59E0B), Color(0xFFEF4444)],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: const Text('장부 정정 신청', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFF59E0B), Color(0xFFEF4444)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
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
              // 안내 배너
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppTheme.pending.withOpacity(0.12), AppTheme.pending.withOpacity(0.04)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.pending.withOpacity(0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppTheme.pending.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.info_rounded, color: AppTheme.pending, size: 18),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        '블록체인에 등록된 내역은 수정·삭제 불가합니다. 정정 사유와 함께 새로운 트랜잭션으로 기록됩니다.',
                        style: TextStyle(fontSize: 13, height: 1.5, color: AppTheme.textMain),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              _SectionLabel(label: '정정 대상'),
              const SizedBox(height: 12),

              TextFormField(
                controller: _entryIdController,
                keyboardType: TextInputType.number,
                decoration: AppTheme.inputDecoration(
                  label: '정정 대상 내역 ID (Entry ID) *',
                  hint: '예: 1',
                  icon: Icons.tag_rounded,
                ),
                // ID 를 바꾸면 이전 조회 결과는 더 이상 이 ID 의 것이 아니다.
                onChanged: (_) => setState(() {
                  _target = null;
                  _targetError = null;
                }),
                validator: (v) => InputRules.entryId(v),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _looking ? null : _lookupTarget,
                icon: const Icon(Icons.search_rounded, size: 18),
                label: Text(_looking ? '조회 중...' : '내역 조회'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.pending,
                  side: const BorderSide(color: AppTheme.pending),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
              if (_target != null) _TargetCard(chain: _target!),
              if (_targetError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_targetError!,
                    style: const TextStyle(color: AppTheme.expense, fontSize: 12, height: 1.4),
                  ),
                ),
              const SizedBox(height: 20),

              _SectionLabel(label: '정정 사유'),
              const SizedBox(height: 12),

              // 정정 사유 선택 카드
              ...CorrectionReason.values.map((reason) {
                final isSelected = _selectedReason == reason;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GestureDetector(
                    onTap: () => setState(() => _selectedReason = reason),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: isSelected ? const Color(0xFFFFF8E1) : Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isSelected ? AppTheme.pending : AppTheme.divider,
                          width: isSelected ? 2 : 1.5,
                        ),
                        boxShadow: isSelected ? [] : AppTheme.softShadow,
                      ),
                      child: Row(
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isSelected ? AppTheme.pending : Colors.transparent,
                              border: Border.all(
                                color: isSelected ? AppTheme.pending : AppTheme.textSub.withOpacity(0.4),
                                width: 2,
                              ),
                            ),
                            child: isSelected
                                ? const Icon(Icons.check_rounded, color: Colors.white, size: 14)
                                : null,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(reason.label,
                                  style: TextStyle(
                                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                    color: isSelected ? AppTheme.textMain : AppTheme.textMain,
                                    fontSize: 14,
                                  ),
                                ),
                                Text(reason.code,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isSelected ? AppTheme.pending : AppTheme.textSub,
                                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
              const SizedBox(height: 20),

              _SectionLabel(label: '정정 내용'),
              const SizedBox(height: 12),

              TextFormField(
                controller: _correctedAmountController,
                keyboardType: TextInputType.number,
                decoration: AppTheme.inputDecoration(
                  label: '수정 후 올바른 금액(원) *',
                  hint: '예: 30000 (현재 금액과의 차이가 정정 금액으로 기록돼요)',
                  icon: Icons.price_change_rounded,
                ),
                onChanged: (_) => setState(() {}),
                validator: (v) {
                  final format = InputRules.nonNegativeAmount(v, fieldName: '올바른 금액');
                  if (format != null) return format;
                  // 정정 항목의 금액(증감분)은 0 일 수 없다 (컨트랙트 ZeroAmount).
                  if (_delta == 0) return '현재 금액과 같아요. 금액이 바뀌지 않는 정정은 기록할 수 없어요.';
                  return null;
                },
              ),
              if (_delta != null && _delta != 0) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.bgPage,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.divider),
                  ),
                  child: Text(
                    '기록되는 정정 금액: ${_signed(_delta!)}\n'
                    '(현재 ${Fmt.won(_target!.finalAmount)} → 올바른 ${Fmt.won(_correctedAmount!)}, 증감분만 새 항목으로 기록돼요)',
                    style: const TextStyle(fontSize: 12, height: 1.5, color: AppTheme.textMain),
                  ),
                ),
              ],
              const SizedBox(height: 14),

              TextFormField(
                controller: _detailController,
                maxLines: 4,
                decoration: AppTheme.inputDecoration(
                  label: '정정 상세 사유 및 소명 내용 *',
                  hint: '예: 실제 영수증 확인 결과 부가세 포함 금액 정정 요청',
                  icon: Icons.notes_rounded,
                ),
                // 이 사유는 텍스트 해시 대상이다 — 빈 값·제어문자·보이지 않는 공백은 서버가 400 (HASHING §3).
                validator: (v) => InputRules.requiredReason(v, fieldName: '상세 사유'),
              ),
              const SizedBox(height: 16),

              // 증빙 첨부
              GestureDetector(
                onTap: () {
                  setState(() => _hasCorrectionReceipt = true);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Row(
                        children: [
                          Icon(Icons.attach_file_rounded, color: Colors.white, size: 18),
                          SizedBox(width: 10),
                          Expanded(child: Text('수정 증빙 영수증 첨부 완료')),
                        ],
                      ),
                      backgroundColor: AppTheme.success,
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      margin: const EdgeInsets.all(16),
                    ),
                  );
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _hasCorrectionReceipt
                        ? AppTheme.success.withOpacity(0.08)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _hasCorrectionReceipt ? AppTheme.success : AppTheme.divider,
                      width: _hasCorrectionReceipt ? 2 : 1.5,
                    ),
                    boxShadow: AppTheme.softShadow,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: _hasCorrectionReceipt
                              ? AppTheme.success.withOpacity(0.12)
                              : AppTheme.primaryLight,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          _hasCorrectionReceipt ? Icons.check_circle_rounded : Icons.attach_file_rounded,
                          color: _hasCorrectionReceipt ? AppTheme.success : AppTheme.primary,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Expanded: 좁은 화면·큰 글자에서 글자가 넘치지 않고 줄바꿈된다
                      Expanded(
                        child: Text(
                          _hasCorrectionReceipt ? '수정 증빙 첨부 완료됨 ✓' : '수정 증빙 자료 재첨부 (영수증)',
                          style: TextStyle(
                            color: _hasCorrectionReceipt ? AppTheme.success : AppTheme.primary,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 28),

              GradientButton(
                onPressed: _submitCorrection,
                label: '정정 신청 제출하기',
                icon: Icons.send_rounded,
                gradient: const LinearGradient(
                  colors: [Color(0xFFF59E0B), Color(0xFFEF4444)],
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

/// 조회한 정정 대상 요약 — 사용자가 어느 내역의 어느 금액을 고치는지 눈으로 확인하게 한다.
class _TargetCard extends StatelessWidget {
  final EntryChain chain;
  const _TargetCard({required this.chain});

  @override
  Widget build(BuildContext context) {
    final e = chain.original;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.pending.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.pending.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('#${e.id} ${e.counterparty}',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.textMain),
          ),
          const SizedBox(height: 4),
          Text(e.purpose, style: const TextStyle(fontSize: 12, color: AppTheme.textSub)),
          const SizedBox(height: 8),
          Text('${e.kind.label} · 현재 금액 ${Fmt.won(chain.finalAmount)}',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textMain),
          ),
          if (chain.hasCorrection)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('원본 ${Fmt.won(e.amount)} · 확정된 정정 ${chain.confirmedCorrections.length}건 반영',
                style: const TextStyle(fontSize: 11, color: AppTheme.textSub),
              ),
            ),
        ],
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
          gradient: const LinearGradient(colors: [Color(0xFFF59E0B), Color(0xFFEF4444)]),
          borderRadius: BorderRadius.circular(2),
        )),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textMain)),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label, value;
  const _InfoRow({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '$label: ', style: const TextStyle(color: AppTheme.textSub, fontSize: 13)),
            TextSpan(text: value, style: const TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w600, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
