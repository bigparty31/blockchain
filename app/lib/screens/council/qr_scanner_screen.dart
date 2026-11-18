import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/app_theme.dart';
import '../../models/event_model.dart';
import '../../services/api_service.dart';
import '../../services/event_service.dart';

/// 카메라 자리. QR 을 읽을 때마다 [onCode] 를 부른다. 테스트는 카메라 대신 가짜를 넣는다.
typedef QrScannerBuilder = Widget Function(BuildContext context, void Function(String payload) onCode);

/// QR 스캐너 (A12) — 행사 입장 때 학생 회원권 QR 을 읽어 입장을 판정한다 (PRD §4.2, API.md 「행사·입장」).
///
/// 1. 행사를 고른다 (없으면 등록).
/// 2. QR 을 비추면 서버가 판정한다: 입장 · 이미 입장 · 회원권 없음 · 없는 학생 · 확인 불가.
///
/// - **자격은 QR 이 아니라 서버가 본다.** QR 에는 학생 ID 만 있다 — 캡처를 돌려 써도 판정은 이번 학기 회원권으로 한다.
/// - **이름·학번으로 본인을 확인한다.** QR 의 ID 는 추측할 수 있어서 결과 카드에 크게 보인다.
/// - 「확인 불가」는 미납이 아니다 — 체인 확인을 못 한 것이라 다시 찍게 한다.
/// - 같은 QR 이 카메라에 계속 비쳐도 한 번만 보낸다. 다시 보내려면 「다시 확인」.
class QrScannerScreen extends StatefulWidget {
  final EventService? service;
  final QrScannerBuilder scanner;
  final DateTime Function()? clock;

  /// 「다음 학생」 뒤 같은 QR 을 무시하는 시간. 학생이 폰을 치우는 동안 다시 찍히지 않게.
  static const nextCooldown = Duration(seconds: 3);

  const QrScannerScreen({super.key, this.service, this.scanner = cameraScanner, this.clock});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  late final EventService _service = widget.service ?? EventService();
  final _manual = TextEditingController();

  int? _termId;
  List<EventInfo>? _events;
  String? _loadError;
  EventInfo? _event;
  bool _creating = false; // 행사 등록 응답을 기다리는 중 — 「행사 추가」를 잠근다

