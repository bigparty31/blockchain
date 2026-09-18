import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/api_config.dart';
import '../../core/app_theme.dart';
import '../../core/entry_merge.dart';
import '../../core/entry_verifier.dart';
import '../../core/enums.dart';
import '../../core/format.dart';
import '../../models/entry_model.dart';
import '../../models/objection_model.dart';
import '../../services/student_api_service.dart';
import 'objection_screen.dart';
import 'widgets/student_badges.dart';

/// 지출 상세 (S3 영수증 · S4 검증 · S7 OCR 경고 · S9 정정 이력 · S10 트랜잭션)
class EntryDetailScreen extends StatefulWidget {
  final EntryChain chain;
  const EntryDetailScreen({super.key, required this.chain});

  @override
  State<EntryDetailScreen> createState() => _EntryDetailScreenState();
}

class _EntryDetailScreenState extends State<EntryDetailScreen> {
  final _api = StudentApiService();

  List<ObjectionModel> _objections = [];
  VerificationReport? _report;

  /// 검증 3단계에서 해시를 재계산한 **바로 그 바이트**.
  ///
  /// 화면에 이 바이트를 그린다. `Image.network` 로 같은 경로를 다시 받으면
  /// 두 요청 사이에 파일이 바뀌었을 때 **검증한 파일과 보여주는 파일이 달라진다.**
  /// 검증 배지가 붙어 있는 화면에서 그러면 배지가 거짓말을 하는 셈이 된다.
  Uint8List? _receiptBytes;

  EntryModel get _entry => widget.chain.original;

  @override
  void initState() {
    super.initState();
    _loadObjections();
    _verify();
  }

  /// HASHING.md §2 의 세 단계를 모두 돌린다.
  Future<void> _verify() async {
    final onChain = await _api.fetchOnChainEntry(_entry.id);
    final receiptBytes = await _api.fetchReceiptBytes(_entry);
    final wallets = await _api.fetchWalletMap();
    if (!mounted) return;

    setState(() {
      _receiptBytes =
          receiptBytes == null ? null : Uint8List.fromList(receiptBytes);
      _report = EntryVerifier.verify(
        _entry,
        onChain: onChain,
        receiptBytes: receiptBytes,
        walletByUserId: wallets,
      );
    });
  }

  Future<void> _loadObjections() async {
    final list = await _api.fetchObjections(entryId: _entry.id);
    if (mounted) setState(() => _objections = list);
  }

