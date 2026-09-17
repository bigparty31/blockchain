"""원장 밖 컨트랙트의 실제 구현 — RoleManager·MembershipSBT·BudgetToken 조회, ObjectionRegistry.

모두 같은 Web3Relayer 를 받는다. 이의 제기·답변도 릴레이어 계정으로 보내므로 원장 클라이언트와 nonce 를 나눠 써야 한다.
"""
from typing import Optional

from eth_utils import to_checksum_address
from hexbytes import HexBytes

from app.chain.eip712 import Eip712Domain
from app.chain.models import (
    OBJECTION_STATUS_ORDER,
    AnswerRequest,
    ChainBudget,
    ChainConfigError,
    ChainMembership,
    ChainObjection,
    ChainRevert,
    ObjectionStatus,
    ObjectionTx,
    Role,
    check_address,
    check_bytes32,
    check_signature,
)
from app.chain.relayer import Web3Relayer, bytes32, tx_hash_of
from app.chain.revert import OBJECTION_ERRORS

ROLE_ERRORS = ("IRoleManager",)
MEMBERSHIP_ERRORS = ("IMembershipSBT",)
BUDGET_ERRORS = ("IBudgetToken",)


class Web3RoleReader:
    """RoleReader 구현."""

    def __init__(self, relayer: Web3Relayer, address: str):
        self._relayer = relayer
        self._roles = relayer.contract(address, "IRoleManager", ROLE_ERRORS)

    async def check(self) -> None:
        """컨트랙트가 있고, 롤 식별자가 서버가 쓰는 keccak256(이름)과 같은지."""
        await self._relayer.check_contract(self._roles)
        for role in Role:
            onchain = HexBytes(await self._relayer.rpc(getattr(self._roles.web3.functions, role.value)().call())).to_0x_hex()
            if onchain != role.id:
                raise ChainConfigError(f"RoleManager.{role.value}() 가 {onchain} 이다. 서버는 {role.id} 를 쓴다")

    async def has_role(self, role: Role, account: str) -> bool:
        call = self._roles.web3.functions.hasRole(bytes32(role.id), to_checksum_address(check_address(account))).call()
        return await self._relayer.rpc(call, ROLE_ERRORS)


class Web3ObjectionClient:
    """ObjectionClient 구현."""

    def __init__(self, relayer: Web3Relayer, address: str, domain: Eip712Domain):
        self._relayer = relayer
        self._domain = domain
        self._registry = relayer.contract(address, "IObjectionRegistry", OBJECTION_ERRORS)

    async def check(self) -> None:
        await self._relayer.check_contract(self._registry, self._domain)

    async def raise_objection(self, objection_id: int, entry_id: int, content_hash: str, raiser: str) -> ObjectionTx:
        args = [objection_id, entry_id, bytes32(check_bytes32(content_hash)), to_checksum_address(check_address(raiser))]
        receipt = await self._relayer.send(self._registry, self._registry.encode("raise", args))
        return self._result(receipt, "ObjectionRaised", ObjectionStatus.OPEN)

    async def answer_objection(self, request: AnswerRequest, signature: str) -> ObjectionTx:
        args = [(request.objection_id, bytes32(request.answer_hash), request.deadline), HexBytes(check_signature(signature))]
        receipt = await self._relayer.send(self._registry, self._registry.encode("answer", args))
        return self._result(receipt, "ObjectionAnswered", ObjectionStatus.ANSWERED)

    async def get_objection(self, objection_id: int) -> Optional[ChainObjection]:
        functions = self._registry.web3.functions
        if not await self._relayer.rpc(functions.exists(objection_id).call(), OBJECTION_ERRORS):
            return None
        entry_id, content_hash, answer_hash, status, raiser, responder = await self._relayer.rpc(
            functions.getObjection(objection_id).call(), OBJECTION_ERRORS
        )
        return ChainObjection(
            id=objection_id,
            entry_id=entry_id,
            content_hash=HexBytes(content_hash).to_0x_hex(),
            answer_hash=HexBytes(answer_hash).to_0x_hex(),
            status=OBJECTION_STATUS_ORDER[status],
            raiser=to_checksum_address(raiser),
            responder=to_checksum_address(responder),
        )

    def _result(self, receipt, event: str, status: ObjectionStatus) -> ObjectionTx:
        if not self._registry.decode_logs(receipt["logs"], (event,)):
            raise ChainConfigError(f"영수증에 {event} 가 없다 — ABI 나 컨트랙트 주소를 확인")
        return ObjectionTx(tx_hash=tx_hash_of(receipt), status=status)


class Web3MembershipReader:
    """MembershipReader 구현. 발급·소각은 두지 않았다 (호출자가 회장, docs/CHAIN_CLIENT.md §8)."""

    def __init__(self, relayer: Web3Relayer, address: str):
        self._relayer = relayer
        self._sbt = relayer.contract(address, "IMembershipSBT", MEMBERSHIP_ERRORS)

    async def check(self) -> None:
        await self._relayer.check_contract(self._sbt)

    async def has_valid_membership(self, account: str, term: int) -> bool:
        call = self._sbt.web3.functions.hasValidMembership(to_checksum_address(check_address(account)), term).call()
        return await self._relayer.rpc(call, MEMBERSHIP_ERRORS)

    async def token_of(self, account: str, term: int) -> Optional[int]:
        call = self._sbt.web3.functions.tokenOf(to_checksum_address(check_address(account)), term).call()
        token_id = await self._relayer.rpc(call, MEMBERSHIP_ERRORS)
        return token_id or None  # tokenId 는 1부터라 0 은 없음

    async def get_membership(self, token_id: int) -> Optional[ChainMembership]:
        functions = self._sbt.web3.functions
        try:
            # 인터페이스에 exists 가 없어서 ERC721 ownerOf 로 본다. 발급된 적 없거나 소각된 토큰이면 revert 한다
            await self._relayer.rpc(functions.ownerOf(token_id).call(), MEMBERSHIP_ERRORS)
        except ChainRevert:
            return None
        term, commitment = await self._relayer.rpc(functions.getMembership(token_id).call(), MEMBERSHIP_ERRORS)
        if term == 0 and not any(commitment):
            return None
        return ChainMembership(token_id=token_id, term=term, commitment=HexBytes(commitment).to_0x_hex())


class Web3BudgetReader:
    """BudgetReader 구현. 발행·증액·회수는 두지 않았다 (호출자가 회장, docs/CHAIN_CLIENT.md §8)."""

    def __init__(self, relayer: Web3Relayer, address: str):
        self._relayer = relayer
        self._budgets = relayer.contract(address, "IBudgetToken", BUDGET_ERRORS)

    async def check(self) -> None:
        await self._relayer.check_contract(self._budgets)

    async def get_budget(self, budget_id: int) -> Optional[ChainBudget]:
        functions = self._budgets.web3.functions
        if not await self._relayer.rpc(functions.exists(budget_id).call(), BUDGET_ERRORS):
            return None
        term, category, issued, spent, expires_at, version = await self._relayer.rpc(
            functions.getBudget(budget_id).call(), BUDGET_ERRORS
        )
        return ChainBudget(
            id=budget_id, term=term, category=HexBytes(category).to_0x_hex(), issued=issued, spent=spent,
            expires_at=expires_at, version=version,
        )

    async def remaining(self, budget_id: int) -> Optional[int]:
        functions = self._budgets.web3.functions
        if not await self._relayer.rpc(functions.exists(budget_id).call(), BUDGET_ERRORS):
            return None
        return await self._relayer.rpc(functions.remaining(budget_id).call(), BUDGET_ERRORS)
