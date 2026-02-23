"""
Discovery API — /discover
──────────────────────────
Endpoints:
  GET  /discover/recommendations   — Friend-based movie picks
  GET  /discover/trending          — Trending in your network
  GET  /discover/feed              — Combined discovery feed
  GET  /discover/genres/{user_id}  — Genre taste profile
  GET  /discover/genres/compare/{target_id} — Genre comparison
"""
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.db.models import User
from app.db.session import get_db
from app.deps.auth import get_current_user
from app.schemas.discovery import (
    DiscoveryFeedResponse,
    FriendRecommendation,
    GenreComparisonResponse,
    GenreProfileResponse,
    TrendingMovie,
)
from app.services.discovery_service import (
    get_friend_recommendations,
    get_genre_comparison,
    get_genre_profile,
    get_trending_among_friends,
)

router = APIRouter()


@router.get("/recommendations", response_model=list[FriendRecommendation])
def recommendations(
    limit: int = Query(20, ge=1, le=50),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[FriendRecommendation]:
    """Movies your friends love (S/A tier) that you haven't seen yet."""
    results = get_friend_recommendations(db, current_user.id, limit=limit)
    return [
        FriendRecommendation(
            tmdb_id=r["media_item_id"],
            title=r["title"],
            poster_url=r.get("poster_url"),
            year=r.get("year"),
            genres=r.get("genres", []),
            avg_tier=r["avg_tier"],
            avg_tier_numeric=r["avg_tier_numeric"],
            friend_count=r["friend_count"],
            friend_avatars=r.get("friend_avatars", []),
            friend_usernames=r.get("friend_usernames", []),
            top_tier=r["top_tier"],
        )
        for r in results
    ]


@router.get("/trending", response_model=list[TrendingMovie])
def trending(
    limit: int = Query(15, ge=1, le=50),
    days: int = Query(30, ge=1, le=90),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[TrendingMovie]:
    """Movies trending in your friend network (last N days)."""
    results = get_trending_among_friends(db, current_user.id, limit=limit, days=days)
    return [
        TrendingMovie(
            tmdb_id=r["media_item_id"],
            title=r["title"],
            poster_url=r.get("poster_url"),
            year=r.get("year"),
            genres=r.get("genres", []),
            ranker_count=r["ranker_count"],
            avg_tier=r["avg_tier"],
            avg_tier_numeric=r["avg_tier_numeric"],
            recent_rankers=r.get("recent_rankers", []),
        )
        for r in results
    ]


@router.get("/feed", response_model=DiscoveryFeedResponse)
def discovery_feed(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> DiscoveryFeedResponse:
    """Combined discovery feed with recommendations + trending."""
    recs = get_friend_recommendations(db, current_user.id, limit=10)
    trend = get_trending_among_friends(db, current_user.id, limit=8)

    return DiscoveryFeedResponse(
        recommendations=[
            FriendRecommendation(
                tmdb_id=r["media_item_id"],
                title=r["title"],
                poster_url=r.get("poster_url"),
                year=r.get("year"),
                genres=r.get("genres", []),
                avg_tier=r["avg_tier"],
                avg_tier_numeric=r["avg_tier_numeric"],
                friend_count=r["friend_count"],
                friend_avatars=r.get("friend_avatars", []),
                friend_usernames=r.get("friend_usernames", []),
                top_tier=r["top_tier"],
            )
            for r in recs
        ],
        trending=[
            TrendingMovie(
                tmdb_id=t["media_item_id"],
                title=t["title"],
                poster_url=t.get("poster_url"),
                year=t.get("year"),
                genres=t.get("genres", []),
                ranker_count=t["ranker_count"],
                avg_tier=t["avg_tier"],
                avg_tier_numeric=t["avg_tier_numeric"],
                recent_rankers=t.get("recent_rankers", []),
            )
            for t in trend
        ],
    )


@router.get("/genres/{user_id}", response_model=GenreProfileResponse)
def genre_profile(
    user_id: UUID,
    db: Session = Depends(get_db),
) -> GenreProfileResponse:
    """Genre taste profile for a user."""
    result = get_genre_profile(db, user_id)
    return GenreProfileResponse(**result)


@router.get("/genres/compare/{target_id}", response_model=GenreComparisonResponse)
def genre_comparison(
    target_id: UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> GenreComparisonResponse:
    """Compare genre tastes between current user and target."""
    result = get_genre_comparison(db, current_user.id, target_id)
    return GenreComparisonResponse(**result)