  Future<void> _openObjection() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ObjectionScreen(entry: _entry)),
    );
    if (mounted) _loadObjections();
  }

  @override
  Widget build(BuildContext context) {
    final isIncome = _entry.kind == EntryKind.INCOME;

    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppTheme.gradientAppBar(title: isIncome ? '수입 상세' : '지출 상세'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          _buildAmountCard(isIncome),
          const SizedBox(height: 16),
          // 검증 배지 바로 위에 둔다. 예시 데이터에 붙은 「검증됨」은
          // 지어낸 값끼리 맞는다는 뜻일 뿐이라 따로 읽히면 오해를 부른다.
          if (_api.usingDemoData) ...[
            const DemoDataBanner(),
            const SizedBox(height: 16),
          ],
          _VerificationCard(report: _report),
          const SizedBox(height: 16),
          if (OcrWarningBadge.isWarning(_entry.ocrStatus, _entry.categoryWarning)) ...[
            _buildOcrWarningCard(),
            const SizedBox(height: 16),
          ],
          _buildInfoCard(),
          const SizedBox(height: 16),
          if (widget.chain.hasCorrection) ...[
            _buildCorrectionHistory(),
            const SizedBox(height: 16),
          ],
          if (_entry.receiptPath != null) ...[
            _buildReceiptCard(),
            const SizedBox(height: 16),
          ],
          _buildChainCard(),
          const SizedBox(height: 20),
          _buildObjectionSection(),
        ],
      ),
    );
  }

  Widget _buildAmountCard(bool isIncome) {
    final color = isIncome ? AppTheme.income : AppTheme.expense;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: AppTheme.cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusBadge(label: isIncome ? '수입' : '지출', color: color),
              const SizedBox(width: 6),
              EntryStatusBadge(status: widget.chain.displayStatus),
              const Spacer(),
              Text(
                '#${_entry.id}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (widget.chain.hasCorrection)
            Text(
              Fmt.won(_entry.amount),
              style: TextStyle(
                fontSize: 15,
                color: AppTheme.textSub.withOpacity(0.8),
                decoration: TextDecoration.lineThrough,
              ),
            ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              Fmt.won(widget.chain.finalAmount),
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                color: color,
                letterSpacing: -1,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _entry.counterparty,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppTheme.textMain,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _entry.purpose,
            style: const TextStyle(fontSize: 13, color: AppTheme.textSub, height: 1.4),
          ),
        ],
      ),
    );
  }

  /// 「OCR 불일치 상태로 승인됨」 (S7)
  Widget _buildOcrWarningCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.pending.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.pending.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OcrWarningBadge(
            ocrStatus: _entry.ocrStatus,
            categoryWarning: _entry.categoryWarning,
          ),
          const SizedBox(height: 12),
          if (_entry.ocrAmount != null)
            _kv('영수증 판독 금액', Fmt.won(_entry.ocrAmount!)),
          _kv('등록된 금액', Fmt.won(_entry.amount)),
          if (_entry.warningAckReason != null) ...[
            const SizedBox(height: 10),
            const Text(
              '승인자가 입력한 사유',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: AppTheme.textSub,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _entry.warningAckReason!,
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.textMain,
                height: 1.5,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            'OCR 판독값은 항목 해시에 포함되지 않습니다. 판독 불일치는 경고이며 '
            '기록 자체의 변조 여부와는 별개입니다.',
            style: TextStyle(
              fontSize: 10,
              color: AppTheme.textSub.withOpacity(0.9),
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '기본 정보',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppTheme.textMain,
            ),
          ),
          const SizedBox(height: 12),
          _kv('사용일', Fmt.date(_entry.occurredAt)),
          _kv('구분', _entry.kind.label),
          if (_entry.budgetId != null) _kv('예산 항목 ID', '#${_entry.budgetId}'),
          if (_entry.ocrStatus != null) _kv('OCR 판정', _entry.ocrStatus!.label),
          if (_entry.ocrApprovalNo != null) _kv('승인번호', _entry.ocrApprovalNo!),
          if (_entry.rejectReason != null) _kv('반려 사유', _entry.rejectReason!),
          const SizedBox(height: 4),
          Text(
            '사용일은 날짜 단위로만 기록됩니다. 시각은 담지 않습니다.',
            style: TextStyle(
              fontSize: 10,
              color: AppTheme.textSub.withOpacity(0.9),
            ),
          ),
        ],
      ),
    );
  }

  /// 정정 이력 (S9) — 원본은 남고 정정이 아래에 붙는다.
  ///
  /// 정정 항목의 금액은 **새 총액이 아니라 증감분**이다.
  Widget _buildCorrectionHistory() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.history_rounded, size: 16, color: AppTheme.info),
              SizedBox(width: 6),
              Text(
                '정정 이력',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textMain,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '확정된 기록은 수정하지 않습니다. 원본은 그대로 남고, 정정 항목이 '
            '원본을 참조해 새로 등록됩니다.',
            style: TextStyle(
              fontSize: 11,
              color: AppTheme.textSub.withOpacity(0.9),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          _historyRow(label: '원본', entry: _entry, isOriginal: true),
          ...widget.chain.corrections.map(
            (c) => _historyRow(label: '정정', entry: c, isOriginal: false),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.bgPage,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.functions_rounded, size: 14, color: AppTheme.textSub),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '합계에는 최종값 ${Fmt.won(widget.chain.finalAmount)}만 반영됩니다.',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSub),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _historyRow({
    required String label,
    required EntryModel entry,
    required bool isOriginal,
  }) {
    // 정정 항목은 증감분이므로 부호를 붙여 보여준다.
    final amountText = isOriginal
        ? Fmt.won(entry.amount)
        : '${entry.amount > 0 ? '+' : ''}${Fmt.won(entry.amount)}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(
              color: isOriginal ? AppTheme.textSub : AppTheme.info,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '$label #${entry.id}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isOriginal ? AppTheme.textSub : AppTheme.info,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      Fmt.date(entry.occurredAt),
                      style: const TextStyle(fontSize: 11, color: AppTheme.textSub),
                    ),
                    const SizedBox(width: 6),
                    EntryStatusBadge(status: entry.status),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  amountText,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: isOriginal ? AppTheme.textMain : AppTheme.info,
                    decoration: isOriginal ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (entry.correctionReason != null) ...[
                  const SizedBox(height: 4),
                  CorrectionBadge(reason: entry.correctionReason!),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 영수증 이미지 열람 (S3) + 바이트 재계산 결과 (검증 3단계)
  Widget _buildReceiptCard() {
    final receipt = _report?.receipt;
    // `receipt_path` 가 절대 URL(S3·CDN)로 바뀌어도 깨지지 않게 한다.
    // 상대 경로일 때만 베이스 URL 을 붙인다.
    final path = _entry.receiptPath ?? '';
    final url = path.startsWith('http') ? path : '${ApiConfig.baseUrl}$path';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '영수증',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppTheme.textMain,
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 160),
              color: AppTheme.bgPage,
              // 검증에 쓴 바이트가 있으면 그것을 그린다. 아직 못 받았을 때만
              // 네트워크로 떨어진다 (검증 전 잠깐, 또는 다운로드 실패).
              child: _receiptBytes != null
                  ? Image.memory(
                      _receiptBytes!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _receiptFallback(),
                    )
                  : Image.network(
                      url,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _receiptFallback(),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          if (receipt != null) _buildReceiptCheck(receipt),
        ],
      ),
    );
  }

  Widget _receiptFallback() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(Icons.image_not_supported_rounded,
              size: 36, color: AppTheme.textSub.withOpacity(0.5)),
          const SizedBox(height: 8),
          Text(
            '영수증 이미지를 불러올 수 없습니다',
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.textSub.withOpacity(0.8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReceiptCheck(ReceiptCheck receipt) {
    late final Color color;
    late final IconData icon;
    late final String label;

    switch (receipt.state) {
      case CheckState.passed:
        color = AppTheme.success;
        icon = Icons.check_circle_outline_rounded;
        label = '내려받은 파일이 기록된 영수증과 같습니다';
      case CheckState.failed:
        color = AppTheme.expense;
        icon = Icons.gpp_bad_rounded;
        label = '내려받은 파일이 기록된 영수증과 다릅니다';
      case CheckState.unavailable:
        color = AppTheme.textSub;
        icon = Icons.help_outline_rounded;
        label = '영수증을 내려받지 못해 확인하지 못했습니다';
      case CheckState.notApplicable:
        return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          if (receipt.expected != null) ...[
            const SizedBox(height: 8),
            _hashLine('기록된 해시', receipt.expected!),
          ],
          if (receipt.actual != null) ...[
            const SizedBox(height: 4),
            _hashLine('내려받은 파일의 해시', receipt.actual!),
          ],
        ],
      ),
    );
  }

  Widget _hashLine(String label, String hash) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 118,
          child: Text(
            label,
            style: const TextStyle(fontSize: 10, color: AppTheme.textSub),
          ),
        ),
        Expanded(
          child: Text(
            Fmt.shortHash(hash, head: 14, tail: 8),
            style: const TextStyle(
              fontSize: 10,
              fontFamily: 'monospace',
              color: AppTheme.textMain,
            ),
          ),
        ),
      ],
    );
  }

  /// 트랜잭션 해시 (S10)
  Widget _buildChainCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '온체인 기록',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppTheme.textMain,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '등록 시 해시만 먼저 기록(Pending)하고, 승인 시 확정(Confirm)됩니다. '
            '두 기록이 모두 남아 승인 전 변경을 추적할 수 있습니다.',
            style: TextStyle(
              fontSize: 11,
              color: AppTheme.textSub.withOpacity(0.9),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          _txRow('Pending 트랜잭션', _entry.txPending),
          _txRow('Confirm 트랜잭션', _entry.txConfirm),
          // `block_number` 가 응답에 실려 오면 자동으로 값이 뜬다 (S10).
          // 그때까지만 아래 안내가 대신 자리를 지킨다.
          if (_entry.blockNumber != null)
            _txRow('블록 번호', '#${_entry.blockNumber}')
          else
            Text(
              '블록 번호는 API 에서 아직 내려오지 않습니다.',
              style: TextStyle(
                fontSize: 10,
                color: AppTheme.textSub.withOpacity(0.9),
              ),
            ),
        ],
      ),
    );
  }

  Widget _txRow(String label, String? hash) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
            ),
          ),
          Expanded(
            child: hash == null
                ? const Text(
                    '아직 없음',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                  )
                : GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: hash));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('트랜잭션 해시를 복사했습니다'),
                          behavior: SnackBarBehavior.floating,
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            Fmt.shortHash(hash),
                            style: const TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              color: AppTheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const Icon(Icons.copy_rounded, size: 13, color: AppTheme.textSub),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 이의 제기 및 답변 (S8)
  Widget _buildObjectionSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '이의 제기',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: AppTheme.textMain,
              ),
            ),
            const SizedBox(width: 8),
            if (_objections.isNotEmpty)
              StatusBadge(label: '${_objections.length}건', color: AppTheme.primary),
          ],
        ),
        const SizedBox(height: 10),
        ..._objections.map(
          (o) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ObjectionTile(objection: o),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: GradientButton(
            onPressed: _openObjection,
            label: '이 ${_entry.kind.label}에 대해 질문하기',
            icon: Icons.help_outline_rounded,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '이의를 제기해도 원장은 수정되지 않습니다. 설명이 기록으로 쌓이고, '
          '답변하지 않은 사실도 그대로 남습니다.',
          style: TextStyle(
            fontSize: 11,
            color: AppTheme.textSub.withOpacity(0.9),
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              k,
              style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.textMain,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 검증 배지 상세 카드 (S4)
///
/// 배지 색만 보여주면 학생은 그 색을 믿는 수밖에 없다.
/// 세 단계의 결과와 근거가 된 값을 함께 보여줘야 직접 확인할 수 있다.
class _VerificationCard extends StatelessWidget {
  final VerificationReport? report;
  const _VerificationCard({required this.report});

  @override
  Widget build(BuildContext context) {
    if (report == null) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: AppTheme.cardDecoration,
        child: const Row(
          children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 10),
            Text(
              '검증하는 중입니다',
              style: TextStyle(fontSize: 13, color: AppTheme.textSub),
            ),
          ],
        ),
      );
    }

    final r = report!;
    late final Color color;
    late final String headline;
    late final String body;

    switch (r.status) {
      case VerificationStatus.verified:
        color = AppTheme.success;
        headline = '검증됨';
        body = '세 가지를 모두 확인했습니다. 기록이 등록된 이후 바뀌지 않았고, '
            '블록체인에 남은 값과도 일치합니다.';
      case VerificationStatus.tampered:
        color = AppTheme.expense;
        headline = '변조 감지';
        body = '앱에서 다시 계산한 값이 블록체인에 기록된 값과 다릅니다. '
            '등록 이후 내용이 변경되었을 수 있습니다.';
      case VerificationStatus.partial:
        color = AppTheme.info;
        headline = '부분 검증';
        body = '확인한 항목에서는 이상이 없었지만, 아직 확인하지 못한 항목이 '
            '있습니다. 이상 없음이 아니라 「아직 모름」입니다.';
      case VerificationStatus.unavailable:
        color = AppTheme.textSub;
        headline = '검증 불가';
        body = '대조할 온체인 기록이 없습니다. 통과가 아니라 확인할 수 없다는 뜻입니다.';
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              VerificationBadge(status: r.status),
              const Spacer(),
              Text(
                headline,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: const TextStyle(fontSize: 12, color: AppTheme.textMain, height: 1.5),
          ),

          const Divider(height: 24),

          // ── 1단계 ──
          _StepRow(
            step: 1,
            title: '항목 해시 재계산',
            state: r.hashState,
            detail: r.hashState == CheckState.passed
                ? '금액·사용처·목적·사용일·영수증이 최초 기록과 일치'
                : r.hashState == CheckState.failed
                    ? '재계산한 값이 기록된 값과 다름'
                    : '대조할 해시가 없음',
          ),
          const SizedBox(height: 10),
          _hashRow('앱에서 재계산한 값', r.recomputedHash, color),
          const SizedBox(height: 6),
          _hashRow(
            r.onChainHash != null ? '블록체인에 기록된 값' : '서버가 내려준 값',
            r.comparedAgainst ?? '없음',
            color,
          ),
          if (r.onChainHash == null) ...[
            const SizedBox(height: 4),
            Text(
              '체인 값을 직접 읽지 못해 서버 값과 비교했습니다.',
              style: TextStyle(fontSize: 10, color: AppTheme.textSub.withOpacity(0.9)),
            ),
          ],

          const SizedBox(height: 16),

          // ── 2단계 ──
          _StepRow(
            step: 2,
            title: '해시가 덮지 않는 항목 대조',
            state: _aggregate(r.fieldChecks),
            detail: r.fieldChecks.isEmpty
                ? '온체인 조회 API가 없어 대조하지 못함'
                : '수입·지출 구분과 예산 항목은 해시에 들어가지 않아 따로 확인합니다',
          ),
          if (r.fieldChecks.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...r.fieldChecks.map(_buildFieldRow),
          ],

          const SizedBox(height: 16),

          // ── 3단계 ──
          _StepRow(
            step: 3,
            title: '영수증 파일 재계산',
            state: r.receipt.state,
            detail: switch (r.receipt.state) {
              CheckState.passed => '내려받은 파일이 기록된 영수증과 동일',
              CheckState.failed => '내려받은 파일이 기록된 영수증과 다름',
              CheckState.notApplicable => '영수증이 없는 항목',
              CheckState.unavailable => '영수증을 내려받지 못함',
            },
          ),

          if (r.mismatches.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.expense.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '어긋난 항목 ${r.mismatches.length}건',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.expense,
                    ),
                  ),
                  const SizedBox(height: 6),
                  ...r.mismatches.map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '${f.label} — 체인 ${f.chain} / 앱에 표시된 값 ${f.local}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.textMain,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 12),
          Text(
            '검증은 서버가 아니라 이 앱 안에서 계산합니다.',
            style: TextStyle(fontSize: 10, color: AppTheme.textSub.withOpacity(0.9)),
          ),
        ],
      ),
    );
  }

  /// 필드 대조 전체의 대표 상태.
  static CheckState _aggregate(List<FieldCheck> checks) {
    if (checks.isEmpty) return CheckState.unavailable;
    if (checks.any((c) => c.state == CheckState.failed)) return CheckState.failed;
    if (checks.any((c) => c.state == CheckState.unavailable)) {
      return CheckState.unavailable;
    }
    return CheckState.passed;
  }

  Widget _buildFieldRow(FieldCheck f) {
    final (icon, color) = switch (f.state) {
      CheckState.passed => (Icons.check_rounded, AppTheme.success),
      CheckState.failed => (Icons.close_rounded, AppTheme.expense),
      CheckState.unavailable => (Icons.remove_rounded, AppTheme.textSub),
      CheckState.notApplicable => (Icons.remove_rounded, AppTheme.textSub),
    };

    return Padding(
      padding: const EdgeInsets.only(left: 28, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              f.label,
              style: const TextStyle(fontSize: 11, color: AppTheme.textMain),
            ),
          ),
          if (f.state == CheckState.failed)
            Text(
              '불일치',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
        ],
      ),
    );
  }

  Widget _hashRow(String label, String hash, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSub)),
        const SizedBox(height: 2),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withOpacity(0.2)),
          ),
          child: Text(
            Fmt.shortHash(hash, head: 18, tail: 10),
            style: const TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: AppTheme.textMain,
            ),
          ),
        ),
      ],
    );
  }
}

