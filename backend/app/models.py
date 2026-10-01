"""
SQLAlchemy 모델 정의서 (정본 Single Source of Truth)
- 문서: docs/ERD.md (v1.2)
- 요구사항: 학생회비-투명성-시스템-PRD v0.7.md (§8 데이터 모델), 3주차_일자별_계획.md
- 대상 DB: PostgreSQL 15+ (개발/테스트 시 SQLite 호환)
"""

from datetime import datetime
from typing import List, Optional
from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    Column,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.orm import relationship

from app.database import Base

# SQLite에서는 INTEGER PRIMARY KEY여야 자동 증가(rowid)가 활성화되고,
# PostgreSQL에서는 BIGINT / BIGSERIAL로 동작하도록 variant 지정
ID_TYPE = BigInteger().with_variant(Integer, "sqlite")


# =============================================================================
# 1. 사용자 (users)
# =============================================================================
class User(Base):
    __tablename__ = "users"

    id = Column(ID_TYPE, primary_key=True, autoincrement=True, doc="고유 ID (1부터 시작)")
    student_no = Column(String(20), nullable=False, unique=True, index=True, doc="학번 (UNIQUE, 로그인 키)")
    password_hash = Column(String(255), nullable=False, doc="비밀번호 bcrypt 해시")
    name = Column(String(50), nullable=False, doc="사용자 성명")
    role = Column(String(20), nullable=False, index=True, doc="STUDENT, TREASURER, AUDITOR, PRESIDENT")
    wallet_index = Column(Integer, nullable=True, unique=True, doc="학생 HD 월렛 인덱스")
    wallet_address = Column(String(42), nullable=True, unique=True, doc="임원 EVM 지갑 주소 (0x...)")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="계정 생성 일시")

    # 관계 정의
    entries_created = relationship("Entry", foreign_keys="Entry.created_by", back_populates="creator")
    entries_approved = relationship("Entry", foreign_keys="Entry.approved_by", back_populates="approver")
    entries_rejected = relationship("Entry", foreign_keys="Entry.rejected_by", back_populates="rejecter")
    budget_versions_approved = relationship("BudgetVersion", foreign_keys="BudgetVersion.approved_by", back_populates="approver")
    budget_revisions_requested = relationship("BudgetRevisionRequest", foreign_keys="BudgetRevisionRequest.requested_by", back_populates="requester")
    budget_revisions_resolved = relationship("BudgetRevisionRequest", foreign_keys="BudgetRevisionRequest.resolved_by", back_populates="resolver")
    snapshots_uploaded = relationship("Snapshot", foreign_keys="Snapshot.uploaded_by", back_populates="uploader")
    memberships = relationship("Membership", back_populates="user")
    objections = relationship("Objection", foreign_keys="Objection.user_id", back_populates="user")
    objections_answered = relationship("Objection", foreign_keys="Objection.answered_by", back_populates="answerer")

    __table_args__ = (
        CheckConstraint("role IN ('STUDENT', 'TREASURER', 'AUDITOR', 'PRESIDENT')", name="ck_users_role"),
        CheckConstraint("role != 'STUDENT' OR wallet_index IS NOT NULL", name="ck_users_student_wallet"),
        CheckConstraint("role = 'STUDENT' OR wallet_address IS NOT NULL", name="ck_users_council_wallet"),
        CheckConstraint("wallet_address IS NULL OR wallet_address = lower(wallet_address)", name="ck_users_wallet_address_lower"),
    )


# =============================================================================
# 2. 학기 (terms)
# =============================================================================
class Term(Base):
    __tablename__ = "terms"

    id = Column(ID_TYPE, primary_key=True, autoincrement=True, doc="고유 ID (1부터 시작)")
    term_code = Column(Integer, nullable=False, unique=True, index=True, doc="온체인 학기 코드 (YYYYS 형식, 예: 20261, uint32 호환)")
    name = Column(String(50), nullable=False, unique=True, doc="학기 명칭 (예: 2026-2학기)")
    started_at = Column(DateTime(timezone=True), nullable=False, doc="학기 시작 일시")
    ended_at = Column(DateTime(timezone=True), nullable=False, doc="학기 종료 일시")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="등록 일시")

    # 관계 정의
    budgets = relationship("Budget", back_populates="term")
    budget_revisions = relationship("BudgetRevisionRequest", back_populates="term")
    entries = relationship("Entry", back_populates="term")
    snapshots = relationship("Snapshot", back_populates="term")
    memberships = relationship("Membership", back_populates="term")

    __table_args__ = (
        CheckConstraint("started_at < ended_at", name="ck_terms_dates"),
        CheckConstraint("term_code > 0", name="ck_terms_code"),
        Index("idx_terms_dates", "started_at", "ended_at"),
    )


