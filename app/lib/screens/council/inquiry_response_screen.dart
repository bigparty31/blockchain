import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/elapsed_days.dart';
import '../../models/objection_model.dart';
import '../../services/objection_answer_service.dart';
import '../../services/signed_post.dart';
import 'input_rules.dart';

/// 제기일부터 오늘까지 지난 날 수. 답하지 않은 사실이 남는 것이 압력이다 (PRD §4.5).
///
/// 세는 규칙은 [kstElapsedDaysFromDate] 에 있다 — 학생 화면의 「제기 후 N일 경과」와 **같은
/// 구현**이다. 예전에는 기기 시간대로 셌는데, 그러면 UTC 인 에뮬레이터·해외 로밍에서 학생이
/// 보는 일수와 감사가 보는 일수가 하루 어긋났다.
int inquiryElapsedDays(String raisedDate, {DateTime? now}) =>
    kstElapsedDaysFromDate(raisedDate, now: now);

/// [이승호 담당: app/lib/screens/council/]
/// 5. 학생 이의 제기 답변 화면 — 답변 주체는 감사·회장이다 (PRD §4.5)
///
/// 목록은 서버(`GET /objections`)에서 읽고, 답변은 임원 기기 키로 서명해 체인에 기록한다
/// ([ObjectionAnswerService]). 못 읽으면 예시로 메우지 않고 「다시 시도」를 보인다.
class InquiryResponseScreen extends StatefulWidget {
  /// 서버 연동. 테스트에서 가짜로 갈아끼운다.
  final ObjectionAnswerApi? api;

  const InquiryResponseScreen({super.key, this.api});

  @override
  State<InquiryResponseScreen> createState() => _InquiryResponseScreenState();
}

