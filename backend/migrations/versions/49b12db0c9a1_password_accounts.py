"""Invite-only password accounts and authentication provider metadata.

Revision ID: 49b12db0c9a1
Revises: 0380e9c4211c
"""
from alembic import op
import sqlalchemy as sa

revision = "49b12db0c9a1"
down_revision = "0380e9c4211c"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("users") as batch:
        batch.alter_column("apple_sub", existing_type=sa.String(255), nullable=True)
    op.create_table("password_credentials",
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("username", sa.String(32), nullable=False, unique=True),
        sa.Column("password_hash", sa.String(512), nullable=False))
    op.create_table("registration_invites",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("digest", sa.String(64), nullable=False, unique=True),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked", sa.Boolean(), nullable=False),
        sa.Column("max_uses", sa.Integer(), nullable=False),
        sa.Column("uses", sa.Integer(), nullable=False))
    op.add_column("sessions", sa.Column("auth_provider", sa.String(20), nullable=False, server_default="apple"))


def downgrade():
    connection = op.get_bind()
    if (connection.execute(sa.text("SELECT 1 FROM password_credentials LIMIT 1")).first()
        or connection.execute(sa.text("SELECT 1 FROM users WHERE apple_sub IS NULL LIMIT 1")).first()):
        raise RuntimeError("Cannot downgrade while password accounts exist; preserve users and restore the application release instead")
    op.drop_column("sessions", "auth_provider")
    op.drop_table("registration_invites")
    op.drop_table("password_credentials")
    with op.batch_alter_table("users") as batch:
        batch.alter_column("apple_sub", existing_type=sa.String(255), nullable=False)