# =============================================================================
# =============================================================================
# 3. 예산 (budgets)
# 주의: 한 (term, category)마다 체인 budgetId 1개 대응. 개정 시 row를 추가하지 않고
#       budget_versions에 버전을 기록하여 id 불변성을 보장함 (IBudgetToken.sol 호환)
# =============================================================================
class Budget(Base):
    __tablename__ = "budgets"

    id = Column(ID_TYPE, primary_key=True, autoincrement=True, doc="체인 budgetId (1부터 시작)")
    term_id = Column(BigInteger, ForeignKey("terms.id", ondelete="RESTRICT"), nullable=False, doc="학기 ID")
    category = Column(String(50), nullable=False, doc="예산 항목명")
    expires_at = Column(DateTime(timezone=True), nullable=False, doc="예산 집행 유효 만료일")
    tx_issue = Column(String(66), nullable=True, doc="v1 최초 토큰 발행 트랜잭션 해시")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="생성 일시")

    # 관계 정의
    term = relationship("Term", back_populates="budgets")
    entries = relationship("Entry", back_populates="budget")
    revision_requests = relationship("BudgetRevisionRequest", back_populates="budget")
    versions = relationship("BudgetVersion", back_populates="budget", cascade="all, delete-orphan")

    __table_args__ = (
        UniqueConstraint("term_id", "category", name="uq_budgets_term_category"),
        Index("idx_budgets_lookup", "term_id", "category"),
        {"sqlite_autoincrement": True},
    )


# =============================================================================
# 3-1. 예산 버전 이력 (budget_versions)
# 주의 1: 예산 개정 시 새 버전 row 추가 (기존 row UPDATE 금지)
# 주의 2: planned_amount는 소수점 없는 원 단위 정수 (BIGINT, int256 호환)
# =============================================================================
class BudgetVersion(Base):
    __tablename__ = "budget_versions"

    id = Column(ID_TYPE, primary_key=True, autoincrement=True, doc="고유 ID")
    budget_id = Column(BigInteger, ForeignKey("budgets.id", ondelete="RESTRICT"), nullable=False, doc="예산 ID")
    version = Column(Integer, nullable=False, server_default=text("1"), default=1, doc="예산 버전 (1: 최초, 2+: 개정)")
    planned_amount = Column(BigInteger, nullable=False, doc="편성 금액 (원 단위 정수)")
    revision_reason = Column(Text, nullable=True, doc="개정 사유 (버전 2 이상 필수)")
    approved_by = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=True, doc="승인한 감사/회장")
    tx_hash = Column(String(66), nullable=True, doc="온체인 발행/증액 TX 해시 (v1: issue, v2+: increase)")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="등록 일시")

    # 관계 정의
    budget = relationship("Budget", back_populates="versions")
    approver = relationship("User", foreign_keys=[approved_by], back_populates="budget_versions_approved")

    __table_args__ = (
        UniqueConstraint("budget_id", "version", name="uq_budget_versions_budget_version"),
        CheckConstraint("planned_amount >= 0", name="ck_budget_versions_amount"),
        CheckConstraint("version >= 1", name="ck_budget_versions_version"),
        CheckConstraint("version = 1 OR revision_reason IS NOT NULL", name="ck_budget_versions_revision_reason"),
        Index("idx_budget_versions_lookup", "budget_id", "version"),
        Index("idx_budget_versions_approved_by", "approved_by"),
    )


