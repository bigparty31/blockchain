"""학생 지갑 주소 파생 (app/services/student_wallet.py)."""
import pytest

from app.services import student_wallet
from app.services.student_wallet import MNEMONIC_ENV, WalletDerivationError, student_address

# 공개된 Hardhat 기본 니모닉. m/44'/60'/0'/0/{0,1} 주소는 Hardhat 문서의 계정 0·1 과 같다
TEST_MNEMONIC = "test test test test test test test test test test test junk"


# 캐시가 붙은 원래 함수. 시험이 monkeypatch 로 바꿔 끼운 뒤에도 이것을 비운다 — 정리 순서는 conftest 의 다른
# autouse fixture 에 따라 달라져서, 정리할 때 student_wallet._derive 가 아직 바꿔 끼운 함수일 수 있다
_CACHED = (student_wallet._derive, student_wallet._seed)


@pytest.fixture(autouse=True)
def fresh_cache():
    for cached in _CACHED:
        cached.cache_clear()
    yield
    for cached in _CACHED:
        cached.cache_clear()


def test_derives_bip44_addresses(monkeypatch):
    monkeypatch.setenv(MNEMONIC_ENV, TEST_MNEMONIC)
    assert student_address(0) == "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    assert student_address(1) == "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"


def test_same_index_same_address_and_different_index_different_address(monkeypatch):
    monkeypatch.setenv(MNEMONIC_ENV, TEST_MNEMONIC)
    assert student_address(7) == student_address(7)
    assert student_address(7) != student_address(8)


def test_address_follows_mnemonic_change(monkeypatch):
    monkeypatch.setenv(MNEMONIC_ENV, TEST_MNEMONIC)
    first = student_address(0)
    monkeypatch.setenv(MNEMONIC_ENV, "abandon " * 11 + "about")
    assert student_address(0) != first


@pytest.mark.parametrize("value", ["", "   "])
def test_missing_mnemonic(monkeypatch, value):
    monkeypatch.setenv(MNEMONIC_ENV, value)
    with pytest.raises(WalletDerivationError):
        student_address(0)


def test_unset_mnemonic(monkeypatch):
    monkeypatch.delenv(MNEMONIC_ENV, raising=False)
    with pytest.raises(WalletDerivationError):
        student_address(0)


def test_invalid_mnemonic_does_not_leak_words(monkeypatch):
    secret = "secret words that are not a mnemonic"
    monkeypatch.setenv(MNEMONIC_ENV, secret)
    with pytest.raises(WalletDerivationError) as e:
        student_address(0)
    assert secret not in str(e.value)
    assert e.value.__cause__ is None


@pytest.mark.parametrize("index", [-1, 2**31, True, "0", 1.0, None])
def test_index_out_of_range(monkeypatch, index):
    monkeypatch.setenv(MNEMONIC_ENV, TEST_MNEMONIC)
    with pytest.raises(WalletDerivationError):
        student_address(index)


def test_zero_address_is_refused(monkeypatch):
    monkeypatch.setenv(MNEMONIC_ENV, TEST_MNEMONIC)
    monkeypatch.setattr(student_wallet, "_derive", lambda mnemonic, index: "0x" + "0" * 40)
    with pytest.raises(WalletDerivationError):
        student_address(0)
