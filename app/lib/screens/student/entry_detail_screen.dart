import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/api_config.dart';
import '../../core/app_theme.dart';
import '../../core/entry_merge.dart';
import '../../core/enums.dart';
import '../../core/format.dart';
import '../../core/meta_hash.dart';
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

  EntryModel get _entry => widget.chain.latest;

  @override
  void initState() {
    super.initState();
    _loadObjections();
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
    final verification = MetaHash.verify(_entry);
    final isIncome = _entry.kind == EntryKind.INCOME;

    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppTheme.gradientAppBar(title: isIncome ? '수입 상세' : '지출 상세'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          _buildAmountCard(isIncome),
          const SizedBox(height: 16),
          _VerificationCard(outcome: verification),
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
              EntryStatusBadge(status: _entry.status),
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
              Fmt.won(widget.chain.original.amount),
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
              Fmt.won(_entry.amount),
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
  ///
  /// 경고를 무시하고 승인했다면 승인자가 입력한 사유가 온체인에 남는다.
  /// 그 사유를 학생에게 그대로 보여주는 것이 이 카드의 목적이다.
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
          _kv('사용 일시', Fmt.dateTime(_entry.occurredAt)),
          _kv('구분', _entry.kind.label),
          if (_entry.budgetId != null) _kv('예산 항목 ID', '#${_entry.budgetId}'),
          if (_entry.ocrStatus != null) _kv('OCR 판정', _entry.ocrStatus!.label),
          if (_entry.ocrApprovalNo != null) _kv('승인번호', _entry.ocrApprovalNo!),
          if (_entry.rejectReason != null) _kv('반려 사유', _entry.rejectReason!),
        ],
      ),
    );
  }

  /// 정정 이력 (S9) — 원본은 남고 정정이 아래에 붙는다.
  Widget _buildCorrectionHistory() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history_rounded, size: 16, color: AppTheme.info),
              const SizedBox(width: 6),
              const Text(
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
          _historyRow(
            label: '원본',
            entry: widget.chain.original,
            isOriginal: true,
          ),
          ...widget.chain.corrections.map(
            (c) => _historyRow(label: '정정', entry: c, isOriginal: false),
          ),
          const SizedBox(height: 8),
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
                    '합계에는 최종값 ${Fmt.won(widget.chain.effectiveAmount)}만 '
                    '반영됩니다.',
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
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  Fmt.won(entry.amount),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textMain,
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

  /// 영수증 이미지 열람 (S3)
  Widget _buildReceiptCard() {
    final url = '${ApiConfig.baseUrl}${_entry.receiptPath}';

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
              child: Image.network(
                url,
                fit: BoxFit.cover,
                // 서버가 안 떠 있으면 자리표시자를 보여준다.
                errorBuilder: (_, __, ___) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Column(
                    children: [
                      Icon(Icons.image_not_supported_rounded,
                          size: 36, color: AppTheme.textSub.withOpacity(0.5)),
                      const SizedBox(height: 8),
                      Text(
                        '영수증을 불러올 수 없습니다',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.textSub.withOpacity(0.8),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _entry.receiptPath!,
                        style: TextStyle(
                          fontSize: 10,
                          color: AppTheme.textSub.withOpacity(0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_entry.receiptHash != null) ...[
            const SizedBox(height: 10),
            _kv('영수증 해시', Fmt.shortHash(_entry.receiptHash!)),
          ],
        ],
      ),
    );
  }

  /// 트랜잭션 해시·블록 (S10)
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
              StatusBadge(
                label: '${_objections.length}건',
                color: AppTheme.primary,
              ),
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
            label: '이 지출에 대해 질문하기',
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
/// 배지만 보여주면 학생은 그 색을 믿는 수밖에 없다. 재계산한 해시와
/// 온체인 해시를 나란히 보여줘야 직접 확인할 수 있다.
class _VerificationCard extends StatelessWidget {
  final VerificationOutcome outcome;
  const _VerificationCard({required this.outcome});

  @override
  Widget build(BuildContext context) {
    late final Color color;
    late final String headline;
    late final String body;

    switch (outcome.status) {
      case VerificationStatus.verified:
        color = AppTheme.success;
        headline = '검증됨';
        body = '이 기록은 등록된 이후 내용이 바뀌지 않았습니다. '
            '금액·사용처·목적·일시·영수증이 모두 최초 기록과 일치합니다.';
      case VerificationStatus.tampered:
        color = AppTheme.expense;
        headline = '변조 감지';
        body = '앱에서 다시 계산한 값이 블록체인에 기록된 값과 다릅니다. '
            '등록 이후 내용이 변경되었을 수 있습니다.';
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
              VerificationBadge(status: outcome.status),
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
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.textMain,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 14),
          _hashRow('앱에서 재계산한 값', outcome.recomputed, color),
          const SizedBox(height: 8),
          _hashRow(
            '블록체인에 기록된 값',
            outcome.onChain.isEmpty ? '없음' : outcome.onChain,
            color,
          ),
          const SizedBox(height: 10),
          Text(
            '검증은 서버가 아니라 이 앱 안에서 계산합니다.',
            style: TextStyle(
              fontSize: 10,
              color: AppTheme.textSub.withOpacity(0.9),
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
        Text(
          label,
          style: const TextStyle(fontSize: 10, color: AppTheme.textSub),
        ),
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
            style: const TextStyle(
              fontSize: 13,
              color: AppTheme.textMain,
              height: 1.5,
            ),
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
