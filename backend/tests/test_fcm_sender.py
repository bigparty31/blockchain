"""FCM 전송기 (app/services/fcm_sender.py) — firebase_admin 대신 가짜 messaging 으로 시험한다."""
from types import SimpleNamespace

import pytest

from app.services import fcm_sender, push


class Unregistered(Exception):
    pass


class FakeMessaging:
    """firebase_admin.messaging 대역. failures: 토큰 → 예외."""

    UnregisteredError = Unregistered

    def __init__(self, failures=None):
        self.failures = failures or {}
        self.multicasts, self.sent = [], []

    Notification = staticmethod(lambda title, body: SimpleNamespace(title=title, body=body))
    AndroidNotification = staticmethod(lambda channel_id: SimpleNamespace(channel_id=channel_id))
    AndroidConfig = staticmethod(lambda priority, notification: SimpleNamespace(priority=priority, notification=notification))
    MulticastMessage = staticmethod(lambda **kw: SimpleNamespace(**kw))
    Message = staticmethod(lambda **kw: SimpleNamespace(**kw))

    def send_each_for_multicast(self, msg):
        self.multicasts.append(msg)
        return SimpleNamespace(
            responses=[
                SimpleNamespace(success=t not in self.failures, exception=self.failures.get(t)) for t in msg.tokens
            ]
        )

    def send(self, msg):
        self.sent.append(msg)


MESSAGE = push.PushMessage(title="학생회 회계", body="새 지출 내역이 등록되었습니다.", data={"kind": "ENTRY_REGISTERED", "entry_id": "7"})


def test_토큰으로_보내고_제목_본문_data_채널을_담는다():
    m = FakeMessaging()
    assert fcm_sender.FcmSender(m).send_to_tokens(["a", "b"], MESSAGE) == []
    sent = m.multicasts[0]
    assert sent.tokens == ["a", "b"]
    assert (sent.notification.title, sent.notification.body) == ("학생회 회계", "새 지출 내역이 등록되었습니다.")
    assert sent.data == {"kind": "ENTRY_REGISTERED", "entry_id": "7"}
    assert sent.android.notification.channel_id == "student_council_default"


def test_등록되지_않은_토큰만_돌려주고_다른_실패는_토큰을_남긴다():
    m = FakeMessaging({"gone": Unregistered("x"), "flaky": RuntimeError("일시 오류")})
    invalid = fcm_sender.FcmSender(m).send_to_tokens(["ok", "gone", "flaky"], MESSAGE)
    assert invalid == ["gone"], "일시 오류로 토큰을 해제하면 알림을 영영 못 받는다"


def test_토큰이_500개를_넘으면_나눠_보낸다(monkeypatch):
    m = FakeMessaging({"t600": Unregistered("x")})
    tokens = [f"t{i}" for i in range(1, 701)]
    invalid = fcm_sender.FcmSender(m).send_to_tokens(tokens, MESSAGE)
    assert [len(c.tokens) for c in m.multicasts] == [500, 200]
    assert invalid == ["t600"], "두 번째 묶음의 응답도 제 토큰과 맞춘다"


def test_토픽으로_보낸다():
    m = FakeMessaging()
    fcm_sender.FcmSender(m).send_to_topic("students_2026-2", MESSAGE)
    assert m.sent[0].topic == "students_2026-2"
    assert m.sent[0].notification.body == "새 지출 내역이 등록되었습니다."


@pytest.fixture
def keep_sender():
    before = push.get_sender()
    yield
    push.set_sender(before)


def test_키_경로가_없으면_끼우지_않고_서버를_막지_않는다(keep_sender):
    before = push.get_sender()
    assert fcm_sender.install_from_env({}) is False
    assert fcm_sender.install_from_env({"GOOGLE_APPLICATION_CREDENTIALS": "  "}) is False
    assert push.get_sender() is before


def test_키_파일이_없으면_끼우지_않는다(keep_sender, tmp_path):
    before = push.get_sender()
    assert fcm_sender.install_from_env({"GOOGLE_APPLICATION_CREDENTIALS": str(tmp_path / "없음.json")}) is False
    assert push.get_sender() is before


def test_키_내용이_잘못돼도_던지지_않는다(keep_sender, tmp_path):
    key = tmp_path / "bad.json"
    key.write_text("{}")
    before = push.get_sender()
    assert fcm_sender.install_from_env({"GOOGLE_APPLICATION_CREDENTIALS": str(key)}) is False
    assert push.get_sender() is before


def test_올바른_키면_FcmSender_를_끼운다(keep_sender, tmp_path, monkeypatch):
    firebase_admin = pytest.importorskip("firebase_admin")
    from firebase_admin import credentials

    key = tmp_path / "ok.json"
    key.write_text("{}")
    monkeypatch.setattr(credentials, "Certificate", lambda path: object())
    monkeypatch.setattr(firebase_admin, "initialize_app", lambda cred: None)
    monkeypatch.setattr(firebase_admin, "_apps", {"x": 1})
    assert fcm_sender.install_from_env({"GOOGLE_APPLICATION_CREDENTIALS": str(key)}) is True
    assert isinstance(push.get_sender(), fcm_sender.FcmSender)
