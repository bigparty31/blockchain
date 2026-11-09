"""add_notifications_and_device_tokens

알림 1단계 (PRD §4.8, docs/NOTIFICATION_API.md): notifications, device_tokens.
kind CHECK 는 app/schemas/notification.py 의 NotificationKind 와 같아야 한다 (tests/test_notifications.py 가 확인한다).
#68(b7e4c2d91a05, 행사·입장)이 먼저 머지되어 그 뒤에 잇는다.

Revision ID: 8257fdacf035
Revises: b7e4c2d91a05
Create Date: 2026-11-07 13:59:07.716555

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '8257fdacf035'
down_revision: Union[str, Sequence[str], None] = 'b7e4c2d91a05'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table('device_tokens',
    sa.Column('id', sa.BigInteger().with_variant(sa.Integer(), 'sqlite'), autoincrement=True, nullable=False),
    sa.Column('user_id', sa.BigInteger(), nullable=False),
    sa.Column('platform', sa.String(length=20), nullable=False),
    sa.Column('token', sa.String(length=512), nullable=False),
    sa.Column('registered_at', sa.DateTime(timezone=True), server_default=sa.text('(CURRENT_TIMESTAMP)'), nullable=False),
    sa.Column('revoked_at', sa.DateTime(timezone=True), nullable=True),
    sa.CheckConstraint("platform IN ('android')", name='ck_device_tokens_platform'),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ondelete='RESTRICT'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('token', name='uq_device_tokens_token')
    )
    with op.batch_alter_table('device_tokens', schema=None) as batch_op:
        batch_op.create_index('idx_device_tokens_user', ['user_id'], unique=False)

    op.create_table('notifications',
    sa.Column('id', sa.BigInteger().with_variant(sa.Integer(), 'sqlite'), autoincrement=True, nullable=False),
    sa.Column('user_id', sa.BigInteger(), nullable=False),
    sa.Column('kind', sa.String(length=40), nullable=False),
    sa.Column('entry_id', sa.BigInteger(), nullable=True),
    sa.Column('budget_revision_request_id', sa.BigInteger(), nullable=True),
    sa.Column('objection_id', sa.BigInteger(), nullable=True),
    sa.Column('body', sa.Text(), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('(CURRENT_TIMESTAMP)'), nullable=False),
    sa.Column('notified_at', sa.DateTime(timezone=True), server_default=sa.text('(CURRENT_TIMESTAMP)'), nullable=False),
    sa.Column('read_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('resolved_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('remind_count', sa.Integer(), server_default=sa.text('0'), nullable=False),
    sa.Column('next_remind_at', sa.DateTime(timezone=True), nullable=True),
    sa.CheckConstraint("kind IN ('ENTRY_REGISTERED', 'ENTRY_EDIT_REQUESTED', 'ENTRY_CONFIRMED', 'ENTRY_REJECTED', 'ENTRY_CONFIRM_FAILED', 'ENTRY_BLOCKED', 'REVISION_REQUESTED', 'REVISION_PRESIDENT_SIGNED', 'REVISION_APPROVED', 'REVISION_REJECTED', 'ROLE_CHANGE_REQUESTED', 'PRESIDENT_RECOVERY_PROPOSED', 'RECLASSIFY_PAIR_UNCONFIRMED', 'SIGNATURE_DEADLINE_NEAR')", name='ck_notifications_kind'),
    sa.CheckConstraint('entry_id IS NULL OR budget_revision_request_id IS NULL', name='ck_notifications_single_target'),
    sa.CheckConstraint('remind_count >= 0', name='ck_notifications_remind_count'),
    sa.ForeignKeyConstraint(['budget_revision_request_id'], ['budget_revision_requests.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['entry_id'], ['entries.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['objection_id'], ['objections.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ondelete='RESTRICT'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('notifications', schema=None) as batch_op:
        batch_op.create_index('idx_notifications_entry', ['entry_id'], unique=False)
        batch_op.create_index('idx_notifications_next_remind', ['next_remind_at'], unique=False)
        batch_op.create_index('idx_notifications_revision', ['budget_revision_request_id'], unique=False)
        batch_op.create_index('idx_notifications_user_open', ['user_id', 'resolved_at', 'read_at'], unique=False)
        # 같은 건의 안 읽은 확정 실패는 받는 사람마다 한 건 (동시 기록 중복 방지)
        batch_op.create_index(
            'uq_notifications_confirm_failed_unread',
            ['entry_id', 'user_id'],
            unique=True,
            postgresql_where=sa.text("kind = 'ENTRY_CONFIRM_FAILED' AND read_at IS NULL"),
            sqlite_where=sa.text("kind = 'ENTRY_CONFIRM_FAILED' AND read_at IS NULL"),
        )



def downgrade() -> None:
    """Downgrade schema."""
    with op.batch_alter_table('notifications', schema=None) as batch_op:
        batch_op.drop_index('uq_notifications_confirm_failed_unread')
        batch_op.drop_index('idx_notifications_user_open')
        batch_op.drop_index('idx_notifications_revision')
        batch_op.drop_index('idx_notifications_next_remind')
        batch_op.drop_index('idx_notifications_entry')

    op.drop_table('notifications')
    with op.batch_alter_table('device_tokens', schema=None) as batch_op:
        batch_op.drop_index('idx_device_tokens_user')

    op.drop_table('device_tokens')
