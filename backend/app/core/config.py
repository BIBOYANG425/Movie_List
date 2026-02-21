import json
from typing import Union

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


def _parse_cors_origins(v: Union[str, list[str]]) -> list[str]:
    """Parse CORS_ORIGINS from env: JSON array, comma-separated, or single URL."""
    if isinstance(v, list):
        return [str(x).strip() for x in v if x]
    s = str(v).strip()
    if not s:
        return []
    if s.startswith("["):
        try:
            return [x.strip() for x in json.loads(s) if x]
        except json.JSONDecodeError:
            pass
    return [x.strip() for x in s.split(",") if x.strip()]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # ── Database ──────────────────────────────────────────────────────────────
    DATABASE_URL: str = "postgresql://marquee:marquee@localhost:5432/marquee"

    # ── JWT ───────────────────────────────────────────────────────────────────
    SECRET_KEY: str = "changeme-replace-with-a-long-random-string-in-production"
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 60 * 24 * 7  # 7 days

    # ── External APIs ─────────────────────────────────────────────────────────
    # If empty, TMDB fallback is disabled and media search stays DB-only.
    TMDB_API_KEY: str = ""
    GEMINI_API_KEY: str = ""

    # ── Server ────────────────────────────────────────────────────────────────
    PORT: int = 8000  # App Runner / Cloud Run inject $PORT

    # ── CORS ──────────────────────────────────────────────────────────────────
    # Env: comma-separated (https://a.com,https://b.com) or JSON ["https://a.com"]
    CORS_ORIGINS: list[str] = [
        "http://localhost:5173",
        "http://localhost:3000",
        "http://localhost:8080",
    ]

    @field_validator("CORS_ORIGINS", mode="before")
    @classmethod
    def parse_cors(cls, v: object) -> list[str]:
        if v is None:
            return []
        return _parse_cors_origins(v)

    # ── App ───────────────────────────────────────────────────────────────────
    APP_ENV: str = "development"  # development | production
    ENABLE_DOCS: bool = True  # Set to False to disable /docs in production

    @property
    def is_dev(self) -> bool:
        return self.APP_ENV == "development"


settings = Settings()
