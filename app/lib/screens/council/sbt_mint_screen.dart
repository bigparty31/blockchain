import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/roster_parser.dart';
import '../../core/signing/sbt_types.dart';
import '../../models/sbt_mint_model.dart';
import '../../services/sbt_mint_service.dart';

/// 명단 파일을 골라 **바이트**를 돌려준다. 고르지 않고 닫으면 null.
typedef RosterPicker = Future<List<int>?> Function();

Future<List<int>?> pickRosterFile() async {
  final picked = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['csv', 'txt'],
    withData: true,
  );
  if (picked == null || picked.files.isEmpty) return null;
  final bytes = picked.files.single.bytes;
  if (bytes == null) throw const MintFailed(MintFailure.notReady, '고른 파일을 읽지 못했어요. 다시 골라 주세요.');
  return bytes;
}

/// 회원권(SBT) 일괄 발행 (A3, PRD §4.2) — 회장·감사.
///
/// 납부자 명단 → 발행 준비(서버가 학번을 지갑 주소로 바꾸고 제외 학생을 알려 줌) → 확인 → 기기 서명 → 제출 → 학생별 결과.
/// 100명이 넘으면 100명씩 **한 묶음씩** 차례로 한다 (묶음마다 nonce 가 하나씩 오른다).
///
/// 결과를 모를 때(응답 없음·제출 중)는 「결과 확인」만 보인다 — 같은 서명을 다시 보내지 않는다.
class SbtMintScreen extends StatefulWidget {
  final SbtMintService? service;
  final RosterPicker picker;

  const SbtMintScreen({super.key, this.service, this.picker = pickRosterFile});

  @override
  State<SbtMintScreen> createState() => _SbtMintScreenState();
}

class _SbtMintScreenState extends State<SbtMintScreen> {
  late final SbtMintService _service = widget.service ?? SbtMintService();
  final _paste = TextEditingController();

  Roster? _roster;
  List<List<String>> _chunks = const [];
  int _chunk = 0;
  int? _termId;

  /// 지금 묶음의 발행 요청 (준비됨·결과).
  MintBatch? _batch;

  /// 지금 묶음에서 발행할 학생이 0명일 때 서버가 알려 준 제외 학생.
  List<MintExcluded>? _nobody;

  /// 끝난 묶음들 (요약에 쓴다).
  final List<MintBatch> _done = [];

  bool _busy = false;
  String? _error;

  /// 제출 결과를 모른다 — 「결과 확인」만 허용한다.
  bool _mustCheck = false;

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  bool get _lastChunk => _chunk >= _chunks.length - 1;

  // ───────────────────────────── 명단

  Future<void> _pickFile() async {
    try {
      final bytes = await widget.picker();
      if (bytes == null) return;
      _useRoster(RosterParser.parseBytes(bytes));
    } on MintFailed catch (e) {
      setState(() => _error = e.message);
    }
  }

  void _readPaste() => _useRoster(RosterParser.parseText(_paste.text));

  void _useRoster(Roster roster) {
    setState(() {
      _roster = roster;
      _chunks = [
        for (var i = 0; i < roster.studentNos.length; i += SbtTypes.maxBatch)
          roster.studentNos.sublist(i, (i + SbtTypes.maxBatch).clamp(0, roster.studentNos.length)),
      ];
      _chunk = 0;
      _batch = null;
      _nobody = null;
      _done.clear();
      _error = roster.studentNos.isEmpty ? '명단에서 학번을 찾지 못했어요. 학번 칸이 있는지 확인해 주세요.' : null;
    });
  }

