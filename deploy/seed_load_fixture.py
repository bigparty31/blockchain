"""부하 시험용 장부 채우기 — 한 학기치를 실제 2단계 체인 흐름으로 만든다 (로컬 Hardhat 전용).

**왜 필요한가.** `scripts.seed` 의 기본 시드는 확정 2건이다. 그 상태로 `deploy/k6/read_mix.js` 를
돌리면 `/entries` 가 체인 `get_entry` 를 2번만 부르므로 **캐시가 아끼는 양이 실제의 1/80 로
나온다.** 실제 한 학기 장부는 수백 건이고, `/entries` 는 건수만큼 체인을 부른다. 캐시 ON/OFF
비교가 의미를 가지려면 장부 규모부터 실제와 같아야 한다.

앱이 하는 EIP-712 서명을 `scripts.local_chain` 헬퍼로 대신한다 — 서버는 임원 키를 갖지 않으므로
(PRD §9.2) 이 스크립트가 "앱 역할"을 한다.

실행 (저장소 루트에서, 임원 API 컨테이너 안으로 표준입력으로 넣는다 — 파일을 복사할 필요가 없다):

    docker compose exec -T -e SEED_COUNT=150 api python - < deploy/seed_load_fixture.py

150건에 약 20초 걸린다. **되돌리려면 미리 덤프를 떠 둔다** — 이 스크립트가 만드는 영수증은
바이트만 다른 더미라서, 그 항목을 앱 상세로 열면 이미지가 깨져 보인다. 시연 데이터가 아니다:

    docker compose exec -T db pg_dump -U council -d council -Fc > before_seed.dump
    docker compose exec -T db pg_restore -U council -d council --clean --if-exists < before_seed.dump

체인은 Hardhat 인메모리라 데이터 볼륨이 없다. DB 만 되돌리면 체인에는 이 항목들이 남지만
id 가 겹치지 않아 기존 기록 검증에는 영향이 없다.
"""
import asyncio
import os
import secrets
from datetime import datetime, timedelta, timezone

import aiohttp
from web3 import AsyncHTTPProvider, AsyncWeb3

from app.chain.deployment import deployment_path, load_deployment
from app.chain.models import RecordRequest
from app.chain.provider import get_chain_client
from app.chain.web3_client import LEDGER
from app.database import SessionLocal
from app.models import Entry as DBEntry
from app.schemas.entry import EntryKind
from app.utils.hashing import canonical_text, text_hash
from scripts.local_chain import (
    AUDITOR_INDEX,
    TREASURER_INDEX,
    approval_from_entry,
    chain_now,
    hardhat_key,
    sign_as_app,
)

BASE = "http://127.0.0.1:8000"
PW = "userPassword123!"
KST = timezone(timedelta(hours=9))

VENDORS = ["대한인쇄사", "한결문구", "미래음향", "학림꽃집", "청운다과", "성북물류"]
PURPOSES = ["현수막 제작", "명찰 제작", "음향 대여", "행사 비품", "간식 구매", "자료 인쇄"]

# 지출 1건당 금액. 예산 잔량 안에 들어가야 한다 — 넘으면 `BudgetToken.spend` 가 revert 하고
# 확정이 막힌다 (예산은 하드 게이트다). 기본 시드의 세 예산(250만·150만·100만) 기준이다.
EXPENSE_AMOUNT = 15_000
INCOME_AMOUNT = 50_000


async def login(session, student_no):
    async with session.post(f"{BASE}/auth/login", json={"student_no": student_no, "password": PW}) as r:
        body = await r.json()
        assert r.status == 200, body
        return body["access_token"]


async def upload_receipt(session, headers, i):
    """지출에는 영수증이 필수다. 건마다 바이트를 다르게 만든다 — 같은 해시면 중복으로 걸린다.

    업로드 검증이 확장자만 보므로(`receipts.py` 의 `ALLOWED_EXTENSIONS`) 내용은 보지 않는다.
    """
    blob = b"\x89PNG\r\n\x1a\n" + secrets.token_bytes(512)
    form = aiohttp.FormData()
    form.add_field("file", blob, filename=f"load_fixture_{i:04d}.png", content_type="image/png")
    async with session.post(f"{BASE}/receipts", headers=headers, data=form) as r:
        up = await r.json()
        assert r.status == 201, f"영수증 업로드 실패 {r.status}: {up}"
    return up


