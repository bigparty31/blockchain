"""FCM 전송기 (app/services/fcm_sender.py) — firebase_admin 대신 가짜 messaging 으로 시험한다."""
from types import SimpleNamespace

import pytest

from app.services import fcm_sender, push


class Unregistered(Exception):
    pass


class SenderMismatch(Exception):
    pass


class InvalidArgument(Exception):
    pass


class FakeMessaging:
    """firebase_admin.messaging 대역. failures: 토큰 → 예외."""

    UnregisteredError = Unregistered
    SenderIdMismatchError = SenderMismatch
    InvalidArgumentError = InvalidArgument

    def __init__(self, failures=None, explode_on=None):
        self.failures = failures or {}
        self.explode_on = explode_on  # 이 번호(0부터)의 묶음은 통째로 예외
        self.multicasts, self.sent, self.apps = [], [], []

    Notification = staticmethod(lambda title, body: SimpleNamespace(title=title, body=body))
    AndroidNotification = staticmethod(lambda channel_id: SimpleNamespace(channel_id=channel_id))
    AndroidConfig = staticmethod(lambda priority, notification: SimpleNamespace(priority=priority, notification=notification))
    MulticastMessage = staticmethod(lambda **kw: SimpleNamespace(**kw))
    Message = staticmethod(lambda **kw: SimpleNamespace(**kw))

    def send_each_for_multicast(self, msg, app=None):
        self.apps.append(app)
        if self.explode_on == len(self.multicasts):
            self.multicasts.append(msg)
            raise ConnectionError("네트워크")
        self.multicasts.append(msg)
        return SimpleNamespace(
            responses=[
                SimpleNamespace(success=t not in self.failures, exception=self.failures.get(t)) for t in msg.tokens
            ]
        )

    def send(self, msg, app=None):
        self.sent.append(msg)
        self.apps.append(app)


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


def test_토큰이_500개를_넘으면_나눠_보낸다():
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
    pytest.importorskip("firebase_admin")  # 없으면 ImportError 분기로 통과해 실제 처리를 검증하지 못한다
    key = tmp_path / "bad.json"
    key.write_text("{}")
    before = push.get_sender()
    assert fcm_sender.install_from_env({"GOOGLE_APPLICATION_CREDENTIALS": str(key)}) is False
    assert push.get_sender() is before


def test_올바른_키면_FcmSender_를_이름_붙은_앱으로_끼운다(keep_sender, tmp_path, monkeypatch):
    firebase_admin = pytest.importorskip("firebase_admin")
    from firebase_admin import credentials

    key = tmp_path / "ok.json"
    key.write_text("{}")
    made = {}
    monkeypatch.setattr(credentials, "Certificate", lambda path: object())
    monkeypatch.setattr(firebase_admin, "get_app", lambda name: (_ for _ in ()).throw(ValueError(name)))
    monkeypatch.setattr(firebase_admin, "initialize_app", lambda cred, name: made.setdefault("app", f"app:{name}"))
    assert fcm_sender.install_from_env({"GOOGLE_APPLICATION_CREDENTIALS": str(key)}) is True
    sender = push.get_sender()
    assert isinstance(sender, fcm_sender.FcmSender)
    assert sender._app == "app:council-push"


def test_다른_프로젝트_토큰은_해제하고_혼자_형식이_틀린_토큰도_해제한다():
    m = FakeMessaging({"other": SenderMismatch("x"), "bad": InvalidArgument("x")})
    assert fcm_sender.FcmSender(m).send_to_tokens(["ok", "other", "bad"], MESSAGE) == ["other", "bad"]


def test_묶음이_전부_InvalidArgument_면_메시지가_틀린_것일_수_있어_해제하지_않는다():
    m = FakeMessaging({"a": InvalidArgument("x"), "b": InvalidArgument("x")})
    assert fcm_sender.FcmSender(m).send_to_tokens(["a", "b"], MESSAGE) == []


def test_뒤_묶음이_통째로_실패해도_앞_묶음의_해제_대상을_돌려주고_나머지를_보낸다():
    m = FakeMessaging({"t3": Unregistered("x")}, explode_on=1)
    tokens = [f"t{i}" for i in range(1, 1202)]  # 500 + 500 + 201
    invalid = fcm_sender.FcmSender(m).send_to_tokens(tokens, MESSAGE)
    assert invalid == ["t3"], "첫 묶음에서 모은 것을 버리지 않는다"
    assert [len(c.tokens) for c in m.multicasts] == [500, 500, 201], "둘째가 실패해도 셋째를 보낸다"


def test_이름_붙은_앱으로_보낸다():
    m = FakeMessaging()
    sender = fcm_sender.FcmSender(m, app="APP")
    sender.send_to_tokens(["a"], MESSAGE)
    sender.send_to_topic("t", MESSAGE)
    assert m.apps == ["APP", "APP"], "기본 앱이 이미 있어도 우리 키의 앱으로 보낸다"


def test_서버_lifespan_은_끝나면_원래_전송기로_되돌린다(monkeypatch):
    from app.services import notification_worker

    before = push.get_sender()
    monkeypatch.setenv("NOTIFICATION_WORKER", "1")
    monkeypatch.setattr(fcm_sender, "install_from_env", lambda: push.set_sender(object()) or True)
    with fcm_sender.installed_for_server():
        assert push.get_sender() is not before
    assert push.get_sender() is before


def test_NOTIFICATION_WORKER_0_이면_끼우지_않는다(monkeypatch):
    before = push.get_sender()
    monkeypatch.setenv("NOTIFICATION_WORKER", "0")
    monkeypatch.setattr(fcm_sender, "install_from_env", lambda: pytest.fail("끼우면 안 된다"))
    with fcm_sender.installed_for_server():
        assert push.get_sender() is before


@pytest.mark.parametrize("module", ["app.main", "app.main_council"])
def test_공용_서버가_쓰는_두_진입점_모두_시작할_때_전송기를_끼운다(module, monkeypatch):
    """리뷰 1번 — api 컨테이너는 app.main:app 으로 뜬다. 한쪽에만 넣으면 공용 서버에서 푸시가 로그로만 남는다."""
    import asyncio
    import importlib

    from contextlib import contextmanager

    mod = importlib.import_module(module)
    monkeypatch.setenv("CHAIN_FAKE", "1")
    entered = []

    @contextmanager
    def fake_installed():
        entered.append(module)
        yield

    monkeypatch.setattr(mod.fcm_sender, "installed_for_server", fake_installed)

    async def run():
        async with mod.lifespan(mod.app):
            pass

    asyncio.run(run())
    assert entered == [module]
