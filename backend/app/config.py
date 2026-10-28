from dataclasses import dataclass
import os


@dataclass(frozen=True)
class Settings:
    database_url: str = "postgresql+psycopg://chronograph@db/chronograph"
    apple_audience: str = "com.shiyao-zhang.ChronoGraph"
    public_base_url: str = "https://localhost"
    session_ttl_days: int = 30
    source_stale_hours: int = 24
    max_snapshot_events: int = 20_000
    max_snapshot_days: int = 180

    @classmethod
    def from_env(cls):
        return cls(
            database_url=os.getenv("DATABASE_URL", cls.database_url),
            apple_audience=os.getenv("APPLE_AUDIENCE", cls.apple_audience),
            public_base_url=os.getenv("PUBLIC_BASE_URL", cls.public_base_url).rstrip("/"),
            session_ttl_days=int(os.getenv("SESSION_TTL_DAYS", "30")),
            source_stale_hours=int(os.getenv("SOURCE_STALE_HOURS", "24")),
        )
