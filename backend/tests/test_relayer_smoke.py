"""관문 2 스모크 스크립트(scripts/relayer_smoke.py)가 제대로 판정하는지 확인한다.

실제 실행(main)은 체인에 기록을 남기니 노드 테스트에서는 판정 로직(run_smoke)을 evm_snapshot 안에서 돌린다.
"""
import asyncio
import io
import os
import time
from contextlib import redirect_stdout
from types import SimpleNamespace

import pytest

import re

from app.chain import ChainEntry, ChainRevert, ChainUnavailable, RevertReason, TxResult, eip712
from app.chain.deployment import DEFAULT_PATH, load_deployment
from app.chain.models import (
    UINT64_MAX,
    ZERO_ADDRESS,
    BlockReason,
    BudgetRevertReason,
    BudgetTxResult,
    ChainBudget,
    EntryTxDetail,
)
from app.chain.provider import reset_chain_client
from app.chain.web3_client import BUDGET_TOKEN, LEDGER, Web3ChainClient
from app.schemas.entry import EntryKind, EntryStatus
from chain_support import (
    AUDITOR,
    AUDITOR_KEY,
    PRESIDENT,
    PRESIDENT_KEY,
    RELAYER,
    RELAYER_KEY,
    RPC_URL,
    TEST_ID_BASE,
    TREASURER_KEY,
    deployment_variant,
    in_snapshot,
)
from scripts import relayer_smoke
from scripts.relayer_smoke import (
    SMOKE_BASE_ID,
    ChainView,
    load_vectors,
    local_only_problem,
    marks_for,
    run_smoke,
    smoke_base_id,
)


@pytest.fixture(autouse=True)
def isolated(clean_chain_env):
    reset_chain_client()
    yield
    reset_chain_client()


def smoke_and_count(signing_key: str, auditor_key: str = AUDITOR_KEY, **keys):
    """스냅샷 안에서 판정하고 (보고서, 릴레이어가 보낸 트랜잭션 수) 를 돌려준다. keys 는 president_key."""

    async def run():
        client = await Web3ChainClient.connect(RPC_URL, RELAYER_KEY, DEFAULT_PATH)
        chain = ChainView.open(RPC_URL, load_deployment(DEFAULT_PATH), DEFAULT_PATH)

        async def body():
            before = await chain.nonce(RELAYER)
            report = await run_smoke(client, chain, signing_key, auditor_key, smoke_base_id(time.time_ns()), **keys)
            return report, await chain.nonce(RELAYER) - before

        try:
            return await in_snapshot(chain.w3, body)
        finally:
            await chain.close()
            await client.close()

    return asyncio.run(run())


def smoke(signing_key: str, auditor_key: str = AUDITOR_KEY, **keys):
    return smoke_and_count(signing_key, auditor_key, **keys)[0]


ENTRY_TITLES = ("[수입]", "[지출]")
PASSED = "관문 2 통과: 서명 → 릴레이 → 체인 기록 (수입 확정 1건, 지출 BLOCKED 1건, 반려 1건, 예산 발행 → 지출 확정 → BLOCKED → 증액 → 재등록 확정)"
# 통과한 실행의 단계 순서: 수입(확정), 지출 BLOCKED, 반려, 예산 발행 → 예산 안 지출(확정) → 초과 BLOCKED → 증액 → 재등록(확정)
STEPS = ["수입", "지출", "수입", "예산 발행", "지출", "지출", "예산 증액", "지출"]


def kinds(report) -> list:
    return [re.match(r"\[([^\]]+)\]", case.title).group(1) for case in report.cases]


def relays(report) -> list:
    """보고서가 판정한 전송 (라벨이 「… 릴레이 → 결과」). 같은 요청·같은 증액의 재전송 확인은 보내지 않아 들어가지 않는다."""
    return [c.label for case in report.cases for c in case.checks if "릴레이 →" in c.label]


