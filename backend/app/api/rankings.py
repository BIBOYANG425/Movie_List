"""
Rankings Service — /rankings
─────────────────────────────
The core of the app. Delegates math to the Postgres function
insert_ranking_between() and the Python service ranking_math.py.

Day 1: Stubs with correct request/response shapes.
Day 4: Full implementation with ownership guards + DB writes.

Endpoints:
  GET   /rankings/user/{user_id}         — Fetch user's full ranked list (with filters)
  POST  /rankings                        — Rank an item for the first time
  PATCH /rankings/move                   — Move an already-ranked item
  DELETE /rankings/{ranking_id}          — Remove an item from the list
"""
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.db.session import get_db

router = APIRouter()


# ── Pydantic schemas ──────────────────────────────────────────────────────────

class RankingResponse(BaseModel):
    id: str
    media_item_id: str
    tier: str
    rank_position: float
    visual_score: float

    class Config:
        from_attributes = True


class CreateRankingRequest(BaseModel):
    media_id: str
    tier: str
    prev_ranking_id: str | None = None  # UUID of item directly above
    next_ranking_id: str | None = None  # UUID of item directly below


class MoveRankingRequest(BaseModel):
    media_id: str
    tier: str                           # Target tier (may differ from current)
    prev_ranking_id: str | None = None
    next_ranking_id: str | None = None


# ── Routes ────────────────────────────────────────────────────────────────────

@router.get("/user/{user_id}", response_model=list[RankingResponse])
def get_user_list(
    user_id: UUID,
    genre: str | None = Query(None, description="Filter by genre (JSONB containment)"),
    media_type: str | None = Query(None, description="Filter by media_type"),
    db: Session = Depends(get_db),
) -> list:
    """
    Return a user's full ranked list, sorted S→A→B→C→D then by rank_position ASC.

    Day 4 implementation will:
      1. JOIN user_rankings → media_items.
      2. Apply genre filter with JSONB @> operator.
      3. Apply media_type filter.
      4. ORDER BY tier CASE expression, rank_position ASC.
    """
    # TODO (Day 4): implement full query
    return []


@router.post("", response_model=RankingResponse, status_code=201)
def create_ranking(
    payload: CreateRankingRequest,
    db: Session = Depends(get_db),
) -> RankingResponse:
    """
    Rank a media item for the first time.

    Calls the Postgres function insert_ranking_between() which handles:
      - Fractional position calculation
      - Visual score interpolation
      - Automatic rebalance when gaps get too small

    TODO (Day 4): verify ownership, call DB function, return result.
    """
    from fastapi import HTTPException, status
    raise HTTPException(status_code=status.HTTP_501_NOT_IMPLEMENTED, detail="Coming in Day 4")


@router.patch("/move", response_model=RankingResponse)
def move_ranking(
    payload: MoveRankingRequest,
    db: Session = Depends(get_db),
) -> RankingResponse:
    """
    Move an existing ranking to a new position (possibly a different tier).

    Transaction:
      1. SELECT ... FOR UPDATE on neighbor rows (prevents race conditions).
      2. Call insert_ranking_between() for new position + score.
      3. Update the existing ranking row atomically.

    TODO (Day 4): implement with ownership guard.
    """
    from fastapi import HTTPException, status
    raise HTTPException(status_code=status.HTTP_501_NOT_IMPLEMENTED, detail="Coming in Day 4")


@router.delete("/{ranking_id}", status_code=204)
def delete_ranking(
    ranking_id: UUID,
    db: Session = Depends(get_db),
) -> None:
    """
    Remove a ranking. Only the owning user may do this.
    TODO (Day 4): verify ownership, delete row.
    """
    from fastapi import HTTPException, status
    raise HTTPException(status_code=status.HTTP_501_NOT_IMPLEMENTED, detail="Coming in Day 4")
