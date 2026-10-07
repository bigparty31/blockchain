"""관문 2 스모크 — 서명 → 릴레이 → 체인 기록을 실제로 해 보고 판정한다.

    cd backend && .venv/bin/python -m scripts.relayer_smoke

로컬 Hardhat 노드에 배포가 끝나 있어야 한다. 실행할 때마다 체인에 항목 2개를 실제로 남긴다 — 수입(PENDING 으로 등록한 뒤
감사가 확정해 CONFIRMED)과 예산 없는 지출(BLOCKED, BUDGET_NOT_FOUND). id 는 등록 API 가 쓰는 DB id(1부터)와 겹치지 않는
예약 구간이고 실행마다 다르다. 노드를 재시작하면 사라진다.

이 스크립트는 총무·감사 키로 EIP-712 서명하는 "앱 역할" 을 한다. 서버는 임원 키를 갖지 않으므로(PRD §9.2) app/ 밖에 두고,
로컬 체인(31337)에서만 동작한다. 서버 쪽은 등록·승인 API 와 같은 순서로 간다 — 앱 서명 → 서명자의 롤 대조 →
record_pending / confirm_entry (CHAIN_CLIENT §1 ③, §4). 롤은 체인의 RoleManager 로 확인하고, 맞지 않으면 보내지 않는다.
확정 서명의 entryCommit 은 앱처럼 체인에 등록된 값(get_entry)으로 계산한다 (CHAIN_CLIENT §5).
체인 상태(롤·nonce·잔액·시각)는 검사 대상인 클라이언트와 별도 연결로 읽는다.
기록할 값은 docs/hashing_vectors.json 의 meta_hash 벡터라, 체인에 해시 규칙(HASHING.md)대로 계산된 값이 남는다.
예산을 발행한 뒤의 지출(PENDING)은 하지 않는다 — BudgetToken 릴레이는 이번 범위가 아니고, 공용 개발 노드에 예산을 발행하면
"학기·항목당 예산 하나" 규칙 때문에 예산 편성 화면이 막힌다.
"""
import asyncio
import json
import os
import sys
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import aiohttp
from web3 import AsyncHTTPProvider, AsyncWeb3

from app.chain import ChainEntry, ChainError, ChainRevert, RecordRequest, RevertReason
from app.chain.deployment import Deployment, deployment_path, load_abi, load_deployment
from app.chain.models import ZERO_ADDRESS, BlockReason
from app.chain.web3_client import LEDGER, ROLE_MANAGER, RPC_TIMEOUT_SECONDS, Web3ChainClient
from app.schemas.entry import EntryKind, EntryStatus
from scripts.local_chain import (
    AUDITOR_INDEX,
    LOCAL_CHAIN_ID,
    LOCAL_RPC_URL,
    RELAYER_INDEX,
    TREASURER_INDEX,
    approval_from_entry,
    chain_now,
    hardhat_key,
    sign_as_app,
)

# 등록 API 는 DB id 를 1부터 쓴다. 그 범위와 겹치지 않게 8000억에 실행 시각(밀리초) × 10 을 더한다 (지금은 18조대).
# 실행마다 다르고, 체인 테스트의 스냅샷 구간(chain_support.TEST_ID_BASE, 9000억대)과도 겹치지 않는다
SMOKE_BASE_ID = 800_000_000_000
TERM = 20262  # 벡터의 사용일(2026년 9월)이 속한 학기
DEADLINE_SECONDS = 600  # 발급 + 10분 (API.md §2.3). 기준은 체인 시각이다

VECTORS = Path(__file__).resolve().parents[2] / "docs" / "hashing_vectors.json"


@dataclass(frozen=True)
class SmokeCase:
    vector: str
    kind: EntryKind
    offset: int  # base id 에 더하는 값
    expected: tuple  # (status, block_reason)
    try_duplicate: bool
    confirm: bool  # 등록 뒤 감사가 확정한다 (PENDING → CONFIRMED)