@pytest.mark.chain
def test_smoke_passes_on_the_local_chain(node):
    report, sent = smoke_and_count(TREASURER_KEY)
    assert report.passed, report.render()
    assert kinds(report) == STEPS
    # 릴레이어가 보낸 트랜잭션 = 보고서가 판정한 전송. 재전송 확인(등록·증액)은 시뮬레이션에서 걸려 보내지 않는다
    assert sent == len(relays(report)), relays(report)
    assert all("재전송" not in label for label in relays(report))
    assert report.render().endswith(PASSED)


@pytest.mark.chain
@pytest.mark.parametrize("approver_key, approver", [(AUDITOR_KEY, AUDITOR), (PRESIDENT_KEY, PRESIDENT)])
def test_confirmation_shows_the_signer_as_approver(node, approver_key, approver):
    # 회장도 감사와 같은 승인 권한이다 (PRD §3). 확정 단계 라벨은 등록 단계와 겹치지 않는다.
    # 같은 키가 증액 승인에도 쓰이는데 증액 승인은 감사만 할 수 있다 — 회장 키면 그 단계만 ❌ 다
    # (test_increase_approver_must_be_an_auditor). 여기서는 확정 단계만 본다
    report = smoke(TREASURER_KEY, approver_key)
    income = report.cases[0]
    assert income.ok, report.render()
    assert [c.label for c in income.checks[5:]] == [
        "확정 서명 → 서명자가 체인의 감사·회장",
        "확정 릴레이 → CONFIRMED",
        "확정 before_broadcast hash = 결과 hash",
        "체인에서 다시 읽음 → CONFIRMED, 승인자 = 서명자",
    ]
    assert income.checks[5].detail == approver
    assert len({c.label for c in income.checks}) == len(income.checks)


@pytest.mark.chain
def test_approver_without_the_role_is_caught_before_confirming(node):
    # 승인 API 처럼 확정 서명자를 체인의 감사·회장 롤과 대조한다. 총무가 확정 서명을 하면 ❌ 이고 확정은 보내지 않는다
    report, sent = smoke_and_count(TREASURER_KEY, auditor_key=TREASURER_KEY)
    assert not report.passed
    income, _, rejected, issued, spent = report.cases
    assert all(c.ok for c in income.checks[:5]) and len(income.checks) == 6
    assert "감사·회장이 아니라 보내지 않았다" in income.checks[5].detail
    # 반려도 같은 기준이다. 예산 경로는 첫 지출의 확정이 막힌 곳에서 멈춘다 — 잔량이 어긋난 채 다음 단계로 가지 않는다
    assert rejected.checks[-1].label == "반려 서명 → 서명자가 체인의 감사·회장" and not rejected.checks[-1].ok
    assert issued.ok and not spent.ok and "감사·회장이 아니라 보내지 않았다" in spent.checks[-1].detail
    assert sent == 5  # 등록 네 건(수입·지출·반려 대상·예산 안 지출)과 예산 발행만
    assert report.render().endswith("관문 2 실패: ❌ 단계를 확인한다")


@pytest.mark.chain
def test_signer_without_the_treasurer_role_is_caught_before_sending(node):
    # 서명자는 서명한 키가 아니라 체인의 총무 롤과 대조한다. 총무가 아니면 ❌ 이고 보내지 않는다 (등록 API 와 같다)
    report, sent = smoke_and_count(RELAYER_KEY)
    assert not report.passed
    entries = [case for case in report.cases if case.title.startswith(ENTRY_TITLES)]
    assert len(entries) == 4  # 수입·지출·반려 대상, 그리고 예산 경로의 첫 지출에서 멈췄다
    for case in entries:
        assert len(case.checks) == 1 and not case.checks[0].ok
        assert "서명자가 체인의 총무" in case.checks[0].label and "총무가 아니라 보내지 않았다" in case.checks[0].detail
    # 예산 발행은 회장 서명이라 나간다. 총무 서명이 틀린 등록은 하나도 보내지 않았다
    assert [case.title.startswith("[예산 발행]") and case.ok for case in report.cases].count(True) == 1
    assert sent == 1
    assert report.render().endswith("관문 2 실패: ❌ 단계를 확인한다")


