"""
Marquee API — FastAPI application entry point.

Routers are registered here. Each service lives in app/api/.
"""
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import settings
from app.api import auth, media, rankings, social
from app.api import reviews as reviews_api
from app.api import taste as taste_api
from app.api import shared_watchlists as shared_watchlists_api

app = FastAPI(
    title="Marquee API",
    description="Backend for the Marquee movie ranking app.",
    version="0.2.0",
    docs_url="/docs" if settings.ENABLE_DOCS else None,
    redoc_url="/redoc" if settings.ENABLE_DOCS else None,
)

# ── CORS ──────────────────────────────────────────────────────────────────────
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Routers ───────────────────────────────────────────────────────────────────
app.include_router(auth.router,     prefix="/auth",     tags=["auth"])
app.include_router(media.router,    prefix="/media",    tags=["media"])
app.include_router(rankings.router, prefix="/rankings", tags=["rankings"])
app.include_router(social.router,   prefix="/social",   tags=["social"])
# Phase 1 social features
app.include_router(reviews_api.router,            prefix="/reviews",           tags=["reviews"])
app.include_router(taste_api.router,              prefix="/taste",             tags=["taste"])
app.include_router(shared_watchlists_api.router,  prefix="/watchlists/shared", tags=["shared-watchlists"])


# ── Health check ──────────────────────────────────────────────────────────────
@app.get("/health", tags=["system"])
def health_check() -> dict:
    """Liveness probe. Returns 200 when the server is up."""
    return {"status": "ok", "version": "0.1.0", "env": settings.APP_ENV}
