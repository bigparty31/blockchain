"""등록 릴레이 — 초안을 만들고, 총무 서명을 확인해 체인에 올리고, 결과를 모르는 제출을 마무리한다.

흐름과 상태는 docs/RELAY.md. 체인은 ChainClient 로, 저장은 DraftStore 로만 만난다.
"""
import time
from typing import Callable, Optional

from app.chain.client import ChainClient, RoleReader
from app.chain.models import ChainNotSent, ChainRevert, ChainUnavailable, RecordRequest, RevertReason, Role, TxResult, check_address
from app.relay.checks import RecoverSigner, check_deadline, check_role, check_signer
from app.relay.models import (
    ENTRY_ID_TAKEN,
    NOT_RECORDED_BY_DEADLINE,
    NOT_SENT,
    Draft,
    DraftStatus,
    RelayError,
    RelayErrorCode,
)
from app.relay.store import DraftStore
from app.schemas.entry import EntryKind


class RegistrationRelay:
    def __init__(
        self,
        chain: ChainClient,
        store: DraftStore,
        recover_signer: RecoverSigner,
        *,
        clock: Callable[[], float] = time.time,
        max_deadline_seconds: int = 600,
        deadline_margin_seconds: int = 120,
        roles: Optional[RoleReader] = None,
    ):
        self._chain = chain
        self._store = store
        self._recover_signer = recover_signer
        self._roles = roles  # 붙이면 총무 롤이 없는 서명을 체인에 보내기 전에 ROLE_MISSING 으로 막는다
        self._clock = clock
        self._max_deadline = max_deadline_seconds
        self._deadline_margin = deadline_margin_seconds

    async def open_draft(
        self,
        *,
        created_by: int,
        registrant: str,
        meta_hash: str,
        amount: int,
        kind: EntryKind,
        occurred_at: int,
        budget_id: Optional[int] = None,
        corrects_id: Optional[int] = None,
    ) -> Draft:
        """① 입력 검증·정규화·meta_hash 계산이 끝난 값으로 초안을 만들고 id 를 예약한다.

        budget_id·corrects_id 는 DB 처럼 없으면 None 으로 받는다 (체인에는 0, docs/HASHING.md §2.1).

        Raises:
            RelayError(INVALID_DRAFT): 체인에 올리면 revert 되거나 막힐 값. 번호를 받기 전에 막는다.
        """
        fields = {
            "hash": meta_hash,
            "amount": amount,
            "kind": kind,
            "occurred_at": occurred_at,
            "budget_id": budget_id or 0,
            "corrects_id": corrects_id or 0,
        }
        _check_draft(registrant, fields)
        draft = Draft(id=await self._store.reserve_id(), created_by=created_by, registrant=registrant, **fields)
        await self._store.add(draft)
        return draft

    async def submit(self, draft_id: int, *, meta_hash: str, deadline: int, signature: str) -> Draft:
        """③ 총무 서명을 확인하고 체인에 올린다. 결과가 반영된 초안을 돌려준다.

        같은 초안으로 다시 불려도 SUBMITTING·RECORDED 면 체인에 다시 보내지 않고 지금 상태를 돌려준다.
        돌려받은 status 가 SUBMITTING 이면 결과를 아직 모르는 것이다 — reconcile 이 마무리한다.

        Raises:
            RelayError: 체인에 보내기 전에 막혔다. 초안 상태는 그대로다.
            ChainUnavailable: 롤 조회를 붙였는데 읽지 못했다. 초안 상태는 그대로다.
        """
        draft = await self._get(draft_id)
        if draft.status in (DraftStatus.SUBMITTING, DraftStatus.RECORDED):
            return draft
        if draft.status == DraftStatus.DISCARDED:
            raise RelayError(RelayErrorCode.DRAFT_DISCARDED, f"id={draft_id}")
        request = self._check_submission(draft, meta_hash, deadline, signature)
        await check_role(self._roles, draft.registrant, (Role.TREASURER,))

        claimed = await self._store.transition(
            draft_id,
            (DraftStatus.DRAFT, DraftStatus.FAILED),
            {"status": DraftStatus.SUBMITTING, "deadline": deadline, "signature": signature.lower(), "fail_reason": None},
        )
        if claimed is None:
            return await self._get(draft_id)  # 같은 초안으로 동시에 들어온 다른 요청이 먼저 보냈다

        try:
            result = await self._chain.record_pending(request, signature)
        except ChainNotSent:
            return await self._fail(draft_id, NOT_SENT)  # 체인에 없는 것이 확정. 바로 다시 제출할 수 있다
        except ChainUnavailable:
            return claimed  # 들어갔는지 모른다. SUBMITTING 으로 두고 reconcile 이 마무리한다
        except ChainRevert as e:
            if e.reason != RevertReason.ENTRY_ALREADY_EXISTS:
                return await self._fail(draft_id, e.reason.value)
            try:
                return await self._settle(claimed) or claimed
            except ChainUnavailable:
                return claimed
        return await self._record(draft_id, result)

    async def reconcile(self) -> list[Draft]:
        """결과를 모르는 SUBMITTING 초안을 체인과 대조해 마무리한다. 주기적으로 부른다. 상태가 바뀐 초안을 돌려준다.

        체인에 있으면 RECORDED. 없는데 서명 시한 + 여유가 지났으면 FAILED — 시한이 지난 서명은 컨트랙트가
        거부하므로 앞으로도 들어갈 수 없다. 둘 다 아니면 다음 번에 다시 본다.
        """
        now = self._clock()
        changed = []
        for draft in await self._store.list_submitting():
            try:
                settled = await self._settle(draft)
            except ChainUnavailable:
                continue
            if settled is None and now > draft.deadline + self._deadline_margin:
                # 읽어 둔 제출 그대로일 때만 — 그사이 실패하고 새 서명으로 다시 제출됐으면 새 제출은 건드리지 않는다
                settled = await self._fail(draft.id, NOT_RECORDED_BY_DEADLINE, expected_signature=draft.signature)
            if settled is not None and settled.status != DraftStatus.SUBMITTING:
                changed.append(settled)
        return changed

    async def open_drafts(self, created_by: int) -> list[Draft]:
        """총무의 끝나지 않은 초안. 실패한 초안을 찾아 다시 서명하는 화면이 쓴다."""
        return await self._store.list_open(created_by)

    async def discard(self, draft_id: int, *, by_user: int) -> Draft:
        """DRAFT·FAILED 초안을 버린다. 체인에 들어갔을 수 있는 SUBMITTING 은 버릴 수 없다."""
        draft = await self._get(draft_id)
        if draft.created_by != by_user:
            raise RelayError(RelayErrorCode.NOT_OWNER, f"id={draft_id}")
        discarded = await self._store.transition(
            draft_id, (DraftStatus.DRAFT, DraftStatus.FAILED), {"status": DraftStatus.DISCARDED}
        )
        if discarded is None:
            current = await self._get(draft_id)
            raise RelayError(RelayErrorCode.CANNOT_DISCARD, f"status={current.status.value}")
        return discarded

    # ------------------------------------------------------------ 내부

    def _check_submission(self, draft: Draft, meta_hash: str, deadline: int, signature: str) -> RecordRequest:
        if meta_hash != draft.hash:
            raise RelayError(RelayErrorCode.HASH_MISMATCH, f"server={draft.hash} app={meta_hash}")
        check_deadline(self._clock(), deadline, self._max_deadline)
        request = draft.record_request(deadline)
        check_signer(self._recover_signer, request, signature, draft.registrant)
        return request

    async def _settle(self, draft: Draft) -> Optional[Draft]:
        """체인에 이 id 가 있으면 초안을 마무리한다. 체인에 없으면 None."""
        entry = await self._chain.get_entry(draft.id)
        if entry is None:
            return None
        if entry.hash != draft.hash or entry.registrant.lower() != draft.registrant.lower():
            return await self._fail(draft.id, ENTRY_ID_TAKEN)
        result = await self._chain.get_record_result(draft.id)
        if result is None:
            return draft  # 항목은 있는데 이벤트가 아직 안 읽힌다. 다음 번에 다시 본다
        return await self._record(draft.id, result)

    async def _record(self, draft_id: int, result: TxResult) -> Draft:
        recorded = await self._store.record(draft_id, result.status, result.block_reason, result.tx_hash)
        return recorded or await self._get(draft_id)

    async def _fail(self, draft_id: int, reason: str, *, expected_signature: Optional[str] = None) -> Draft:
        failed = await self._store.transition(
            draft_id,
            (DraftStatus.SUBMITTING,),
            {"status": DraftStatus.FAILED, "fail_reason": reason},
            expected_signature=expected_signature,
        )
        return failed or await self._get(draft_id)

    async def _get(self, draft_id: int) -> Draft:
        draft = await self._store.get(draft_id)
        if draft is None:
            raise RelayError(RelayErrorCode.DRAFT_NOT_FOUND, f"id={draft_id}")
        return draft


def _check_draft(registrant: str, fields: dict) -> None:
    try:
        check_address(registrant)
        RecordRequest(id=1, deadline=0, **fields)  # 해시 형식·KST 자정 등 모델 규칙
    except ValueError as e:
        raise RelayError(RelayErrorCode.INVALID_DRAFT, str(e)) from e

    if fields["amount"] == 0:
        problem = "금액이 0 이다"
    elif fields["amount"] < 0 and not fields["corrects_id"]:
        problem = "음수 금액은 정정 항목만 된다"
    elif fields["kind"] == EntryKind.EXPENSE and not fields["budget_id"]:
        problem = "지출에는 예산이 있어야 한다"  # 체인에 올리면 BLOCKED(BUDGET_NOT_FOUND)
    elif fields["kind"] == EntryKind.INCOME and fields["budget_id"]:
        problem = "수입에는 예산을 붙이지 않는다"
    else:
        return
    raise RelayError(RelayErrorCode.INVALID_DRAFT, problem)