/// 제기 시각(Unix 초)의 한국 날짜(`yyyy-MM-dd`). 경과일 계산은 [inquiryElapsedDays] 와 같은 KST 기준이다.
String inquiryDateOf(int raisedAtEpochSeconds) {
  final d = DateTime.fromMillisecondsSinceEpoch(raisedAtEpochSeconds * 1000, isUtc: true).add(const Duration(hours: 9));
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

Map<String, dynamic> _itemOf(ObjectionModel o) => {
      'id': o.id,
      'entryId': o.entryId,
      'studentName': '재학생',
      'question': o.content,
      'date': inquiryDateOf(o.raisedAt),
      'isAnswered': o.status == ObjectionStatus.ANSWERED,
      'answer': o.answer,
      'model': o,
    };

class _InquiryResponseScreenState extends State<InquiryResponseScreen> {
  int _selectedFilterIndex = 0;

  late final ObjectionAnswerApi _api = widget.api ?? ObjectionAnswerService();
  List<Map<String, dynamic>> _inquiries = const [];
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final list = await _api.list();
      if (!mounted) return;
      // 오래 기다린 건이 위로 — 답하지 않은 사실이 남는 것이 압력이다 (PRD §4.5)
      final items = [for (final o in list) _itemOf(o)]..sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
      setState(() {
        _inquiries = items;
        _loading = false;
      });
    } on EntryDecisionException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadError = '이의 목록을 불러오지 못했어요.';
        _loading = false;
      });
    }
  }

  /// 서명해 답변을 기록한다. 다이얼로그가 받을 결과([_AnswerResult])를 돌려준다.
  ///
  /// - 성공: 목록의 그 건을 서버가 돌려준 값으로 바꾸고 닫는다.
  /// - 결과를 모르는 실패(시간 초과)·409: 목록을 새로 읽어 **이미 답변 완료로 보이면 닫는다** — 열어 둔 채 다시
  ///   누르면 `prepare-answer` 가 409 로 또 실패한다. 아직 대기면 입력을 둔 채 이유를 보인다.
  /// - 401: 로그인이 끝났다(세션은 이미 비웠다). 다시 읽지도, 닫지도, 알리지도 않는다 — 전역 401 처리가
  ///   로그인 화면으로 갈아끼우고 안내한다. 여기서 pop 하면 그 로그인 화면이 pop 된다.
  Future<_AnswerResult> _submitAnswer(Map<String, dynamic> item, String text) async {
    try {
      final saved = await _api.answer(item['model'] as ObjectionModel, text);
      if (!mounted) return const _AnswerResult(close: true);
      setState(() {
        final i = _inquiries.indexWhere((e) => e['id'] == item['id']);
        if (i >= 0) _inquiries = [..._inquiries]..[i] = _itemOf(saved);
      });
      _toast('답변이 등록되었습니다.');
      return const _AnswerResult(close: true);
    } on EntryDecisionException catch (e) {
      if (e.failure == EntryDecisionFailure.unauthorized) return const _AnswerResult.sessionEnded();
      if (e.failure == EntryDecisionFailure.unknownOutcome || e.failure == EntryDecisionFailure.conflict) {
        await _load();
        if (mounted && _inquiries.any((x) => x['id'] == item['id'] && x['isAnswered'] == true)) {
          _toast('답변이 이미 기록되어 있어요.');
          return const _AnswerResult(close: true);
        }
      }
      return _AnswerResult(close: false, message: e.message);
    } catch (_) {
      return const _AnswerResult(close: false, message: '답변을 등록하지 못했어요. 잠시 후 다시 시도해 주세요.');
    }
  }

  void _toast(String message, {bool ok = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(ok ? Icons.check_circle_rounded : Icons.error_outline_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: ok ? AppTheme.success : AppTheme.expense,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  /// 답변 작성. **이미 답변한 이의에는 다시 답변할 수 없다** — 컨트랙트가
  /// `ObjectionAlreadyAnswered` 로 거부한다 (IObjectionRegistry). 그래서 답변 대기 건에만 연다.
  void _openAnswerDialog(Map<String, dynamic> item) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AnswerDialog(item: item, onSubmit: (text) => _submitAnswer(item, text)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final unansweredCount = _inquiries.where((e) => !e['isAnswered']).length;

    List<Map<String, dynamic>> filteredList = _inquiries;
    if (_selectedFilterIndex == 1) filteredList = _inquiries.where((e) => e['isAnswered'] == false).toList();
    else if (_selectedFilterIndex == 2) filteredList = _inquiries.where((e) => e['isAnswered'] == true).toList();

    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: const Text('학생 이의 답변', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF10B981), Color(0xFF06B6D4)],
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? _LoadError(message: _loadError!, onRetry: _load)
              : _content(unansweredCount, filteredList),
    );
  }

  Widget _content(int unansweredCount, List<Map<String, dynamic>> filteredList) {
    return Column(
        children: [
          // 요약 헤더
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: AppTheme.softShadow,
            ),
            child: Row(
              children: [
                Expanded(
                  child: _StatItem(
                    label: '전체 이의',
                    value: '${_inquiries.length}건',
                    color: AppTheme.primary,
                    icon: Icons.question_answer_rounded,
                  ),
                ),
                Container(width: 1, height: 40, color: AppTheme.divider),
                Expanded(
                  child: _StatItem(
                    label: '답변 대기',
                    value: '$unansweredCount건',
                    color: AppTheme.expense,
                    icon: Icons.pending_rounded,
                  ),
                ),
                Container(width: 1, height: 40, color: AppTheme.divider),
                Expanded(
                  child: _StatItem(
                    label: '답변 완료',
                    value: '${_inquiries.length - unansweredCount}건',
                    color: AppTheme.success,
                    icon: Icons.check_circle_rounded,
                  ),
                ),
              ],
            ),
          ),

          // 필터 칩
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            // Wrap: 좁은 화면·큰 글자에서 칩이 다음 줄로 내려가 넘치지 않는다
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _FilterChip(label: '전체 (${_inquiries.length})', index: 0, selectedIndex: _selectedFilterIndex,
                  onTap: () => setState(() => _selectedFilterIndex = 0)),
                _FilterChip(label: '답변 대기 ($unansweredCount)', index: 1, selectedIndex: _selectedFilterIndex,
                  color: AppTheme.expense, onTap: () => setState(() => _selectedFilterIndex = 1)),
                _FilterChip(label: '답변 완료', index: 2, selectedIndex: _selectedFilterIndex,
                  color: AppTheme.success, onTap: () => setState(() => _selectedFilterIndex = 2)),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 목록
          Expanded(
            child: filteredList.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: AppTheme.primaryLight,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.inbox_rounded, color: AppTheme.primary, size: 36),
                        ),
                        const SizedBox(height: 16),
                        const Text('해당 이의 내역이 없습니다',
                          style: TextStyle(color: AppTheme.textSub, fontSize: 15),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    itemCount: filteredList.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final item = filteredList[index];
                      final isAnswered = item['isAnswered'] == true;
                      return _InquiryCard(
                        item: item,
                        isAnswered: isAnswered,
                        onAnswer: () => _openAnswerDialog(item),
                      );
                    },
                  ),
          ),
        ],
    );
  }
}

