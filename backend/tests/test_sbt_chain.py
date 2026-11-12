"""회원권(MembershipSBT) 발행·소각 릴레이를 실제 컨트랙트로 (PRD v0.16 §4.2, §7.2, §9.2).

전부 로컬 노드에 실제로 보내고 evm_snapshot 으로 되돌린다. 공용 노드에는 회원권이 남지 않는다.
받는 주소는 실행마다 새로 만든다 — 공용 노드에서 앱이 이미 발행한 학생 주소와 겹치면 건너뜀(Skipped)으로 결과가 바뀐다.
서명은 앱 역할로 회장·감사·총무의 Hardhat 키가 한다 (scripts/local_chain.py).

가짜 체인으로 보는 시험(test_membership_chain.py, test_membership_mint_api.py)과 달리 컨트랙트가 서명자·nonce·시한을
직접 판정한다. 서버가 계산한 EIP-712 값이 컨트랙트와 어긋나면 여기서 NotApprover 로 드러난다.
"""
from datetime import datetime, timedelta, timezone

import pytest
from eth_account import Account
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.auth import users
from app.chain import ChainRevert
from app.chain.deployment import DEFAULT_PATH, load_deployment
from app.chain.models import BurnRequest, MembershipRevertReason, MintBatchRequest
from app.chain.web3_client import MEMBERSHIP_SBT
from app.database import Base
from app.models import Membership, Term, User
from app.schemas.auth import Role
from app.services import membership_mint, student_wallet
from app.services.student_wallet import MNEMONIC_ENV, student_address
from chain_support import AUDITOR, AUDITOR_KEY, PRESIDENT, PRESIDENT_KEY, RELAYER, TREASURER_KEY, on_chain, unchecked
from scripts.local_chain import sign_as_app

DOMAIN = load_deployment(DEFAULT_PATH).eip712[MEMBERSHIP_SBT]
TERM = 20262


@pytest.fixture(autouse=True)
def isolated(clean_chain_env):
    yield


def fresh(n: int) -> tuple:
    """공용 노드에 기록이 있을 수 없는 새 주소 n 개."""
    return tuple(Account.create().address for _ in range(n))


async def nonce_of(client, signer: str) -> int:
    return await client.membership_nonce(signer)


async def relayer_nonce(client) -> int:
    return await client._w3.eth.get_transaction_count(RELAYER, "pending")


async def mint(client, now, recipients, key=PRESIDENT_KEY, signer=PRESIDENT, before_broadcast=None, change=None):
    """change 는 모델 검증을 건너뛰고 바꿀 값 — 컨트랙트가 스스로 거부하는지 볼 때만 쓴다."""
    request = MintBatchRequest(recipients=recipients, term=TERM, nonce=await nonce_of(client, signer), deadline=now + 600)
    request = unchecked(request, **change) if change else request
    return await client.mint_memberships(request, sign_as_app(request, DOMAIN, key), before_broadcast)


async def burn(client, now, holder, key=AUDITOR_KEY, signer=AUDITOR):
    request = BurnRequest(holder=holder, term=TERM, reason="REFUND", nonce=await nonce_of(client, signer), deadline=now + 600)
    return await client.burn_membership_relayed(request, sign_as_app(request, DOMAIN, key))


async def reverted(client, call) -> tuple:
    """revert 사유와, 그 사이 릴레이어가 트랜잭션을 보냈는지. 시뮬레이션에서 걸리면 보내지 않는다 (가스 0)."""
    before = await relayer_nonce(client)
    try:
        await call
        reason = None
    except ChainRevert as e:
        reason = e.reason
    return reason, await relayer_nonce(client) != before


# ---------------------------------------------------------------- 발행


@pytest.mark.chain
def test_president_mints_a_batch_and_the_nonce_moves(node):
    students = fresh(2)
    seen = []

    async def body(client, now):
        before = await nonce_of(client, PRESIDENT)

        async def claim(tx_hash):
            seen.append(tx_hash)  # 발행 API 라면 여기서 SUBMITTING 으로 선점한다

        result = await mint(client, now, students, before_broadcast=claim)
        return (
            result,
            [await client.has_valid_membership(a, TERM) for a in students],
            [await client.membership_token_of(a, TERM) for a in students],
            await nonce_of(client, PRESIDENT) - before,
            await client.mint_tx_result(result.tx_hash),
        )

    result, valid, tokens, moved, again = on_chain(body)
    assert [m.address for m in result.minted] == list(students) and result.skipped == ()
    assert result.signer == PRESIDENT
    assert valid == [True, True]
    assert tokens == [m.token_id for m in result.minted] and all(t > 0 for t in tokens)
    assert moved == 1
    assert seen == [result.tx_hash]
    assert again == result  # 응답을 잃어도 hash 로 같은 결과를 다시 읽는다


