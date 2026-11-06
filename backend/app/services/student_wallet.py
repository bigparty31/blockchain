"""학생 지갑 주소 파생 (PRD §4.2).

학생 키는 기기가 아니라 서버의 HD 월렛에서 파생한다. 주소는 m/44'/60'/0'/0/{wallet_index} 이고 니모닉은
환경변수 STUDENT_WALLET_MNEMONIC 에 둔다. 여기서는 주소만 돌려준다 — 개인키는 밖으로 내보내지 않는다.

한 학생에게 주소가 하나라는 보증은 users.wallet_index 에 있다 (PRD §13). 같은 학생에게 새 index 를 주면 SBT 를 두 번 받을 수 있다.
0 주소는 파생이 잘못됐다는 뜻이라 돌려주지 않고 멈춘다 — SBT 일괄 발행에 0 주소가 섞이면 배치 전체가 revert 된다 (PRD §7.2).
"""
import os
from functools import lru_cache

from eth_account import Account
from eth_account.hdaccount import key_from_seed, seed_from_mnemonic

MNEMONIC_ENV = "STUDENT_WALLET_MNEMONIC"
_ZERO_ADDRESS = "0x" + "0" * 40
# BIP-32 의 비강화 자식 index 범위. 마지막 단계(/{index})는 강화하지 않는다
_MAX_INDEX = 2**31 - 1

Account.enable_unaudited_hdwallet_features()


class WalletDerivationError(Exception):
    """학생 주소를 만들 수 없다 (니모닉 없음·형식 오류, index 범위 밖). 설정 문제라 회원권 확인은 '모름'으로 다룬다."""


def derivation_path(wallet_index: int) -> str:
    return f"m/44'/60'/0'/0/{wallet_index}"


def student_address(wallet_index: int) -> str:
    """wallet_index 의 학생 지갑 주소 (EIP-55).

    Raises:
        WalletDerivationError: 니모닉이 없거나 틀렸거나 index 가 범위 밖.
    """
    if isinstance(wallet_index, bool) or not isinstance(wallet_index, int) or not 0 <= wallet_index <= _MAX_INDEX:
        raise WalletDerivationError(f"wallet_index 는 0 이상 {_MAX_INDEX} 이하 정수여야 한다: {wallet_index!r}")
    mnemonic = os.environ.get(MNEMONIC_ENV, "").strip()
    if not mnemonic:
        raise WalletDerivationError(f"{MNEMONIC_ENV} 가 설정되지 않았다")
    address = _derive(mnemonic, wallet_index)
    if address.lower() == _ZERO_ADDRESS:
        raise WalletDerivationError("파생한 주소가 0 주소다")
    return address


@lru_cache(maxsize=4096)
def _derive(mnemonic: str, wallet_index: int) -> str:
    key = key_from_seed(_seed(mnemonic), derivation_path(wallet_index))
    return Account.from_key(key).address


@lru_cache(maxsize=4)
def _seed(mnemonic: str) -> bytes:
    try:
        return seed_from_mnemonic(mnemonic, "")
    except Exception:  # eth_account 는 형식 오류를 자체 ValidationError 로 낸다
        # 에러 메시지에 니모닉이 들어가므로 원문을 싣지 않는다
        raise WalletDerivationError(f"{MNEMONIC_ENV} 가 BIP-39 니모닉이 아니다") from None
