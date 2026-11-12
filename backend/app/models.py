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
from app.schemas.notification import NotificationKind

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
    budget_revisions_president_signed = relationship("BudgetRevisionRequest", foreign_keys="BudgetRevisionRequest.president_signed_by", back_populates="president_signer")
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
    revision_request_id = Column(BigInteger, ForeignKey("budget_revision_requests.id", ondelete="SET NULL"), nullable=True, doc="근거 증액 요청 ID (v2+ 필수)")
    tx_hash = Column(String(66), nullable=True, doc="온체인 발행/증액 TX 해시 (v1: issue, v2+: increase)")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="등록 일시")

    # 관계 정의
    budget = relationship("Budget", back_populates="versions")
    approver = relationship("User", foreign_keys=[approved_by], back_populates="budget_versions_approved")
    revision_request = relationship("BudgetRevisionRequest", back_populates="budget_version")

    __table_args__ = (
        UniqueConstraint("budget_id", "version", name="uq_budget_versions_budget_version"),
        CheckConstraint("planned_amount >= 0", name="ck_budget_versions_amount"),
        CheckConstraint("version >= 1", name="ck_budget_versions_version"),
        CheckConstraint("version = 1 OR revision_reason IS NOT NULL", name="ck_budget_versions_revision_reason"),
        CheckConstraint("version = 1 OR revision_request_id IS NOT NULL", name="ck_budget_versions_revision_request_id"),
        Index("idx_budget_versions_lookup", "budget_id", "version"),
        Index("idx_budget_versions_approved_by", "approved_by"),
        Index("idx_budget_versions_revision_request_id", "revision_request_id"),
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
    blocked_entry_id = Column(BigInteger, ForeignKey("entries.id", ondelete="SET NULL"), nullable=True, doc="근거 차단 지출 ID")
    requested_amount = Column(BigInteger, nullable=False, doc="증액분 요청액 (원 단위 양의 정수)")
    reason = Column(Text, nullable=False, doc="개정 요청 사유")
    requested_by = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, doc="요청 총무 ID")
    requested_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="요청 일시")
    status = Column(String(20), nullable=False, server_default=text("'PENDING'"), default="PENDING", doc="PENDING, PRESIDENT_SIGNED, APPROVED, REJECTED")
    president_signed_by = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=True, doc="요청 서명 회장 ID")
    president_signature = Column(String(132), nullable=True, doc="회장의 EIP-712 IncreaseRequest 서명값")
    president_signed_at = Column(DateTime(timezone=True), nullable=True, doc="회장 서명 일시")
    signature_deadline = Column(BigInteger, nullable=True, doc="회장 서명 시한 (Unix 초)")
    signed_version = Column(Integer, nullable=True, doc="서명 대상 온체인 버전 (감사 승인 시 재구성용)")
    tx_increase = Column(String(66), nullable=True, doc="증액 릴레이 트랜잭션 해시 (선점용)")
    resolved_by = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=True, doc="최종 처리 감사/회장 ID")
    resolved_at = Column(DateTime(timezone=True), nullable=True, doc="처리 일시")
    reject_reason = Column(Text, nullable=True, doc="반려 사유 (서버 전용)")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="등록 일시")

    # 관계 정의
    term = relationship("Term", back_populates="budget_revisions")
    budget = relationship("Budget", back_populates="revision_requests")
    blocked_entry = relationship("Entry", foreign_keys=[blocked_entry_id], back_populates="budget_revisions_triggered")
    requester = relationship("User", foreign_keys=[requested_by], back_populates="budget_revisions_requested")
    president_signer = relationship("User", foreign_keys=[president_signed_by], back_populates="budget_revisions_president_signed")
    resolver = relationship("User", foreign_keys=[resolved_by], back_populates="budget_revisions_resolved")
    budget_version = relationship("BudgetVersion", uselist=False, back_populates="revision_request")

    __table_args__ = (
        CheckConstraint("status IN ('PENDING', 'PRESIDENT_SIGNED', 'APPROVED', 'REJECTED')", name="ck_budget_rev_status"),
        CheckConstraint("requested_amount > 0", name="ck_budget_rev_amount"),
        CheckConstraint(
            "status != 'PRESIDENT_SIGNED' OR (president_signed_by IS NOT NULL AND president_signature IS NOT NULL AND president_signed_at IS NOT NULL AND signature_deadline IS NOT NULL AND signed_version IS NOT NULL)",
            name="ck_budget_rev_pres_signed_fields",
        ),
        CheckConstraint("status NOT IN ('APPROVED', 'REJECTED') OR (resolved_by IS NOT NULL AND resolved_at IS NOT NULL)", name="ck_budget_rev_resolved"),
        CheckConstraint("status != 'REJECTED' OR reject_reason IS NOT NULL", name="ck_budget_rev_reject_reason"),
        CheckConstraint("resolved_by IS NULL OR requested_by != resolved_by", name="ck_budget_rev_maker_checker"),
        CheckConstraint("president_signed_by IS NULL OR requested_by != president_signed_by", name="ck_budget_rev_req_pres_diff"),
        CheckConstraint("status != 'APPROVED' OR president_signed_by IS NULL OR resolved_by != president_signed_by", name="ck_budget_rev_pres_aud_diff"),
        CheckConstraint("status != 'APPROVED' OR tx_increase IS NOT NULL", name="ck_budget_rev_approved_tx"),
        Index("idx_budget_rev_pending", "term_id", "status"),
        Index("idx_budget_rev_budget", "budget_id"),
        Index("idx_budget_rev_requested_by", "requested_by"),
        Index("idx_budget_rev_blocked_entry", "blocked_entry_id"),
        Index("idx_budget_rev_president_signed_by", "president_signed_by"),
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
    tx_confirm = Column(String(66), nullable=True, doc="확정 또는 반려 TX 해시 (한 칸을 함께 선점한다)")
    corrects_entry_id = Column(BigInteger, ForeignKey("entries.id", ondelete="RESTRICT"), nullable=True, doc="정정 대상 원본 Entry ID")
    correction_reason = Column(String(30), nullable=True, doc="INPUT_ERROR, RECEIPT_RECHECK, REFUND, RECLASSIFY, OTHER")
    revision_requested_at = Column(DateTime(timezone=True), nullable=True, doc="T4 수정 요청 일시 (값이 있으면 승인 릴레이 차단)")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="등록 일시")

    # 관계 정의
    term = relationship("Term", back_populates="entries")
    budget = relationship("Budget", back_populates="entries")
    creator = relationship("User", foreign_keys=[created_by], back_populates="entries_created")
    approver = relationship("User", foreign_keys=[approved_by], back_populates="entries_approved")
    rejecter = relationship("User", foreign_keys=[rejected_by], back_populates="entries_rejected")
    corrects_entry = relationship("Entry", remote_side=[id], backref="corrected_by_entries")
    budget_revisions_triggered = relationship("BudgetRevisionRequest", back_populates="blocked_entry")
    objections = relationship("Objection", back_populates="entry")
    bank_transaction = relationship("BankTransaction", uselist=False, back_populates="matched_entry")

    __table_args__ = (
        CheckConstraint("kind IN ('INCOME', 'EXPENSE')", name="ck_entries_kind"),
        CheckConstraint("amount != 0 AND (amount > 0 OR corrects_entry_id IS NOT NULL)", name="ck_entries_amount"),
        CheckConstraint("ocr_amount IS NULL OR ocr_amount >= 0", name="ck_entries_ocr_amount"),
        CheckConstraint("status IS NULL OR status IN ('PENDING', 'CONFIRMED', 'REJECTED', 'BLOCKED')", name="ck_entries_status"),
        CheckConstraint("block_reason IS NULL OR block_reason IN ('BUDGET_EXCEEDED', 'BUDGET_EXPIRED', 'BUDGET_NOT_FOUND')", name="ck_entries_block_reason"),
        CheckConstraint("ocr_status IS NULL OR ocr_status IN ('MATCH', 'MISMATCH', 'DUPLICATE', 'NO_NUMBER', 'UNREADABLE')", name="ck_entries_ocr_status"),
        CheckConstraint("correction_reason IS NULL OR correction_reason IN ('INPUT_ERROR', 'RECEIPT_RECHECK', 'REFUND', 'RECLASSIFY', 'OTHER')", name="ck_entries_correction_reason"),
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
    burn_reason = Column(String(30), nullable=True, doc="소각 사유 (REFUND, WITHDRAWAL)")
    minted_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="발급 일시")
    burned_at = Column(DateTime(timezone=True), nullable=True, doc="소각/환불 회수 일시")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="등록 일시")

    # 관계 정의
    user = relationship("User", back_populates="memberships")
    term = relationship("Term", back_populates="memberships")

    __table_args__ = (
        CheckConstraint("burned_at IS NULL OR burned_at >= minted_at", name="ck_memberships_burn_date"),
        CheckConstraint("burn_reason IS NULL OR burn_reason IN ('REFUND', 'WITHDRAWAL')", name="ck_memberships_burn_reason"),
        Index(
            "uq_memberships_active_user_term",
            "user_id",
            "term_id",
            unique=True,
            postgresql_where=text("burned_at IS NULL"),
            sqlite_where=text("burned_at IS NULL"),
        ),
        Index("idx_memberships_lookup", "user_id", "term_id"),
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


# =============================================================================
# 10. 행사 (events) — PRD v0.15 §4.2, §8
# =============================================================================
class Event(Base):
    __tablename__ = "events"

    id = Column(ID_TYPE, primary_key=True, autoincrement=True, doc="고유 ID")
    term_id = Column(BigInteger, ForeignKey("terms.id", ondelete="RESTRICT"), nullable=False, doc="학기 ID (이 학기 회원권으로 입장 판정)")
    name = Column(String(100), nullable=False, doc="행사명")
    held_at = Column(DateTime(timezone=True), nullable=False, doc="행사 일시")
    created_by = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, doc="등록한 임원 ID")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="등록 일시")

    # 관계 정의 — 기존 User·Term 클래스는 건드리지 않으려고 back_populates 없이 단방향으로 둔다
    term = relationship("Term")
    creator = relationship("User", foreign_keys=[created_by])
    check_ins = relationship("CheckIn", back_populates="event")

    __table_args__ = (
        Index("idx_events_term_id", "term_id"),
    )