  // 스캔 상태
  bool _busy = false;
  String? _lastPayload; // 마지막으로 읽은 QR — 같은 QR 은 다시 보내지 않는다
  DateTime? _ignoreUntil; // 「다음 학생」 직후 — 아직 카메라에 비친 같은 QR 을 무시하는 끝 시각
  _ScanView? _view;
  int _admitted = 0;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _events = null;
      _loadError = null;
    });
    try {
      final termId = _termId ?? await _service.termId();
      final events = await _service.events(termId);
      if (!mounted) return;
      setState(() {
        _termId = termId;
        _events = events;
      });
    } on ApiUnavailable catch (e) {
      if (mounted) setState(() => _loadError = e.message);
    }
  }

  // ───────────────────────────── 행사

  Future<void> _addEvent() async {
    final termId = _termId;
    if (termId == null) return;
    final draft = await showDialog<(String, DateTime)>(
      context: context,
      builder: (_) => _NewEventDialog(now: _now()),
    );
    if (draft == null || !mounted) return;
    setState(() => _creating = true);
    try {
      final created = await _service.create(termId: termId, name: draft.$1, heldAt: draft.$2);
      if (!mounted) return;
      setState(() => _events = [created, ...?_events]);
      // 기다리는 사이 다른 행사를 골라 스캔 중이면 바꾸지 않는다 — 그 행사의 입장 결과가 새 행사 화면에 붙지 않게
      if (_event == null) _choose(created);
    } on EventActionFailed catch (e) {
      _snack(e.message);
    } on ApiUnavailable catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  void _choose(EventInfo event) => setState(() {
        _event = event;
        _view = null;
        _lastPayload = null;
        _admitted = 0;
      });

  // ───────────────────────────── 스캔

  /// 카메라나 직접 입력에서 QR 문자열이 들어왔다.
  Future<void> _onCode(String raw, {bool force = false}) async {
    final event = _event;
    final payload = raw.trim();
    if (event == null || _busy || payload.isEmpty) return;
    // 카메라는 같은 QR 을 1초에 몇 번씩 읽는다. 결과 카드에 떠 있는 QR 은 「다시 확인」 전까지 무시하고,
    // 「다음 학생」 직후 잠깐은 아직 카메라에 남은 같은 QR 도 무시한다 (곧바로 「이미 입장」이 뜨지 않게)
    if (!force && payload == _lastPayload) {
      final until = _ignoreUntil;
      if (_view != null || (until != null && _now().isBefore(until))) return;
    }
    _lastPayload = payload;
    _ignoreUntil = null;

    if (!isStudentQr(payload)) {
      setState(() => _view = const _ScanView.message('학생 회원권 QR 이 아니에요', '학생 앱의 「내 회원권」 QR 을 비춰 주세요.'));
      return;
    }
    // 앞 학생의 카드를 바로 지운다 — 응답(최대 10초)을 기다리는 동안 앞 학생의 「입장 확인」을 이 학생 것으로 보지 않게
    setState(() {
      _busy = true;
      _view = const _ScanView.checking();
    });
    _ScanView view;
    CheckInOutcome? outcome;
    try {
      outcome = await _service.checkIn(eventId: event.id, payload: payload);
      view = _ScanView.outcome(outcome);
    } on EventActionFailed catch (e) {
      view = _ScanView.message('확인하지 못했어요', e.message, retry: true);
    } on ApiUnavailable catch (e) {
      view = _ScanView.message('확인하지 못했어요', e.message, retry: e is! ApiForbidden && e is! ApiUnauthorized);
    }
    if (!mounted) return;
    // 기다리는 사이 화면의 행사가 바뀌었으면 이 결과는 지금 행사의 것이 아니다 — 보이지도 세지도 않는다
    if (_event?.id != event.id) {
      setState(() => _busy = false);
      return;
    }
    if (outcome != null) {
      if (outcome.result == CheckInResult.admitted) _admitted++;
      HapticFeedback.mediumImpact();
    }
    setState(() {
      _busy = false;
      _view = view;
    });
  }

  void _retry() {
    final payload = _lastPayload;
    if (payload != null) _onCode(payload, force: true);
  }

  /// 다음 학생. 방금 학생의 QR 은 [nextCooldown] 동안 카메라로 다시 읽어도 보내지 않는다.
  void _next() => setState(() {
        _view = null;
        _ignoreUntil = _now().add(QrScannerScreen.nextCooldown);
      });

  void _submitManual() {
    final text = _manual.text;
    _manual.clear();
    FocusScope.of(context).unfocus();
    _onCode(text, force: true);
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ───────────────────────────── 그리기

  @override
  Widget build(BuildContext context) {
    final event = _event;
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: Text(event == null ? 'QR 스캐너 · 행사 선택' : event.name),
        actions: [
          if (event != null)
            TextButton(
              onPressed: _busy ? null : () => setState(() => _event = null),
              child: const Text('행사 바꾸기'),
            ),
        ],
      ),
      body: SafeArea(child: event == null ? _buildEvents() : _buildScanner()),
    );
  }

  Widget _buildEvents() {
    final events = _events;
    if (_loadError != null) {
      return _Centered(
        icon: Icons.cloud_off_rounded,
        text: _loadError!,
        action: TextButton(onPressed: _load, child: const Text('다시 불러오기')),
      );
    }
    if (events == null) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('입장을 확인할 행사를 고르세요', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textMain)),
        const SizedBox(height: 4),
        const Text('이번 학기 회원권이 있는 학생만 입장할 수 있어요.', style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
        const SizedBox(height: 12),
        if (events.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('이번 학기 행사가 아직 없어요. 행사를 추가해 주세요.',
                textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSub)),
          ),
        for (final e in events)
          Card(
            child: ListTile(
              leading: const Icon(Icons.event_rounded, color: AppTheme.primary),
              title: Text(e.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(_kstLabel(e.heldAt)),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _choose(e),
            ),
          ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _creating ? null : _addEvent,
          icon: const Icon(Icons.add_rounded),
          label: const Text('행사 추가'),
        ),
      ],
    );
  }

  Widget _buildScanner() {
    return Column(
      children: [
        Expanded(
          flex: 5,
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(16)),
            child: Stack(
              fit: StackFit.expand,
              children: [
                widget.scanner(context, _onCode),
                if (_busy)
                  const ColoredBox(
                    color: Color(0x66000000),
                    child: Center(child: CircularProgressIndicator(color: Colors.white)),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          // 이 화면에서 센 값이다 (서버 집계 아님) — 화면을 나가거나 행사를 바꾸면 0 부터
          child: Text('이 화면에서 입장 $_admitted명',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSub, fontWeight: FontWeight.bold)),
        ),
        Expanded(
          flex: 4,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            children: [
              switch (_view) {
                null => const _Hint(),
                final v when v.checking => const _CheckingCard(),
                final v => _ResultCard(view: v, onRetry: _busy ? null : _retry, onNext: _busy ? null : _next),
              },
              const SizedBox(height: 12),
              _ManualInput(controller: _manual, enabled: !_busy, onSubmit: _submitManual),
            ],
          ),
        ),
      ],
    );
  }
}

