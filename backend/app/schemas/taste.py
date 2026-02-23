"""
Taste compatibility request/response schemas.
"""
from uuid import UUID

from pydantic import BaseModel


class SharedMovieItem(BaseModel):
    """A movie both users have ranked, with tier comparison."""

    media_item_id: UUID
    media_title: str
    poster_url: str | None = None
    viewer_tier: str
    viewer_score: float
    target_tier: str
    target_score: float
    tier_difference: int  # 0 = same, positive = viewer rated higher


class TasteCompatibilityResponse(BaseModel):
    """Taste compatibility score between two users."""

    target_user_id: UUID
    target_username: str
    score: int  # 0-100
    shared_count: int
    agreements: int  # same-tier placements
    near_agreements: int  # ±1 tier
    disagreements: int  # ±2+ tiers
    top_shared: list[SharedMovieItem]  # best mutual movies (both S/A)
    biggest_divergences: list[SharedMovieItem]  # biggest disagreements


class SharedMovieListResponse(BaseModel):
    """Paginated list of shared movies."""

    movies: list[SharedMovieItem]
    total: int


class RankingComparisonItem(BaseModel):
    """A single item in a ranking comparison view."""

    media_item_id: UUID
    media_title: str
    poster_url: str | None = None
    viewer_tier: str | None = None
    viewer_score: float | None = None
    viewer_rank_position: float | None = None
    target_tier: str | None = None
    target_score: float | None = None
    target_rank_position: float | None = None
    is_shared: bool = False


class RankingComparisonResponse(BaseModel):
    """Full ranking comparison between two users."""

    target_user_id: UUID
    target_username: str
    viewer_total: int
    target_total: int
    shared_count: int
    items: list[RankingComparisonItem]
