"""로컬 Hardhat 체인에서 쓰는 값과 도우미. 스모크 스크립트와 체인 테스트(tests/chain_support.py)가 같이 쓴다.

계정 배치·서명 방식이 바뀌면 여기만 고친다. 키는 Hardhat 기본 니모닉에서 유도한다 (공개된 테스트 키라 파일에 적지 않는다).
임원 키로 서명하는 것은 "앱 역할" 이라 서버 코드(app/)에는 두지 않는다 (PRD §9.2).
"""
import time

from eth_account import Account
from eth_account.messages import encode_typed_data

from app.chain.commit import entry_commit_of
from app.chain.deployment import Eip712Domain
from app.chain.eip712 import SignedPayload, typed_data_for
from app.chain.models import ZERO_BYTES32, ChainEntry, ConfirmApproval

LOCAL_CHAIN_ID = 31337
LOCAL_RPC_URL = "http://127.0.0.1:8545"
HARDHAT_MNEMONIC = "test test test test test test test test test test test junk"

# contracts/scripts/deploy.ts 의 계정 배치
PRESIDENT_INDEX, TREASURER_INDEX, AUDITOR_INDEX, RELAYER_INDEX = 1, 2, 3, 4

Account.enable_unaudited_hdwallet_features()


def hardhat_key(index: int) -> str:
    return "0x" + bytes(Account.from_mnemonic(HARDHAT_MNEMONIC, account_path=f"m/44'/60'/0'/0/{index}").key).hex()


def sign_typed_data(typed: dict, key: str) -> str:
    """typed data(eth_signTypedData_v4 모양)에 키로 서명한다."""
    return "0x" + bytes(Account.sign_message(encode_typed_data(full_message=typed), key).signature).hex()


def sign_as_app(payload: SignedPayload, domain: Eip712Domain, key: str) -> str:
    """앱이 하는 EIP-712 서명. 화면에 보여준 값으로 typed data 를 만들어 임원 키로 서명한다."""
    return sign_typed_data(typed_data_for(payload, domain), key)


def approval_from_entry(entry: ChainEntry, deadline: int, **override) -> ConfirmApproval:
    """앱이 만드는 확정 요청. 체인에 등록된 값(get_entry)으로 hash·entryCommit 을 채운다 (CHAIN_CLIENT §5).

    기본은 경고 없는 승인이다. override 로 경고·사유나 값을 바꿔 본다.
    """
    fields = dict(
        id=entry.id,
        hash=entry.hash,
        entry_commit=entry_commit_of(entry),
        had_warning=False,
        warning_reason_hash=ZERO_BYTES32,
        deadline=deadline,
    )
    return ConfirmApproval(**{**fields, **override})


async def chain_now(w3) -> int:
    """체인이 다음 블록에 쓸 시각. deadline 을 정할 때 쓴다 — 컨트랙트는 block.timestamp 로 만료를 본다.

    Hardhat 은 블록이 없으면 최신 블록 시각이 마지막 블록(예: 배포)에 머물고, 다음 블록은 실제 시각으로 채굴한다.
    pending 블록 시각이 그 "다음 채굴 시각" 이다 — evm_increaseTime 으로 앞당긴 양도 들어 있다.
    pending 블록을 주지 않는 노드면 최신 블록 시각과 실제 시각 중 늦은 쪽으로 대신한다.
    """
    pending = await w3.eth.get_block("pending")
    if pending is not None:
        return pending["timestamp"]
    return max((await w3.eth.get_block("latest"))["timestamp"], int(time.time()))
