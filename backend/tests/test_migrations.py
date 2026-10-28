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
