import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../core/app_theme.dart';
import '../../core/format.dart';
import '../../core/term_info.dart';
import '../../models/membership_model.dart';
import '../../services/student_api_service.dart';

/// 본인 SBT 보유 표시 + 참여용 QR (S5)
///
/// **QR 에는 학생 식별자만 담는다** (PRD §148).
/// QR 에 「납부함」을 담으면 캡처 이미지를 남에게 전달하는 것만으로 뚫린다.
/// 자격 확인은 스캐너 쪽에서 조회해서 판단한다.
class MySbtScreen extends StatefulWidget {
  const MySbtScreen({super.key});

  @override
  State<MySbtScreen> createState() => _MySbtScreenState();
}

class _MySbtScreenState extends State<MySbtScreen> {
  final _api = StudentApiService();

  bool _loading = true;
  MembershipModel? _membership;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = await _api.fetchMyMembership();
    if (!mounted) return;
    setState(() {
      _membership = m;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPage,
      appBar: AppTheme.gradientAppBar(title: '내 SBT · QR'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              children: [
                if (_membership == null || !_membership!.isValid)
                  _buildNoMembership()
                else ...[
                  _buildQrCard(_membership!),
                  const SizedBox(height: 16),
                  _buildDetailCard(_membership!),
                ],
                const SizedBox(height: 16),
                _buildNotice(),
              ],
            ),
    );
  }

  Widget _buildQrCard(MembershipModel m) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: AppTheme.cardDecoration,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: AppTheme.success.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.verified_user_rounded, size: 14, color: AppTheme.success),
                SizedBox(width: 5),
                Text(
                  '학생회비 납부 확인됨',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.success,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // QR — 행사 입장 시 제시한다.
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppTheme.divider, width: 1.5),
            ),
            child: QrImageView(
              data: m.qrPayload,
              version: QrVersions.auto,
              size: 200,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: AppTheme.textMain,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: AppTheme.textMain,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            m.qrPayload,
            style: const TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: AppTheme.textSub,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '행사장에서 이 QR을 제시하세요',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.textMain,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailCard(MembershipModel m) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '멤버십 정보',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppTheme.textMain,
            ),
          ),
          const SizedBox(height: 12),
          _kv('토큰 번호', '#${m.tokenId}'),
          _kv('발급 일시', Fmt.date(m.mintedAt)),
          _kv('학기', TermInfo.currentTerm),
          _kv('커밋 해시', Fmt.shortHash(m.commitHash)),
          const SizedBox(height: 6),
          Text(
            '커밋 해시는 학번에 무작위 값을 섞어 만든 값입니다. 블록체인에는 이 값만 '
            '올라가며 학번 자체는 올라가지 않습니다.',
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

  Widget _buildNoMembership() {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: AppTheme.cardDecoration,
      child: Column(
        children: [
          Icon(Icons.no_accounts_rounded,
              size: 48, color: AppTheme.textSub.withOpacity(0.5)),
          const SizedBox(height: 14),
          const Text(
            '보유한 멤버십이 없습니다',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppTheme.textMain,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '학생회비를 납부하면 학생회에서 확인 후 멤버십을 발급합니다. '
            '발급되면 이 화면에 QR이 나타납니다.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.textSub.withOpacity(0.95),
              height: 1.5,
            ),
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
          const Icon(Icons.shield_outlined, size: 16, color: AppTheme.primaryDark),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'QR에는 본인 식별자만 담겨 있고 납부 여부는 담겨 있지 않습니다. '
              '입장 확인은 스캔한 쪽에서 조회해 판단하므로, 화면을 캡처해 남에게 '
              '보내도 대신 입장할 수 없습니다.',
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

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 90,
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
