from pydantic_settings import BaseSettings, SettingsConfigDict


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
    TMDB_API_KEY: str = ""
    GEMINI_API_KEY: str = ""

    # ── CORS ──────────────────────────────────────────────────────────────────
    # Frontend dev server + production origin
    CORS_ORIGINS: list[str] = [
        "http://localhost:5173",  # Vite dev
        "http://localhost:3000",
        "http://localhost:8080",
    ]

    # ── App ───────────────────────────────────────────────────────────────────
    APP_ENV: str = "development"  # development | production

    @property
    def is_dev(self) -> bool:
        return self.APP_ENV == "development"


settings = Settings()