def test_ids_stay_out_of_the_database_range_and_differ_within_a_second():
    # 등록 API 는 DB id 를 1부터 쓴다. 같은 초에 두 번 돌려도 id 가 달라야 재실행이 거짓 실패하지 않는다
    now = time.time_ns()
    first, second = smoke_base_id(now), smoke_base_id(now + 1_000_000)  # 1밀리초 뒤
    assert SMOKE_BASE_ID < first < second and second + 2 <= UINT64_MAX
    # 체인 테스트의 스냅샷 구간(9000억대)과도 떨어져 있다 — 스모크 기록은 공용 노드에 남는다
    assert first > TEST_ID_BASE + 10**9


def test_missing_vector_is_named():
    with pytest.raises(ValueError, match="meta_hash 벡터가 없다: renamed_vector"):
        load_vectors(["income_without_receipt", "renamed_vector"])


@pytest.mark.parametrize("encoding, expected", [("utf-8", ("✅", "❌")), ("cp949", ("O", "X")), (None, ("✅", "❌"))])
def test_marks_fit_the_output_encoding(encoding, expected):
    # 한국어 Windows 에서 파일로 보내면 stdout 이 cp949 라 이모지에서 print 가 죽는다 (체인에 이미 기록한 뒤에)
    assert marks_for(encoding) == expected


@pytest.mark.chain
def test_real_report_is_encodable_in_cp949(node):
    # 표시 기호뿐 아니라 보고서 문장(머리말·항목·결론)도 cp949 로 담겨야 한다. 통과·실패 보고서 둘 다
    for key, approver in ((TREASURER_KEY, AUDITOR_KEY), (RELAYER_KEY, AUDITOR_KEY), (TREASURER_KEY, TREASURER_KEY)):
        smoke(key, approver).render(marks_for("cp949")).encode("cp949")


def test_only_a_local_deployment_is_accepted(tmp_path):
    def change(raw):
        raw["chainId"] = 80002
        for domain in raw["eip712"].values():
            domain["chainId"] = 80002

    remote = load_deployment(deployment_variant(tmp_path, change))
    assert "로컬 체인(31337)이 아니다" in local_only_problem(remote)
    assert local_only_problem(load_deployment(DEFAULT_PATH)) == ""


def test_main_refuses_a_remote_deployment_without_connecting(tmp_path, monkeypatch):
    # 총무 키(공개된 Hardhat 키)로 서명하니 로컬이 아니면 연결 전에 멈춘다. 환경변수도 바꾸지 않는다
    def change(raw):
        raw["chainId"] = 80002
        for domain in raw["eip712"].values():
            domain["chainId"] = 80002

    monkeypatch.setenv("DEPLOYMENTS_FILE", str(deployment_variant(tmp_path, change)))

    async def must_not_connect(*args, **kwargs):
        raise AssertionError("로컬이 아닌데 연결했다")

    monkeypatch.setattr(Web3ChainClient, "connect", must_not_connect)
    out = io.StringIO()
    with redirect_stdout(out):
        assert asyncio.run(relayer_smoke.main()) == 1
    assert "관문 2 실패: 로컬 체인(31337)이 아니다" in out.getvalue()
    assert "CHAIN_RPC_URL" not in os.environ and "RELAYER_PRIVATE_KEY" not in os.environ


def _stub_chain(approver: bool = True):
    """run_smoke 가 읽는 체인 보기의 가짜. 노드 없이 판정 흐름만 본다. 체인 시각은 1_800_000_000 이다."""

    async def balance(address):
        return 10**18

    async def block(identifier):
        return {"timestamp": 1_800_000_000}

    class Chain:
        deployment = load_deployment(DEFAULT_PATH)
        w3 = SimpleNamespace(eth=SimpleNamespace(get_balance=balance, get_block=block))

        async def is_treasurer(self, address):
            return True

        async def is_approver(self, address):
            return approver

        async def is_president(self, address):
            return True

        async def is_auditor(self, address):
            return True

        async def nonce(self, address):
            return 0

    return Chain()


