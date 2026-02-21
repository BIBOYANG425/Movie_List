"""
Media Service — /media
───────────────────────
Endpoints:
  GET  /media/search              — Fuzzy title search (pg_trgm)
  GET  /media/{media_id}          — Single item detail
  POST /media/create_stub         — User-submitted item (manual entry)
"""
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.db.models import User
from app.db.session import get_db
from app.deps.auth import get_current_user
from app.schemas.media import (
    CreateMediaStubRequest,
    MediaItemDetailResponse,
    MediaSearchResponse,
    MediaTypeEnum,
    SearchMeta,
)
from app.services.media_service import (
    DuplicateManualMediaError,
    InvalidMediaPayloadError,
    create_manual_stub,
    get_media_by_id,
    map_media_response,
    search_media_hybrid,
)

router = APIRouter()


def _error(code: str, message: str) -> dict:
    """Standard error envelope."""
    return {"error": {"code": code, "message": message}}


# ── Routes ────────────────────────────────────────────────────────────────────

@router.get("/search", response_model=MediaSearchResponse)
async def search_media(
    q: str = Query(..., min_length=1, description="Search query"),
    media_type: MediaTypeEnum | None = Query(None, description="Filter by media type"),
    limit: int = Query(20, ge=1, le=50),
    offset: int = Query(0, ge=0),
    db: Session = Depends(get_db),
) -> MediaSearchResponse:
    """
    Hybrid media search:
      1. Query local DB with pg_trgm similarity + ILIKE.
      2. If local recall is low, call TMDB and cache upsert movie hits.
    """
    try:
        rows, source = await search_media_hybrid(
            db,
            q=q,
            media_type=media_type,
            limit=limit,
            offset=offset,
        )
    except InvalidMediaPayloadError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=_error("MEDIA_SEARCH_FAILED", str(exc)),
        ) from exc

    items = [map_media_response(row) for row in rows]
    return MediaSearchResponse(
        items=items,
        meta=SearchMeta(count=len(items), source=source),
    )


@router.get("/{media_id}", response_model=MediaItemDetailResponse)
def get_media_item(media_id: UUID, db: Session = Depends(get_db)) -> MediaItemDetailResponse:
    """
    Fetch a single media item by UUID.
    """
    row = get_media_by_id(db, media_id)
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=_error("MEDIA_NOT_FOUND", f"Media item {media_id} not found"),
        )
    return map_media_response(row)


@router.post(
    "/create_stub",
    response_model=MediaItemDetailResponse,
    status_code=status.HTTP_201_CREATED,
)
def create_stub(
    payload: CreateMediaStubRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> MediaItemDetailResponse:
    """Create a user-submitted manual media entry (PLAY or MOVIE)."""
    try:
        row = create_manual_stub(db, current_user.id, payload)
    except InvalidMediaPayloadError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=_error("INVALID_MEDIA_PAYLOAD", str(exc)),
        ) from exc
    except DuplicateManualMediaError as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=_error("MEDIA_ALREADY_EXISTS", str(exc)),
        ) from exc

    return map_media_response(row)
