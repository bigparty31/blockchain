import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:local_auth/local_auth.dart';
import 'dart:io';

/// [이승호 담당: app/lib/screens/council/]
/// 카메라·생체인증 실기기 권한 및 기능 사전 검증 화면
/// - image_picker (카메라 촬영 / 갤러리)
/// - local_auth (생체인증 지원 여부 / 지문·Face ID 인증 트리거)
class HardwareTestScreen extends StatefulWidget {
  const HardwareTestScreen({super.key});

  @override
  State<HardwareTestScreen> createState() => _HardwareTestScreenState();
}

class _HardwareTestScreenState extends State<HardwareTestScreen> {
  final LocalAuthentication _auth = LocalAuthentication();
  final ImagePicker _picker = ImagePicker();

  // 생체인증 상태
  bool _canCheckBiometrics = false;
  List<BiometricType> _availableBiometrics = [];
  String _biometricStatus = '검사 대기 중';

  // 카메라 상태
  File? _pickedImage;
  String _cameraStatus = '촬영 대기 중';

  @override
  void initState() {
    super.initState();
    _checkHardwareCapabilities();
  }

  /// 1. 기기의 생체인증 지원 여부 확인
  Future<void> _checkHardwareCapabilities() async {
    try {
      final canCheck = await _auth.canCheckBiometrics;
      final isSupported = await _auth.isDeviceSupported();
      final biometrics = await _auth.getAvailableBiometrics();

      setState(() {
        _canCheckBiometrics = canCheck || isSupported;
        _availableBiometrics = biometrics;
        _biometricStatus = _canCheckBiometrics
            ? '생체인증 하드웨어 감지됨: ${biometrics.map((b) => b.name).join(', ')}'
            : '생체인증 미지원 기기 또는 등록된 생체정보 없음';
      });
    } catch (e) {
      setState(() {
        _biometricStatus = '생체인증 모듈 확인 오류: $e';
      });
    }
  }

  /// 2. 생체인증(지문/Face ID) 실제 트리거
  Future<void> _authenticateBiometrics() async {
    try {
      final authenticated = await _auth.authenticate(
        localizedReason: '학생회비 지출 승인을 위한 본인 생체인증을 진행합니다.',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false, // 핀/패턴 폴백 허용
        ),
      );

      setState(() {
        _biometricStatus = authenticated
            ? '✅ 생체인증 성공! (서명 키 접근 권한 획득)'
            : '❌ 생체인증 취소 또는 실패';
      });
    } catch (e) {
      setState(() {
        _biometricStatus = '인증 에러: $e (Android 권한 또는 에뮬레이터 설정 확인 필요)';
      });
    }
  }

  /// 3. 카메라 촬영 테스트
  Future<void> _takePhoto() async {
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
      );

      if (photo != null) {
        setState(() {
          _pickedImage = File(photo.path);
          _cameraStatus = '✅ 사진 촬영 성공 (${photo.name})';
        });
      } else {
        setState(() => _cameraStatus = '사진 촬영이 취소되었습니다.');
      }
    } catch (e) {
      setState(() {
        _cameraStatus = '카메라 권한 오류: $e\n(AndroidManifest CAMERA 권한 확인 필요)';
      });
    }
  }

  /// 4. 갤러리 이미지 선택 테스트
  Future<void> _pickFromGallery() async {
    try {
      final XFile? image = await _picker.pickImage(source: ImageSource.gallery);

      if (image != null) {
        setState(() {
          _pickedImage = File(image.path);
          _cameraStatus = '✅ 갤러리 이미지 선택 성공 (${image.name})';
        });
      }
    } catch (e) {
      setState(() {
        _cameraStatus = '갤러리 접근 권한 오류: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('하드웨어 권한 및 실기기 테스트'),
        backgroundColor: const Color(0xFF0F172A),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 권한 가이드 배너
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.indigo.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.indigo.shade200),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.verified_user, color: Colors.indigo),
                      SizedBox(width: 8),
                      Text(
                        '9/13 필수 과제: 권한 및 하드웨어 사전 검증',
                        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.indigo, fontSize: 14),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  // [개발 연동: image_picker 및 local_auth]
                  Text(
                    '안드로이드/iOS 실기기에서 영수증 촬영(카메라)과 서명 생체인증(지문/Face ID)이 원활히 작동하는지 확인하는 전용 테스트 도구입니다.',
                    style: TextStyle(fontSize: 12.5, color: Colors.black87, height: 1.4),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // 섹션 1: 생체인증 (local_auth)
            _buildSectionCard(
              title: '1. 생체인증 (지문 / Face ID)',
              subtitle: '학생회장/감사 온체인 트랜잭션 서명용',
              icon: Icons.fingerprint,
              color: Colors.indigo,
              statusText: _biometricStatus,
              extraContent: _availableBiometrics.isNotEmpty
                  ? Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Text(
                        '감지된 센서 목록: ${_availableBiometrics.map((b) => b.name).join(', ')}',
                        style: const TextStyle(fontSize: 12, color: Colors.indigo, fontWeight: FontWeight.w600),
                      ),
                    )
                  : null,
              actions: [
                ElevatedButton.icon(
                  onPressed: _authenticateBiometrics,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('생체인증 팝업 테스트 실행'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _checkHardwareCapabilities,
                  icon: const Icon(Icons.refresh),
                  label: const Text('생체 센서 다시 검색'),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // 섹션 2: 카메라 & 갤러리 (image_picker)
            _buildSectionCard(
              title: '2. 카메라 및 갤러리 (영수증 촬영)',
              subtitle: '영수증 촬영 및 OCR 판독 이미지 첨부',
              icon: Icons.camera_alt,
              color: Colors.blue,
              statusText: _cameraStatus,
              extraContent: _pickedImage != null
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12.0),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(_pickedImage!, height: 160, width: double.infinity, fit: BoxFit.cover),
                      ),
                    )
                  : null,
              actions: [
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _takePhoto,
                        icon: const Icon(Icons.photo_camera),
                        label: const Text('카메라 촬영'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blue[800], foregroundColor: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickFromGallery,
                        icon: const Icon(Icons.photo_library),
                        label: const Text('갤러리 선택'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required String statusText,
    Widget? extraContent,
    required List<Widget> actions,
  }) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(backgroundColor: color.withOpacity(0.12), child: Icon(icon, color: color)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      Text(subtitle, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.grey[50], borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey[300]!)),
              child: Text(statusText, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
            ),
            if (extraContent != null) extraContent,
            const SizedBox(height: 14),
            ...actions,
          ],
        ),
      ),
    );
  }
}