class _RecordingClient:
    """체인처럼 기록하고 다시 읽어 주는 가짜 클라이언트. 스모크가 부르는 릴레이(등록·확정·반려·예산 발행·증액)와 조회를 모두 흉내 낸다.

    규칙은 컨트랙트와 같게 둔다: 예산 없는 지출은 BLOCKED(BUDGET_NOT_FOUND), 잔량을 넘는 지출은 BLOCKED(BUDGET_EXCEEDED),
    확정한 지출은 잔량을 줄이고, 증액은 서명한 version 이 지금 version 과 같을 때만 들어간다. results 로 종류별 등록 결과를,
    confirm_error 로 확정 실패를 바꿔 본다. 부른 횟수는 calls 에 남는다.
    """

    relayer_address = RELAYER

    def __init__(self, results=None, confirm_error=None):
        deployment = load_deployment(DEFAULT_PATH)
        self.domains = {LEDGER: deployment.eip712[LEDGER], BUDGET_TOKEN: deployment.eip712[BUDGET_TOKEN]}
        self.results = results or {}
        self.confirm_error = confirm_error
        self.recorded = {}
        self.budgets = {}
        self.reasons = {}  # tx hash → 반려 사유 해시
        self.calls = {}
        self._tx = 0

    @property
    def confirm_calls(self):
        return self.calls.get("confirm_entry", 0)

    def _call(self, name):
        self.calls[name] = self.calls.get(name, 0) + 1
        self._tx += 1
        return f"0x{self._tx:064x}"

    def signer_of(self, payload, signature):
        domain = self.domains[BUDGET_TOKEN if isinstance(payload, eip712.BUDGET_PAYLOADS) else LEDGER]
        return eip712.recover_signer(eip712.typed_data_for(payload, domain), signature)

    def _judge(self, request):
        if request.kind in self.results:
            return self.results[request.kind]
        if request.kind is EntryKind.INCOME:
            return EntryStatus.PENDING, None
        budget = self.budgets.get(request.budget_id)
        if budget is None:
            return EntryStatus.BLOCKED, BlockReason.BUDGET_NOT_FOUND
        if budget.remaining < request.amount:
            return EntryStatus.BLOCKED, BlockReason.BUDGET_EXCEEDED
        return EntryStatus.PENDING, None

    async def record_pending(self, request, signature, before_broadcast=None):
        if request.id in self.recorded:
            raise ChainRevert(RevertReason.ENTRY_ALREADY_EXISTS, f"id={request.id}")
        status, block_reason = self._judge(request)
        tx = self._call("record_pending")
        if before_broadcast:
            await before_broadcast(tx)
        self.recorded[request.id] = ChainEntry(
            **request.model_dump(exclude={"deadline"}),
            status=status,
            registrant=self.signer_of(request, signature),
            approver=ZERO_ADDRESS,
        )
        return TxResult(tx_hash=tx, status=status, block_reason=block_reason)

    async def get_entry(self, entry_id):
        return self.recorded.get(entry_id)

    async def confirm_entry(self, approval, signature, before_broadcast=None):
        tx = self._call("confirm_entry")  # 실패한 시도도 센다
        if self.confirm_error:
            raise self.confirm_error
        entry = self.recorded[approval.id]
        if entry.status is not EntryStatus.PENDING:
            raise ChainRevert(RevertReason.INVALID_STATUS, f"id={approval.id}")
        if before_broadcast:
            await before_broadcast(tx)
        self.recorded[entry.id] = entry.model_copy(update={"status": EntryStatus.CONFIRMED, "approver": self.signer_of(approval, signature)})
        budget = self.budgets.get(entry.budget_id)
        if entry.kind is EntryKind.EXPENSE and budget is not None:
            self.budgets[budget.id] = budget.model_copy(update={"spent": budget.spent + entry.amount})
        return TxResult(tx_hash=tx, status=EntryStatus.CONFIRMED)

    async def reject_entry(self, decision, signature, before_broadcast=None):
        tx = self._call("reject_entry")
        if before_broadcast:
            await before_broadcast(tx)
        entry = self.recorded[decision.id]
        self.recorded[entry.id] = entry.model_copy(update={"status": EntryStatus.REJECTED, "approver": self.signer_of(decision, signature)})
        self.reasons[tx] = decision.reason_hash
        return TxResult(tx_hash=tx, status=EntryStatus.REJECTED)

    async def entry_tx_detail(self, tx_hash, entry_id):
        status = self.recorded[entry_id].status
        return EntryTxDetail(tx_hash=tx_hash, status=status, block_number=1, reason_hash=self.reasons.get(tx_hash))

    async def issue_budget(self, request, signature, before_broadcast=None):
        tx = self._call("issue_budget")
        if before_broadcast:
            await before_broadcast(tx)
        self.budgets[request.budget_id] = ChainBudget(
            id=request.budget_id,
            term=request.term,
            category=request.category,
            issued=request.amount,
            spent=0,
            expires_at=request.expires_at,
            version=1,
            reclaim_count=0,
        )
        return BudgetTxResult(tx_hash=tx, budget_id=request.budget_id, version=1)

    async def increase_budget(self, request, requester_signature, approver_signature, before_broadcast=None):
        budget = self.budgets[request.budget_id]
        if request.version != budget.version:  # 시뮬레이션에서 걸린다 — 보내지 않는다
            raise ChainRevert(BudgetRevertReason.VERSION_MISMATCH, f"expected={budget.version}")
        tx = self._call("increase_budget")
        if before_broadcast:
            await before_broadcast(tx)
        self.budgets[budget.id] = budget.model_copy(update={"issued": budget.issued + request.amount, "version": budget.version + 1})
        return BudgetTxResult(tx_hash=tx, budget_id=budget.id, version=budget.version + 1)

    async def get_budget(self, budget_id):
        return self.budgets.get(budget_id)


