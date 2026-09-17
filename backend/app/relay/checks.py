"""등록·확정·반려 릴레이가 체인에 보내기 전에 똑같이 하는 확인."""
from typing import Any, Optional

from app.chain.client import RoleReader
from app.chain.eip712 import RecoverSigner
from app.chain.models import Role
from app.relay.models import RelayError, RelayErrorCode


def check_deadline(now: float, deadline: int, max_seconds: int) -> None:
    if not now < deadline <= now + max_seconds:
        raise RelayError(RelayErrorCode.INVALID_DEADLINE, f"deadline={deadline} now={int(now)} max={max_seconds}s")


def check_signer(recover: RecoverSigner, struct: Any, signature: str, expected: str) -> None:
    """서버가 만든 struct 로 서명자를 복구해 expected 와 비교한다. 앱이 한 필드라도 다르게 서명했으면 다른 주소가 나온다."""
    try:
        signer = recover(struct, signature)
    except ValueError as e:
        raise RelayError(RelayErrorCode.INVALID_SIGNATURE, str(e)) from e
    if signer.lower() != expected.lower():
        raise RelayError(RelayErrorCode.SIGNER_MISMATCH, f"expected={expected} recovered={signer}")


async def check_role(roles: Optional[RoleReader], account: str, allowed: tuple[Role, ...]) -> None:
    """롤 조회가 붙어 있으면 account 가 allowed 중 하나를 갖는지 본다. 없으면 체인의 NotRegistrant·NotApprover 에 맡긴다.

    Raises:
        RelayError(ROLE_MISSING)
        ChainUnavailable: 롤을 읽지 못했다. 아무것도 바꾸지 않았다.
    """
    if roles is None:
        return
    for role in allowed:
        if await roles.has_role(role, account):
            return
    raise RelayError(RelayErrorCode.ROLE_MISSING, f"{account} 에 {'/'.join(r.value for r in allowed)} 롤이 없다")