/// 결과 카드에 보일 것 — 확인 중이거나, 서버 판정이거나, 보내지 못한 이유.
class _ScanView {
  final CheckInOutcome? outcome;
  final String? title;
  final String? body;
  final bool retry;
  final bool checking;

  const _ScanView.outcome(CheckInOutcome this.outcome)
      : title = null,
        body = null,
        retry = false,
        checking = false;

  const _ScanView.message(String this.title, String this.body, {this.retry = false})
      : outcome = null,
        checking = false;

  const _ScanView.checking()
      : outcome = null,
        title = null,
        body = null,
        retry = false,
        checking = true;
}

/// 응답을 기다리는 동안의 카드. 이름·학번·색이 없어 어떤 판정으로도 보이지 않는다.
class _CheckingCard extends StatelessWidget {
  const _CheckingCard();

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('scan_checking'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.textSub.withValues(alpha: 0.3), width: 1.5),
        ),
        child: const Row(
          children: [
            SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Text('확인 중…', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textSub)),
          ],
        ),
      );
}

class _ResultCard extends StatelessWidget {
  final _ScanView view;
  final VoidCallback? onRetry;
  final VoidCallback? onNext;

  const _ResultCard({required this.view, required this.onRetry, required this.onNext});

  @override
  Widget build(BuildContext context) {
    final o = view.outcome;
    final (Color color, IconData icon, String title, String? body, bool retry) = o == null
        ? (AppTheme.textSub, Icons.info_outline_rounded, view.title!, view.body, view.retry)
        : switch (o.result) {
            CheckInResult.admitted => (AppTheme.success, Icons.check_circle_rounded, '입장 확인', '학생증의 이름·학번과 같은지 확인하세요.', false),
            CheckInResult.alreadyCheckedIn => (
                AppTheme.pending,
                Icons.repeat_rounded,
                '이미 입장했어요',
                o.checkedInAt == null ? null : '처음 입장: ${_kstLabel(o.checkedInAt!)}',
                false
              ),
            CheckInResult.notMember => (AppTheme.expense, Icons.block_rounded, '회원권이 없어요', '이번 학기 학생회비 납부(회원권)가 확인되지 않아요.', false),
            CheckInResult.unknownStudent => (AppTheme.expense, Icons.person_off_rounded, '등록되지 않은 학생이에요', 'QR 의 학생을 찾지 못했어요.', false),
            // 거부가 아니다 — 미납으로 안내하지 않는다 (API.md)
            CheckInResult.unverifiable => (AppTheme.info, Icons.sync_problem_rounded, '회원권을 확인하지 못했어요', '미납이 아니라 확인이 안 된 거예요. 다시 확인해 주세요.', true),
          };

    final who = o?.name == null ? null : '${o!.name} · ${o.studentNo ?? '-'}';
    return Container(
      key: const Key('scan_result'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color))),
            ],
          ),
          if (who != null) ...[
            const SizedBox(height: 8),
            Text(who, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.textMain)),
          ],
          if (body != null) ...[
            const SizedBox(height: 6),
            Text(body, style: const TextStyle(fontSize: 13, color: AppTheme.textSub)),
          ],
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (retry) TextButton(onPressed: onRetry, child: const Text('다시 확인')),
              FilledButton(onPressed: onNext, child: const Text('다음 학생')),
            ],
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('학생 앱 「내 회원권」의 QR 을 화면 가운데에 비춰 주세요.',
            textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSub)),
      );
}

