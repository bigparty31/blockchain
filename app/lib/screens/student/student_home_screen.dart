import 'package:flutter/material.dart';

/// [장정아 담당 파트: app/lib/screens/student/]
/// 학생 전용 화면 (잔액 조회, 예산 현황, 영수증 검증 및 이의 제기)
class StudentHomeScreen extends StatelessWidget {
  const StudentHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('학생회비 열람 (학생용)'),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.school, size: 72, color: Color(0xFF1E3A8A)),
              const SizedBox(height: 16),
              const Text(
                '학생 전용 화면',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              // [개발 정보: 담당자 장정아 (feat/app-student), 경로 app/lib/screens/student/]
              Text(
                '학생회비 잔액 조회 및 영수증 열람 서비스\n(학생용 기능 준비 중)',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[700], height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