# =============================================================================
# 4. 예산 개정 요청 (budget_revision_requests)
# =============================================================================
class BudgetRevisionRequest(Base):
    __tablename__ = "budget_revision_requests"

    id = Column(ID_TYPE, primary_key=True, autoincrement=True, doc="고유 ID")
    term_id = Column(BigInteger, ForeignKey("terms.id", ondelete="RESTRICT"), nullable=False, doc="학기 ID")
    category = Column(String(50), nullable=False, doc="예산 항목명")
    budget_id = Column(BigInteger, ForeignKey("budgets.id", ondelete="SET NULL"), nullable=True, doc="기존 예산 ID")
    requested_amount = Column(BigInteger, nullable=False, doc="증액 요청 편성액 (원 단위 정수)")
    reason = Column(Text, nullable=False, doc="개정 요청 사유")
    requested_by = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, doc="요청 총무 ID")
    requested_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="요청 일시")
    status = Column(String(20), nullable=False, server_default=text("'PENDING'"), default="PENDING", doc="PENDING, APPROVED, REJECTED")
    resolved_by = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=True, doc="처리 감사/회장 ID")
    resolved_at = Column(DateTime(timezone=True), nullable=True, doc="처리 일시")
    reject_reason = Column(Text, nullable=True, doc="반려 사유 (서버 전용)")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="등록 일시")

    # 관계 정의
    term = relationship("Term", back_populates="budget_revisions")
    budget = relationship("Budget", back_populates="revision_requests")
    requester = relationship("User", foreign_keys=[requested_by], back_populates="budget_revisions_requested")
    resolver = relationship("User", foreign_keys=[resolved_by], back_populates="budget_revisions_resolved")

    __table_args__ = (
        CheckConstraint("status IN ('PENDING', 'APPROVED', 'REJECTED')", name="ck_budget_rev_status"),
        CheckConstraint("requested_amount >= 0", name="ck_budget_rev_amount"),
        CheckConstraint("status = 'PENDING' OR (resolved_by IS NOT NULL AND resolved_at IS NOT NULL)", name="ck_budget_rev_resolved"),
        CheckConstraint("status != 'REJECTED' OR reject_reason IS NOT NULL", name="ck_budget_rev_reject_reason"),
        CheckConstraint("resolved_by IS NULL OR requested_by != resolved_by", name="ck_budget_rev_maker_checker"),
        Index("idx_budget_rev_pending", "term_id", "status"),
        Index("idx_budget_rev_budget", "budget_id"),
        Index("idx_budget_rev_requested_by", "requested_by"),
    )


