"""add_budget_revision_and_v013_fields

Revision ID: 8c6ab430f272
Revises: ca18aa2570a9
Create Date: 2026-11-03 12:56:04.718737

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '8c6ab430f272'
down_revision: Union[str, Sequence[str], None] = 'ca18aa2570a9'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    with op.batch_alter_table('budget_revision_requests', schema=None) as batch_op:
        batch_op.add_column(sa.Column('blocked_entry_id', sa.BigInteger(), nullable=True))
        batch_op.add_column(sa.Column('president_signed_by', sa.BigInteger(), nullable=True))
        batch_op.add_column(sa.Column('president_signature', sa.String(length=132), nullable=True))
        batch_op.add_column(sa.Column('president_signed_at', sa.DateTime(timezone=True), nullable=True))
        batch_op.add_column(sa.Column('signature_deadline', sa.BigInteger(), nullable=True))
        batch_op.add_column(sa.Column('signed_version', sa.Integer(), nullable=True))
        batch_op.add_column(sa.Column('tx_increase', sa.String(length=66), nullable=True))
        batch_op.create_index('idx_budget_rev_blocked_entry', ['blocked_entry_id'], unique=False)
        batch_op.create_index('idx_budget_rev_president_signed_by', ['president_signed_by'], unique=False)
        batch_op.create_foreign_key('fk_budget_rev_blocked_entry', 'entries', ['blocked_entry_id'], ['id'], ondelete='SET NULL')
        batch_op.create_foreign_key('fk_budget_rev_president_signed_by', 'users', ['president_signed_by'], ['id'], ondelete='RESTRICT')

    with op.batch_alter_table('budget_versions', schema=None) as batch_op:
        batch_op.add_column(sa.Column('revision_request_id', sa.BigInteger(), nullable=True))
        batch_op.create_index('idx_budget_versions_revision_request_id', ['revision_request_id'], unique=False)
        batch_op.create_foreign_key('fk_budget_versions_revision_request', 'budget_revision_requests', ['revision_request_id'], ['id'], ondelete='SET NULL')

    with op.batch_alter_table('entries', schema=None) as batch_op:
        batch_op.add_column(sa.Column('revision_requested_at', sa.DateTime(timezone=True), nullable=True))

    with op.batch_alter_table('memberships', schema=None) as batch_op:
        batch_op.add_column(sa.Column('burn_reason', sa.String(length=30), nullable=True))
        batch_op.alter_column('commit_hash',
               existing_type=sa.VARCHAR(length=66),
               nullable=True)


def downgrade() -> None:
    """Downgrade schema."""
    with op.batch_alter_table('memberships', schema=None) as batch_op:
        batch_op.alter_column('commit_hash',
               existing_type=sa.VARCHAR(length=66),
               nullable=False)
        batch_op.drop_column('burn_reason')

    with op.batch_alter_table('entries', schema=None) as batch_op:
        batch_op.drop_column('revision_requested_at')

    with op.batch_alter_table('budget_versions', schema=None) as batch_op:
        batch_op.drop_constraint('fk_budget_versions_revision_request', type_='foreignkey')
        batch_op.drop_index('idx_budget_versions_revision_request_id')
        batch_op.drop_column('revision_request_id')

    with op.batch_alter_table('budget_revision_requests', schema=None) as batch_op:
        batch_op.drop_constraint('fk_budget_rev_president_signed_by', type_='foreignkey')
        batch_op.drop_constraint('fk_budget_rev_blocked_entry', type_='foreignkey')
        batch_op.drop_index('idx_budget_rev_president_signed_by')
        batch_op.drop_index('idx_budget_rev_blocked_entry')
        batch_op.drop_column('tx_increase')
        batch_op.drop_column('signed_version')
        batch_op.drop_column('signature_deadline')
        batch_op.drop_column('president_signed_at')
        batch_op.drop_column('president_signature')
        batch_op.drop_column('president_signed_by')
        batch_op.drop_column('blocked_entry_id')