def run_stub(client, chain=None):
    return asyncio.run(run_smoke(client, chain or _stub_chain(), TREASURER_KEY, AUDITOR_KEY, smoke_base_id(time.time_ns())))


def test_the_whole_run_passes_on_the_stub():
    # 노드 없이도 반려·예산 경로까지 모든 단계가 실제로 판정된다 (스텁에 없는 메서드가 ❌ 로 묻히지 않는다)
    client = _RecordingClient()
    report = run_stub(client)
    assert report.passed, report.render()
    assert kinds(report) == STEPS
    assert client.calls == {
        "record_pending": 6,  # 수입·지출·반려 대상·예산 안 지출·초과·재등록 (같은 요청 재전송은 보내지 않는다)
        "confirm_entry": 3,  # 수입·예산 안 지출·재등록
        "reject_entry": 1,
        "issue_budget": 1,
        "increase_budget": 1,  # 같은 증액 재전송은 VersionMismatch 로 보내지 않는다
    }
    assert sum(client.calls.values()) == len(relays(report))


def test_a_failing_step_is_reported_and_the_run_continues():
    # 노드가 잠깐 끊겨 다시 읽기가 실패해도 보고서가 끝까지 나오고 다음 항목도 실행된다 (traceback 으로 죽지 않는다)
    deadlines = []

    class Client(_RecordingClient):
        async def record_pending(self, request, signature, before_broadcast=None):
            deadlines.append(request.deadline)
            return await super().record_pending(request, signature, before_broadcast)

        async def get_entry(self, entry_id):
            raise ChainUnavailable("노드가 잠깐 끊김")

    client = Client()
    report = run_stub(client)
    assert not report.passed
    # 항목마다 다시 읽기에서 ❌, 반려 대상도 반려하지 않고, 예산 경로는 발행 뒤 첫 지출에서 멈춘다
    assert kinds(report) == ["수입", "지출", "수입", "예산 발행", "지출"]
    for case in report.cases:
        failed = [c for c in case.checks if not c.ok]
        if case.title.startswith("[예산 발행]"):
            assert not failed
        else:
            assert [c.label for c in failed] == ["체인에서 다시 읽음"] and "ChainUnavailable" in failed[0].detail
    assert client.confirm_calls == 0 and "reject_entry" not in client.calls  # 다시 읽지 못한 항목은 확정·반려하지 않는다
    # deadline 은 실제 시각이 아니라 체인 시각(다음 블록) 기준이다 — 컨트랙트는 block.timestamp 로 만료를 본다
    assert len(deadlines) >= 2 and set(deadlines) == {1_800_000_000 + relayer_smoke.DEADLINE_SECONDS}


