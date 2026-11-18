"""add_ocr_readings

영수증 판독 기록(OcrReading) 테이블 추가 — PRD §6, #36 리뷰.
POST /ocr/receipt 가 판독값을 사진 SHA-256(= receipt_hash)으로 저장하고, POST /entries 가 앱이 보낸 ocr_* 대신
이 값과 입력 금액으로 다시 판정한다. 로그인 시도(3f1a9c7d2e84) 뒤에 잇는다.

Revision ID: c41d8e2a7f90
Revises: 3f1a9c7d2e84
Create Date: 2026-11-18 12:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'c41d8e2a7f90'
down_revision: Union[str, Sequence[str], None] = '3f1a9c7d2e84'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table('ocr_readings',
    sa.Column('receipt_hash', sa.String(length=66), nullable=False),
    sa.Column('readable', sa.Boolean(), nullable=False),
    sa.Column('amount', sa.BigInteger(), nullable=True),
    sa.Column('approval_no', sa.String(length=50), nullable=True),
    sa.Column('paid_at', sa.BigInteger(), nullable=True),
    sa.Column('approval_label_found', sa.Boolean(), nullable=False),
    sa.Column('low_confidence', sa.Boolean(), nullable=False),
    sa.Column('read_by', sa.BigInteger(), nullable=False),
    sa.Column('read_at', sa.DateTime(timezone=True), server_default=sa.text('(CURRENT_TIMESTAMP)'), nullable=False),
    sa.CheckConstraint('amount IS NULL OR amount >= 0', name='ck_ocr_readings_amount'),
    sa.ForeignKeyConstraint(['read_by'], ['users.id'], ondelete='RESTRICT'),
    sa.PrimaryKeyConstraint('receipt_hash')
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_table('ocr_readings')
