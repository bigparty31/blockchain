import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_theme.dart';
import '../../core/signing/dev_keys.dart';
import '../../core/signing/device_key.dart';
import '../../core/signing/signing_service.dart';

/// 이 기기의 서명 키 (보드 ⑥ 키 상태 · 11/9 시연 기기 주소 제출).
///
/// - 키가 없으면 만든다. **기기 잠금(PIN·패턴·생체)이 없으면 만들지 않는다** (PRD §9.2) — 잠금 없는 폰의 키는
///   폰을 집은 사람 누구나 쓸 수 있다.
/// - 키가 있으면 주소를 보여 준다. 이 주소를 체인의 임원 롤로 등록한다(발표용 배포 때 `RoleManager` 초기 롤).
///   서버에 주소를 등록하는 API 는 두지 않는다 — 서버가 임원 주소를 바꿀 수 있으면 신뢰 모델이 무너진다.
/// - **있는 키는 덮어쓰지 않는다.** 덮어쓰면 체인 롤과 주소가 어긋나 이 기기의 서명이 전부 거부된다.
/// - 개발 빌드(`DEV_TOOLS`)에서만 공개 Hardhat 키를 넣을 수 있다 — 개발 스택 시드 계정과 짝이다.
class SigningKeyScreen extends StatefulWidget {
  /// 본인 확인·키 생성. 테스트에서 가짜 본인 확인을 넣는다.
  final SigningService? signing;

  const SigningKeyScreen({super.key, this.signing});

  @override
  State<SigningKeyScreen> createState() => _SigningKeyScreenState();
}

class _SigningKeyScreenState extends State<SigningKeyScreen> {
  late final SigningService _signing = widget.signing ?? SigningService();

  String? _address;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final address = await DeviceKey.address();
    if (!mounted) return;
    setState(() {
      _address = address;
      _loading = false;
    });
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      await _signing.createKey();
    } on SigningException catch (e) {
      error = e.message;
    } on StateError catch (e) {
      error = e.message;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    await _load();
  }

  /// 개발 빌드 — 공개 Hardhat 키로 바꾼다. 개발 스택에서만 의미가 있다.
  ///
  /// 이미 키가 있으면 먼저 묻는다 — 진짜 키를 쓰던 기기에서 잘못 누르면 되돌릴 방법이 `rotateKey`(회장+감사 2인 서명)뿐이다.
  /// 지우지 않고 덮어쓴다 — 지우고 쓰면 그 사이에 실패했을 때 키가 없는 상태로 남는다.
  Future<void> _importDev(DevKey key) async {
    if (_address != null && !await _confirmReplace()) return;
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      await DeviceKey.importDevKey(key.privateKey);
    } on StateError catch (e) {
      error = e.message;
    } on ArgumentError catch (e) {
      error = '${e.message}';
    } on FormatException catch (e) {
      error = e.message;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    await _load();
  }

  Future<bool> _confirmReplace() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('서명 키를 바꿀까요?', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        content: const Text('이 기기에 있는 서명 키가 개발용 키로 바뀌고, 지금 키는 되돌릴 수 없어요.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('바꾸기')),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppBar(
        title: const Text('서명 키', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        flexibleSpace: Container(decoration: const BoxDecoration(gradient: AppTheme.primaryGradient)),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _card(_address == null ? _noKey() : _hasKey(_address!)),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!, style: const TextStyle(color: AppTheme.expense, fontSize: 13, height: 1.4)),
                  ),
                if (DeviceKey.allowDevKeyImport) ...[
                  const SizedBox(height: 24),
                  _card(_devKeys()),
                ],
              ],
            ),
    );
  }

  Widget _card(Widget child) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: AppTheme.softShadow,
        ),
        child: child,
      );

  Widget _noKey() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.key_off_rounded, color: AppTheme.expense),
              SizedBox(width: 10),
              Expanded(
                child: Text('이 기기에 서명 키가 없어요',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppTheme.textMain)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '등록·승인·반려는 이 기기의 키로 서명해요. 키를 만들려면 기기 잠금(PIN·패턴·생체)이 켜져 있어야 해요.',
            style: TextStyle(fontSize: 12, height: 1.5, color: AppTheme.textSub),
          ),
          const SizedBox(height: 14),
          GradientButton(
            onPressed: _busy ? null : _create,
            label: '새 서명 키 만들기',
            icon: Icons.vpn_key_rounded,
          ),
        ],
      );

  Widget _hasKey(String address) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.verified_user_rounded, color: AppTheme.success),
              SizedBox(width: 10),
              Text('이 기기의 서명 키 주소',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppTheme.textMain)),
            ],
          ),
          const SizedBox(height: 10),
          SelectableText(address, style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: AppTheme.textMain)),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: address));
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('주소를 복사했어요'), behavior: SnackBarBehavior.floating),
              );
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('주소 복사'),
          ),
          const Text(
            '이 주소가 체인의 임원 롤로 등록돼야 서명이 받아들여져요. 발표용 배포 전에 팀장님께 전달해 주세요. '
            '키는 이 기기 밖으로 나가지 않아요.',
            style: TextStyle(fontSize: 12, height: 1.5, color: AppTheme.textSub),
          ),
        ],
      );

  Widget _devKeys() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('개발용 Hardhat 키 넣기',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppTheme.textMain)),
          const SizedBox(height: 6),
          const Text(
            '개발 빌드에서만 보여요. 공개된 키라 개발 스택(Hardhat)에서만 쓰고, 지금 키를 바꿔요.',
            style: TextStyle(fontSize: 12, height: 1.5, color: AppTheme.textSub),
          ),
          const SizedBox(height: 10),
          for (final key in DevKeys.all)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton(
                onPressed: _busy ? null : () => _importDev(key),
                child: Text(key.label),
              ),
            ),
        ],
      );
}
