"""FCM 전송기 — `push.PushSender` 의 실제 구현 (firebase-admin).

`GOOGLE_APPLICATION_CREDENTIALS`(서비스 계정 키 **파일 경로**)가 있을 때만 켠다. 없으면 `push.LoggingSender`
(로그만 남김)가 그대로 쓰이고 서버는 평소처럼 뜬다 — 푸시는 폴링 알림의 보조이므로 키가 없다고 서버를 막지 않는다.

`firebase_admin` 은 켤 때 처음 읽는다. 패키지가 없거나 키 파일이 잘못돼도 서버는 뜨고 이유만 경고로 남긴다.
"""
import logging
import os
from contextlib import contextmanager
from typing import Any, Iterator, List, Optional

from app.services import push

logger = logging.getLogger(__name__)

CREDENTIALS_ENV = "GOOGLE_APPLICATION_CREDENTIALS"
MULTICAST_LIMIT = 500  # FCM 한 번에 보낼 수 있는 토큰 수
# 앱이 만든 알림 채널 (AndroidManifest.xml default_notification_channel_id). 채널이 다르면 안드로이드가 기본 채널로 보낸다
ANDROID_CHANNEL_ID = "student_council_default"
APP_NAME = "council-push"  # 기본 앱이 이미 있어도 우리 키로 보내려고 이름 붙은 앱을 쓴다


def _notification(messaging: Any, message: push.PushMessage) -> Any:
    return messaging.Notification(title=message.title, body=message.body)


def _android(messaging: Any) -> Any:
    return messaging.AndroidConfig(priority="high", notification=messaging.AndroidNotification(channel_id=ANDROID_CHANNEL_ID))


class FcmSender:
    """블로킹 호출이다. 전송 스레드에서만 불린다 (push.deliver)."""

    def __init__(self, messaging: Any, app: Any = None, exceptions: Any = None):
        self._m = messaging
        self._app = app
        # InvalidArgumentError 는 messaging 이 아니라 firebase_admin.exceptions 에 있다 (messaging 에 없어 AttributeError 가 난다)
        self._x = exceptions

    def send_to_tokens(self, tokens: List[str], message: push.PushMessage) -> List[str]:
        """기기들로 보낸다. 서버가 해제해도 되는 토큰만 돌려준다.

        - 해제: FCM 이 등록되지 않았다고 답한 토큰(`UnregisteredError`), 다른 프로젝트 토큰(`SenderIdMismatchError`),
          같은 묶음의 다른 토큰은 성공했는데 혼자 `InvalidArgumentError` 인 토큰(형식이 틀린 토큰).
          한 묶음이 전부 `InvalidArgumentError` 이면 메시지 자체가 틀린 것일 수 있어 해제하지 않는다.
        - 그 밖의 실패(일시 오류·쿼터)는 토큰을 남긴다 — 다음 알림에 다시 시도한다.
        - 묶음 하나가 통째로 실패해도 다음 묶음을 보내고, 그때까지 모은 해제 대상은 항상 돌려준다.
        """
        m = self._m
        invalid: List[str] = []
        for start in range(0, len(tokens), MULTICAST_LIMIT):
            chunk = tokens[start : start + MULTICAST_LIMIT]
            try:
                batch = m.send_each_for_multicast(
                    m.MulticastMessage(
                        tokens=chunk,
                        notification=_notification(m, message),
                        data=dict(message.data),
                        android=_android(m),
                    ),
                    app=self._app,
                )
            except Exception as e:
                logger.warning("푸시 묶음 전송 실패(%s): 기기 %d대는 다음 알림에 다시 시도한다", type(e).__name__, len(chunk))
                continue
            try:
                invalid.extend(self._invalid_in(chunk, batch.responses))
            except Exception as e:
                # 판정 중 오류가 나도 다음 묶음과 이미 모은 해제 대상을 잃지 않는다
                logger.warning("푸시 응답 판정 실패(%s): 이 묶음의 토큰은 유지한다", type(e).__name__)
        return invalid

    def _invalid_in(self, chunk: List[str], responses: List[Any]) -> List[str]:
        m = self._m
        bad_argument = getattr(self._x, "InvalidArgumentError", None)
        any_ok = any(r.success for r in responses)
        invalid: List[str] = []
        for token, response in zip(chunk, responses):
            if response.success:
                continue
            exc = response.exception
            if isinstance(exc, (m.UnregisteredError, m.SenderIdMismatchError)) or (
                any_ok and bad_argument is not None and isinstance(exc, bad_argument)
            ):
                invalid.append(token)
            else:
                logger.warning("푸시 전송 실패(토큰 유지): %s", type(exc).__name__)
        return invalid

    def send_to_topic(self, topic: str, message: push.PushMessage) -> None:
        self._m.send(
            self._m.Message(
                topic=topic,
                notification=_notification(self._m, message),
                data=dict(message.data),
                android=_android(self._m),
            ),
            app=self._app,
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
        from firebase_admin import credentials, exceptions, messaging

        try:
            app = firebase_admin.get_app(APP_NAME)
        except ValueError:
            app = firebase_admin.initialize_app(credentials.Certificate(path), name=APP_NAME)
    except Exception as e:
        # 경로·파일 내용이 로그에 남지 않게 예외 종류만 적는다 (traceback 에 파싱 오류가 찍힌다)
        logger.error("FCM 초기화에 실패해 전송기를 끼우지 않는다 (%s)", type(e).__name__)
        return False
    push.set_sender(FcmSender(messaging, app, exceptions))
    logger.info("FCM 전송기를 끼웠다")
    return True


@contextmanager
def installed_for_server() -> Iterator[None]:
    """서버 lifespan 용. 푸시 전송 스레드를 띄울 때(NOTIFICATION_WORKER 켬)만 전송기를 끼우고,
    서버가 내려갈 때 원래 전송기로 되돌린다 — 같은 프로세스에서 이어지는 시험이 실제 FCM 으로 보내지 않게."""
    from app.services import notification_worker

    previous = push.get_sender()
    if notification_worker.enabled():
        install_from_env()
    try:
        yield
    finally:
        push.set_sender(previous)