@pytest.mark.chain
def test_already_valid_addresses_are_skipped_not_reverted(node):
    # 이미 유효한 주소 때문에 전체를 되돌리지 않는다 (PRD §7.2)
    first, second = fresh(2)

    async def body(client, now):
        await mint(client, now, (first,))
        return await mint(client, now, (first, second))

    result = on_chain(body)
    assert result.skipped == (first,)
    assert [m.address for m in result.minted] == [second]


@pytest.mark.chain
def test_an_auditor_can_mint_too(node):
    (student,) = fresh(1)

    async def body(client, now):
        result = await mint(client, now, (student,), key=AUDITOR_KEY, signer=AUDITOR)
        return result.signer, await client.has_valid_membership(student, TERM)

    assert on_chain(body) == (AUDITOR, True)


@pytest.mark.chain
def test_server_recovers_the_signer_the_contract_accepts(node):
    # 서버가 제출 전에 대조하는 서명자(signer_of)와 컨트랙트가 이벤트에 남긴 서명자가 같다 — 도메인·타입 해시가 일치한다
    students = fresh(1)

    async def body(client, now):
        request = MintBatchRequest(recipients=students, term=TERM, nonce=await nonce_of(client, PRESIDENT), deadline=now + 600)
        signature = sign_as_app(request, DOMAIN, PRESIDENT_KEY)
        return client.signer_of(request, signature), (await client.mint_memberships(request, signature)).signer

    recovered, on_chain_signer = on_chain(body)
    assert recovered == on_chain_signer == PRESIDENT


# ---------------------------------------------------------------- 거부 (보내지 않는다)


@pytest.mark.chain
def test_treasurer_signature_is_not_approver_and_is_not_sent(node):
    async def body(client, now):
        treasurer = Account.from_key(TREASURER_KEY).address
        return await reverted(client, mint(client, now, fresh(1), key=TREASURER_KEY, signer=treasurer))

    assert on_chain(body) == (MembershipRevertReason.NOT_APPROVER, False)


@pytest.mark.chain
def test_reused_signature_is_invalid_nonce(node):
    async def body(client, now):
        request = MintBatchRequest(recipients=fresh(1), term=TERM, nonce=await nonce_of(client, PRESIDENT), deadline=now + 600)
        signature = sign_as_app(request, DOMAIN, PRESIDENT_KEY)
        await client.mint_memberships(request, signature)
        return await reverted(client, client.mint_memberships(request, signature))

    assert on_chain(body) == (MembershipRevertReason.INVALID_NONCE, False)


@pytest.mark.chain
def test_expired_signature_is_rejected(node):
    async def body(client, now):
        return await reverted(client, mint(client, now, fresh(1), change={"deadline": now - 1}))

    assert on_chain(body) == (MembershipRevertReason.SIGNATURE_EXPIRED, False)


@pytest.mark.chain
@pytest.mark.parametrize(
    "recipients, reason",
    [
        (("0x" + "00" * 20,), MembershipRevertReason.ZERO_ADDRESS),
        ((), MembershipRevertReason.EMPTY_BATCH),
        ("101", MembershipRevertReason.BATCH_TOO_LARGE),
    ],
)
def test_batches_the_contract_refuses_whole(node, recipients, reason):
    # 모델이 먼저 막는 값이지만 컨트랙트도 스스로 거부하는지 본다 (PRD §7.2 빈 배열·100명 초과·0 주소는 전체 revert)
    async def body(client, now):
        targets = fresh(101) if recipients == "101" else recipients
        return await reverted(client, mint(client, now, fresh(1), change={"recipients": targets}))

    assert on_chain(body) == (reason, False)


# ---------------------------------------------------------------- 소각


