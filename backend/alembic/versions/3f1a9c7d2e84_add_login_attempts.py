"""add_login_attempts

로그인 시도(LoginAttempt) 테이블 추가 — PRD v0.15 §9.1, §9.2.
학번별 연속 실패 5회면 잠근다. 학생 서버가 여러 대여도 횟수가 합쳐지도록 DB 에 둔다.
#78(8257fdacf035, 알림)이 먼저 머지되어 그 뒤에 잇는다.
학생 서버의 읽기 전용 계정에는 이 마이그레이션 뒤에 이 테이블 쓰기 권한을 준다 (docs/SERVER_ENV.md §5).

Revision ID: 3f1a9c7d2e84
Revises: 8257fdacf035
Create Date: 2026-11-09 12:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '3f1a9c7d2e84'
down_revision: Union[str, Sequence[str], None] = '8257fdacf035'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table('login_attempts',
    sa.Column('student_no', sa.String(length=20), nullable=False),
    sa.Column('failed_count', sa.Integer(), server_default=sa.text('0'), nullable=False),
    sa.Column('last_attempt_at', sa.BigInteger(), nullable=False),
    sa.Column('locked_until', sa.BigInteger(), nullable=True),
    sa.CheckConstraint('failed_count >= 0', name='ck_login_attempts_failed_count'),
    sa.PrimaryKeyConstraint('student_no')
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_table('login_attempts')
