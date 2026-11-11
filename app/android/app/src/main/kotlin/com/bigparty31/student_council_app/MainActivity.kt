package com.bigparty31.student_council_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity

// local_auth 플러그인 생체인증(지문/Face ID) 정상 동작을 위해 FlutterFragmentActivity 상속 필수
class MainActivity: FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createDefaultNotificationChannel()
    }

    // AndroidManifest 의 default_notification_channel_id 가 가리키는 채널을 **여기서 만든다.**
    //
    // 선언만 하고 만들지 않으면 Android 8+ 에서 그 채널이 없으므로 FCM 이 자기
    // 폴백 채널로 알림을 돌린다 — 매니페스트에 적어 둔 중요도가 적용되지 않아
    // 소리·헤드업 없이 조용히 쌓이고, 기기 설정의 알림 항목 이름도 사용자가
    // 알아볼 수 없는 것이 된다.
    private fun createDefaultNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "학생회 알림",
            // 지출 확정과 장부–계좌 차이는 바로 보여야 하는 알림이다 (PRD §4.8).
            NotificationManager.IMPORTANCE_HIGH,
        )
        channel.description = "지출 확정, 장부와 계좌 잔액 차이 알림"
        manager.createNotificationChannel(channel)
    }

    private companion object {
        // AndroidManifest.xml 의
        // com.google.firebase.messaging.default_notification_channel_id 와 **같아야 한다.**
        // 한쪽만 바꾸면 알림이 폴백 채널로 조용히 돌아간다.
        const val CHANNEL_ID = "student_council_default"
    }
}