/// 목록을 못 읽었을 때 — 예시로 메우지 않고 이유와 「다시 시도」를 보인다.
class _LoadError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _LoadError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 40, color: AppTheme.textSub),
            const SizedBox(height: 12),
            Text(message, key: const Key('inquiry_load_error'), textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textSub)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('다시 시도')),
          ],
        ),
      ),
    );
  }
}

/// 다이얼로그가 부모에게 받는 제출 결과.
class _AnswerResult {
  /// true 면 다이얼로그를 닫는다 (성공·이미 기록됨·로그인 끝남).
  final bool close;

  /// [close] 가 false 일 때 입력칸 아래에 보일 이유.
  final String? message;

  /// 401 — 세션이 끝났다. 전역 401 처리(`main.dart` `_forceLogin`)가 쌓인 화면을 모두 지우고 로그인 화면을 올린다.
  /// 이때 다이얼로그가 `Navigator.pop` 을 하면 **맨 위의 로그인 화면이 pop 된다** — 아무것도 하지 않는다.
  final bool sessionEnded;

  const _AnswerResult({required this.close, this.message}) : sessionEnded = false;
  const _AnswerResult.sessionEnded()
      : close = false,
        message = null,
        sessionEnded = true;
}

/// 답변 작성 다이얼로그. 입력칸 컨트롤러는 이 위젯의 State 가 갖고 **사라질 때 함께 정리한다** —
/// 닫는 애니메이션 중에도 입력칸이 컨트롤러를 쓰므로 `showDialog().whenComplete` 에서 정리하지 않는다.
class _AnswerDialog extends StatefulWidget {
  final Map<String, dynamic> item;
  final Future<_AnswerResult> Function(String text) onSubmit;
  const _AnswerDialog({required this.item, required this.onSubmit});

  @override
  State<_AnswerDialog> createState() => _AnswerDialogState();
}

