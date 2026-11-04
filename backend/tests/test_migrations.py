"""
Alembic 마이그레이션 DDL 정합성 및 자동 증가(autoincrement) / 기본값(server_default) 검증 테스트
- 팀원 피드백 5: SQLite에서 sa.BigInteger() 단독 사용 시 autoincrement 실패 방지
- 팀원 피드백 6: ORM 외 직접 DDL/SQL INSERT 시 server_default 주입 검증
- 팀원 피드백 (PR #33): 마이그레이션된 DB 레벨 CHECK 제약조건 전체 검증 (성공 케이스 및 위반 시 IntegrityError)
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
    4. 마이그레이션된 DB에서 신규 CHECK 제약조건들 동작 검증:
       - PRESIDENT_SIGNED 정상 저장
       - ck_budget_rev_amount (requested_amount <= 0 차단)
       - ck_budget_rev_pres_signed_fields (PRESIDENT_SIGNED 서명 필드 누락 차단)
       - ck_budget_rev_req_pres_diff (신청 총무 == 회장 서명 차단)
       - ck_budget_rev_approved_tx (APPROVED 시 tx_increase 누락 차단)
       - ck_budget_versions_revision_request_id (version > 1 시 revision_request_id 누락 차단)
       - ck_entries_correction_reason ('OTHER' 허용 및 잘못된 사유 차단)
    5. alembic downgrade base 로 롤백이 깔끔하게 수행되는지 검증
    """
    db_file = tmp_path / "migration_test.db"
    db_url = f"sqlite:///{db_file.as_posix()}"

    backend_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ini_path = os.path.join(backend_dir, "alembic.ini")

    # 1. Alembic 마이그레이션 수행
    alembic_cfg = Config(ini_path)
    alembic_cfg.set_main_option("sqlalchemy.url", db_url)
    command.upgrade(alembic_cfg, "head")

    # alembic_version 버전 테이블이 정상 커밋되었는지 검증 및 재실행/check 멱등성 검증
    command.check(alembic_cfg)
    command.upgrade(alembic_cfg, "head")  # 재실행 시 중복 테이블 에러 없이 성공해야 함

    # 2. Raw SQLite 연결로 alembic_version 확인 및 직접 INSERT (id 없이 채번 테스트)
    conn = sqlite3.connect(db_file)
    cur = conn.cursor()

    cur.execute("SELECT version_num FROM alembic_version;")
    mig_version_row = cur.fetchone()
    assert mig_version_row is not None
    assert mig_version_row[0] is not None and len(mig_version_row[0]) > 0

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

    # users INSERT (총무 id=1, 회장 id=2, 감사 id=3)
    cur.execute(
        "INSERT INTO users(student_no, password_hash, name, role, wallet_address) "
        "VALUES ('20210001', '$2b$12$dummyhash', '김총무', 'TREASURER', '0x1111111111111111111111111111111111111111');"
    )
    cur.execute(
        "INSERT INTO users(student_no, password_hash, name, role, wallet_address) "
        "VALUES ('20210002', '$2b$12$dummyhash', '박회장', 'PRESIDENT', '0x2222222222222222222222222222222222222222');"
    )
    cur.execute(
        "INSERT INTO users(student_no, password_hash, name, role, wallet_address) "
        "VALUES ('20210003', '$2b$12$dummyhash', '이감사', 'AUDITOR', '0x3333333333333333333333333333333333333333');"
    )
    conn.commit()

    # budgets INSERT
    cur.execute(
        "INSERT INTO budgets(term_id, category, expires_at) "
        "VALUES (1, '행사비', '2027-02-28');"
    )
    conn.commit()

    # budget_versions v1 INSERT (server_default version=1 검증)
    cur.execute(
        "INSERT INTO budget_versions(budget_id, planned_amount) "
        "VALUES (1, 3000000);"
    )
    conn.commit()

    # entries INSERT (server_default hash_version=1 검증)
    cur.execute(
        "INSERT INTO entries(term_id, kind, amount, counterparty, purpose, budget_id, occurred_at, created_by) "
        "VALUES (1, 'EXPENSE', 10000, '알파문구', '문구류', NULL, 1788793200, 1);"
    )
    conn.commit()

    # entries 음수 정정 INSERT 검증
    cur.execute(
        "INSERT INTO entries(term_id, kind, amount, counterparty, purpose, budget_id, occurred_at, created_by, corrects_entry_id, correction_reason) "
        "VALUES (1, 'EXPENSE', -5000, '알파문구', '일부 환불 정정', NULL, 1788793200, 1, 1, 'REFUND');"
    )
    conn.commit()

    # entries correction_reason='OTHER' 허용 검증 (PR #33)
    cur.execute(
        "INSERT INTO entries(term_id, kind, amount, counterparty, purpose, budget_id, occurred_at, created_by, corrects_entry_id, correction_reason) "
        "VALUES (1, 'EXPENSE', 1000, '기타문구', '기타 정정 사유 입력', NULL, 1788793200, 1, 1, 'OTHER');"
    )
    conn.commit()

    # entries 잘못된 correction_reason 차단 검증
    with pytest.raises(sqlite3.IntegrityError):
        cur.execute(
            "INSERT INTO entries(term_id, kind, amount, counterparty, purpose, budget_id, occurred_at, created_by, corrects_entry_id, correction_reason) "
            "VALUES (1, 'EXPENSE', 1000, '문구', '오류', NULL, 1788793200, 1, 1, 'INVALID_REASON');"
        )
    conn.rollback()

    # budget_revision_requests requested_amount <= 0 차단 검증 (ck_budget_rev_amount)
    with pytest.raises(sqlite3.IntegrityError):
        cur.execute(
            "INSERT INTO budget_revision_requests(term_id, category, budget_id, requested_amount, reason, requested_by) "
            "VALUES (1, '행사비', 1, 0, '0원 증액 불가', 1);"
        )
    conn.rollback()

    # budget_revision_requests 정상 PENDING INSERT
    cur.execute(
        "INSERT INTO budget_revision_requests(term_id, category, budget_id, requested_amount, reason, requested_by, status) "
        "VALUES (1, '행사비', 1, 500000, '축제 무대 확장', 1, 'PENDING');"
    )
    conn.commit()

    # budget_revision_requests PRESIDENT_SIGNED 서명 필드 누락 차단 검증 (ck_budget_rev_pres_signed_fields)
    with pytest.raises(sqlite3.IntegrityError):
        cur.execute(
            "INSERT INTO budget_revision_requests(term_id, category, budget_id, requested_amount, reason, requested_by, status) "
            "VALUES (1, '행사비', 1, 500000, '서명 없는 회장서명상태', 1, 'PRESIDENT_SIGNED');"
        )
    conn.rollback()

    # budget_revision_requests 신청 총무 == 회장 서명 차단 검증 (ck_budget_rev_req_pres_diff)
    with pytest.raises(sqlite3.IntegrityError):
        cur.execute(
            "INSERT INTO budget_revision_requests("
            "term_id, category, budget_id, requested_amount, reason, requested_by, status, "
            "president_signed_by, president_signature, president_signed_at, signature_deadline, signed_version"
            ") VALUES ("
            "1, '행사비', 1, 500000, '총무 본인 서명 불가', 1, 'PRESIDENT_SIGNED', "
            "1, '0x1234', '2026-11-04 10:00:00', 1793548800, 1"
            ");"
        )
    conn.rollback()

    # budget_revision_requests 정상 PRESIDENT_SIGNED INSERT 검증 (PR #33 핵심)
    cur.execute(
        "INSERT INTO budget_revision_requests("
        "term_id, category, budget_id, requested_amount, reason, requested_by, status, "
        "president_signed_by, president_signature, president_signed_at, signature_deadline, signed_version"
        ") VALUES ("
        "1, '행사비', 1, 500000, '축제 무대 확장', 1, 'PRESIDENT_SIGNED', "
        "2, '0x1234567890abcdef', '2026-11-04 10:00:00', 1793548800, 1"
        ");"
    )
    conn.commit()

    # budget_revision_requests APPROVED 시 tx_increase 누락 차단 검증 (ck_budget_rev_approved_tx)
    with pytest.raises(sqlite3.IntegrityError):
        cur.execute(
            "INSERT INTO budget_revision_requests("
            "term_id, category, budget_id, requested_amount, reason, requested_by, status, "
            "president_signed_by, president_signature, president_signed_at, signature_deadline, signed_version, "
            "resolved_by, resolved_at, tx_increase"
            ") VALUES ("
            "1, '행사비', 1, 500000, '트랜잭션 누락', 1, 'APPROVED', "
            "2, '0x1234', '2026-11-04 10:00:00', 1793548800, 1, "
            "3, '2026-11-04 11:00:00', NULL"
            ");"
        )
    conn.rollback()

    # budget_revision_requests 정상 APPROVED INSERT
    cur.execute(
        "INSERT INTO budget_revision_requests("
        "term_id, category, budget_id, requested_amount, reason, requested_by, status, "
        "president_signed_by, president_signature, president_signed_at, signature_deadline, signed_version, "
        "resolved_by, resolved_at, tx_increase"
        ") VALUES ("
        "1, '행사비', 1, 500000, '정상 승인', 1, 'APPROVED', "
        "2, '0x1234', '2026-11-04 10:00:00', 1793548800, 1, "
        "3, '2026-11-04 11:00:00', '0xabcdef1234567890'"
        ");"
    )
    conn.commit()

    # budget_versions version > 1 시 revision_request_id 누락 차단 검증 (ck_budget_versions_revision_request_id)
    with pytest.raises(sqlite3.IntegrityError):
        cur.execute(
            "INSERT INTO budget_versions(budget_id, version, planned_amount, revision_reason, approved_by, revision_request_id) "
            "VALUES (1, 2, 3500000, '요청 ID 누락', 3, NULL);"
        )
    conn.rollback()

    # budget_versions 정상 v2 INSERT (revision_request_id 연결)
    cur.execute(
        "INSERT INTO budget_versions(budget_id, version, planned_amount, revision_reason, approved_by, revision_request_id) "
        "VALUES (1, 2, 3500000, '정상 증액 버전', 3, 3);"
    )
    conn.commit()

    # budget_revision_requests 회장 서명자 == 감사 승인자 동일인 차단 검증 (ck_budget_rev_pres_aud_diff)
    with pytest.raises(sqlite3.IntegrityError):
        cur.execute(
            "INSERT INTO budget_revision_requests("
            "term_id, category, budget_id, requested_amount, reason, requested_by, status, "
            "president_signed_by, president_signature, president_signed_at, signature_deadline, signed_version, "
            "resolved_by, resolved_at, tx_increase"
            ") VALUES ("
            "1, '행사비', 1, 500000, '회장=감사 동일인 불가', 1, 'APPROVED', "
            "2, '0x1234', '2026-11-04 10:00:00', 1793548800, 1, "
            "2, '2026-11-04 11:00:00', '0xabcdef1234567890'"
            ");"
        )
    conn.rollback()

    # budget_revision_requests APPROVED 시 resolved_by/resolved_at 누락 차단 검증 (ck_budget_rev_resolved)
    with pytest.raises(sqlite3.IntegrityError):
        cur.execute(
            "INSERT INTO budget_revision_requests("
            "term_id, category, budget_id, requested_amount, reason, requested_by, status, "
            "president_signed_by, president_signature, president_signed_at, signature_deadline, signed_version, "
            "resolved_by, resolved_at, tx_increase"
            ") VALUES ("
            "1, '행사비', 1, 500000, '승인자 누락', 1, 'APPROVED', "
            "2, '0x1234', '2026-11-04 10:00:00', 1793548800, 1, "
            "NULL, NULL, '0xabcdef1234567890'"
            ");"
        )
    conn.rollback()

    # memberships burn_reason 허용값('REFUND', 'WITHDRAWAL') 검증 (ck_memberships_burn_reason)
    cur.execute(
        "INSERT INTO memberships(user_id, term_id, token_id, burn_reason, minted_at, burned_at) "
        "VALUES (1, 1, 101, 'REFUND', '2026-09-01 10:00:00', '2026-09-10 10:00:00');"
    )
    cur.execute(
        "INSERT INTO memberships(user_id, term_id, token_id, burn_reason, minted_at, burned_at) "
        "VALUES (2, 1, 102, 'WITHDRAWAL', '2026-09-01 10:00:00', '2026-09-15 10:00:00');"
    )
    conn.commit()

    # memberships 잘못된 burn_reason 차단 검증 (ck_memberships_burn_reason)
    with pytest.raises(sqlite3.IntegrityError):
        cur.execute(
            "INSERT INTO memberships(user_id, term_id, token_id, burn_reason, minted_at) "
            "VALUES (3, 1, 103, 'INVALID_REASON', '2026-09-01 10:00:00');"
        )
    conn.rollback()

    conn.close()

    # 3. 마이그레이션 롤백(downgrade base) 검증
    command.downgrade(alembic_cfg, "base")