# =============================================================================
# 11. 입장 기록 (check_ins) — 한 행사에 한 학생은 한 번만 입장 (PRD v0.15 §4.2)
# =============================================================================
class CheckIn(Base):
    __tablename__ = "check_ins"

    id = Column(ID_TYPE, primary_key=True, autoincrement=True, doc="고유 ID")
    event_id = Column(BigInteger, ForeignKey("events.id", ondelete="RESTRICT"), nullable=False, doc="행사 ID")
    user_id = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, doc="입장한 학생 ID")
    scanned_by = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, doc="스캔한 임원 ID")
    scanned_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="입장 일시")

    # 관계 정의
    event = relationship("Event", back_populates="check_ins")
    user = relationship("User", foreign_keys=[user_id])
    scanner = relationship("User", foreign_keys=[scanned_by])

    __table_args__ = (
        # 중복 입장 차단의 최종 방어선. 동시에 두 번 스캔돼도 DB 가 하나만 받는다
        UniqueConstraint("event_id", "user_id", name="uq_check_ins_event_user"),
        Index("idx_check_ins_user_id", "user_id"),
    )


# =============================================================================
# 12. 알림 (notifications, device_tokens) — PRD §4.8, docs/NOTIFICATION_API.md
# =============================================================================
# 재알림 대상 종류. 처리되면 닫히고(resolved_at), 재알림 작업이 next_remind_at 으로 다시 알린다
NOTIFICATION_REMIND_KINDS = (
    NotificationKind.ENTRY_REGISTERED.value,
    NotificationKind.ENTRY_EDIT_REQUESTED.value,
    NotificationKind.REVISION_REQUESTED.value,
    NotificationKind.REVISION_PRESIDENT_SIGNED.value,
    NotificationKind.SIGNATURE_DEADLINE_NEAR.value,
)