# =============================================================================
# 5. 수입·지출 원장 (entries)
# 주의 1: amount 및 ocr_amount는 원 단위 정수 (BIGINT, int256 호환)
# 주의 2: occurred_at은 사용일 KST 자정 Unix초 정수 (ts % 86400 == 54000)
# 주의 3: id는 1부터 채번 (0은 없음/NULL 예약)
# 주의 4: hash_version 기본값 1, rejected_by(반려자) 필수 포함
# =============================================================================
class Entry(Base):
    __tablename__ = "entries"

    id = Column(ID_TYPE, primary_key=True, autoincrement=True, doc="고유 ID (1부터 시작)")
    term_id = Column(BigInteger, ForeignKey("terms.id", ondelete="RESTRICT"), nullable=False, doc="학기 ID")
    kind = Column(String(20), nullable=False, doc="INCOME, EXPENSE")
    amount = Column(BigInteger, nullable=False, doc="금액 (원 단위, 정정 항목만 음수 가능)")
    counterparty = Column(String(100), nullable=False, doc="거래처 상호 또는 납부자")
    purpose = Column(Text, nullable=False, doc="지출 목적 / 내용")
    budget_id = Column(BigInteger, ForeignKey("budgets.id", ondelete="RESTRICT"), nullable=True, doc="배정 예산 ID (수입은 NULL, 지출은 선택/체인에서 예산 없으면 BLOCKED)")
    occurred_at = Column(BigInteger, nullable=False, doc="거래 발생 일자 (KST 자정 Unix초)")
    receipt_path = Column(String(255), nullable=True, doc="영수증 이미지 경로")
    receipt_hash = Column(String(66), nullable=True, doc="영수증 파일 SHA256 (0x...)")
    meta_hash = Column(String(66), nullable=True, doc="메타데이터 SHA256 (0x...)")
    hash_version = Column(Integer, nullable=False, server_default=text("1"), default=1, doc="해시 규칙 버전 (기본값 1)")
    ocr_amount = Column(BigInteger, nullable=True, doc="OCR 판독 금액 (원 단위 정수)")
    ocr_approval_no = Column(String(50), nullable=True, doc="OCR 카드 승인번호")
    ocr_paid_at = Column(BigInteger, nullable=True, doc="OCR 결제 시각 (Unix 초)")
    ocr_status = Column(String(20), nullable=True, doc="MATCH, MISMATCH, DUPLICATE 등")
    category_warning = Column(Boolean, nullable=False, server_default=text("false"), default=False, doc="용도 불일치 의심 경고")
    warning_ack_reason = Column(Text, nullable=True, doc="경고 승인 사유")
    status = Column(String(20), nullable=True, doc="초안은 NULL, 체인: PENDING, CONFIRMED, REJECTED, BLOCKED")
    block_reason = Column(String(30), nullable=True, doc="BUDGET_EXCEEDED, BUDGET_EXPIRED, BUDGET_NOT_FOUND")
    created_by = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, doc="작성 총무 ID")
    approved_by = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=True, doc="승인 감사/회장 ID")
    rejected_by = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=True, doc="반려 감사/회장 ID")
    reject_reason = Column(Text, nullable=True, doc="반려 사유")
    tx_pending = Column(String(66), nullable=True, doc="대기/차단 기록 TX 해시")
    tx_confirm = Column(String(66), nullable=True, doc="최종 확정 TX 해시")
    corrects_entry_id = Column(BigInteger, ForeignKey("entries.id", ondelete="RESTRICT"), nullable=True, doc="정정 대상 원본 Entry ID")
    correction_reason = Column(String(30), nullable=True, doc="INPUT_ERROR, RECEIPT_RECHECK, REFUND, RECLASSIFY")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="등록 일시")

    # 관계 정의
    term = relationship("Term", back_populates="entries")
    budget = relationship("Budget", back_populates="entries")
    creator = relationship("User", foreign_keys=[created_by], back_populates="entries_created")
    approver = relationship("User", foreign_keys=[approved_by], back_populates="entries_approved")
    rejecter = relationship("User", foreign_keys=[rejected_by], back_populates="entries_rejected")
    corrects_entry = relationship("Entry", remote_side=[id], backref="corrected_by_entries")
    objections = relationship("Objection", back_populates="entry")
    bank_transaction = relationship("BankTransaction", uselist=False, back_populates="matched_entry")

    __table_args__ = (
        CheckConstraint("kind IN ('INCOME', 'EXPENSE')", name="ck_entries_kind"),
        CheckConstraint("amount != 0 AND (amount > 0 OR corrects_entry_id IS NOT NULL)", name="ck_entries_amount"),
        CheckConstraint("ocr_amount IS NULL OR ocr_amount >= 0", name="ck_entries_ocr_amount"),
        CheckConstraint("status IS NULL OR status IN ('PENDING', 'CONFIRMED', 'REJECTED', 'BLOCKED')", name="ck_entries_status"),
        CheckConstraint("block_reason IS NULL OR block_reason IN ('BUDGET_EXCEEDED', 'BUDGET_EXPIRED', 'BUDGET_NOT_FOUND')", name="ck_entries_block_reason"),
        CheckConstraint("ocr_status IS NULL OR ocr_status IN ('MATCH', 'MISMATCH', 'DUPLICATE', 'NO_NUMBER', 'UNREADABLE')", name="ck_entries_ocr_status"),
        CheckConstraint("correction_reason IS NULL OR correction_reason IN ('INPUT_ERROR', 'RECEIPT_RECHECK', 'REFUND', 'RECLASSIFY')", name="ck_entries_correction_reason"),
        CheckConstraint("kind = 'EXPENSE' OR budget_id IS NULL", name="ck_entries_income_no_budget"),
        CheckConstraint("approved_by IS NULL OR created_by != approved_by", name="ck_entries_maker_checker"),
        CheckConstraint("rejected_by IS NULL OR created_by != rejected_by", name="ck_entries_rejected_maker"),
        CheckConstraint("corrects_entry_id IS NULL OR corrects_entry_id != id", name="ck_entries_no_self_correct"),
        CheckConstraint("corrects_entry_id IS NULL OR correction_reason IS NOT NULL", name="ck_entries_correct_reason_req"),
        CheckConstraint("status != 'REJECTED' OR reject_reason IS NOT NULL", name="ck_entries_reject_reason"),
        Index("idx_entries_dashboard", "term_id", "kind", "status"),
        Index("idx_entries_budget_id", "budget_id"),
        Index("idx_entries_occurred_at", "occurred_at"),
        Index("idx_entries_created_by", "created_by"),
        Index("idx_entries_approved_by", "approved_by"),
        Index("idx_entries_rejected_by", "rejected_by"),
        Index("idx_entries_corrects_entry_id", "corrects_entry_id"),
        # 영수증 중복 판정 인덱스 (PRD §6: DUPLICATE 경고 조회용 일반 인덱스)
        Index("idx_entries_ocr_dup", "ocr_approval_no", "ocr_paid_at", "amount"),
        {"sqlite_autoincrement": True},
    )


