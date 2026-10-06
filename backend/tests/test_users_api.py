"""GET /users/wallets — 학생 앱 검증 2단계가 읽는 user id ↔ 지갑 주소 매핑 (docs/backend_requests.md 1-2)."""
import re

from fastapi.testclient import TestClient

from app.auth import users
from app.main import app
from app.schemas.auth import Role

client = TestClient(app)


def with_wallet():
    """기대값은 역할이 아니라 지갑 유무로 만든다 — 구현과 같은 기준이다."""
    return {str(u.id): u.wallet_address for u in users.SEED_USERS if u.wallet_address}


def test_wallets_is_open_and_maps_ids_to_addresses():
    # 다른 조회 API 와 같이 토큰 없이 부른다. 학생 앱은 헤더를 붙이지 않는다
    res = client.get("/users/wallets")
    assert res.status_code == 200
    assert res.json() == with_wallet()


def test_keys_are_id_strings_the_app_can_parse():
    # 앱은 int.parse(key) 로 읽는다 (student_api_service.dart fetchWalletMap)
    for key, address in client.get("/users/wallets").json().items():
        assert key.isdecimal()
        assert re.fullmatch(r"0x[0-9a-fA-F]{40}", address)


def test_users_without_wallet_are_not_listed():
    # 지갑이 없는 학생은 체인에 서명자로 나오지 않는다
    without = {str(u.id) for u in users.SEED_USERS if not u.wallet_address}
    assert without  # 시드에 학생이 있어야 이 테스트가 의미 있다
    assert without.isdisjoint(client.get("/users/wallets").json())


def test_former_officer_with_wallet_is_still_listed(monkeypatch):
    # 임기가 끝나 학생이 된 사람도 과거에 등록·승인한 항목을 검증하려면 매핑에 남아야 한다
    former = users.User(id=98, student_no="20239998", name="전총무", role=Role.STUDENT, password_hash="unused",
                        wallet_address="0x" + "cd" * 20)
    monkeypatch.setattr(users, "SEED_USERS", [*users.SEED_USERS, former])
    assert client.get("/users/wallets").json()["98"] == former.wallet_address


def test_follows_seed_changes(monkeypatch):
    # 목록을 고정값으로 두지 않고 호출할 때마다 사용자 데이터에서 만든다
    extra = users.User(id=99, student_no="20249999", name="임시감사", role=Role.AUDITOR, password_hash="unused",
                       wallet_address="0x" + "ab" * 20)
    monkeypatch.setattr(users, "SEED_USERS", [*users.SEED_USERS, extra])
    assert client.get("/users/wallets").json()["99"] == extra.wallet_address


def test_wallets_are_unique():
    # 두 사용자가 같은 주소를 가지면 체인 서명자가 누구인지 가릴 수 없다. 대소문자(EIP-55)는 같은 주소로 본다
    addresses = [a.lower() for a in client.get("/users/wallets").json().values()]
    assert len(addresses) == len(set(addresses))