# 안 읽은 확정 실패 알림 (uq_notifications_confirm_failed_unread 의 조건)
CONFIRM_FAILED_UNREAD = f"kind = '{NotificationKind.ENTRY_CONFIRM_FAILED.value}' AND read_at IS NULL"


class Notification(Base):
    """임원 한 명에게 간 알림 한 건. 학생에게는 행을 만들지 않는다 — 학생은 FCM 토픽 푸시만 받는다 (PRD §4.8).

    대상 건(항목·증액 요청·이의)이 지워지면 알림도 함께 지운다(CASCADE). 알림은 파생 데이터라 본 데이터 삭제를 막지 않는다 —
    예: 예산 발행이 시드 더미 증액 요청을 정리할 때 (routers/budgets.py _cleanup_unissued_seed_versions).
    """

    __tablename__ = "notifications"

    id = Column(ID_TYPE, primary_key=True, autoincrement=True, doc="고유 ID")
    user_id = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, doc="받는 임원 ID")
    kind = Column(String(40), nullable=False, doc="docs/enums.md notification kind")
    entry_id = Column(BigInteger, ForeignKey("entries.id", ondelete="CASCADE"), nullable=True, doc="대상 항목")
    budget_revision_request_id = Column(
        BigInteger, ForeignKey("budget_revision_requests.id", ondelete="CASCADE"), nullable=True, doc="대상 증액 요청"
    )
    objection_id = Column(
        BigInteger, ForeignKey("objections.id", ondelete="CASCADE"), nullable=True, doc="대상 이의 (v0.13 범위 밖이라 비어 있다)"
    )
    body = Column(Text, nullable=False, doc="서버가 kind 로 만든 문구. 만들 때 저장한다")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="처음 알린 일시")
    notified_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="마지막으로 알린 일시 (목록 정렬 기준)")
    read_at = Column(DateTime(timezone=True), nullable=True, doc="읽은 일시. 재알림 때 비운다")
    resolved_at = Column(DateTime(timezone=True), nullable=True, doc="처리돼 닫힌 일시. 재알림 대상 종류만 닫힌다")
    remind_count = Column(Integer, nullable=False, server_default=text("0"), default=0, doc="재알림 횟수 (최대 3)")
    next_remind_at = Column(DateTime(timezone=True), nullable=True, doc="다음 재알림 일시. 재알림 대상이 아니거나 끝났으면 NULL")

    __table_args__ = (
        CheckConstraint(
            "kind IN (" + ", ".join(f"'{kind.value}'" for kind in NotificationKind) + ")",
            name="ck_notifications_kind",
        ),
        CheckConstraint("entry_id IS NULL OR budget_revision_request_id IS NULL", name="ck_notifications_single_target"),
        CheckConstraint("remind_count >= 0", name="ck_notifications_remind_count"),
        Index("idx_notifications_user_open", "user_id", "resolved_at", "read_at"),
        Index("idx_notifications_entry", "entry_id"),
        Index("idx_notifications_revision", "budget_revision_request_id"),
        Index("idx_notifications_next_remind", "next_remind_at"),
        # 같은 건의 확정 실패는 받는 사람마다 안 읽은 알림이 한 건이다. 실패 기록이 동시에 두 번 와도 DB 가 막는다
        # (create_notification 은 이 인덱스에 걸리면 건너뛴다). 읽은 뒤 다시 실패하면 새 행이 들어간다
        Index(
            "uq_notifications_confirm_failed_unread",
            "entry_id",
            "user_id",
            unique=True,
            postgresql_where=text(CONFIRM_FAILED_UNREAD),
            sqlite_where=text(CONFIRM_FAILED_UNREAD),
        ),
    )


