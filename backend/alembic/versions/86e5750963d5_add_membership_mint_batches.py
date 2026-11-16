"""add_membership_mint_batches

회원권 일괄 발행 (PRD v0.16 §4.2, §7.2, docs/API.md 「회원권 2」): membership_mint_batches, membership_mint_targets.
부모는 develop head(b7e4c2d91a05, 행사·입장)다. 알림(#78)·로그인 시도(#89)가 먼저 머지되면 down_revision 을 그 head 로 바꾼다.

Revision ID: 86e5750963d5
Revises: b7e4c2d91a05
Create Date: 2026-11-09 12:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '86e5750963d5'
down_revision: Union[str, Sequence[str], None] = 'b7e4c2d91a05'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table('membership_mint_batches',
    sa.Column('id', sa.BigInteger().with_variant(sa.Integer(), 'sqlite'), autoincrement=True, nullable=False),
    sa.Column('term_id', sa.BigInteger(), nullable=False),
    sa.Column('requested_by', sa.BigInteger(), nullable=False),
    sa.Column('signer_address', sa.String(length=42), nullable=False),
    sa.Column('nonce', sa.BigInteger(), nullable=False),
    sa.Column('status', sa.String(length=20), server_default=sa.text("'PREPARED'"), nullable=False),
    sa.Column('deadline', sa.BigInteger(), nullable=True),
    sa.Column('signature', sa.String(length=132), nullable=True),
    sa.Column('tx_hash', sa.String(length=66), nullable=True),
    sa.Column('reason', sa.String(length=40), nullable=True),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('(CURRENT_TIMESTAMP)'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('(CURRENT_TIMESTAMP)'), nullable=False),
    sa.CheckConstraint("status IN ('PREPARED', 'SUBMITTING', 'MINTED', 'REJECTED', 'NO_RESPONSE')", name='ck_mint_batches_status'),
    sa.CheckConstraint("status = 'PREPARED' OR signature IS NOT NULL", name='ck_mint_batches_signature'),
    sa.CheckConstraint("status NOT IN ('SUBMITTING', 'MINTED', 'NO_RESPONSE') OR tx_hash IS NOT NULL", name='ck_mint_batches_tx'),
    sa.CheckConstraint("status != 'REJECTED' OR reason IS NOT NULL", name='ck_mint_batches_reason'),
    sa.ForeignKeyConstraint(['requested_by'], ['users.id'], ondelete='RESTRICT'),
    sa.ForeignKeyConstraint(['term_id'], ['terms.id'], ondelete='RESTRICT'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('tx_hash', name='uq_mint_batches_tx_hash')
    )
    with op.batch_alter_table('membership_mint_batches', schema=None) as batch_op:
        batch_op.create_index('idx_mint_batches_term', ['term_id'], unique=False)

    op.create_table('membership_mint_targets',
    sa.Column('id', sa.BigInteger().with_variant(sa.Integer(), 'sqlite'), autoincrement=True, nullable=False),
    sa.Column('batch_id', sa.BigInteger(), nullable=False),
    sa.Column('position', sa.Integer(), nullable=False),
    sa.Column('user_id', sa.BigInteger(), nullable=False),
    sa.Column('address', sa.String(length=42), nullable=False),
    sa.Column('status', sa.String(length=10), server_default=sa.text("'PENDING'"), nullable=False),
    sa.Column('token_id', sa.BigInteger(), nullable=True),
    sa.Column('membership_id', sa.BigInteger(), nullable=True),
    sa.CheckConstraint("status IN ('PENDING', 'MINTED', 'SKIPPED')", name='ck_mint_targets_status'),
    sa.CheckConstraint('position >= 0 AND position < 100', name='ck_mint_targets_position'),
    sa.CheckConstraint("status != 'MINTED' OR token_id IS NOT NULL", name='ck_mint_targets_token'),
    sa.ForeignKeyConstraint(['batch_id'], ['membership_mint_batches.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['membership_id'], ['memberships.id'], ondelete='SET NULL'),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ondelete='RESTRICT'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('batch_id', 'position', name='uq_mint_targets_batch_position'),
    sa.UniqueConstraint('batch_id', 'user_id', name='uq_mint_targets_batch_user')
    )
    with op.batch_alter_table('membership_mint_targets', schema=None) as batch_op:
        batch_op.create_index('idx_mint_targets_user', ['user_id'], unique=False)


def downgrade() -> None:
    """Downgrade schema."""
    with op.batch_alter_table('membership_mint_targets', schema=None) as batch_op:
        batch_op.drop_index('idx_mint_targets_user')

    op.drop_table('membership_mint_targets')
    with op.batch_alter_table('membership_mint_batches', schema=None) as batch_op:
        batch_op.drop_index('idx_mint_batches_term')

    op.drop_table('membership_mint_batches')
