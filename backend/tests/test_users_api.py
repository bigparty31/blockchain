"""GET /users/wallets — 학생 앱 검증 2단계가 읽는 지갑 주소 → user id 매핑 (docs/backend_requests.md 1-2)."""
import re

from fastapi.testclient import TestClient

from app.auth import users
from app.main import app
from app.schemas.auth import Role

client = TestClient(app)


def with_wallet():
    """기대값은 역할이 아니라 지갑 유무로 만든다 — 구현과 같은 기준이다."""
    return {u.wallet_address.lower(): u.id for u in users.SEED_USERS if u.wallet_address}


def test_wallets_is_open_and_maps_addresses_to_ids():
    # 다른 조회 API 와 같이 토큰 없이 부른다. 학생 앱은 헤더를 붙이지 않는다
    res = client.get("/users/wallets")
    assert res.status_code == 200
    assert res.json() == with_wallet()


def test_keys_are_lowercase_addresses_and_values_are_ids():
    # 앱은 체인 주소를 소문자로 바꿔 그대로 찾는다. 체크섬(EIP-55) 키면 같은 주소를 못 찾는다
    for address, user_id in client.get("/users/wallets").json().items():
        assert re.fullmatch(r"0x[0-9a-f]{40}", address)
        assert type(user_id) is int


def test_users_without_wallet_are_not_listed():
    # 지갑이 없는 학생은 체인에 서명자로 나오지 않는다
    without = {u.id for u in users.SEED_USERS if not u.wallet_address}
    assert without  # 시드에 학생이 있어야 이 테스트가 의미 있다
    assert without.isdisjoint(client.get("/users/wallets").json().values())


def test_former_officer_with_wallet_is_still_listed(monkeypatch):
    # 임기가 끝나 학생이 된 사람도 과거에 등록·승인한 항목을 검증하려면 매핑에 남아야 한다
    former = users.User(id=98, student_no="20239998", name="전총무", role=Role.STUDENT, password_hash="unused",
                        wallet_address="0x" + "cd" * 20)
    monkeypatch.setattr(users, "SEED_USERS", [*users.SEED_USERS, former])
    assert client.get("/users/wallets").json()[former.wallet_address] == 98


def test_checksum_address_is_listed_lowercase(monkeypatch):
    # 시드·DB 에 체크섬 표기로 들어 있어도 키는 소문자다
    officer = users.User(id=97, student_no="20249997", name="체크섬감사", role=Role.AUDITOR, password_hash="unused",
                         wallet_address="0xAbCdEf" + "12" * 17)
    monkeypatch.setattr(users, "SEED_USERS", [*users.SEED_USERS, officer])
    wallets = client.get("/users/wallets").json()
    assert wallets[officer.wallet_address.lower()] == 97
    assert officer.wallet_address not in wallets


def test_follows_seed_changes(monkeypatch):
    # 목록을 고정값으로 두지 않고 호출할 때마다 사용자 데이터에서 만든다
    extra = users.User(id=99, student_no="20249999", name="임시감사", role=Role.AUDITOR, password_hash="unused",
                       wallet_address="0x" + "ab" * 20)
    monkeypatch.setattr(users, "SEED_USERS", [*users.SEED_USERS, extra])
    assert client.get("/users/wallets").json()[extra.wallet_address] == 99


def test_seed_wallets_are_unique():
    # 두 사용자가 같은 주소를 가지면 체인 서명자가 누구인지 가릴 수 없다. 대소문자(EIP-55)는 같은 주소로 본다.
    # 응답은 주소가 키라 중복이 겹쳐 사라지므로 시드에서 직접 센다
    addresses = [u.wallet_address.lower() for u in users.SEED_USERS if u.wallet_address]
    assert len(addresses) == len(set(addresses))


def test_duplicate_address_fails_instead_of_picking_one(monkeypatch):
    # 덮어쓰면 한 사람의 서명이 다른 사람 것으로 보인다. 틀린 매핑을 주느니 실패한다
    taken = next(u.wallet_address for u in users.SEED_USERS if u.wallet_address)
    clone = users.User(id=96, student_no="20249996", name="중복감사", role=Role.AUDITOR, password_hash="unused",
                       wallet_address=taken.upper().replace("0X", "0x"))
    monkeypatch.setattr(users, "SEED_USERS", [*users.SEED_USERS, clone])
    res = TestClient(app, raise_server_exceptions=False).get("/users/wallets")
    assert res.status_code == 500