class DeviceToken(Base):
    """임원 기기의 FCM 등록 토큰 (학생회 서버에 등록). 학생은 토픽을 구독하므로 등록하지 않는다."""

    __tablename__ = "device_tokens"

    id = Column(ID_TYPE, primary_key=True, autoincrement=True, doc="고유 ID")
    user_id = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, doc="임원 ID")
    platform = Column(String(20), nullable=False, doc="android (iOS 제외, PRD §4.8)")
    token = Column(String(512), nullable=False, doc="FCM 등록 토큰. 한 기기에 한 행 — 다른 사람이 올리면 그 사람에게 넘어간다")
    registered_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="등록(또는 넘겨받은) 일시")
    revoked_at = Column(DateTime(timezone=True), nullable=True, doc="해제 일시 (로그아웃, FCM 무효 응답)")

    __table_args__ = (
        CheckConstraint("platform IN ('android')", name="ck_device_tokens_platform"),
        UniqueConstraint("token", name="uq_device_tokens_token"),
        Index("idx_device_tokens_user", "user_id"),
    )


# =============================================================================
# 14. 회원권 일괄 발행 요청 (membership_mint_batches, membership_mint_targets) — PRD v0.16 §4.2, §7.2
#     13번은 로그인 시도(#89) 자리다
# =============================================================================
# 요청 상태 (docs/API.md 「회원권 2」). PREPARED·REJECTED 만 제출할 수 있다
MINT_BATCH_STATUSES = ("PREPARED", "SUBMITTING", "MINTED", "REJECTED", "NO_RESPONSE")
# 대상 결과. SKIPPED 는 이미 유효해 컨트랙트가 건너뛴 학생
MINT_TARGET_STATUSES = ("PENDING", "MINTED", "SKIPPED")


