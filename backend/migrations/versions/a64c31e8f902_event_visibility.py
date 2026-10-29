"""Persist a per-event privacy upper bound without changing legacy snapshot identity."""
from alembic import op
import sqlalchemy as sa

revision = "a64c31e8f902"
down_revision = "49b12db0c9a1"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("busy_events", sa.Column("visibility", sa.String(length=10), nullable=True))
    # A historical event used its source's upload level. Materialize it now so a
    # later increase of that source cannot implicitly widen the event's bound.
    op.execute(sa.text("UPDATE busy_events SET visibility = (SELECT upload_level FROM sources WHERE sources.id = busy_events.source_id)"))


def downgrade():
    op.drop_column("busy_events", "visibility")
