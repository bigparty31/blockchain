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

from app.chain import ChainEntry, ChainRevert, ChainUnavailable, RevertReason, TxResult, eip712
from app.chain.deployment import DEFAULT_PATH, load_deployment
from app.chain.models import UINT64_MAX, ZERO_ADDRESS, BlockReason
from app.chain.provider import reset_chain_client
from app.chain.web3_client import LEDGER, Web3ChainClient
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
    rpc,
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


def smoke_and_count(signing_key: str, approver_key: str = AUDITOR_KEY):
    """스냅샷 안에서 판정하고 (보고서, 릴레이어가 보낸 트랜잭션 수) 를 돌려준다."""

    async def run():
        client = await Web3ChainClient.connect(RPC_URL, RELAYER_KEY, DEFAULT_PATH)
        chain = ChainView.open(RPC_URL, load_deployment(DEFAULT_PATH), DEFAULT_PATH)

        async def body():
            before = await chain.nonce(RELAYER)
            report = await run_smoke(client, chain, signing_key, approver_key, smoke_base_id(time.time_ns()))
            return report, await chain.nonce(RELAYER) - before

        try:
            return await in_snapshot(chain.w3, body)
        finally:
            await chain.close()
            await client.close()

    return asyncio.run(run())


def smoke(signing_key: str, approver_key: str = AUDITOR_KEY):
    return smoke_and_count(signing_key, approver_key)[0]


@pytest.mark.chain
def test_smoke_passes_on_the_local_chain(node):
    report, sent = smoke_and_count(TREASURER_KEY)
    assert report.passed, report.render()
    assert [len(case.checks) for case in report.cases] == [9, 4]  # 수입은 재전송 확인과 확정(4개)까지
    assert sent == 3  # 수입 등록, 지출 등록(BLOCKED 도 기록), 수입 확정
    assert report.render().endswith(
        "관문 2·확정 통과: 서명 → 릴레이 → 체인 기록 (수입 PENDING → CONFIRMED 1건, 지출 BLOCKED 1건)"
    )


@pytest.mark.chain
@pytest.mark.parametrize("approver_key, approver", [(AUDITOR_KEY, AUDITOR), (PRESIDENT_KEY, PRESIDENT)])
def test_confirmation_shows_the_signer_as_approver(node, approver_key, approver):
    # 회장도 감사와 같은 승인 권한이다 (PRD §3). 확정 단계 라벨은 등록 단계와 겹치지 않는다
    report = smoke(TREASURER_KEY, approver_key)
    income = report.cases[0]
    assert report.passed, report.render()
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
    report, sent = smoke_and_count(TREASURER_KEY, approver_key=TREASURER_KEY)
    assert not report.passed
    income = report.cases[0]
    assert all(c.ok for c in income.checks[:5]) and len(income.checks) == 6
    assert "감사·회장이 아니라 보내지 않았다" in income.checks[5].detail
    assert sent == 2  # 등록 두 건만
    assert report.render().endswith("관문 2 실패: ❌ 단계를 확인한다")


@pytest.mark.chain
def test_signer_without_the_treasurer_role_is_caught_before_sending(node):
    # 서명자는 서명한 키가 아니라 체인의 총무 롤과 대조한다. 총무가 아니면 ❌ 이고 보내지 않는다 (등록 API 와 같다)
    before = rpc("eth_getTransactionCount", [RELAYER, "latest"])
    report = smoke(RELAYER_KEY)
    assert not report.passed
    for case in report.cases:
        assert len(case.checks) == 1 and not case.checks[0].ok
        assert "서명자가 체인의 총무" in case.checks[0].label and "총무가 아니라 보내지 않았다" in case.checks[0].detail
    assert rpc("eth_getTransactionCount", [RELAYER, "latest"]) == before  # 스냅샷과 별개로, 아예 보내지 않았다
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

        async def nonce(self, address):
            return 0

    return Chain()