class MembershipMintBatch(Base):
    """회원권 일괄 발행 한 묶음 (1~100명). 준비 때 서명할 값(nonce·수령자 순서)을 고정해 두고, 제출 때 그 값으로 서명을 확인한다.

    서명자는 준비한 임원 한 명이다 — nonce 가 서명자마다 따로라 다른 임원의 서명으로는 낼 수 없다.
    tx_hash 는 보내기 직전에 조건부 UPDATE 로 선점한다(SUBMITTING). 응답을 잃으면(NO_RESPONSE) 같은 서명을 다시 보내지 않고
    이 hash 로 결과를 확인한다 — 들어갔으면 nonce 가 올라 재전송은 InvalidNonce 로 보여 결과를 잃는다.
    """

    __tablename__ = "membership_mint_batches"

    id = Column(ID_TYPE, primary_key=True, autoincrement=True, doc="고유 ID")
    term_id = Column(BigInteger, ForeignKey("terms.id", ondelete="RESTRICT"), nullable=False, doc="발행 학기")
    requested_by = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, doc="준비한 임원 (회장·감사)")
    signer_address = Column(String(42), nullable=False, doc="서명할 지갑 주소 (준비할 때 requested_by 의 wallet_address, 소문자)")
    nonce = Column(BigInteger, nullable=False, doc="준비할 때 읽은 MembershipSBT.nonces(signer). 성공마다 1씩 올라 int64 를 넘지 않는다")
    status = Column(String(20), nullable=False, server_default=text("'PREPARED'"), default="PREPARED", doc="요청 상태")
    deadline = Column(BigInteger, nullable=True, doc="제출한 서명의 유효 시한 (Unix 초). API 가 int64 범위로 받는다")
    signature = Column(String(132), nullable=True, doc="제출한 서명 (0x + 130자)")
    tx_hash = Column(String(66), nullable=True, doc="보낸(보내는 중인) 트랜잭션 hash. 보내기 직전에 선점한다")
    reason = Column(String(40), nullable=True, doc="REJECTED 사유 (Solidity 에러 이름 또는 Unknown)")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="준비 일시")
    updated_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), doc="마지막 상태 변경 일시")

    term = relationship("Term")
    requester = relationship("User", foreign_keys=[requested_by])
    targets = relationship(
        "MembershipMintTarget", back_populates="batch", order_by="MembershipMintTarget.position", cascade="all, delete-orphan"
    )

    __table_args__ = (
        CheckConstraint(
            "status IN (" + ", ".join(f"'{s}'" for s in MINT_BATCH_STATUSES) + ")", name="ck_mint_batches_status"
        ),
        CheckConstraint("status = 'PREPARED' OR signature IS NOT NULL", name="ck_mint_batches_signature"),
        CheckConstraint("status NOT IN ('SUBMITTING', 'MINTED', 'NO_RESPONSE') OR tx_hash IS NOT NULL", name="ck_mint_batches_tx"),
        CheckConstraint("status != 'REJECTED' OR reason IS NOT NULL", name="ck_mint_batches_reason"),
        UniqueConstraint("tx_hash", name="uq_mint_batches_tx_hash"),
        Index("idx_mint_batches_term", "term_id"),
    )


class MembershipMintTarget(Base):
    """일괄 발행의 대상 학생 한 명. position 순서가 서명한 recipients 배열의 순서다."""

    __tablename__ = "membership_mint_targets"

    id = Column(ID_TYPE, primary_key=True, autoincrement=True, doc="고유 ID")
    batch_id = Column(BigInteger, ForeignKey("membership_mint_batches.id", ondelete="CASCADE"), nullable=False, doc="요청 ID")
    position = Column(Integer, nullable=False, doc="recipients 배열의 자리 (0부터)")
    user_id = Column(BigInteger, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, doc="학생 ID")
    address = Column(String(42), nullable=False, doc="학생 지갑 주소 (EIP-55). 서명 대상")
    status = Column(String(10), nullable=False, server_default=text("'PENDING'"), default="PENDING", doc="대상 결과")
    token_id = Column(BigInteger, nullable=True, doc="발행됐거나 이미 있던 회원권의 tokenId")
    membership_id = Column(
        BigInteger, ForeignKey("memberships.id", ondelete="SET NULL"), nullable=True, doc="만든(또는 있던) DB 회원권 기록"
    )

    batch = relationship("MembershipMintBatch", back_populates="targets")
    user = relationship("User", foreign_keys=[user_id])

    __table_args__ = (
        CheckConstraint(
            "status IN (" + ", ".join(f"'{s}'" for s in MINT_TARGET_STATUSES) + ")", name="ck_mint_targets_status"
        ),
        CheckConstraint("position >= 0 AND position < 100", name="ck_mint_targets_position"),
        CheckConstraint("status != 'MINTED' OR token_id IS NOT NULL", name="ck_mint_targets_token"),
        UniqueConstraint("batch_id", "position", name="uq_mint_targets_batch_position"),
        UniqueConstraint("batch_id", "user_id", name="uq_mint_targets_batch_user"),
        Index("idx_mint_targets_user", "user_id"),
    )
