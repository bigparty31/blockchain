"""FCM 전송기 — `push.PushSender` 의 실제 구현 (firebase-admin).

`GOOGLE_APPLICATION_CREDENTIALS`(서비스 계정 키 **파일 경로**)가 있을 때만 켠다. 없으면 `push.LoggingSender`
(로그만 남김)가 그대로 쓰이고 서버는 평소처럼 뜬다 — 푸시는 폴링 알림의 보조이므로 키가 없다고 서버를 막지 않는다.

`firebase_admin` 은 켤 때 처음 읽는다. 패키지가 없거나 키 파일이 잘못돼도 서버는 뜨고 이유만 경고로 남긴다.
"""
import logging
import os
from typing import Any, List, Optional

from app.services import push

logger = logging.getLogger(__name__)

CREDENTIALS_ENV = "GOOGLE_APPLICATION_CREDENTIALS"
MULTICAST_LIMIT = 500  # FCM 한 번에 보낼 수 있는 토큰 수
# 앱이 만든 알림 채널 (AndroidManifest.xml default_notification_channel_id). 채널이 다르면 안드로이드가 기본 채널로 보낸다
ANDROID_CHANNEL_ID = "student_council_default"


def _notification(messaging: Any, message: push.PushMessage) -> Any:
    return messaging.Notification(title=message.title, body=message.body)


def _android(messaging: Any) -> Any:
    return messaging.AndroidConfig(priority="high", notification=messaging.AndroidNotification(channel_id=ANDROID_CHANNEL_ID))


class FcmSender:
    """블로킹 호출이다. 전송 스레드에서만 불린다 (push.deliver)."""

    def __init__(self, messaging: Any):
        self._m = messaging

    def send_to_tokens(self, tokens: List[str], message: push.PushMessage) -> List[str]:
        """기기들로 보낸다. FCM 이 등록되지 않은 토큰이라고 답한 것만 돌려준다 (서버가 해제한다).

        그 밖의 실패(일시 오류·잘못된 요청)는 토큰을 해제하지 않는다 — 다음 알림에 다시 시도한다.
        """
        invalid: List[str] = []
        for start in range(0, len(tokens), MULTICAST_LIMIT):
            chunk = tokens[start : start + MULTICAST_LIMIT]
            batch = self._m.send_each_for_multicast(
                self._m.MulticastMessage(
                    tokens=chunk,
                    notification=_notification(self._m, message),
                    data=dict(message.data),
                    android=_android(self._m),
                )
            )
            for token, response in zip(chunk, batch.responses):
                if response.success:
                    continue
                if isinstance(response.exception, self._m.UnregisteredError):
                    invalid.append(token)
                else:
                    logger.warning("푸시 전송 실패(토큰 유지): %s", response.exception)
        return invalid

    def send_to_topic(self, topic: str, message: push.PushMessage) -> None:
        self._m.send(
            self._m.Message(
                topic=topic,
                notification=_notification(self._m, message),
                data=dict(message.data),
                android=_android(self._m),
            )
        )


def install_from_env(environ: Optional[dict] = None) -> bool:
    """키 경로가 있으면 FCM 전송기를 끼운다. 끼웠으면 True. 어떤 실패도 서버를 막지 않는다."""
    env = os.environ if environ is None else environ
    path = (env.get(CREDENTIALS_ENV) or "").strip()
    if not path:
        logger.info("%s 가 없어 FCM 전송기를 끼우지 않는다 (푸시는 로그만 남긴다)", CREDENTIALS_ENV)
        return False
    if not os.path.isfile(path):
        logger.warning("%s 가 가리키는 파일이 없어 FCM 전송기를 끼우지 않는다", CREDENTIALS_ENV)
        return False
    try:
        import firebase_admin
        from firebase_admin import credentials, messaging

        if not firebase_admin._apps:
            firebase_admin.initialize_app(credentials.Certificate(path))
    except Exception:
        # 경로·내용은 남기지 않는다
        logger.exception("FCM 초기화에 실패해 전송기를 끼우지 않는다")
        return False
    push.set_sender(FcmSender(messaging))
    logger.info("FCM 전송기를 끼웠다")
    return True
