"""
Social Service — /social
─────────────────────────
Follow graph + activity feed.

Day 1: Stubs.
Day 5+: Full implementation.

Endpoints:
  POST   /social/follow/{user_id}     — Follow a user
  DELETE /social/follow/{user_id}     — Unfollow
  GET    /social/feed                 — Recent rankings from people you follow
  GET    /social/leaderboard          — Top-ranked items across all users
"""
from uuid import UUID

from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.db.session import get_db

router = APIRouter()


# ── Pydantic schemas ──────────────────────────────────────────────────────────

class FeedItem(BaseModel):
    user_id: str
    username: str
    media_title: str
    tier: str
    visual_score: float
    ranked_at: str


# ── Routes ────────────────────────────────────────────────────────────────────

@router.post("/follow/{user_id}", status_code=201)
def follow_user(user_id: UUID, db: Session = Depends(get_db)) -> dict:
    """
    Follow a user. Inserts a Follow row.
    TODO (Day 5): auth guard + duplicate check.
    """
    from fastapi import HTTPException, status
    raise HTTPException(status_code=status.HTTP_501_NOT_IMPLEMENTED, detail="Coming in Day 5")


@router.delete("/follow/{user_id}", status_code=204)
def unfollow_user(user_id: UUID, db: Session = Depends(get_db)) -> None:
    """
    Unfollow a user. Deletes the Follow row.
    TODO (Day 5): auth guard.
    """
    from fastapi import HTTPException, status
    raise HTTPException(status_code=status.HTTP_501_NOT_IMPLEMENTED, detail="Coming in Day 5")


@router.get("/feed", response_model=list[FeedItem])
def get_feed(db: Session = Depends(get_db)) -> list:
    """
    Return the 50 most recent rankings from users you follow.

    Strategy (Day 5): fan-out on read — query user_rankings JOIN users
    WHERE user_id IN (SELECT following_id FROM follows WHERE follower_id = me)
    ORDER BY created_at DESC LIMIT 50.
    """
    return []


@router.get("/leaderboard")
def get_leaderboard(db: Session = Depends(get_db)) -> list:
    """
    Items with the most S-tier rankings across all users.
    TODO (Day 5): aggregate query.
    """
    return []
