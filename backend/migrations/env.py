from alembic import context
from app.config import Settings
from app.database import Base, make_engine
from app import models

target_metadata = Base.metadata

if context.is_offline_mode():
    context.configure(url=Settings.from_env().database_url, target_metadata=target_metadata,
                      literal_binds=True, dialect_opts={"paramstyle": "named"})
    with context.begin_transaction():
        context.run_migrations()
else:
    engine = make_engine(Settings.from_env().database_url)
    with engine.connect() as connection:
        # SQLite batch ALTER rebuilds users, which other tables reference. Disable
        # FK enforcement before the migration transaction and check every FK
        # before restoring it. PostgreSQL keeps its transactional ALTER behavior.
        sqlite = connection.dialect.name == "sqlite"
        if sqlite:
            connection.exec_driver_sql("PRAGMA foreign_keys=OFF")
            connection.commit()
        context.configure(connection=connection, target_metadata=target_metadata)
        try:
            with context.begin_transaction():
                context.run_migrations()
            if sqlite:
                violations = connection.exec_driver_sql("PRAGMA foreign_key_check").fetchall()
                if violations:
                    raise RuntimeError("Migration left invalid foreign key references")
                connection.commit()
        finally:
            if sqlite:
                if connection.in_transaction():
                    connection.rollback()
                connection.exec_driver_sql("PRAGMA foreign_keys=ON")
                connection.commit()