@pytest.mark.chain
def test_burn_then_remint_gives_a_new_token(node):
    (student,) = fresh(1)

    async def body(client, now):
        first = (await mint(client, now, (student,))).minted[0].token_id
        burned = await burn(client, now, student)
        valid_after_burn = await client.has_valid_membership(student, TERM)
        again, sent = await reverted(client, burn(client, now, student))
        second = (await mint(client, now, (student,))).minted[0].token_id
        return first, burned, valid_after_burn, (again, sent), second

    first, burned, valid_after_burn, second_burn, second = on_chain(body)
    assert (burned.holder, burned.token_id, burned.reason.value, burned.signer) == (student, first, "REFUND", AUDITOR)
    assert valid_after_burn is False
    assert second_burn == (MembershipRevertReason.NO_MEMBERSHIP, False)
    assert second != first


# ---------------------------------------------------------------- 발행 API 의 서비스 흐름 (준비 → 기기 서명 → 제출 → 조회)

TERM_ID = 2
STUDENTS = [(201, "20259901", "가학생", 101), (202, "20259902", "나학생", 102)]  # 시드 학생(index 0)과 겹치지 않게


@pytest.fixture
def mint_db(tmp_path, monkeypatch):
    """시드 임원 + 학생 2명 + 이번 학기. 학생 주소는 이 시험만의 새 니모닉에서 파생한다 (공용 노드 기록과 겹치지 않게)."""
    _, mnemonic = Account.create_with_mnemonic()
    monkeypatch.setenv(MNEMONIC_ENV, mnemonic)
    student_wallet._derive.cache_clear()
    student_wallet._seed.cache_clear()
    engine = create_engine(f"sqlite:///{tmp_path / 'sbt.db'}", connect_args={"check_same_thread": False})
    Base.metadata.create_all(bind=engine)
    session = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    now = datetime.now(timezone.utc)
    with session() as db:
        for u in users.SEED_USERS:
            db.add(
                User(
                    id=u.id,
                    student_no=u.student_no,
                    password_hash=u.password_hash,
                    name=u.name,
                    role=u.role.value,
                    wallet_index=u.wallet_index,
                    wallet_address=u.wallet_address.lower() if u.wallet_address else None,
                )
            )
        for user_id, student_no, name, index in STUDENTS:
            db.add(User(id=user_id, student_no=student_no, password_hash="x", name=name, role="STUDENT", wallet_index=index))
        db.add(Term(id=TERM_ID, term_code=TERM, name="이번 학기", started_at=now - timedelta(days=30), ended_at=now + timedelta(days=90)))
        db.commit()
    yield session
    engine.dispose()
    student_wallet._derive.cache_clear()
    student_wallet._seed.cache_clear()


@pytest.mark.chain
def test_mint_api_flow_against_the_contract(node, mint_db):
    president = next(u for u in users.SEED_USERS if u.role == Role.PRESIDENT)
    student_nos = [no for _, no, _, _ in STUDENTS]

    async def body(client, now):
        with mint_db() as db:
            prepared = await membership_mint.prepare(db, client, president, TERM_ID, student_nos)
            batch_id = prepared.batch.id
            deadline = now + 600
            # 앱이 준비 응답의 값으로 만든 서명 대상 = 서버가 저장한 값으로 다시 만든 것
            request = membership_mint.mint_request(prepared.batch, TERM, deadline)
            signature = sign_as_app(request, DOMAIN, PRESIDENT_KEY)
            batch = await membership_mint.submit(db, client, president, batch_id, deadline, signature)
            submitted = (batch.status, [(t.status, t.token_id) for t in sorted(batch.targets, key=lambda t: t.position)])
        with mint_db() as db:
            refreshed = (await membership_mint.refresh(db, client, batch_id)).status
            rows = sorted((m.user_id, m.term_id, m.token_id) for m in db.query(Membership))
        on_chain_tokens = [await client.membership_token_of(student_address(i), TERM) for _, _, _, i in STUDENTS]
        with mint_db() as db:
            try:
                await membership_mint.prepare(db, client, president, TERM_ID, student_nos)
                again = None
            except membership_mint.NothingToMint as e:
                again = [x.status for x in e.excluded]
        return submitted, refreshed, rows, on_chain_tokens, again

    (status, targets), refreshed, rows, tokens, again = on_chain(body)
    assert status == refreshed == "MINTED"
    assert targets == [("MINTED", t) for t in tokens] and all(t > 0 for t in tokens)
    assert rows == sorted((user_id, TERM_ID, t) for (user_id, _, _, _), t in zip(STUDENTS, tokens))
    assert again == ["ALREADY_MEMBER", "ALREADY_MEMBER"]  # 다시 준비하면 체인 기준으로 모두 빠진다