def test_a_failing_confirmation_is_reported_and_the_run_continues():
    # 확정 릴레이에서 노드가 끊겨도 ❌ 로 남기고 지출 항목을 계속한다
    report = run_stub(_RecordingClient(confirm_error=ChainUnavailable("확정 중 노드가 끊김")))
    # 수입 확정 ❌ 뒤에도 지출·반려·예산 발행은 실행되고, 예산 경로는 확정이 실패한 첫 지출에서 멈춘다
    assert kinds(report) == ["수입", "지출", "수입", "예산 발행", "지출"]
    failed = [(kinds(report)[i], c.label) for i, case in enumerate(report.cases) for c in case.checks if not c.ok]
    assert failed == [("수입", "확정 릴레이"), ("지출", "확정 릴레이")]
    assert all("ChainUnavailable" in c.detail for case in report.cases for c in case.checks if not c.ok)
    assert report.cases[2].checks[-1].label.startswith("체인에서 다시 읽음 → REJECTED")  # 반려는 끝까지 갔다


def test_confirmation_is_skipped_when_registration_did_not_match():
    # 수입이 예상(PENDING)과 달리 BLOCKED 로 오면 그 실패만 보여 준다. 확정까지 보내 InvalidStatus 를 덧붙이지 않는다
    blocked = (EntryStatus.BLOCKED, BlockReason.BUDGET_NOT_FOUND)
    client = _RecordingClient(results={EntryKind.INCOME: blocked, EntryKind.EXPENSE: blocked})
    report = run_stub(client)
    income = report.cases[0]
    assert not income.checks[1].ok and income.checks[1].label.startswith("릴레이 → BLOCKED")
    assert client.confirm_calls == 0 and not any(c.label.startswith("확정") for c in income.checks)
    assert "reject_entry" not in client.calls  # 반려 대상도 등록이 어긋나 반려하지 않는다
    assert kinds(report) == ["수입", "지출", "수입", "예산 발행", "지출"]  # 예산 안 지출이 BLOCKED 라 멈춘다


def test_approver_role_is_checked_before_confirming_without_a_node():
    # 체인 보기가 감사·회장이 아니라고 하면 확정을 보내지 않는다
    client = _RecordingClient()
    report = run_stub(client, _stub_chain(approver=False))
    income, _, rejected = report.cases[:3]
    assert client.confirm_calls == 0 and "감사·회장이 아니라 보내지 않았다" in income.checks[-1].detail
    assert "reject_entry" not in client.calls and "감사·회장이 아니라 보내지 않았다" in rejected.checks[-1].detail


class _Closable:
    def __init__(self, closed: list, name: str):
        self.closed, self.name, self.relayer_address = closed, name, RELAYER

    async def close(self):
        self.closed.append(self.name)


@pytest.mark.parametrize("fails_at", ["run_smoke", "chain_view"])
def test_main_reports_setup_failures_and_closes_connections(monkeypatch, fails_at):
    # 준비 단계(잔액·체인 시각 조회, 체인 보기 열기)에서 노드가 끊겨도 traceback 이 아니라 "관문 2 실패" 로 끝나고,
    # 이미 연 연결은 닫는다
    from app.chain import ChainUnavailable

    closed = []

    async def connect(*args, **kwargs):
        return _Closable(closed, "client")

    def open_view(cls, *args):
        if fails_at == "chain_view":
            raise ChainUnavailable("체인 보기를 열지 못함")
        return _Closable(closed, "view")

    async def run(*args, **kwargs):
        raise ChainUnavailable("잔액 조회 중 노드가 끊김")

    monkeypatch.setattr(Web3ChainClient, "connect", connect)
    monkeypatch.setattr(ChainView, "open", classmethod(open_view))
    monkeypatch.setattr(relayer_smoke, "run_smoke", run)
    out = io.StringIO()
    with redirect_stdout(out):
        assert asyncio.run(relayer_smoke.main()) == 1
    assert "관문 2 실패: 판정 중 오류 (ChainUnavailable" in out.getvalue()
    assert closed == (["client"] if fails_at == "chain_view" else ["view", "client"])


# ---------------------------------------------------------------- 반려·예산 경로