# =============================================================================
# 6. 통장 스냅샷 (snapshots)
# =============================================================================
class Snapshot(Base):
    __tablename__ = "snapshots"

    id = Column(ID_TYPE, primary_key=True, autoincrement=True, doc="고유 ID")
    term_id = Column(BigInteger, ForeignKey("terms.id", ondelete="RESTRICT"), nullable=False, doc="학기 ID")
    bank_balance = Column(BigInteger, nullable=False, doc="통장 잔액 (원 단위 정수)")
    snapshot_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="스냅샷 일시")
    csv_path = Column(String(255), nullable=True, doc="CSV 파일 경로")
    file_hash = Column(String(66), nullable=True, doc="원본 CSV 바이트 SHA256 해시 (0x...)")
    uploaded_by = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=True, doc="업로드 총무 ID")
    tx_hash = Column(String(66), nullable=True, doc="온체인 기록 TX 해시")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="등록 일시")

    # 관계 정의
    term = relationship("Term", back_populates="snapshots")
    uploader = relationship("User", foreign_keys=[uploaded_by], back_populates="snapshots_uploaded")
    bank_transactions = relationship("BankTransaction", back_populates="snapshot", cascade="all, delete-orphan")

    __table_args__ = (
        CheckConstraint("bank_balance >= 0", name="ck_snapshots_balance"),
        Index("idx_snapshots_term_at", "term_id", "snapshot_at"),
        Index("idx_snapshots_uploaded_by", "uploaded_by"),
    )


# =============================================================================
# 7. 은행 거래 내역 대조 (bank_transactions)
# =============================================================================
class BankTransaction(Base):
    __tablename__ = "bank_transactions"

    id = Column(ID_TYPE, primary_key=True, autoincrement=True, doc="고유 ID")
    snapshot_id = Column(BigInteger, ForeignKey("snapshots.id", ondelete="CASCADE"), nullable=False, doc="스냅샷 ID")
    tran_date = Column(String(10), nullable=False, doc="거래일자 (YYYY-MM-DD)")
    tran_time = Column(String(8), nullable=True, doc="거래시각 (HH:MM:SS)")
    description = Column(String(100), nullable=False, doc="적요 원문")
    direction = Column(String(10), nullable=False, doc="IN, OUT")
    amount = Column(BigInteger, nullable=False, doc="거래 금액 (원 단위 양의 정수)")
    balance_after = Column(BigInteger, nullable=False, doc="거래 후 계좌 잔액 (원 단위 정수)")
    matched_entry_id = Column(BigInteger, ForeignKey("entries.id", ondelete="SET NULL"), nullable=True, doc="대응 원장 ID (1:1 소모 매칭)")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="등록 일시")

    # 관계 정의
    snapshot = relationship("Snapshot", back_populates="bank_transactions")
    matched_entry = relationship("Entry", back_populates="bank_transaction")

    __table_args__ = (
        CheckConstraint("direction IN ('IN', 'OUT')", name="ck_bank_tran_direction"),
        CheckConstraint("amount > 0", name="ck_bank_tran_amount"),
        CheckConstraint("balance_after >= 0", name="ck_bank_tran_balance"),
        Index("idx_bank_tran_snapshot", "snapshot_id"),
        Index(
            "uq_bank_tran_matched_entry",
            "matched_entry_id",
            unique=True,
            postgresql_where=text("matched_entry_id IS NOT NULL"),
            sqlite_where=text("matched_entry_id IS NOT NULL"),
        ),
        Index("idx_bank_tran_unmatched", "snapshot_id", "matched_entry_id"),
    )


