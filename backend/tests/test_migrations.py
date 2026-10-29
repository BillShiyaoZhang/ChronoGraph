from pathlib import Path
from alembic import command
from alembic.config import Config
from sqlalchemy import inspect
from app.database import Base, make_engine


def test_initial_migration_is_repeatable_and_matches_metadata(tmp_path, monkeypatch):
    from alembic.autogenerate import compare_metadata
    from alembic.migration import MigrationContext
    url = "sqlite+pysqlite:///" + str(tmp_path / "migration.db")
    monkeypatch.setenv("DATABASE_URL", url)
    config = Config("alembic.ini")
    command.upgrade(config, "head")
    command.upgrade(config, "head")
    engine = make_engine(url)
    with engine.connect() as connection:
        assert "busy_events" in inspect(connection).get_table_names()
        differences = compare_metadata(MigrationContext.configure(connection), Base.metadata)
        assert differences == []
    command.downgrade(config, "base")
    assert inspect(engine).get_table_names() == ["alembic_version"]
    engine.dispose()


def test_password_migration_preserves_populated_apple_accounts(tmp_path, monkeypatch):
    import sqlalchemy as sa
    from uuid import uuid4
    from app.models import now
    url = "sqlite+pysqlite:///" + str(tmp_path / "populated.db")
    monkeypatch.setenv("DATABASE_URL", url)
    config = Config("alembic.ini")
    command.upgrade(config, "0380e9c4211c")
    engine = make_engine(url)
    user, device, source = [str(uuid4()) for _ in range(3)]
    with engine.begin() as connection:
        connection.execute(sa.text("INSERT INTO users (id,apple_sub,display_name,deleted,created_at) VALUES (:id,'legacy-apple','Legacy',0,:instant)"), {"id": user, "instant": now()})
        connection.execute(sa.text("INSERT INTO devices (id,user_id,name,created_at) VALUES (:id,:user,'Legacy iPhone',:instant)"), {"id": device, "user": user, "instant": now()})
        connection.execute(sa.text("INSERT INTO sessions (digest,user_id,device_id,expires_at) VALUES (:digest,:user,:device,:instant)"), {"digest": "a" * 64, "user": user, "device": device, "instant": now()})
        connection.execute(sa.text("INSERT INTO sources (id,owner_id,device_id,name,upload_level,generation) VALUES (:id,:user,:device,'Legacy calendar','opaque',0)"), {"id": source, "user": user, "device": device})
    command.upgrade(config, "head")
    with engine.connect() as connection:
        assert connection.execute(sa.text("SELECT apple_sub FROM users WHERE id=:id"), {"id": user}).scalar_one() == "legacy-apple"
        assert connection.execute(sa.text("SELECT auth_provider FROM sessions")).scalar_one() == "apple"
        assert connection.execute(sa.text("SELECT owner_id FROM sources")).scalar_one() == user
        assert connection.exec_driver_sql("PRAGMA foreign_key_check").all() == []
    command.downgrade(config, "0380e9c4211c")
    command.upgrade(config, "head")
    with engine.begin() as connection:
        local = str(uuid4())
        connection.execute(sa.text("INSERT INTO users (id,apple_sub,display_name,deleted,created_at) VALUES (:id,NULL,'Local',0,:instant)"), {"id": local, "instant": now()})
    import pytest
    with pytest.raises(RuntimeError, match="Cannot downgrade while password accounts exist"):
        command.downgrade(config, "0380e9c4211c")
    with engine.connect() as connection:
        assert connection.execute(sa.text("SELECT id FROM users WHERE id=:id"), {"id": local}).scalar_one() == local
        assert "password_credentials" in inspect(connection).get_table_names()
    engine.dispose()


def test_event_visibility_migration_backfills_each_source_without_losing_snapshots(tmp_path, monkeypatch):
    import sqlalchemy as sa
    from datetime import timedelta
    from uuid import uuid4
    from app.models import now
    url = "sqlite+pysqlite:///" + str(tmp_path / "event-visibility.db")
    monkeypatch.setenv("DATABASE_URL", url)
    config = Config("alembic.ini")
    command.upgrade(config, "49b12db0c9a1")
    engine = make_engine(url)
    owner, device = str(uuid4()), str(uuid4())
    instant = now()
    sources = {level: str(uuid4()) for level in ("opaque", "partial", "full")}
    with engine.begin() as connection:
        connection.execute(sa.text("INSERT INTO users (id,apple_sub,display_name,deleted,created_at) VALUES (:id,'migration-apple','Synthetic',0,:instant)"), {"id": owner, "instant": instant})
        connection.execute(sa.text("INSERT INTO devices (id,user_id,name,created_at) VALUES (:id,:owner,'Synthetic',:instant)"), {"id": device, "owner": owner, "instant": instant})
        for level, source_id in sources.items():
            connection.execute(sa.text("INSERT INTO sources (id,owner_id,device_id,name,upload_level,generation,snapshot_id,snapshot_digest) VALUES (:id,:owner,:device,'Synthetic',:level,7,:snapshot,:digest)"),
                               {"id": source_id, "owner": owner, "device": device, "level": level, "snapshot": str(uuid4()), "digest": "b" * 64})
            connection.execute(sa.text("INSERT INTO busy_events (source_id,id,start,end,is_all_day,timezone,availability,title,location,notes) VALUES (:source,:id,:start,:end,0,'UTC','busy',:title,:location,:notes)"),
                               {"source": source_id, "id": str(uuid4()), "start": instant, "end": instant + timedelta(hours=1),
                                "title": "Synthetic title" if level != "opaque" else None,
                                "location": "Synthetic location" if level == "full" else None,
                                "notes": "Synthetic notes" if level == "full" else None})
    command.upgrade(config, "head")
    command.upgrade(config, "head")
    with engine.connect() as connection:
        rows = connection.execute(sa.text("SELECT source_id,visibility,title,notes FROM busy_events")).all()
        assert {row.source_id: row.visibility for row in rows} == {value: key for key, value in sources.items()}
        assert next(row for row in rows if row.visibility == "full").notes == "Synthetic notes"
        assert connection.execute(sa.text("SELECT count(*) FROM sources WHERE generation=7 AND snapshot_digest=:digest"), {"digest": "b" * 64}).scalar_one() == 3
        assert connection.exec_driver_sql("PRAGMA foreign_key_check").all() == []
    command.downgrade(config, "49b12db0c9a1")
    assert "visibility" not in {column["name"] for column in inspect(engine).get_columns("busy_events")}
    command.upgrade(config, "head")
    with engine.connect() as connection:
        assert connection.execute(sa.text("SELECT count(*) FROM busy_events WHERE visibility IS NOT NULL")).scalar_one() == 3
    engine.dispose()