/// 검증 한 단계의 제목 줄.
class _StepRow extends StatelessWidget {
  final int step;
  final String title;
  final CheckState state;
  final String detail;

  const _StepRow({
    required this.step,
    required this.title,
    required this.state,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (state) {
      CheckState.passed => (Icons.check_circle_rounded, AppTheme.success),
      CheckState.failed => (Icons.cancel_rounded, AppTheme.expense),
      CheckState.unavailable => (Icons.help_outline_rounded, AppTheme.textSub),
      CheckState.notApplicable => (Icons.remove_circle_outline_rounded, AppTheme.textSub),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$step. $title',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textMain,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                detail,
                style: const TextStyle(fontSize: 11, color: AppTheme.textSub, height: 1.3),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 이의 한 건 — 질문과 답변
class _ObjectionTile extends StatelessWidget {
  final ObjectionModel objection;
  const _ObjectionTile({required this.objection});

  @override
  Widget build(BuildContext context) {
    final answered = objection.status == ObjectionStatus.ANSWERED;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusBadge(
                label: objection.status.label,
                color: answered ? AppTheme.success : AppTheme.pending,
              ),
              const Spacer(),
              Text(
                Fmt.date(objection.raisedAt),
                style: const TextStyle(fontSize: 11, color: AppTheme.textSub),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Q. ${objection.content}',
            style: const TextStyle(fontSize: 13, color: AppTheme.textMain, height: 1.5),
          ),
          if (answered && objection.answer != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.bgPage,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'A. ${objection.answer}',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textMain,
                  height: 1.5,
                ),
              ),
            ),
          ] else ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.schedule_rounded,
                    size: 13, color: AppTheme.pending.withOpacity(0.9)),
                const SizedBox(width: 4),
                Text(
                  '아직 답변이 없습니다',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.pending.withOpacity(0.9),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