CASES = (
    SmokeCase("income_without_receipt", EntryKind.INCOME, 1, (EntryStatus.PENDING, None), try_duplicate=True, confirm=True),
    SmokeCase(
        "expense_with_receipt",
        EntryKind.EXPENSE,
        2,
        (EntryStatus.BLOCKED, BlockReason.BUDGET_NOT_FOUND),
        try_duplicate=False,
        confirm=False,
    ),
)


def smoke_base_id(now_ns: int) -> int:
    """이번 실행의 id 기준 (실행 시각, 나노초). 항목 id 는 이 값 + offset 이다. 밀리초가 다르면 겹치지 않는다."""
    return SMOKE_BASE_ID + (now_ns // 1_000_000) * 10


def load_vectors(names) -> dict:
    """이름 → meta_hash 벡터. 파일은 한 번만 읽는다. 없는 이름은 무엇이 없는지 알려 준다."""
    names = list(names)  # 두 번 훑는다 — 제너레이터가 들어와도 비지 않게
    vectors = {v["name"]: v for v in json.loads(VECTORS.read_text(encoding="utf-8"))["meta_hash"]}
    missing = [name for name in names if name not in vectors]
    if missing:
        raise ValueError(f"{VECTORS.name} 에 meta_hash 벡터가 없다: {', '.join(missing)}")
    return {name: vectors[name] for name in names}


# ---------------------------------------------------------------- 체인 보기 (검사 대상과 별도 연결)


@dataclass
class ChainView:
    """체인 상태를 읽는 연결. 검사 대상인 클라이언트의 내부를 들여다보지 않고 따로 읽는다."""

    w3: AsyncWeb3
    deployment: Deployment
    role_manager: object

    @classmethod
    def open(cls, rpc_url: str, deployment: Deployment, deployment_file: Path) -> "ChainView":
        # 검사 대상 클라이언트와 같은 연결 설정 — 노드가 응답하지 않으면 오래 멈추지 않고 바로 실패한다
        w3 = AsyncWeb3(
            AsyncHTTPProvider(
                rpc_url,
                request_kwargs={"timeout": aiohttp.ClientTimeout(total=RPC_TIMEOUT_SECONDS)},
                exception_retry_configuration=None,
            )
        )
        contract = deployment.contracts[ROLE_MANAGER]
        role_manager = w3.eth.contract(
            address=AsyncWeb3.to_checksum_address(contract.address), abi=load_abi(contract, deployment_file)
        )
        return cls(w3, deployment, role_manager)

    async def is_treasurer(self, address: str) -> bool:
        functions = self.role_manager.functions
        return await functions.hasRole(await functions.TREASURER().call(), address).call()

    async def is_approver(self, address: str) -> bool:
        # 원장의 _requireApprover 와 같은 기준: roleOf 가 감사 또는 회장 (PRD §3 "회장도 감사와 같은 승인 권한").
        # RoleManager.isGovernor 는 지금 같은 집합이지만 "롤 변경 서명 자격" 이라 쓰지 않는다 — 확인할 것은 원장 규칙이다
        functions = self.role_manager.functions
        return await functions.roleOf(address).call() in {await functions.AUDITOR().call(), await functions.PRESIDENT().call()}

    async def nonce(self, address: str) -> int:
        return await self.w3.eth.get_transaction_count(address, "latest")

    async def close(self) -> None:
        await self.w3.provider.disconnect()


# ---------------------------------------------------------------- 보고서


@dataclass
class Check:
    label: str
    ok: bool
    detail: str = ""


@dataclass
class Case:
    title: str
    checks: list = field(default_factory=list)

    def check(self, label: str, ok: bool, detail: str = "") -> bool:
        self.checks.append(Check(label, ok, detail))
        return ok

    def failed(self, label: str, error: BaseException) -> None:
        self.check(label, False, f"{type(error).__name__}: {error}")


@dataclass
class SmokeReport:
    header: str
    cases: list = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return bool(self.cases) and all(c.ok for case in self.cases for c in case.checks)

    def render(self, marks: tuple = ("✅", "❌")) -> str:
        ok_mark, fail_mark = marks
        lines = [self.header, ""]
        for case in self.cases:
            lines.append(case.title)
            lines += [f"  {ok_mark if c.ok else fail_mark} {c.label}" + (f"  {c.detail}" if c.detail else "") for c in case.checks]
        lines.append("")
        if self.passed:
            lines.append("관문 2·확정 통과: 서명 → 릴레이 → 체인 기록 (수입 PENDING → CONFIRMED 1건, 지출 BLOCKED 1건)")
        else:
            lines.append(f"관문 2 실패: {fail_mark} 단계를 확인한다")
        return "\n".join(lines)


def marks_for(encoding: Optional[str]) -> tuple:
    """출력 인코딩에 맞는 표시. 한국어 Windows 의 cp949 는 이모지를 담지 못해, 파일로 보내면 print 가 죽는다.
    보고서 문장도 cp949 에 있는 문자만 쓴다 (줄표 — 대신 : 를 쓰는 이유)."""
    try:
        "✅❌".encode(encoding or "utf-8")
    except (UnicodeEncodeError, LookupError):
        return ("O", "X")
    return ("✅", "❌")


# ---------------------------------------------------------------- 판정


async def _record_case(
    client: Web3ChainClient, chain: ChainView, treasurer_key: str, case: Case, request: RecordRequest, spec: SmokeCase
) -> Optional[ChainEntry]:
    """등록 단계. 체인에서 다시 읽은 항목을 돌려준다 (확정 단계가 이 값으로 entryCommit 을 계산한다). 못 읽었으면 None."""
    signature = sign_as_app(request, chain.deployment.eip712[LEDGER], treasurer_key)

    # 등록 API 처럼 보내기 전에 서명자를 대조한다. 기준은 서명한 키가 아니라 체인의 총무 롤이다
    try:
        signer = client.signer_of(request, signature)
        is_treasurer = await chain.is_treasurer(signer)
    except Exception as e:  # 판정 도구라 어떤 실패든 보고서에 남긴다
        case.failed("앱 서명 → 서명자가 체인의 총무", e)
        return None
    if not case.check("앱 서명 → 서명자가 체인의 총무", is_treasurer, signer if is_treasurer else f"{signer} 는 총무가 아니라 보내지 않았다"):
        return None

    claimed = []

    async def before_broadcast(tx_hash: str) -> None:
        claimed.append(tx_hash)  # 등록 API 라면 여기서 tx_pending 을 선점한다

    try:
        result = await client.record_pending(request, signature, before_broadcast)
    except Exception as e:
        case.failed("릴레이", e)
        return None
    status = result.status.value + (f"({result.block_reason.value})" if result.block_reason else "")
    case.check(f"릴레이 → {status}", (result.status, result.block_reason) == spec.expected, f"tx {result.tx_hash}")
    case.check("before_broadcast hash = 결과 hash", claimed == [result.tx_hash])

    try:
        entry = await client.get_entry(request.id)
    except Exception as e:
        case.failed("체인에서 다시 읽음", e)
        return None
    signed = {
        "hash": request.hash,
        "amount": request.amount,
        "kind": request.kind,
        "status": spec.expected[0],
        "term": request.term,
        "occurred_at": request.occurred_at,
        "budget_id": request.budget_id,
        "corrects_id": request.corrects_id,
        "registrant": signer,
        "approver": ZERO_ADDRESS,
    }
    on_chain = None if entry is None else {key: getattr(entry, key) for key in signed}
    mismatched = [] if on_chain is None else [key for key in signed if on_chain[key] != signed[key]]
    case.check(
        "체인에서 다시 읽음 → 10개 필드 일치",
        on_chain is not None and not mismatched,
        "체인에 없음" if on_chain is None else ", ".join(mismatched),
    )

    if spec.try_duplicate:
        # 같은 요청을 다시 보내면 시뮬레이션에서 걸려 보내지 않는다 (중복 등록 방지, 가스 0)
        label = "같은 요청 재전송 → ENTRY_ALREADY_EXISTS (nonce 그대로)"
        try:
            before = await chain.nonce(client.relayer_address)
            try:
                await client.record_pending(request, signature)
                reason = None
            except ChainRevert as e:
                reason = e.reason
            after = await chain.nonce(client.relayer_address)
        except Exception as e:
            case.failed(label, e)
            return entry
        case.check(
            label,
            reason is RevertReason.ENTRY_ALREADY_EXISTS and after == before,
            "" if reason is RevertReason.ENTRY_ALREADY_EXISTS else f"결과 {reason}",
        )
    return entry


async def _confirm_case(
    client: Web3ChainClient, chain: ChainView, approver_key: str, case: Case, entry: ChainEntry, deadline: int
) -> None:
    """확정 단계 (10/4 "confirmEntry 1건"). 승인 API 처럼 서명자가 체인의 감사·회장인지 대조한 뒤 보낸다."""
    # 앱(감사 기기)은 체인에 등록된 값으로 entryCommit 을 계산해 서명한다. 서버는 미리 대조하지 않는다 (CHAIN_CLIENT §5)
    approval = approval_from_entry(entry, deadline)
    signature = sign_as_app(approval, chain.deployment.eip712[LEDGER], approver_key)

    label = "확정 서명 → 서명자가 체인의 감사·회장"
    try:
        signer = client.signer_of(approval, signature)
        is_approver = await chain.is_approver(signer)
    except Exception as e:
        case.failed(label, e)
        return
    if not case.check(label, is_approver, signer if is_approver else f"{signer} 는 감사·회장이 아니라 보내지 않았다"):
        return

    claimed = []

    async def before_broadcast(tx_hash: str) -> None:
        claimed.append(tx_hash)  # 승인 API 라면 여기서 tx_confirm 을 선점한다

    try:
        result = await client.confirm_entry(approval, signature, before_broadcast)
    except Exception as e:
        case.failed("확정 릴레이", e)
        return
    case.check(f"확정 릴레이 → {result.status.value}", result.status is EntryStatus.CONFIRMED, f"tx {result.tx_hash}")
    case.check("확정 before_broadcast hash = 결과 hash", claimed == [result.tx_hash])

    label = "체인에서 다시 읽음 → CONFIRMED, 승인자 = 서명자"
    try:
        confirmed = await client.get_entry(entry.id)
    except Exception as e:
        case.failed(label, e)
        return
    if confirmed is None:
        case.check(label, False, "체인에 없음")
        return
    seen = (confirmed.status, confirmed.approver)
    case.check(label, seen == (EntryStatus.CONFIRMED, signer), "" if seen == (EntryStatus.CONFIRMED, signer) else f"{seen[0].value}, {seen[1]}")


async def run_smoke(
    client: Web3ChainClient, chain: ChainView, treasurer_key: str, approver_key: str, base_id: int
) -> SmokeReport:
    """관문 2·확정 판정. 실제 실행(main)과 테스트(스냅샷 안)가 같이 쓴다. 등록은 treasurer_key, 확정은 approver_key 로 서명한다.

    항목 단계(서명·릴레이·다시 읽기·재전송·확정)의 실패는 보고서에 남기고 다음 항목을 계속한다.
    확정은 등록 단계가 모두 통과했을 때만 한다 — 등록이 어긋난 항목을 확정하면 그 여파의 실패가 원인을 가린다.
    준비 단계(벡터·잔액·체인 시각)의 실패는 예외로 올라가고, main 이 "관문 2 실패" 로 알린다.
    """
    vectors = load_vectors(spec.vector for spec in CASES)
    balance = await chain.w3.eth.get_balance(client.relayer_address)
    report = SmokeReport(
        f"관문 2 스모크: chainId {chain.deployment.chain_id}, 릴레이어 {client.relayer_address} (잔액 {balance / 10**18:,.4f} ETH)"
    )
    deadline = await chain_now(chain.w3) + DEADLINE_SECONDS

    for spec in CASES:
        values = vectors[spec.vector]["input"]
        request = RecordRequest(
            id=base_id + spec.offset,
            hash=vectors[spec.vector]["expected"],
            amount=values["amount"],
            kind=spec.kind,
            term=TERM,
            occurred_at=values["occurred_at"],
            budget_id=0,
            corrects_id=0,
            deadline=deadline,
        )
        label = "[수입]" if spec.kind is EntryKind.INCOME else "[지출]"
        budget = "" if spec.kind is EntryKind.INCOME else ", 예산 0"
        then = ", 감사 확정" if spec.confirm else ""
        case = Case(f"{label} id={request.id}  {spec.vector}  {values['amount']:,}원{budget}{then}")
        report.cases.append(case)
        entry = await _record_case(client, chain, treasurer_key, case, request, spec)
        if spec.confirm and entry is not None and all(c.ok for c in case.checks):
            await _confirm_case(client, chain, approver_key, case, entry, deadline)
    return report


# ---------------------------------------------------------------- 실행


def local_only_problem(deployment: Deployment) -> str:
    """로컬 체인의 배포 기록이 아니면 이유를 돌려준다. 총무·감사 키(Hardhat 공개 키)로 서명하니 로컬에서만 돈다."""
    if deployment.chain_id != LOCAL_CHAIN_ID:
        return f"로컬 체인({LOCAL_CHAIN_ID})이 아니다 (chainId {deployment.chain_id}). 이 스크립트는 로컬에서만 돈다"
    return ""


async def main() -> int:
    # 설정은 환경변수에서 읽기만 한다(CHAIN_CLIENT §8). 비어 있으면 로컬 기본값. 프로세스 환경은 바꾸지 않는다
    rpc_url = os.environ.get("CHAIN_RPC_URL") or LOCAL_RPC_URL
    relayer_key = os.environ.get("RELAYER_PRIVATE_KEY") or hardhat_key(RELAYER_INDEX)
    marks = marks_for(getattr(sys.stdout, "encoding", None))
    if hasattr(sys.stdout, "reconfigure"):
        # 표시 기호는 인코딩에 맞췄지만, 노드·예외 메시지에 담기지 않는 문자가 섞여도 출력 때문에 죽지 않게 한다
        sys.stdout.reconfigure(errors="replace")
    path = deployment_path()
    try:
        deployment = load_deployment(path)
    except ChainError as e:
        print(f"관문 2 실패: 배포 기록을 읽지 못했다 ({e})")
        return 1
    problem = local_only_problem(deployment)
    if problem:
        print(f"관문 2 실패: {problem}")
        return 1
    try:
        client = await Web3ChainClient.connect(rpc_url, relayer_key, path)
    except ChainError as e:
        print(f"관문 2 실패: 체인에 연결하지 못했다 ({e})")
        return 1
    chain = None
    try:
        chain = ChainView.open(rpc_url, deployment, path)
        report = await run_smoke(
            client, chain, hardhat_key(TREASURER_INDEX), hardhat_key(AUDITOR_INDEX), smoke_base_id(time.time_ns())
        )
    except Exception as e:  # 판정 도구라 traceback 대신 결론을 먼저 알리고, 원인은 stderr 에 남긴다
        print(f"관문 2 실패: 판정 중 오류 ({type(e).__name__}: {e})")
        traceback.print_exc()
        return 1
    finally:
        if chain is not None:
            await chain.close()
        await client.close()
    print(report.render(marks))
    return 0 if report.passed else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
