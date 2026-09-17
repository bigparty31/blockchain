"""학생 지갑 주소 파생 (PRD §9.2).

학생은 체인에 쓰지 않는다. 서버가 쓰는 곳은 이의 제기의 raiser 와 SBT 발급 대상 주소뿐이라 주소만 만든다.
니모닉은 환경변수 STUDENT_WALLET_MNEMONIC 로 받고 저장소에 넣지 않는다. User.wallet_index 가 경로의 마지막 숫자다.

서버는 StudentWallets 를 한 번 만들어 쓴다. 만들 때 니모닉에서 공통 경로 m/44'/60'/0'/0 까지 한 번 내려가고
니모닉·시드는 들고 있지 않는다. 학생마다 마지막 한 단계(BIP32 비강화 파생)만 계산하고, 만든 주소는 캐시한다.
"""
import hashlib
import hmac
import os
from collections import OrderedDict
from collections.abc import Mapping

from eth_account.hdaccount import seed_from_mnemonic
from eth_account.hdaccount.deterministic import HardNode, SoftNode, derive_child_key
from eth_keys import keys

STUDENT_PATH = "m/44'/60'/0'/0/{index}"
MNEMONIC_ENV = "STUDENT_WALLET_MNEMONIC"

_SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
_PARENT_PATH = (HardNode(44), HardNode(60), HardNode(0), SoftNode(0))  # m/44'/60'/0'/0
_MAX_INDEX = 2**31  # 마지막 단계는 비강화 경로라 2^31 미만


class StudentWallets:
    def __init__(self, mnemonic: str, cache_size: int = 10_000):
        """Raises: ValueError — 니모닉이 올바르지 않다. 서버 시작 때 만들어 잘못된 설정을 바로 드러낸다."""
        try:
            seed = seed_from_mnemonic(mnemonic, "")
        except Exception as e:  # eth-account 는 잘못된 니모닉에 ValidationError 등 여러 예외를 낸다
            raise ValueError(f"니모닉이 올바르지 않다: {type(e).__name__}") from e
        master = hmac.new(b"Bitcoin seed", seed, hashlib.sha512).digest()
        key, chain_code = master[:32], master[32:]
        for node in _PARENT_PATH:
            key, chain_code = derive_child_key(key, chain_code, node)
        self._parent_key = int.from_bytes(key, "big")
        self._parent_point = keys.PrivateKey(key).public_key.to_compressed_bytes()
        self._chain_code = chain_code
        self._cache: OrderedDict[int, str] = OrderedDict()
        self._cache_size = cache_size

    def address(self, index: int) -> str:
        """m/44'/60'/0'/0/{index} 의 주소 (EIP-55). 같은 인덱스는 항상 같은 주소다.

        Raises: ValueError — 인덱스가 0 이상 2^31 미만이 아니다.
        """
        if not 0 <= index < _MAX_INDEX:
            raise ValueError(f"wallet_index 는 0 이상 2^31 미만이어야 한다: {index}")
        cached = self._cache.get(index)
        if cached is not None:
            self._cache.move_to_end(index)
            return cached
        address = self._derive(index)
        self._cache[index] = address
        if len(self._cache) > self._cache_size:
            self._cache.popitem(last=False)
        return address

    def _derive(self, index: int) -> str:
        # BIP32 CKDpriv 비강화: I = HMAC-SHA512(c_par, serP(K_par) || ser32(i)), k_i = I_L + k_par (mod n)
        i = index
        while True:
            digest = hmac.new(self._chain_code, self._parent_point + i.to_bytes(4, "big"), hashlib.sha512).digest()
            tweak = int.from_bytes(digest[:32], "big")
            child = (tweak + self._parent_key) % _SECP256K1_N
            if tweak < _SECP256K1_N and child != 0:
                break
            i += 1  # 2^-127 확률로 무효인 키. BIP32·eth-account 와 같이 다음 번호로 넘어간다
        return keys.PrivateKey(child.to_bytes(32, "big")).public_key.to_checksum_address()


def student_address(mnemonic: str, index: int) -> str:
    """한 번만 쓸 때. 서버에서는 StudentWallets 를 한 번 만들어 쓴다 (니모닉을 매번 다시 풀지 않게)."""
    return StudentWallets(mnemonic, cache_size=0).address(index)


def mnemonic_from_env(env: Mapping[str, str] = os.environ) -> str:
    try:
        return env[MNEMONIC_ENV]
    except KeyError:
        raise ValueError(f"{MNEMONIC_ENV} 가 없다") from None
