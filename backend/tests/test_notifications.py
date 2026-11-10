"""알림 kind 가 docs/enums.md 와 같은지 본다. 호출하는 쪽이 쓰는 이름이라 어긋나면 조용히 다른 알림이 된다."""
import re
from pathlib import Path

from app.services.notifications import NotificationKind, create_notification, resolve_notifications


def test_kinds_match_enums_doc():
    doc = (Path(__file__).parents[2] / "docs" / "enums.md").read_text(encoding="utf-8")
    section = doc.split("## notification kind", 1)[1].split("\n## ", 1)[0]
    assert re.findall(r"^\| `([A-Z_]+)` \|", section, re.MULTILINE) == [kind.value for kind in NotificationKind]


def test_stub_accepts_the_documented_calls():
    assert create_notification(None, NotificationKind.ENTRY_EDIT_REQUESTED, entry_id=1) is None
    assert create_notification(None, NotificationKind.REVISION_REQUESTED, budget_revision_request_id=1, user_ids=[2]) is None
    assert resolve_notifications(None, entry_id=1) is None
