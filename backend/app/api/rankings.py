"""
Rankings API — /rankings
──────────────────────────
Endpoints:
  GET    /rankings/me                  — Current user's full ranked list
  POST   /rankings                    — Rank a media item for the first time (201)
  PATCH  /rankings/{ranking_id}/move  — Move a ranking to a new position
  DELETE /rankings/{ranking_id}       — Remove a ranking (204)
"""
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.db.models import User
from app.db.session import get_db
from app.deps.auth import get_current_user
from app.schemas.rankings import (
    CreateRankingRequest,
    MoveRankingRequest,
    RankingListItem,
)
from app.services.ranking_service import (
    DuplicateRankingError,
    RankingNotFoundError,
    create_ranking,
    delete_ranking,
    get_ranking_with_media,
    list_rankings,
    move_ranking,
)

router = APIRouter()


def _error(code: str, message: str) -> dict:
    """Standard error envelope."""
    return {"error": {"code": code, "message": message}}


# ── Routes ────────────────────────────────────────────────────────────────────


@router.get("/me", response_model=list[RankingListItem])
def get_my_rankings(
    tier: str | None = Query(None, description="Filter by tier (S/A/B/C/D)"),
    genre: str | None = Query(None, description="Filter by genre (JSONB containment)"),
    media_type: str | None = Query(None, description="Filter by media_type"),
    limit: int = Query(500, ge=1, le=1000),
    offset: int = Query(0, ge=0),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    """
    Return the authenticated user's ranked list, sorted S->A->B->C->D
    then by rank_position ASC within each tier.
    """
    return list_rankings(
        db,
        current_user.id,
        tier=tier,
        genre=genre,
        media_type=media_type,
        limit=limit,
        offset=offset,
    )


@router.post(
    "",
    response_model=RankingListItem,
    status_code=status.HTTP_201_CREATED,
)
def create_ranking_endpoint(
    payload: CreateRankingRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """
    Rank a media item for the first time.

    Delegates to the Postgres function insert_ranking_between() which handles
    fractional position calculation, score interpolation, and automatic rebalance.
    """
    try:
        ranking = create_ranking(db, current_user.id, payload)
    except DuplicateRankingError as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=_error("DUPLICATE_RANKING", str(exc)),
        ) from exc
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=_error("RANKING_CREATE_FAILED", str(exc)),
        ) from exc

    hydrated = get_ranking_with_media(db, ranking.id, current_user.id)
    if hydrated is None:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=_error("INTERNAL", "Failed to load created ranking"),
        )
    return hydrated


@router.patch("/{ranking_id}/move", response_model=RankingListItem)
def move_ranking_endpoint(
    ranking_id: UUID,
    payload: MoveRankingRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """
    Move an existing ranking to a new position (possibly a different tier).

    Uses row-level locking (SELECT ... FOR UPDATE) to prevent race conditions.
    """
    try:
        ranking = move_ranking(db, current_user.id, ranking_id, payload)
    except RankingNotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=_error("RANKING_NOT_FOUND", str(exc)),
        ) from exc
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=_error("RANKING_MOVE_FAILED", str(exc)),
        ) from exc

    hydrated = get_ranking_with_media(db, ranking.id, current_user.id)
    if hydrated is None:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=_error("INTERNAL", "Failed to load moved ranking"),
        )
    return hydrated


@router.delete("/{ranking_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_ranking_endpoint(
    ranking_id: UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Remove a ranking. Only the owning user may delete their own ranking."""
    deleted = delete_ranking(db, current_user.id, ranking_id)
    if not deleted:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=_error("RANKING_NOT_FOUND", f"Ranking {ranking_id} not found"),
        )