/// 카메라를 못 쓸 때(권한 거부·에뮬레이터) QR 문자열을 직접 넣는다. 판정은 카메라와 같다.
class _ManualInput extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSubmit;

  const _ManualInput({required this.controller, required this.enabled, required this.onSubmit});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('manual_qr'),
              controller: controller,
              enabled: enabled,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'QR 문자열 직접 입력',
                hintText: 'SCA:2026-2:U000001',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => onSubmit(),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: enabled ? onSubmit : null, child: const Text('확인')),
        ],
      );
}

class _Centered extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;

  const _Centered({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 40, color: AppTheme.textSub),
              const SizedBox(height: 12),
              Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textSub)),
              if (action != null) ...[const SizedBox(height: 8), action!],
            ],
          ),
        ),
      );
}

/// 행사 추가 — 이름과 날짜. 시각은 고른 날의 지금 시각으로 둔다.
class _NewEventDialog extends StatefulWidget {
  final DateTime now;
  const _NewEventDialog({required this.now});

  @override
  State<_NewEventDialog> createState() => _NewEventDialogState();
}

class _NewEventDialogState extends State<_NewEventDialog> {
  final _name = TextEditingController();
  late DateTime _day = widget.now;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kst = _kst(_day);
    return AlertDialog(
      title: const Text('행사 추가'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('event_name'),
            controller: _name,
            autofocus: true,
            maxLength: 100,
            decoration: const InputDecoration(labelText: '행사 이름', hintText: '예: 해오름제'),
          ),
          Row(
            children: [
              Expanded(child: Text('날짜: ${kst.year}-${_two(kst.month)}-${_two(kst.day)}')),
              TextButton(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: DateTime(kst.year, kst.month, kst.day),
                    firstDate: DateTime(kst.year - 1),
                    lastDate: DateTime(kst.year + 1, 12, 31),
                  );
                  if (picked == null) return;
                  // 고른 날(KST)의 같은 시각
                  setState(() => _day = _day.add(DateTime(picked.year, picked.month, picked.day)
                      .difference(DateTime(kst.year, kst.month, kst.day))));
                },
                child: const Text('바꾸기'),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
        FilledButton(
          onPressed: () {
            if (_name.text.trim().isEmpty) return;
            Navigator.pop(context, (_name.text, _day));
          },
          child: const Text('추가'),
        ),
      ],
    );
  }
}

DateTime _kst(DateTime t) => t.toUtc().add(const Duration(hours: 9));
String _two(int v) => v.toString().padLeft(2, '0');

/// 행사·입장 시각은 기기 시간대와 상관없이 KST 로 보인다.
String _kstLabel(DateTime t) {
  final k = _kst(t);
  return '${k.year}-${_two(k.month)}-${_two(k.day)} ${_two(k.hour)}:${_two(k.minute)}';
}

// ───────────────────────────── 카메라

/// 기본 카메라 스캐너 (`mobile_scanner`). QR 만 읽는다.
Widget cameraScanner(BuildContext context, void Function(String payload) onCode) => _CameraScanner(onCode: onCode);

class _CameraScanner extends StatefulWidget {
  final void Function(String payload) onCode;
  const _CameraScanner({required this.onCode});

  @override
  State<_CameraScanner> createState() => _CameraScannerState();
}

class _CameraScannerState extends State<_CameraScanner> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MobileScanner(
        controller: _controller,
        onDetect: (capture) {
          for (final b in capture.barcodes) {
            final value = b.rawValue;
            if (value != null && value.isNotEmpty) {
              widget.onCode(value);
              return;
            }
          }
        },
        errorBuilder: (context, error) => _Centered(
          icon: Icons.no_photography_rounded,
          text: error.errorCode == MobileScannerErrorCode.permissionDenied
              ? '카메라 권한이 없어요. 설정에서 허용하거나, 아래에 QR 문자열을 직접 입력해 주세요.'
              : '카메라를 켜지 못했어요. 아래에 QR 문자열을 직접 입력해 주세요.',
        ),
      );
}
