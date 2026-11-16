"""add_events_and_check_ins

행사(Event)·입장 기록(CheckIn) 테이블 추가 — PRD v0.15 §4.2, §8.
한 행사에 한 학생은 한 번만 입장할 수 있다 (uq_check_ins_event_user).

Revision ID: b7e4c2d91a05
Revises: 8c6ab430f272
Create Date: 2026-11-06 12:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'b7e4c2d91a05'
down_revision: Union[str, Sequence[str], None] = '8c6ab430f272'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# 모델과 같은 규칙: SQLite 에서는 INTEGER PRIMARY KEY 여야 자동 증가가 된다
ID_TYPE = sa.BigInteger().with_variant(sa.Integer(), "sqlite")


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table('events',
    sa.Column('id', ID_TYPE, autoincrement=True, nullable=False),
    sa.Column('term_id', sa.BigInteger(), nullable=False),
    sa.Column('name', sa.String(length=100), nullable=False),
    sa.Column('held_at', sa.DateTime(timezone=True), nullable=False),
    sa.Column('created_by', sa.BigInteger(), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('(CURRENT_TIMESTAMP)'), nullable=False),
    sa.ForeignKeyConstraint(['created_by'], ['users.id'], ondelete='RESTRICT'),
    sa.ForeignKeyConstraint(['term_id'], ['terms.id'], ondelete='RESTRICT'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('events', schema=None) as batch_op:
        batch_op.create_index('idx_events_term_id', ['term_id'], unique=False)

    op.create_table('check_ins',
    sa.Column('id', ID_TYPE, autoincrement=True, nullable=False),
    sa.Column('event_id', sa.BigInteger(), nullable=False),
    sa.Column('user_id', sa.BigInteger(), nullable=False),
    sa.Column('scanned_by', sa.BigInteger(), nullable=False),
    sa.Column('scanned_at', sa.DateTime(timezone=True), server_default=sa.text('(CURRENT_TIMESTAMP)'), nullable=False),
    sa.ForeignKeyConstraint(['event_id'], ['events.id'], ondelete='RESTRICT'),
    sa.ForeignKeyConstraint(['scanned_by'], ['users.id'], ondelete='RESTRICT'),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ondelete='RESTRICT'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('event_id', 'user_id', name='uq_check_ins_event_user')
    )
    with op.batch_alter_table('check_ins', schema=None) as batch_op:
        batch_op.create_index('idx_check_ins_user_id', ['user_id'], unique=False)


def downgrade() -> None:
    """Downgrade schema."""
    with op.batch_alter_table('check_ins', schema=None) as batch_op:
        batch_op.drop_index('idx_check_ins_user_id')
    op.drop_table('check_ins')

    with op.batch_alter_table('events', schema=None) as batch_op:
        batch_op.drop_index('idx_events_term_id')
    op.drop_table('events')