class _AnswerDialogState extends State<_AnswerDialog> {
  /// 서버 `OBJECTION_TEXT_MAX_LENGTH` — 초과하면 서버가 422 로 거부한다. 서버는 코드 포인트로 센다.
  static const maxAnswerLength = 5000;

  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? _validate(String? v) {
    final basic = InputRules.requiredReason(v, fieldName: '답변');
    if (basic != null) return basic;
    if ((v ?? '').runes.length > maxAnswerLength) return '답변은 $maxAnswerLength자까지 쓸 수 있어요';
    return null;
  }

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    // 원문 그대로 넘긴다 — 정본화·해시는 서비스가 서명 전에 한다
    final result = await widget.onSubmit(_controller.text);
    if (!mounted || result.sessionEnded) return;
    if (result.close) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _busy = false;
      _error = result.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    // 서명·기록 중에는 시스템 뒤로가기로도 닫히지 않는다 — 닫으면 결과 메시지를 아무도 못 보고,
    // 다시 열어 보내면 409 가 난다
    return PopScope(
      canPop: !_busy,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        // 질문은 서버가 주는 값이라 길 수 있다(최대 5000자). 스크롤이 없으면 입력칸·버튼이 화면 밖으로 밀려
        // 답변할 수 없다 — 키보드가 열려 좁아져도 마찬가지다.
        child: SingleChildScrollView(
         child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.success.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.rate_review_rounded, color: AppTheme.success, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('이의 답변 (내역 #${item['entryId']})',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.textMain),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text('${item['studentName']} · ${item['date']}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.bgPage,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.divider),
                ),
                // 긴 질문은 이 안에서 따로 스크롤한다 — 입력칸까지 한 화면에 남게
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(
                    child: Text(item['question'],
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, color: AppTheme.textMain, height: 1.4),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Form(
                key: _formKey,
                child: TextFormField(
                  controller: _controller,
                  maxLines: 4,
                  enabled: !_busy,
                  decoration: AppTheme.inputDecoration(
                    label: '감사·회장 공식 답변 *',
                    hint: '확인한 내용을 구체적으로 적어 주세요.',
                    icon: Icons.edit_rounded,
                  ),
                  // 답변은 텍스트 해시(answerHash) 대상이다 — 빈 값·제어문자·보이지 않는 공백은
                  // 서버가 400 으로 거부한다 (HASHING §3). String.trim() 은 쓰지 않는다 (BOM 처리가
                  // Python 과 달라 해시가 갈린다). 정본화는 서명용 해시를 만들 때 Hashing.canonicalText 가 한다.
                  validator: _validate,
                ),
              ),
              const SizedBox(height: 6),
              const Text('답변은 블록체인에 해시로 기록되어 등록 후 수정할 수 없어요.',
                style: TextStyle(fontSize: 11, color: AppTheme.textSub),
              ),
              if (_error == null)
                const SizedBox(height: 16)
              else
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 8),
                  child: Text(_error!, key: const Key('answer_error'), style: const TextStyle(fontSize: 12, color: AppTheme.expense)),
                ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      // 서명·기록 중에 닫으면 결과를 못 본다
                      onPressed: _busy ? null : () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppTheme.divider),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text('취소', style: TextStyle(color: AppTheme.textSub)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: GradientButton(
                      // 서명·전송 중에는 다시 눌러도 아무 일도 없다 — 같은 답변이 두 번 가지 않게
                      onPressed: _busy ? null : _submit,
                      label: _busy ? '서명·기록 중…' : '답변 등록',
                      icon: _busy ? Icons.hourglass_top_rounded : Icons.send_rounded,
                      gradient: const LinearGradient(colors: [AppTheme.success, AppTheme.income]),
                    ),
                  ),
                ],
              ),
            ],
          ),
         ),
        ),
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label, value;
  final Color color;
  final IconData icon;
  const _StatItem({required this.label, required this.value, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: color)),
        Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSub)),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final int index, selectedIndex;
  final Color color;
  final VoidCallback onTap;
  const _FilterChip({
    required this.label,
    required this.index,
    required this.selectedIndex,
    this.color = AppTheme.primary,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = index == selectedIndex;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? color.withOpacity(0.12) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? color : AppTheme.divider,
            width: isSelected ? 2 : 1.5,
          ),
          boxShadow: isSelected ? [] : AppTheme.softShadow,
        ),
        child: Text(label,
          style: TextStyle(
            color: isSelected ? color : AppTheme.textSub,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _InquiryCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool isAnswered;
  final VoidCallback onAnswer;
  const _InquiryCard({required this.item, required this.isAnswered, required this.onAnswer});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppTheme.softShadow,
        border: isAnswered
            ? Border.all(color: AppTheme.success.withOpacity(0.3))
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                StatusBadge(
                  label: isAnswered ? '답변 완료' : '답변 대기',
                  color: isAnswered ? AppTheme.success : AppTheme.expense,
                ),
                const SizedBox(width: 8),
                // Flexible: 큰 글자·좁은 화면에서 넘치지 않고 줄바꿈된다
                Flexible(
                  child: Text('지출 #${item['entryId']} · ${item['date']}',
                    textAlign: TextAlign.end,
                    style: const TextStyle(color: AppTheme.textSub, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 질문
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.bgPage,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.help_outline_rounded, size: 16, color: AppTheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(item['question'],
                      style: const TextStyle(fontSize: 13.5, color: AppTheme.textMain, height: 1.4, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),

            // 답변 (있는 경우)
            if (isAnswered) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppTheme.success.withOpacity(0.08), AppTheme.income.withOpacity(0.05)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.success.withOpacity(0.2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.rate_review_rounded, size: 14, color: AppTheme.success),
                        SizedBox(width: 6),
                        Expanded(
                          child: Text('감사·회장 공식 답변',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppTheme.success),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(item['answer'] ?? '',
                      style: const TextStyle(fontSize: 13, height: 1.4, color: AppTheme.textMain),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),

            // 답변 대기 건에만 작성 버튼을 둔다. 답변 완료 건은 컨트랙트가 재답변을 막는다.
            if (isAnswered)
              const Align(
                alignment: Alignment.centerRight,
                child: Text('답변은 블록체인에 기록되어 수정할 수 없어요',
                  style: TextStyle(fontSize: 11, color: AppTheme.textSub),
                ),
              )
            else
              // Wrap: 좁은 화면·큰 글자에서 경과일과 버튼이 줄을 나눠 넘치지 않는다
              SizedBox(
                width: double.infinity,
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Text('미답변 ${inquiryElapsedDays(item['date'] as String)}일 경과',
                      style: const TextStyle(fontSize: 12, color: AppTheme.expense, fontWeight: FontWeight.bold),
                    ),
                    GestureDetector(
                      onTap: onAnswer,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF10B981), Color(0xFF06B6D4)],
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.reply_rounded, color: Colors.white, size: 15),
                            SizedBox(width: 6),
                            Text('답변 작성하기',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