async def seed_one(session, treasurer, auditor, w3, chain, domains, i, occurred):
    """초안 → recordPending(총무) → confirmEntry(감사) 한 바퀴.

    등록자 ≠ 승인자를 컨트랙트가 강제하므로 두 역할로 각각 서명한다.
    """
    is_income = i % 5 == 0
    if is_income:
        draft = {
            "term_id": 1,
            "kind": "INCOME",
            "amount": INCOME_AMOUNT,
            "counterparty": f"학생회비 납부 {i:03d}",
            "purpose": "학생회비 수납",
            "occurred_at": occurred,
        }
    else:
        up = await upload_receipt(session, treasurer, i)
        draft = {
            "term_id": 1,
            "kind": "EXPENSE",
            "amount": EXPENSE_AMOUNT,
            "counterparty": VENDORS[i % len(VENDORS)],
            "purpose": f"{PURPOSES[i % len(PURPOSES)]} {i:03d}",
            "budget_id": (i % 3) + 1,
            "occurred_at": occurred,
            "receipt_path": up["receipt_path"],
            "receipt_hash": up["receipt_hash"],
        }

    async with session.post(f"{BASE}/entries", headers=treasurer, json=draft) as r:
        created = await r.json()
        if r.status != 201:
            raise RuntimeError(f"초안 등록 실패 {r.status}: {created}")
    eid = created["id"]

    db = SessionLocal()
    row = db.query(DBEntry).filter(DBEntry.id == eid).first()
    meta_hash, amount, occurred_at = row.meta_hash, row.amount, row.occurred_at
    db.close()

    deadline = await chain_now(w3) + 3600
    req = RecordRequest(
        id=eid,
        hash=meta_hash,
        amount=amount,
        kind=EntryKind.INCOME if is_income else EntryKind.EXPENSE,
        term=20262,
        occurred_at=occurred_at,
        budget_id=0 if is_income else (i % 3) + 1,
        corrects_id=0,
        deadline=deadline,
    )
    sig = sign_as_app(req, domains[LEDGER], hardhat_key(TREASURER_INDEX))
    async with session.post(
        f"{BASE}/entries/{eid}/submit", headers=treasurer, json={"signature": sig, "deadline": deadline}
    ) as r:
        sub = await r.json()
        if r.status != 200:
            raise RuntimeError(f"제출 실패 {r.status}: {sub}")

    entry = await chain.get_entry(eid)
    deadline2 = await chain_now(w3) + 3600

    # 더미 영수증은 OCR 판독값이 없어 경고가 붙는다. 경고 항목의 확정은 사유가 필수이고,
    # 그 사유 해시가 서명에 들어간다 — 용도 불일치는 차단이 아니라 사유를 남기는 소프트 경고다.
    body = {"deadline": deadline2}
    if is_income:
        approval = approval_from_entry(entry, deadline2)
    else:
        reason = f"부하 시험용 더미 영수증 {i:04d}"
        approval = approval_from_entry(
            entry,
            deadline2,
            had_warning=True,
            warning_reason_hash=text_hash(canonical_text(reason)),
        )
        body["warning_reason"] = reason
    body["signature"] = sign_as_app(approval, domains[LEDGER], hardhat_key(AUDITOR_INDEX))

    async with session.post(f"{BASE}/entries/{eid}/confirm", headers=auditor, json=body) as r:
        conf = await r.json()
        if r.status != 200:
            raise RuntimeError(f"확정 실패 {r.status}: {conf}")
    return eid, conf["status"]


async def main(count):
    async with aiohttp.ClientSession() as session:
        treasurer = {"Authorization": f"Bearer {await login(session, '20240002')}"}
        auditor = {"Authorization": f"Bearer {await login(session, '20240003')}"}
        w3 = AsyncWeb3(AsyncHTTPProvider(os.environ["CHAIN_RPC_URL"]))
        chain = await get_chain_client()
        domains = load_deployment(deployment_path()).eip712
        occurred = int(
            datetime.now(KST).replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
        )

        ok = 0
        for i in range(count):
            try:
                eid, status = await seed_one(
                    session, treasurer, auditor, w3, chain, domains, i, occurred
                )
                ok += 1
                if ok == 1 or ok % 25 == 0:
                    print(f"  {ok}/{count}건 — 마지막 entry id={eid} {status}", flush=True)
            except Exception as e:
                # 예산 잔량이 바닥나면 여기서 멈춘다. 그때까지 만든 것은 그대로 쓸 수 있다.
                print(f"  {i}번째에서 멈춤: {e}", flush=True)
                break
        print(f"완료: {ok}건 확정")


asyncio.run(main(int(os.environ.get("SEED_COUNT", "150"))))