class _RecordingClient:
    """체인처럼 기록하고 다시 읽어 주는 가짜 클라이언트. 등록 결과(results)와 확정 실패(confirm_error)를 바꿔 본다."""

    relayer_address = RELAYER

    def __init__(self, results=None, confirm_error=None):
        self.domain = load_deployment(DEFAULT_PATH).eip712[LEDGER]
        self.results = results or {spec.kind: spec.expected for spec in relayer_smoke.CASES}
        self.confirm_error = confirm_error
        self.recorded = {}
        self.confirm_calls = 0

    def signer_of(self, payload, signature):
        return eip712.recover_signer(eip712.typed_data_for(payload, self.domain), signature)

    async def record_pending(self, request, signature, before_broadcast=None):
        if request.id in self.recorded:
            raise ChainRevert(RevertReason.ENTRY_ALREADY_EXISTS, f"id={request.id}")
        status, block_reason = self.results[request.kind]
        self.recorded[request.id] = ChainEntry(
            **request.model_dump(exclude={"deadline"}),
            status=status,
            registrant=self.signer_of(request, signature),
            approver=ZERO_ADDRESS,
        )
        await before_broadcast("0x" + "ab" * 32)
        return TxResult(tx_hash="0x" + "ab" * 32, status=status, block_reason=block_reason)

    async def get_entry(self, entry_id):
        return self.recorded.get(entry_id)

    async def confirm_entry(self, approval, signature, before_broadcast=None):
        self.confirm_calls += 1
        raise self.confirm_error or AssertionError("확정하면 안 되는데 확정했다")


def run_stub(client, chain=None):
    return asyncio.run(run_smoke(client, chain or _stub_chain(), TREASURER_KEY, AUDITOR_KEY, smoke_base_id(time.time_ns())))


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
    assert len(report.cases) == 2 and not report.passed
    failed = [c for case in report.cases for c in case.checks if not c.ok]
    assert all(c.label == "체인에서 다시 읽음" and "ChainUnavailable" in c.detail for c in failed[:1])
    assert any(c.label == "체인에서 다시 읽음" for c in report.cases[1].checks)  # 지출 항목도 실행됐다
    assert client.confirm_calls == 0  # 다시 읽지 못한 항목은 확정하지 않는다
    # deadline 은 실제 시각이 아니라 체인 시각(다음 블록) 기준이다 — 컨트랙트는 block.timestamp 로 만료를 본다
    assert deadlines == [1_800_000_000 + relayer_smoke.DEADLINE_SECONDS] * 2


def test_a_failing_confirmation_is_reported_and_the_run_continues():
    # 확정 릴레이에서 노드가 끊겨도 ❌ 로 남기고 지출 항목을 계속한다
    report = run_stub(_RecordingClient(confirm_error=ChainUnavailable("확정 중 노드가 끊김")))
    failed = [c for case in report.cases for c in case.checks if not c.ok]
    assert [c.label for c in failed] == ["확정 릴레이"] and "ChainUnavailable" in failed[0].detail
    assert len(report.cases) == 2 and report.cases[1].checks[-1].ok  # 지출 항목도 끝까지 실행됐다


def test_confirmation_is_skipped_when_registration_did_not_match():
    # 수입이 예상(PENDING)과 달리 BLOCKED 로 오면 그 실패만 보여 준다. 확정까지 보내 InvalidStatus 를 덧붙이지 않는다
    blocked = (EntryStatus.BLOCKED, BlockReason.BUDGET_NOT_FOUND)
    client = _RecordingClient(results={EntryKind.INCOME: blocked, EntryKind.EXPENSE: blocked})
    report = run_stub(client)
    income = report.cases[0]
    assert not income.checks[1].ok and income.checks[1].label.startswith("릴레이 → BLOCKED")
    assert client.confirm_calls == 0 and not any(c.label.startswith("확정") for c in income.checks)


def test_approver_role_is_checked_before_confirming_without_a_node():
    # 체인 보기가 감사·회장이 아니라고 하면 확정을 보내지 않는다
    client = _RecordingClient()
    income = run_stub(client, _stub_chain(approver=False)).cases[0]
    assert client.confirm_calls == 0 and "감사·회장이 아니라 보내지 않았다" in income.checks[-1].detail


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
