"""초기 마스터 데이터(사용자·학기·예산) 시드 스크립트.

    cd backend && python -m scripts.seed
    cd backend && python -m scripts.seed --with-demo-entries

동작 원칙:
- 멱등성(idempotent) 보장: 이미 존재하는 행은 건드리지 않고 누락된 기본 행만 추가한다.
  컨테이너 기동 시 `alembic upgrade head && python -m scripts.seed` 형태로 매번 실행해도 안전하다.
- `app/auth/users.py` 의 `SEED_USERS`(id 1~5)를 정본으로 읽어 `users` 테이블을 채운다.
  DB 의 `ck_users_wallet_address_lower` 제약조건을 충족하기 위해 `wallet_address` 는 소문자로 변환한다.
- 실제 블록체인(Hardhat) 노드와 함께 띄울 때 체인에 없는 트랜잭션 해시가 DB 에 남지 않도록,
  기본 실행에서는 `entries` 원장 행을 넣지 않는다 (`CHAIN_FAKE=1` 단독 데모일 때만 `--with-demo-entries` 사용).
- PostgreSQL 에서 명시적 PK(`id=1..5`) 삽입 후 시퀀스(`BIGSERIAL`)가 뒤처지지 않도록 `setval` 동기화를 수행한다.
"""
import argparse
import os
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Optional, Sequence

from sqlalchemy import inspect, or_, text
from sqlalchemy.orm import Session

# `python scripts/seed.py` 직접 실행 시에도 `app` 패키지를 찾을 수 있도록 경로 보정
_BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _BACKEND_DIR not in sys.path:
    sys.path.insert(0, _BACKEND_DIR)

KST = timezone(timedelta(hours=9))

DEFAULT_TERM_ID = 1
DEFAULT_TERM_CODE = 20262
DEFAULT_TERM_NAME = "2026-2학기"
DEFAULT_TERM_STARTED_AT = datetime(2026, 9, 1, 0, 0, 0, tzinfo=KST)
DEFAULT_TERM_ENDED_AT = datetime(2027, 2, 28, 23, 59, 59, tzinfo=KST)

# docs/API.md 및 app/routers/budgets.py 의 기본 예산 만료 시각 (2026-12-14 23:59:59 KST)
DEFAULT_BUDGET_EXPIRES_AT = datetime.fromtimestamp(1797260399, tz=timezone.utc)

# (budget_id, category, [(version, planned_amount, revision_reason, approved_by), ...])
DEFAULT_BUDGETS = (
    (
        1,
        "행사비",
        (
            (1, 2_000_000, None, 4),
            (2, 2_500_000, "참가인원 증가", 3),
        ),
    ),
    (
        2,
        "사업비",
        (
            (1, 1_500_000, None, 4),
        ),
    ),
    (
        3,
        "운영비",
        (
            (1, 1_000_000, None, 4),
        ),
    ),
)

REQUIRED_TABLES = ("users", "terms", "budgets", "budget_versions", "entries")


@dataclass(frozen=True)
class SeedResult:
    users_created: int = 0
    terms_created: int = 0
    budgets_created: int = 0
    budget_versions_created: int = 0
    entries_created: int = 0


def _ensure_tables_exist(db: Session) -> None:
    bind = db.get_bind()
    inspector = inspect(bind)
    existing = set(inspector.get_table_names())
    missing = [t for t in REQUIRED_TABLES if t not in existing]
    if missing:
        raise RuntimeError(
            f"필수 DB 테이블이 없습니다 ({', '.join(missing)}). 먼저 'alembic upgrade head' 를 실행하세요."
        )


def _sync_postgres_sequences(db: Session) -> None:
    """PostgreSQL 에서 명시적 PK 삽입 후 뒤처진 시퀀스만 앞으로 당긴다.

    빈 테이블이거나(예: entries 기본 0건) 롤백·삭제로 시퀀스가 이미 MAX(id)보다 앞서 있는 경우에는
    절대 되감지(rewind) 않아 온체인 ID 재사용 충돌(EntryAlreadyExists)을 방지한다.
    """
    bind = db.get_bind()
    if bind.dialect.name != "postgresql":
        return
    for table in REQUIRED_TABLES:
        max_id = db.execute(text(f"SELECT MAX(id) FROM {table}")).scalar()
        if max_id is None:
            continue
        seq_name = db.execute(
            text("SELECT pg_get_serial_sequence(:table_name, 'id')"),
            {"table_name": table},
        ).scalar()
        if not seq_name:
            continue
        row = db.execute(text(f"SELECT last_value, is_called FROM {seq_name}")).one()
        last_val, is_called = int(row[0]), bool(row[1])
        next_val = last_val + 1 if is_called else last_val
        if next_val <= int(max_id):
            db.execute(
                text("SELECT setval(:seq_name, :max_id, true)"),
                {"seq_name": seq_name, "max_id": int(max_id)},
            )


