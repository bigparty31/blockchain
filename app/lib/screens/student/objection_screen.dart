import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/enums.dart';
import '../../core/format.dart';
import '../../core/hashing.dart';
import '../../models/entry_model.dart';
import '../../services/student_api_service.dart';

/// 이의 제기 (S8)
///
/// 학생이 확정 지출에 사유를 묻고 학생회가 답변한다.
/// **원장은 고치지 않고 설명만 쌓인다.** 이 화면은 금액이나 상태를
/// 바꾸지 않으며, 미답변 사실이 감사 화면에 카운트로 남는다.
class ObjectionScreen extends StatefulWidget {
  final EntryModel entry;
  const ObjectionScreen({super.key, required this.entry});

  @override
  State<ObjectionScreen> createState() => _ObjectionScreenState();
}

class _ObjectionScreenState extends State<ObjectionScreen> {
  final _api = StudentApiService();
  final _controller = TextEditingController();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // 제출 버튼의 활성 여부가 본문에 달려 있어 한 글자마다 다시 그려야 한다
    // (스토리보드 5 ③).
    _controller.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  /// 이의 본문의 최소 길이 (`student_screens.md` §2.4).
  ///
  /// 「이상함」 한 줄로는 학생회가 무엇을 답해야 할지 알 수 없다.
  static const int minLength = 10;

  /// 정본화한 본문의 길이 — **버튼 상태와 안내에만 쓴다.**
  ///
  /// `backend_requests.md` §1-3 대로 **화면의 최소 길이 검사만 `canonicalText` 로
  /// 재고, 전송값은 건드리지 않는다.** 앞뒤 공백·개행을 세서 10자를 넘기는 것을
  /// 막으려면 정본화한 값으로 재야 하는데, 다듬은 값을 보내면 학생이 친 원문과
  /// 저장·해시되는 값이 갈린다 ([_submit] 참고).
  ///
  /// 길이는 `runes` 로 센다 — Dart 의 `String.length` 는 UTF-16 단위라 이모지
  /// 하나를 2 로 세서, 백엔드(Python `len()`, 코드포인트 단위)와 경계값이 갈린다.
  int get _contentLength => Hashing.canonicalText(_controller.text).runes.length;

  /// 제출할 수 있는 상태인지 (스토리보드 5 ③).
  bool get _canSubmit => _contentLength >= minLength;