@pytest.mark.chain
def test_rejection_and_budget_path_are_judged_on_the_local_chain(node):
    report = smoke(TREASURER_KEY)
    assert report.passed, report.render()
    rejected, issued, spent, over, increased, again = report.cases[2:]
    assert rejected.title.endswith("감사 반려")
    assert rejected.checks[-1].label == "체인에서 다시 읽음 → REJECTED, 반려자 = 서명자, 사유 해시 일치"
    assert issued.title.startswith("[예산 발행]") and "스모크 예산" in issued.title
    # 지출 벡터 35,000원: 발행 52,500 → 확정 뒤 17,500 → 35,000 은 BLOCKED → 17,500 증액 → 35,000 → 재등록 확정 뒤 0
    assert [c.label for c in issued.checks + spent.checks + increased.checks + again.checks if c.label.startswith("예산 잔량")] == [
        "예산 잔량 → 52,500원",
        "예산 잔량 → 17,500원",
        "예산 잔량 → 35,000원",
        "예산 잔량 → 0원",
    ]
    assert over.checks[1].label == "릴레이 → BLOCKED(BUDGET_EXCEEDED)"
    assert increased.checks[-1].label == "같은 증액 재전송 → VersionMismatch (nonce 그대로)"


@pytest.mark.chain
def test_increase_approver_must_be_an_auditor(node):
    # 증액 승인은 감사만 한다 (PRD §4.1). 회장이 승인 서명을 하면 ❌ 이고 증액을 보내지 않으며 재등록으로 가지 않는다
    report, sent = smoke_and_count(TREASURER_KEY, auditor_key=PRESIDENT_KEY)
    assert not report.passed
    increased = report.cases[-1]
    assert increased.title.startswith("[예산 증액]")
    assert increased.checks[-1].label == "증액 승인 서명 → 서명자가 체인의 감사" and not increased.checks[-1].ok
    assert increased.checks[-1].detail.endswith("는 감사가 아니라 보내지 않았다")
    assert sent == 9  # 증액·재등록 없이 그 앞까지


def test_a_failure_while_preparing_a_request_is_reported_not_raised():
    # 요청·서명을 만드는 준비에서 실패해도(배포 기록에 BudgetToken 도메인이 없음) 예외로 run_smoke 를 벗어나지 않는다.
    # 앞서 통과한 수입·지출·반려 결과는 보고서에 그대로 남고, 예산 경로는 발행에서 멈춘다
    chain = _stub_chain()
    deployment = chain.deployment
    chain.deployment = deployment.model_copy(update={"eip712": {k: v for k, v in deployment.eip712.items() if k != BUDGET_TOKEN}})
    client = _RecordingClient()
    report = run_stub(client, chain)
    assert kinds(report) == ["수입", "지출", "수입", "예산 발행"]
    assert all(case.ok for case in report.cases[:3])
    issued = report.cases[-1]
    assert [c.label for c in issued.checks] == ["발행 서명 → 서명자가 체인의 회장"] and "KeyError" in issued.checks[0].detail
    assert "issue_budget" not in client.calls


def test_budget_path_stops_at_the_first_failing_step():
    # 예산 발행이 실패하면 그 예산으로 지출을 등록하지 않는다 — BUDGET_NOT_FOUND 같은 여파의 실패가 원인을 가린다
    recorded = []

    class Client(_RecordingClient):
        async def record_pending(self, request, signature, before_broadcast=None):
            recorded.append(request.budget_id)
            return await super().record_pending(request, signature, before_broadcast)

        async def reject_entry(self, decision, signature, before_broadcast=None):
            raise ChainUnavailable("반려 중 노드가 끊김")

        async def issue_budget(self, request, signature, before_broadcast=None):
            raise ChainUnavailable("발행 중 노드가 끊김")

    report = run_stub(Client())
    issued = report.cases[-1]
    assert issued.title.startswith("[예산 발행]") and issued.checks[-1].label == "발행 릴레이"
    assert "ChainUnavailable" in issued.checks[-1].detail
    assert recorded and set(recorded) == {0}  # 수입(재전송 포함)·지출·반려 대상만. 예산을 단 등록은 없다
