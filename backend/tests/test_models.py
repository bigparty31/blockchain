"""
SQLAlchemy 모델 무결성 및 스키마 검증 테스트 (정본 검증)
- 3주차 필수 요구사항 검증:
  1) hash_version (기본값 1)
  2) rejected_by (반려자 컬럼)
  3) Snapshot.file_hash (통장 원본 CSV 바이트 해시)
  4) id 채번 (1부터 시작하는 PK)
  5) 로그인 키는 학번 (users.student_no, UNIQUE)
"""

from datetime import datetime, timezone, timedelta
import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.models import (
    Base,
    User,
    Term,
    Budget,
    BudgetVersion,
    BudgetRevisionRequest,
    Entry,
    Snapshot,
    BankTransaction,
    Membership,
    Objection,
)


@pytest.fixture(scope="function")
def db_session():
    """테스트용 인메모리 SQLite DB 세션"""
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(bind=engine)
    Session = sessionmaker(bind=engine)
    session = Session()
    try:
        yield session
    finally:
        session.close()
        Base.metadata.drop_all(bind=engine)


def test_schema_has_all_core_tables():
    """ERD에 정의된 핵심 테이블들이 Base 메타데이터에 모두 등록되어 있는지 검증"""
    expected_tables = {
        "users",
        "terms",
        "budgets",
        "budget_versions",
        "budget_revision_requests",
        "entries",
        "snapshots",
        "bank_transactions",
        "memberships",
        "objections",
    }
    registered_tables = set(Base.metadata.tables.keys())
    assert expected_tables.issubset(registered_tables)


def test_mandatory_columns_present():
    """3주차 필수 4대 컬럼 및 학번 로그인 키 존재 검증"""
    entries_table = Base.metadata.tables["entries"]
    snapshots_table = Base.metadata.tables["snapshots"]
    users_table = Base.metadata.tables["users"]

    # 1. entries.hash_version (기본값 1)
    assert "hash_version" in entries_table.c
    assert entries_table.c.hash_version.default.arg == 1

    # 2. entries.rejected_by (반려자)
    assert "rejected_by" in entries_table.c
    assert entries_table.c.rejected_by.nullable is True

    # 3. snapshots.file_hash (통장 CSV 원본 해시)
    assert "file_hash" in snapshots_table.c

    # 4. users.student_no (학번 - 로그인 키, UNIQUE)
    assert "student_no" in users_table.c
    assert users_table.c.student_no.unique is True or any(
        u.columns.contains(users_table.c.student_no) for u in users_table.constraints if getattr(u, 'columns', None)
    )

    # 5. terms.term_code (학기 코드 YYYYS, UNIQUE)
    terms_table = Base.metadata.tables["terms"]
    assert "term_code" in terms_table.c
    assert terms_table.c.term_code.unique is True or any(
        u.columns.contains(terms_table.c.term_code) for u in terms_table.constraints if getattr(u, 'columns', None)
    )


def test_crud_and_relationships(db_session):
    """실제 레코드 생성 및 외래키/관계 정합성 검증"""
    now = datetime.now(timezone.utc)
    term_end = now + timedelta(days=120)

    # 1. 학기 생성
    term = Term(
        term_code=20262,
        name="2026-2학기",
        started_at=now,
        ended_at=term_end,
    )
    db_session.add(term)
    db_session.flush()
    assert term.id == 1

    # 2. 사용자 생성 (총무, 감사, 학생)
    treasurer = User(
        student_no="20210001",
        password_hash="$2b$12$dummyhashforrunningtestonlyxxxxxxxxxxxxxxxxxxxxx",
        name="김총무",
        role="TREASURER",
        wallet_address="0x1111111111111111111111111111111111111111",
    )
    auditor = User(
        student_no="20200002",
        password_hash="$2b$12$dummyhashforrunningtestonlyxxxxxxxxxxxxxxxxxxxxx",
        name="이감사",
        role="AUDITOR",
        wallet_address="0x2222222222222222222222222222222222222222",
    )
    student = User(
        student_no="20240003",
        password_hash="$2b$12$dummyhashforrunningtestonlyxxxxxxxxxxxxxxxxxxxxx",
        name="박학생",
        role="STUDENT",
        wallet_index=1,
    )
    db_session.add_all([treasurer, auditor, student])
    db_session.flush()

    # 3. 예산 및 예산 버전 편성 (budgets + budget_versions)
    budget = Budget(
        term_id=term.id,
        category="행사비",
        expires_at=now,
    )
    db_session.add(budget)
    db_session.flush()
    assert budget.id == 1

    budget_v1 = BudgetVersion(
        budget_id=budget.id,
        version=1,
        planned_amount=3000000,
        approved_by=auditor.id,
    )
    db_session.add(budget_v1)
    db_session.flush()
    assert budget_v1.version == 1

    # 4. 수입/지출 등록 (Entry) - hash_version 및 rejected_by 포함
    entry = Entry(
        term_id=term.id,
        kind="EXPENSE",
        amount=50000,
        counterparty="한결문구",
        purpose="행사 용품 구매",
        budget_id=budget.id,
        occurred_at=1788793200,  # KST 자정 타임스탬프
        hash_version=1,
        created_by=treasurer.id,
        rejected_by=None,
        status="PENDING",
    )
    db_session.add(entry)
    db_session.flush()
    assert entry.id == 1
    assert entry.hash_version == 1

    # 5. 스냅샷 등록 (Snapshot) - file_hash 포함
    snapshot = Snapshot(
        term_id=term.id,
        bank_balance=2950000,
        file_hash="0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        uploaded_by=treasurer.id,
    )
    db_session.add(snapshot)
    db_session.flush()
    assert snapshot.file_hash is not None

    db_session.commit()