  // ───────────────────────────── 준비·서명·확인

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on MintFailed catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        if (e.kind == MintFailure.unknownOutcome) _mustCheck = true;
        if (e.kind == MintFailure.nobody) {
          _nobody = e.excluded;
          _batch = null;
        }
      });
      // 409 — 다른 제출이 진행 중이거나 이미 처리됨. 지금 상태를 다시 읽는다
      if (e.kind == MintFailure.conflict && _batch != null) await _refresh(keepError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prepare() => _run(() async {
        final termId = _termId ??= await _service.termId();
        final batch = await _service.prepare(termId: termId, studentNos: _chunks[_chunk]);
        if (!mounted) return;
        setState(() {
          _batch = batch;
          _nobody = null;
          _mustCheck = batch.status.outcomeUnknown;
        });
      });

  Future<void> _sign() async {
    final batch = _batch;
    if (batch == null || _busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('회원권 발행 서명'),
        content: Text(
          '${batch.targets.length}명에게 ${_termLabel(batch.termCode)} 회원권을 발행해요.\n\n'
          '서명하는 값은 학번이 아니라 학생 지갑 주소 ${batch.recipients.length}개예요. '
          '목록의 학번·이름은 서버가 주소와 짝지어 보여 준 것이에요.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          FilledButton(key: const Key('sbt_confirm'), onPressed: () => Navigator.pop(c, true), child: const Text('서명하고 발행')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      final result = await _service.signAndSubmit(batch);
      if (!mounted) return;
      setState(() {
        _batch = result;
        _mustCheck = result.status.outcomeUnknown;
      });
    });
  }

  Future<void> _refresh({bool keepError = false}) async {
    final batch = _batch;
    if (batch == null) return;
    try {
      final latest = await _service.fetch(batch.id);
      if (!mounted) return;
      setState(() {
        _batch = latest;
        _mustCheck = latest.status.outcomeUnknown;
        if (!keepError) _error = null;
      });
    } on MintFailed catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _check() => _run(() => _refresh());

  /// 다음 묶음으로 넘어가 바로 준비한다.
  Future<void> _next() async {
    setState(() {
      if (_batch != null) _done.add(_batch!);
      _batch = null;
      _nobody = null;
      _chunk++;
    });
    await _prepare();
  }

  // ───────────────────────────── 화면

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(title: const Text('회원권 발행')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _rosterCard(),
          if (_error != null) ...[
            const SizedBox(height: 12),
            _notice(_error!, AppTheme.expense, key: const Key('sbt_error')),
          ],
          if (_roster != null && _roster!.studentNos.isNotEmpty) ...[
            const SizedBox(height: 12),
            _stepCard(),
          ],
          if (_done.isNotEmpty) ...[
            const SizedBox(height: 12),
            _summaryCard(),
          ],
        ],
      ),
    );
  }

  Widget _rosterCard() {
    final roster = _roster;
    // 결과를 모르는 묶음이 있으면 명단을 바꾸지 못하게 한다 — 바꾸면 그 묶음을 확인할 길이 화면에서 사라진다
    final locked = _busy || _mustCheck;
    return _card(
      title: '1. 납부자 명단',
      children: [
        const Text('CSV·TXT 파일을 고르거나 학번을 붙여넣어 주세요. 제목 줄에 「학번」 칸이 있으면 그 칸만 읽어요.',
            style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('sbt_pick_file'),
          onPressed: locked ? null : _pickFile,
          icon: const Icon(Icons.upload_file_rounded),
          label: const Text('명단 파일 고르기'),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('sbt_paste_field'),
          controller: _paste,
          enabled: !locked,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(hintText: '학번을 한 줄에 하나씩', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(key: const Key('sbt_read_paste'), onPressed: locked ? null : _readPaste, child: const Text('붙여넣은 명단 읽기')),
        ),
        if (roster != null && roster.studentNos.isNotEmpty)
          Text(
            [
              '학번 ${roster.studentNos.length}명',
              if (_chunks.length > 1) '${SbtTypes.maxBatch}명씩 ${_chunks.length}번에 나눠 발행',
              if (roster.duplicates > 0) '중복 ${roster.duplicates}건 뺌',
              if (roster.unreadLines > 0) '학번을 못 찾은 줄 ${roster.unreadLines}개',
            ].join(' · '),
            key: const Key('sbt_roster_summary'),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
      ],
    );
  }

  Widget _stepCard() {
    final batch = _batch;
    final progress = _chunks.length > 1 ? ' (${_chunk + 1}/${_chunks.length})' : '';
    final children = <Widget>[];

    if (_nobody != null) {
      children
        ..add(_notice('이 묶음에는 발행할 학생이 없어요.', AppTheme.pending))
        ..add(_excludedList(_nobody!));
      if (!_lastChunk) children.add(_action('sbt_next', '다음 묶음 준비', _next));
    } else if (batch == null) {
      children
        ..add(Text('${_chunks[_chunk].length}명의 지갑 주소와 발행 대상을 서버에서 확인해요.'))
        ..add(_action('sbt_prepare', '발행 준비', _prepare));
    } else {
      children.add(_statusLine(batch));
      children.add(_targetList(batch));
      if (batch.excluded.isNotEmpty) children.add(_excludedList(batch.excluded));
      children.addAll(_actionsFor(batch));
    }
    return _card(title: '2. 발행$progress', children: children);
  }

  List<Widget> _actionsFor(MintBatch batch) {
    if (_mustCheck || batch.status.outcomeUnknown) {
      return [
        _notice('발행 결과를 아직 몰라요. 같은 서명을 다시 보내지 않고 체인에서 결과를 확인해요.', AppTheme.pending),
        _action('sbt_check', '결과 확인', _check),
      ];
    }
    switch (batch.status) {
      case MintBatchStatus.prepared:
        return [
          _notice('서명은 학번이 아니라 위 지갑 주소에 해요. 이름·학번은 서버가 주소와 짝지어 보여 준 것이에요.', AppTheme.info),
          _action('sbt_sign', '${batch.targets.length}명 서명하고 발행', _sign),
        ];
      case MintBatchStatus.minted:
        return [if (!_lastChunk) _action('sbt_next', '다음 묶음 준비', _next)];
      case MintBatchStatus.rejected:
        return switch (batch.reason) {
          'SignatureExpired' || 'InvalidSignature' => [
              _notice(_rejectText(batch.reason), AppTheme.expense),
              _action('sbt_sign', '다시 서명하고 발행', _sign),
            ],
          'InvalidNonce' => [
              _notice(_rejectText(batch.reason), AppTheme.expense),
              _action('sbt_reprepare', '다시 준비', () {
                setState(() => _batch = null);
                return _prepare();
              }),
            ],
          _ => [_notice(_rejectText(batch.reason), AppTheme.expense)],
        };
      case MintBatchStatus.submitting:
      case MintBatchStatus.noResponse:
        return const []; // 위에서 처리
    }
  }

  static String _rejectText(String? reason) => switch (reason) {
        'SignatureExpired' => '서명 유효 시간이 지나 체인이 거부했어요. 다시 서명하면 돼요.',
        'InvalidSignature' => '체인이 서명을 받아들이지 않았어요. 다시 서명해 주세요.',
        'InvalidNonce' => '그사이 다른 발행이 먼저 처리됐어요. 다시 준비해 주세요.',
        'NotApprover' => '이 지갑은 체인에 회장·감사로 등록돼 있지 않아 발행할 수 없어요. 운영자에게 문의해 주세요.',
        _ => '체인이 발행을 거부했어요${reason == null ? '' : ' ($reason)'}.',
      };

  Widget _statusLine(MintBatch batch) {
    final (text, color) = switch (batch.status) {
      MintBatchStatus.prepared => ('준비됨 — 서명 전', AppTheme.info),
      MintBatchStatus.submitting => ('제출 중', AppTheme.pending),
      MintBatchStatus.noResponse => ('결과 모름', AppTheme.pending),
      MintBatchStatus.rejected => ('거부됨', AppTheme.expense),
      MintBatchStatus.minted => (
          '발행 완료 — 새로 ${batch.mintedCount}명${batch.skippedCount > 0 ? ', 이미 보유 ${batch.skippedCount}명' : ''}',
          AppTheme.success
        ),
    };
    return Text(text, key: const Key('sbt_status'), style: TextStyle(fontWeight: FontWeight.w700, color: color));
  }

  Widget _targetList(MintBatch batch) => ExpansionTile(
        key: const Key('sbt_targets'),
        tilePadding: EdgeInsets.zero,
        title: Text('발행 대상 ${batch.targets.length}명'),
        initiallyExpanded: batch.targets.length <= 10,
        children: [
          for (final t in batch.targets)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${t.name} · ${t.studentNo}'),
              subtitle: Text(_short(t.address), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              trailing: Text(
                switch (t.status) {
                  'MINTED' => t.needsCheck ? '발행됨 · 기록 확인 필요' : '발행됨',
                  'SKIPPED' => t.needsCheck ? '이미 보유 · 기록 확인 필요' : '이미 보유',
                  _ => '대기',
                },
                style: TextStyle(fontSize: 12, color: t.needsCheck ? AppTheme.expense : AppTheme.textSub),
              ),
            ),
        ],
      );

  Widget _excludedList(List<MintExcluded> excluded) => ExpansionTile(
        key: const Key('sbt_excluded'),
        tilePadding: EdgeInsets.zero,
        title: Text('제외 ${excluded.length}명'),
        initiallyExpanded: true,
        children: [
          for (final e in excluded)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(e.name == null ? e.studentNo : '${e.name} · ${e.studentNo}'),
              trailing: Text(e.reasonLabel, style: const TextStyle(fontSize: 12, color: AppTheme.textSub)),
            ),
        ],
      );

  Widget _summaryCard() {
    final minted = _done.fold<int>(0, (s, b) => s + b.mintedCount);
    final skipped = _done.fold<int>(0, (s, b) => s + b.skippedCount);
    return _card(
      title: '끝난 묶음',
      children: [Text('${_done.length}묶음 · 새로 발행 $minted명 · 이미 보유 $skipped명', key: const Key('sbt_done_summary'))],
    );
  }

  // ───────────────────────────── 작은 조각

  Widget _action(String key, String label, Future<void> Function() onPressed) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: Key(key),
            onPressed: _busy ? null : onPressed,
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(label),
          ),
        ),
      );

  Widget _notice(String text, Color color, {Key? key}) => Container(
        key: key,
        width: double.infinity,
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: TextStyle(color: color, fontSize: 13)),
      );

  // 배경은 Material 로 칠한다 — Container 색이면 안의 ListTile(펼침 목록) 눌림 효과가 가려진다
  Widget _card({required String title, required List<Widget> children}) => Material(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textMain)),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      );

  static String _short(String address) =>
      address.length <= 14 ? address : '${address.substring(0, 8)}…${address.substring(address.length - 6)}';

  static String _termLabel(int code) => '${code ~/ 10}년 ${code % 10}학기';
}