# =============================================================================
# 8. SBT 회원권 (memberships)
# =============================================================================
class Membership(Base):
    __tablename__ = "memberships"

    id = Column(ID_TYPE, primary_key=True, autoincrement=True, doc="고유 ID")
    user_id = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, doc="학생 ID")
    term_id = Column(BigInteger, ForeignKey("terms.id", ondelete="RESTRICT"), nullable=False, doc="학기 ID")
    token_id = Column(BigInteger, nullable=False, unique=True, doc="온체인 ERC-721 토큰 ID")
    commit_hash = Column(String(66), nullable=False, doc="학번+salt 커밋 해시 (0x...)")
    minted_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="발급 일시")
    burned_at = Column(DateTime(timezone=True), nullable=True, doc="소각/환불 회수 일시")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="등록 일시")

    # 관계 정의
    user = relationship("User", back_populates="memberships")
    term = relationship("Term", back_populates="memberships")

    __table_args__ = (
        CheckConstraint("burned_at IS NULL OR burned_at >= minted_at", name="ck_memberships_burn_date"),
        Index(
            "uq_memberships_active_user_term",
            "user_id",
            "term_id",
            unique=True,
            postgresql_where=text("burned_at IS NULL"),
            sqlite_where=text("burned_at IS NULL"),
        ),
        Index("idx_memberships_lookup", "user_id", "term_id"),
        Index("idx_memberships_commit_hash", "commit_hash"),
    )


# =============================================================================
# 9. 이의 제기 (objections)
# =============================================================================
class Objection(Base):
    __tablename__ = "objections"

    id = Column(ID_TYPE, primary_key=True, autoincrement=True, doc="고유 ID")
    entry_id = Column(BigInteger, ForeignKey("entries.id", ondelete="RESTRICT"), nullable=False, doc="대상 지출 ID")
    user_id = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, doc="제기 학생 ID")
    content = Column(Text, nullable=False, doc="이의 질문 본문")
    answer = Column(Text, nullable=True, doc="학생회 공식 답변 본문")
    answered_by = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=True, doc="답변한 임원 ID")
    status = Column(String(20), nullable=False, server_default=text("'OPEN'"), default="OPEN", doc="OPEN, ANSWERED")
    raised_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="제기 일시")
    answered_at = Column(DateTime(timezone=True), nullable=True, doc="답변 완료 일시")
    tx_raise = Column(String(66), nullable=True, doc="이의 제기 온체인 TX 해시")
    tx_answer = Column(String(66), nullable=True, doc="답변 기록 온체인 TX 해시")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="등록 일시")

    # 관계 정의
    entry = relationship("Entry", back_populates="objections")
    user = relationship("User", foreign_keys=[user_id], back_populates="objections")
    answerer = relationship("User", foreign_keys=[answered_by], back_populates="objections_answered")

    __table_args__ = (
        CheckConstraint("status IN ('OPEN', 'ANSWERED')", name="ck_objections_status"),
        CheckConstraint("status = 'OPEN' OR (answer IS NOT NULL AND answered_by IS NOT NULL AND answered_at IS NOT NULL)", name="ck_objections_answered_state"),
        CheckConstraint("answered_at IS NULL OR answered_at >= raised_at", name="ck_objections_dates"),
        Index("idx_objections_entry_id", "entry_id"),
        Index("idx_objections_status", "status"),
    )