def test_negative_amount_correction_allowed(db_session):
    """정정 항목(corrects_entry_id 존재)은 음수 금액 저장이 허용되어야 함"""
    now = datetime.now(timezone.utc)
    term = Term(term_code=20261, name="2026-1학기", started_at=now, ended_at=now + timedelta(days=100))
    user = User(student_no="20210002", password_hash="dummy", name="총무", role="TREASURER", wallet_address="0x1111111111111111111111111111111111111112")
    db_session.add_all([term, user])
    db_session.flush()

    orig_entry = Entry(
        term_id=term.id,
        kind="EXPENSE",
        amount=20000,
        counterparty="서점",
        purpose="도서 구매",
        occurred_at=1788793200,
        created_by=user.id,
    )
    db_session.add(orig_entry)
    db_session.flush()

    # 음수 정정 항목 등록
    correction = Entry(
        term_id=term.id,
        kind="EXPENSE",
        amount=-20000,
        counterparty="서점",
        purpose="도서 구매 환불 정정",
        occurred_at=1788793200,
        created_by=user.id,
        corrects_entry_id=orig_entry.id,
        correction_reason="REFUND",
    )
    db_session.add(correction)
    db_session.flush()
    assert correction.id > 0
    assert correction.amount == -20000


def test_expense_without_budget_allowed_and_income_with_budget_rejected(db_session):
    """예산 없는 지출(BLOCKED 대상)은 저장이 허용되고, 수입에 예산 배정 시 CheckConstraint 위반이어야 함"""
    from sqlalchemy.exc import IntegrityError

    now = datetime.now(timezone.utc)
    term = Term(term_code=20263, name="2026-3학기", started_at=now, ended_at=now + timedelta(days=100))
    user = User(student_no="20210003", password_hash="dummy", name="총무", role="TREASURER", wallet_address="0x1111111111111111111111111111111111111113")
    budget = Budget(term_id=1, category="비품", expires_at=now)
    db_session.add_all([term, user, budget])
    db_session.flush()

    # 1. 예산 없는 지출 (budget_id=None) 성공해야 함
    blocked_expense = Entry(
        term_id=term.id,
        kind="EXPENSE",
        amount=10000,
        counterparty="문구점",
        purpose="예산 초과 지출 시도",
        budget_id=None,
        occurred_at=1788793200,
        created_by=user.id,
        status="BLOCKED",
        block_reason="BUDGET_NOT_FOUND",
    )
    db_session.add(blocked_expense)
    db_session.flush()
    assert blocked_expense.id > 0

    # 2. 수입에 예산 배정 시 실패해야 함 (ck_entries_income_no_budget)
    invalid_income = Entry(
        term_id=term.id,
        kind="INCOME",
        amount=50000,
        counterparty="학생회비납부자",
        purpose="학생회비 납부",
        budget_id=budget.id,
        occurred_at=1788793200,
        created_by=user.id,
    )
    db_session.add(invalid_income)
    with pytest.raises(IntegrityError):
        db_session.flush()
    db_session.rollback()


def test_wallet_address_lowercase_enforced(db_session):
    """지갑 주소는 대소문자 우회 방지를 위해 소문자여야 함 (CHECK ck_users_wallet_address_lower)"""
    from sqlalchemy.exc import IntegrityError

    invalid_user = User(
        student_no="20219999",
        password_hash="dummy",
        name="임원",
        role="TREASURER",
        wallet_address="0xAbCdEf1111111111111111111111111111111111",  # 대문자 포함
    )
    db_session.add(invalid_user)
    with pytest.raises(IntegrityError):
        db_session.flush()
    db_session.rollback()


def test_membership_burned_reissue_allowed(db_session):
    """소각(burned_at IS NOT NULL)된 SBT가 있어도 동일 (user_id, term_id)로 새 SBT 발행이 허용되어야 함 (sqlite_where 검증)"""
    now = datetime.now(timezone.utc)
    term = Term(term_code=20264, name="2026-4학기", started_at=now, ended_at=now + timedelta(days=100))
    student = User(student_no="20240099", password_hash="dummy", name="학생", role="STUDENT", wallet_index=99)
    db_session.add_all([term, student])
    db_session.flush()

    # 1. 1차 발급 및 소각(환불)
    sbt1 = Membership(
        user_id=student.id,
        term_id=term.id,
        token_id=101,
        commit_hash="0x" + "11" * 32,
        burned_at=now,
    )
    db_session.add(sbt1)
    db_session.flush()

    # 2. 동일 학생/학기에 2차 재발행 (활성 상태)
    sbt2 = Membership(
        user_id=student.id,
        term_id=term.id,
        token_id=102,
        commit_hash="0x" + "22" * 32,
        burned_at=None,
    )
    db_session.add(sbt2)
    db_session.flush()
    assert sbt2.id > 0


