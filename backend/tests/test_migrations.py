"""
Alembic 마이그레이션 DDL 정합성 및 자동 증가(autoincrement) / 기본값(server_default) 검증 테스트
- 팀원 피드백 5: SQLite에서 sa.BigInteger() 단독 사용 시 autoincrement 실패 방지
- 팀원 피드백 6: ORM 외 직접 DDL/SQL INSERT 시 server_default 주입 검증
"""

import os
import sqlite3
import pytest
from alembic.config import Config
from alembic import command


def test_alembic_upgrade_and_insert_autoincrement(tmp_path):
    """
    1. alembic upgrade head 수행
    2. id 컬럼을 명시하지 않고 raw SQL INSERT 수행 시 SQLite autoincrement가 정상 작동하는지 검증
    3. server_default가 명시된 컬럼(version, status 등)이 DB 레벨에서 정상 채워지는지 검증
    4. alembic downgrade base 로 롤백이 깔끔하게 수행되는지 검증
    """
    db_file = tmp_path / "migration_test.db"
    db_url = f"sqlite:///{db_file.as_posix()}"

    backend_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ini_path = os.path.join(backend_dir, "alembic.ini")

    # 1. Alembic 마이그레이션 수행
    alembic_cfg = Config(ini_path)
    alembic_cfg.set_main_option("sqlalchemy.url", db_url)
    command.upgrade(alembic_cfg, "head")

    # 2. Raw SQLite 연결로 직접 INSERT (id 없이 채번 테스트)
    conn = sqlite3.connect(db_file)
    cur = conn.cursor()

    # terms INSERT (피드백 5번 재현 사례)
    cur.execute(
        "INSERT INTO terms(term_code, name, started_at, ended_at) "
        "VALUES (20262, '2026-2', '2026-09-01', '2027-02-28');"
    )
    conn.commit()

    cur.execute("SELECT id, term_code, name FROM terms WHERE term_code = 20262;")
    term_row = cur.fetchone()
    assert term_row is not None
    assert term_row[0] == 1  # autoincrement로 id=1 채번 확인

    # users INSERT (피드백 4번 password_hash 포함)
    cur.execute(
        "INSERT INTO users(student_no, password_hash, name, role, wallet_address) "
        "VALUES ('20210001', '$2b$12$dummyhash', '김총무', 'TREASURER', '0x1111111111111111111111111111111111111111');"
    )
    conn.commit()

    cur.execute("SELECT id, student_no FROM users WHERE student_no = '20210001';")
    user_row = cur.fetchone()
    assert user_row is not None
    assert user_row[0] == 1

    # budgets INSERT (피드백 2번 budgets 테이블)
    cur.execute(
        "INSERT INTO budgets(term_id, category, expires_at) "
        "VALUES (1, '행사비', '2027-02-28');"
    )
    conn.commit()

    cur.execute("SELECT id, category FROM budgets WHERE id = 1;")
    budget_row = cur.fetchone()
    assert budget_row is not None
    assert budget_row[0] == 1

    # budget_versions INSERT (피드백 6번 server_default version=1 검증)
    cur.execute(
        "INSERT INTO budget_versions(budget_id, planned_amount) "
        "VALUES (1, 3000000);"
    )
    conn.commit()

    cur.execute("SELECT id, version, planned_amount FROM budget_versions WHERE budget_id = 1;")
    version_row = cur.fetchone()
    assert version_row is not None
    assert version_row[0] == 1
    assert version_row[1] == 1  # DB server_default 1 적용 확인

    # entries INSERT (피드백 1번 음수 금액 허용, 피드백 3번 예산 없는 지출 허용, 피드백 6번 server_default 검증)
    cur.execute(
        "INSERT INTO entries(term_id, kind, amount, counterparty, purpose, budget_id, occurred_at, created_by) "
        "VALUES (1, 'EXPENSE', 10000, '알파문구', '문구류', NULL, 1788793200, 1);"
    )
    conn.commit()

    cur.execute("SELECT id, hash_version, category_warning, status FROM entries WHERE id = 1;")
    entry_row = cur.fetchone()
    assert entry_row is not None
    assert entry_row[0] == 1
    assert entry_row[1] == 1  # server_default hash_version=1

    # 음수 정정 항목 INSERT 검증 (피드백 1)
    cur.execute(
        "INSERT INTO entries(term_id, kind, amount, counterparty, purpose, budget_id, occurred_at, created_by, corrects_entry_id, correction_reason) "
        "VALUES (1, 'EXPENSE', -5000, '알파문구', '일부 환불 정정', NULL, 1788793200, 1, 1, 'REFUND');"
    )
    conn.commit()

    cur.execute("SELECT id, amount, corrects_entry_id FROM entries WHERE id = 2;")
    correction_row = cur.fetchone()
    assert correction_row is not None
    assert correction_row[0] == 2
    assert correction_row[1] == -5000
    assert correction_row[2] == 1

    conn.close()

    # 3. 마이그레이션 롤백 검증
    command.downgrade(alembic_cfg, "base")
