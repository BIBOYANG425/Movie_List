"""
Media Service — /media
───────────────────────
Day 1: Stubs with correct shapes.
Day 2: pg_trgm search + TMDB fallback.

Endpoints:
  GET  /media/search              — Fuzzy title search (pg_trgm)
  GET  /media/{media_id}          — Single item detail
  POST /media/create_stub         — User-submitted item (future manual entry)
"""
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.db.session import get_db

router = APIRouter()


# ── Pydantic schemas ──────────────────────────────────────────────────────────

class MediaItemResponse(BaseModel):
    id: str
    title: str
    release_year: int | None
    media_type: str
    attributes: dict
    is_verified: bool

    class Config:
        from_attributes = True


# ── Routes ────────────────────────────────────────────────────────────────────

@router.get("/search", response_model=list[MediaItemResponse])
def search_media(
    q: str = Query(..., min_length=1, description="Search query"),
    limit: int = Query(20, ge=1, le=50),
    offset: int = Query(0, ge=0),
    db: Session = Depends(get_db),
) -> list:
    """
    Fuzzy title search using pg_trgm similarity.

    Day 2 implementation will:
      1. Query DB with similarity() > 0.3 using the GiST index.
      2. If results < 3, fall back to TMDB API and cache results.
    """
    # TODO (Day 2): implement pg_trgm query
    return []


@router.get("/{media_id}", response_model=MediaItemResponse)
def get_media_item(media_id: UUID, db: Session = Depends(get_db)) -> MediaItemResponse:
    """
    Fetch a single media item by UUID.
    TODO (Day 2): query DB, raise 404 if not found.
    """
    from fastapi import HTTPException, status
    raise HTTPException(status_code=status.HTTP_501_NOT_IMPLEMENTED, detail="Coming in Day 2")