def seed_database(db: Session, *, with_demo_entries: bool = False) -> SeedResult:
    """빈 DB(또는 일부만 채워진 DB)에 필수 기준 데이터를 멱등하게 주입한다."""
    from app.auth import users as auth_users
    from app.models import (
        Budget as DBBudget,
        BudgetVersion as DBBudgetVersion,
        Entry as DBEntry,
        Term as DBTerm,
        User as DBUser,
    )
    from app.utils.hashing import calculate_meta_hash

    _ensure_tables_exist(db)

    users_created = 0
    terms_created = 0
    budgets_created = 0
    budget_versions_created = 0
    entries_created = 0

    try:
        # 1. 사용자 (SEED_USERS id=1..5, 지갑 주소는 소문자 정규화)
        for u in auth_users.SEED_USERS:
            lower_wallet = u.wallet_address.lower() if u.wallet_address else None
            user_conds = [DBUser.id == u.id, DBUser.student_no == u.student_no]
            if u.wallet_index is not None:
                user_conds.append(DBUser.wallet_index == u.wallet_index)
            if lower_wallet is not None:
                user_conds.append(DBUser.wallet_address == lower_wallet)
            exists = db.query(DBUser).filter(or_(*user_conds)).first()
            if exists is not None:
                continue
            db.add(
                DBUser(
                    id=u.id,
                    student_no=u.student_no,
                    password_hash=u.password_hash,
                    name=u.name,
                    role=u.role.value if hasattr(u.role, "value") else str(u.role),
                    wallet_index=u.wallet_index,
                    wallet_address=lower_wallet,
                )
            )
            users_created += 1
        db.flush()

        # 2. 학기 (id=1, 2026-2학기, term_code=20262)
        term = (
            db.query(DBTerm)
            .filter(
                or_(
                    DBTerm.id == DEFAULT_TERM_ID,
                    DBTerm.term_code == DEFAULT_TERM_CODE,
                    DBTerm.name == DEFAULT_TERM_NAME,
                )
            )
            .first()
        )
        if term is None:
            term = DBTerm(
                id=DEFAULT_TERM_ID,
                term_code=DEFAULT_TERM_CODE,
                name=DEFAULT_TERM_NAME,
                started_at=DEFAULT_TERM_STARTED_AT,
                ended_at=DEFAULT_TERM_ENDED_AT,
            )
            db.add(term)
            db.flush()
            terms_created += 1

        # 3. 예산 및 버전 이력 (id=1 행사비 v1/v2, id=2 사업비 v1, id=3 운영비 v1)
        budget_ids_by_category: dict[str, int] = {}
        for budget_id, category, versions in DEFAULT_BUDGETS:
            budget = (
                db.query(DBBudget)
                .filter(
                    (DBBudget.id == budget_id)
                    | ((DBBudget.term_id == term.id) & (DBBudget.category == category))
                )
                .first()
            )
            if budget is None:
                budget = DBBudget(
                    id=budget_id,
                    term_id=term.id,
                    category=category,
                    expires_at=DEFAULT_BUDGET_EXPIRES_AT,
                    tx_issue=None,
                )
                db.add(budget)
                db.flush()
                budgets_created += 1
            budget_ids_by_category[category] = budget.id

            for ver_no, planned_amount, revision_reason, approver_id in versions:
                ver_exists = (
                    db.query(DBBudgetVersion)
                    .filter(
                        DBBudgetVersion.budget_id == budget.id,
                        DBBudgetVersion.version == ver_no,
                    )
                    .first()
                )
                if ver_exists is not None:
                    continue
                approver_exists = db.query(DBUser.id).filter(DBUser.id == approver_id).first()
                db.add(
                    DBBudgetVersion(
                        budget_id=budget.id,
                        version=ver_no,
                        planned_amount=planned_amount,
                        revision_reason=revision_reason,
                        approved_by=approver_id if approver_exists else None,
                        tx_hash=None,
                    )
                )
                budget_versions_created += 1
        db.flush()

        # 4. 선택적 오프라인 데모 내역 (CHAIN_FAKE=1 화면 확인용)
        if with_demo_entries and db.query(DBEntry).count() == 0:
            treasurer = db.query(DBUser).filter(DBUser.role == "TREASURER").order_by(DBUser.id).first()
            auditor = (
                db.query(DBUser)
                .filter(DBUser.role.in_(("AUDITOR", "PRESIDENT")))
                .filter(DBUser.id != (treasurer.id if treasurer else -1))
                .order_by(DBUser.id)
                .first()
            )
            event_budget_id = budget_ids_by_category.get("행사비")
            project_budget_id = budget_ids_by_category.get("사업비")
            if treasurer is not None and auditor is not None:
                r1 = "0xabc1234567890abcdef1234567890abcdef1234567890abcdef1234567890abc"
                r2 = "0xdef4567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
                demo_rows = (
                    DBEntry(
                        id=1,
                        term_id=term.id,
                        kind="EXPENSE",
                        amount=35_000,
                        counterparty="한결문구",
                        purpose="신입생 환영회 명찰 및 필기구 구매",
                        budget_id=project_budget_id,
                        occurred_at=1788793200,
                        receipt_path="/receipts/sample_01.jpg",
                        receipt_hash=r1,
                        meta_hash=calculate_meta_hash(
                            35_000, "한결문구", "신입생 환영회 명찰 및 필기구 구매", 1788793200, r1
                        ),
                        hash_version=1,
                        ocr_amount=35_000,
                        ocr_approval_no="12345678",
                        ocr_paid_at=1788825820,
                        ocr_status="MATCH",
                        status="CONFIRMED",
                        created_by=treasurer.id,
                        approved_by=auditor.id,
                        tx_pending="0x" + "1" * 64,
                        tx_confirm="0x" + "2" * 64,
                    ),
                    DBEntry(
                        id=2,
                        term_id=term.id,
                        kind="EXPENSE",
                        amount=120_000,
                        counterparty="청년피자",
                        purpose="개강총회 다과 주문",
                        budget_id=event_budget_id,
                        occurred_at=1788706800,
                        receipt_path="/receipts/sample_02.jpg",
                        receipt_hash=r2,
                        meta_hash=calculate_meta_hash(
                            120_000, "청년피자", "개강총회 다과 주문", 1788706800, r2
                        ),
                        hash_version=1,
                        ocr_amount=120_000,
                        ocr_approval_no="87654321",
                        ocr_paid_at=1788775450,
                        ocr_status="MATCH",
                        status="PENDING",
                        created_by=treasurer.id,
                        tx_pending="0x" + "3" * 64,
                    ),
                    DBEntry(
                        id=3,
                        term_id=term.id,
                        kind="INCOME",
                        amount=5_000_000,
                        counterparty="컴퓨터공학과 학생회비 일괄 납부",
                        purpose="2026-2학기 학과 학생회비 수납",
                        budget_id=None,
                        occurred_at=1788620400,
                        meta_hash=calculate_meta_hash(
                            5_000_000,
                            "컴퓨터공학과 학생회비 일괄 납부",
                            "2026-2학기 학과 학생회비 수납",
                            1788620400,
                            None,
                        ),
                        hash_version=1,
                        status="CONFIRMED",
                        created_by=treasurer.id,
                        approved_by=auditor.id,
                        tx_pending="0x" + "4" * 64,
                        tx_confirm="0x" + "5" * 64,
                    ),
                )
                db.add_all(demo_rows)
                db.flush()
                entries_created = len(demo_rows)

        _sync_postgres_sequences(db)
        db.commit()
    except Exception:
        db.rollback()
        raise

    return SeedResult(
        users_created=users_created,
        terms_created=terms_created,
        budgets_created=budgets_created,
        budget_versions_created=budget_versions_created,
        entries_created=entries_created,
    )


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="초기 마스터 데이터(users, terms, budgets) 시드 주입")
    parser.add_argument(
        "--with-demo-entries",
        action="store_true",
        help="CHAIN_FAKE=1 오프라인 데모용 예시 내역 3건(entries)도 함께 주입",
    )
    args = parser.parse_args(argv)

    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")

    from app.env import load_env_file

    load_env_file()
    # 시드 CLI 는 토큰을 발급·검증하지 않으므로 JWT_SECRET 미설정 환경에서도 app.auth.users 를 읽을 수 있게 한다
    if not os.environ.get("JWT_SECRET", "").strip():
        os.environ.setdefault("JWT_DEV_SECRET", "1")

    from app.database import SessionLocal

    db = SessionLocal()
    try:
        result = seed_database(db, with_demo_entries=args.with_demo_entries)
    except Exception as e:
        print(f"[seed] 실패: {e}", file=sys.stderr)
        return 1
    finally:
        db.close()

    print(
        f"[seed] 완료: users +{result.users_created}, terms +{result.terms_created}, "
        f"budgets +{result.budgets_created}, budget_versions +{result.budget_versions_created}, "
        f"entries +{result.entries_created}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