  /// 뒤로 가면 입력한 내용이 사라지므로 한 번 묻는다 (스토리보드 5 ② 「되돌림」).
  Future<bool> _confirmDiscard() async {
    if (_controller.text.trim().isEmpty) return true;

    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('작성 중인 내용이 사라집니다'),
        content: const Text('지금 나가면 입력한 이의 내용은 저장되지 않습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('계속 작성'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('나가기'),
          ),
        ],
      ),
    );
    return leave ?? false;
  }

  Future<void> _submit() async {
    // **다듬은 값을 보내지 않는다.** 본문의 정본화와 해시는 백엔드가 저장 시점에
    // 한 번만 하고 그 값이 정본이다 — HASHING.md §1.1 의 파트별 표가 학생 앱을
    // 「가공 없이 그대로」로 못박았고, student_screens.md §3.4 도 같은 말을 한다.
    //
    // 지금은 양쪽 로직이 같아 결과가 같지만, 한쪽만 바뀌면 학생이 실제로 친 원문과
    // 저장·해시되는 값이 조용히 갈린다. 앱이 먼저 다듬으면 백엔드의 입력 검증
    // (제어문자 거부, §5)이 볼 입력을 앱이 미리 세탁하는 문제도 생긴다.
    final content = _controller.text;

    setState(() => _submitting = true);
    try {
      await _api.raiseObjection(entryId: widget.entry.id, content: content);
    } on ObjectionFailed {
      // **입력 내용은 남겨둔다** (스토리보드 5 ③ 「실패」). 여기서 화면을 닫으면
      // 학생이 쓴 글이 접수되지도 않은 채 사라진다.
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('연결에 실패했습니다'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (!mounted) return;

    setState(() => _submitting = false);

    // 접수 완료 팝업 (스토리보드 5 ④) — 확인을 누르면 지출 상세로 돌아간다.
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('접수되었습니다'),
        content: const Text('학생회가 확인 후 답변을 등록하면 알려드릴게요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('확인'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isIncome = widget.entry.kind == EntryKind.INCOME;

    return PopScope(
      // 뒤로 가기를 가로채 「내용이 사라진다」를 먼저 묻는다 (스토리보드 5 ②).
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _submitting) return;
        final leave = await _confirmDiscard();
        if (!mounted || !leave) return;
        Navigator.pop(this.context);
      },
      child: Scaffold(
        backgroundColor: AppTheme.bgPage,
        appBar: AppTheme.gradientAppBar(title: '이의 제기'),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          children: [
            _buildTargetCard(),
            const SizedBox(height: 20),
            const Text(
              '무엇이 궁금한가요?',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: AppTheme.textMain,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '어느 부분이 왜 이상한지 구체적으로 적을수록 답변이 정확해집니다.',
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.textSub.withOpacity(0.95),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: AppTheme.softShadow,
              ),
              child: TextField(
                controller: _controller,
                maxLines: 7,
                maxLength: 500,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  // 수입 항목에는 영수증이 없어서 지출용 예시가 맞지 않는다.
                  hintText: isIncome
                      ? '예) 입금된 금액이 실제 납부 인원과 맞지 않는 것 같습니다. '
                          '산출 근거를 확인할 수 있을까요?'
                      : '예) 영수증에 적힌 품목과 지출 목적이 맞지 않는 것 같습니다. '
                          '세부 내역서를 확인할 수 있을까요?',
                  hintStyle: const TextStyle(
                    color: AppTheme.textSub,
                    fontSize: 13,
                    height: 1.5,
                  ),
                  contentPadding: const EdgeInsets.all(16),
                  border: InputBorder.none,
                  counterStyle:
                      const TextStyle(fontSize: 11, color: AppTheme.textSub),
                ),
                style: const TextStyle(
                  fontSize: 14,
                  color: AppTheme.textMain,
                  height: 1.5,
                ),
              ),
            ),
            // 쓰기 시작했는데 버튼이 아직 회색이면 왜 그런지 말해 준다.
            // 비어 있을 때는 회색인 이유가 뻔하므로 띄우지 않는다.
            if (_contentLength > 0 && _contentLength < minLength) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.edit_note_rounded,
                      size: 14, color: AppTheme.textSub),
                  const SizedBox(width: 6),
                  Text(
                    '$minLength자 이상 적어 주세요 (${minLength - _contentLength}자 더)',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.textSub,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            _buildNotice(),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: _submitting
                  ? Container(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        color: AppTheme.divider,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  : GradientButton(
                      // 10자 미만이면 회색이고 눌리지 않는다. 버튼 상태가 곧 검사라서
                      // 「눌렀더니 거절」이 생기지 않는다 (스토리보드 5 ③).
                      onPressed: _canSubmit ? _submit : null,
                      enabled: _canSubmit,
                      label: '이의 제출',
                      icon: Icons.send_rounded,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTargetCard() {
    final e = widget.entry;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.description_outlined,
                  size: 15, color: AppTheme.textSub),
              const SizedBox(width: 6),
              Text(
                '대상 내역 #${e.id}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            e.counterparty,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: AppTheme.textMain,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            e.purpose,
            style: const TextStyle(
                fontSize: 12, color: AppTheme.textSub, height: 1.4),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                Fmt.won(e.amount),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.expense,
                ),
              ),
              const Spacer(),
              Text(
                Fmt.date(e.occurredAt),
                style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNotice() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.primaryLight.withOpacity(0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded,
              size: 16, color: AppTheme.primaryDark),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '이의를 제기해도 이미 확정된 기록은 수정되지 않습니다. 학생회의 답변이 '
              '기록으로 쌓이며, 답변하지 않으면 미답변 건으로 남습니다.',
              style: TextStyle(
                fontSize: 11,
                color: AppTheme.primaryDark.withOpacity(0.95),
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
